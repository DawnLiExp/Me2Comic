//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation
import UserNotifications

// MARK: - Processing Parameters

/// Container for image processing configuration
struct ProcessingParameters {
    let widthThreshold: Int /// Width threshold for splitting images
    let resizeHeight: Int /// Target height for resizing
    let quality: Int /// Output quality (1-100)
    let threadCount: Int /// Concurrent threads (1-6)
    let unsharpRadius: Float /// Unsharp mask parameters
    let unsharpSigma: Float
    let unsharpAmount: Float
    let unsharpThreshold: Float
    let batchSize: Int /// Images per batch (1-1000)
    let useGrayColorspace: Bool /// Grayscale conversion flag
}

// MARK: - Auto Calculation Protocol and Implementation

/// Protocol for calculating auto-allocated parameters.
protocol AutoCalculatable {
    func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int)
    func calculateAutoParameters(tasks: [ImageProcessingTask]) -> (threadCount: Int, batchSize: Int)
}

/// Calculates auto-allocated thread count and batch size based on total image count.
struct AutoCalculator: AutoCalculatable {
    /// Task weight definitions for single and double page images.
    struct TaskWeight {
        static let singlePage: Double = 1.0
        static let doublePage: Double = 2.2  // Estimated processing time for double page relative to single page
    }

    /// Calculates auto-allocated thread count and batch size based on total image count.
    /// This method is for backward compatibility or when detailed task info is unavailable.
    /// - Parameter totalImageCount: The total number of images to process.
    /// - Returns: A tuple containing the calculated thread count and batch size.
    func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        // Estimate total weight based on a mixed average (e.g., 1.5 times total count)
        let estimatedWeight = Double(totalImageCount) * 1.5
        let threadCount = calculateThreadCountByWeight(estimatedWeight)
        let batchSize = max(1, min(1000, Int(ceil(Double(totalImageCount) / Double(threadCount)))))
        return (threadCount: threadCount, batchSize: batchSize)
    }

    /// Calculates auto-allocated thread count and batch size based on detailed image processing tasks.
    /// This method considers the processing weight of each task (single vs. double page).
    /// - Parameter tasks: An array of `ImageProcessingTask` objects.
    /// - Returns: A tuple containing the calculated thread count and an estimated batch size.
    func calculateAutoParameters(tasks: [ImageProcessingTask]) -> (threadCount: Int, batchSize: Int) {
        // Calculate total processing weight from all tasks
        let totalWeight = tasks.reduce(0.0) { sum, task in
            // Safely unwrap requiresCropping, defaulting to false if nil
            sum + (task.requiresCropping ?? false ? TaskWeight.doublePage : TaskWeight.singlePage)
        }

        // Determine effective thread count based on total processing weight
        let effectiveThreadCount = calculateThreadCountByWeight(totalWeight)

        // Estimate batch size for compatibility with existing batching logic
        // The actual batching will be done by weight-based splitting
        let estimatedBatchSize = max(1, min(1000, Int(ceil(totalWeight / Double(effectiveThreadCount)))))

        return (threadCount: effectiveThreadCount, batchSize: estimatedBatchSize)
    }

    /// Determines the optimal thread count based on the total processing weight.
    /// - Parameter totalWeight: The sum of processing weights for all tasks.
    /// - Returns: The calculated effective thread count.
    private func calculateThreadCountByWeight(_ totalWeight: Double) -> Int {
        let maxThreadCount = 6
        var effectiveThreadCount: Int

        // Adjust thread count based on total processing weight to better utilize resources
        if totalWeight < 15.0 {  // Equivalent to approx. 10-15 single-page images
            effectiveThreadCount = 1
        } else if totalWeight <= 75.0 {  // Equivalent to approx. 50-75 single-page images
            effectiveThreadCount = 1 + Int(ceil((totalWeight - 15.0) / 30.0))
            effectiveThreadCount = min(3, effectiveThreadCount)
        } else if totalWeight <= 450.0 {  // Equivalent to approx. 300-450 single-page images
            effectiveThreadCount = 4 + Int(ceil((totalWeight - 75.0) / 75.0))
            effectiveThreadCount = min(maxThreadCount, effectiveThreadCount)
        } else {
            effectiveThreadCount = maxThreadCount
        }

        // Ensure thread count is within valid range [1, maxThreadCount]
        return max(1, min(maxThreadCount, effectiveThreadCount))
    }
}

/// Manages the image processing workflow, including parameter validation, file scanning, and batch processing.
class ImageProcessor: ObservableObject {
    /// Path to GraphicsMagick executable
    private var gmPath: String = ""

    /// Operation queue for batch processing
    private let processingQueue = OperationQueue()

    /// Concurrent dispatch queue for processing operations
    private let processingDispatchQueue = DispatchQueue(
        label: "me2.comic.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Total number of images processed
    private var totalImagesProcessed: Int = 0
    /// Timestamp when processing started
    private var processingStartTime: Date?

    /// Thread-safe queue for results collection
    private let resultsQueue = DispatchQueue(label: "me2.comic.me2comic.results")
    /// List of files that failed processing.
    private var allFailedFiles: [String] = []

    // UI state
    /// Indicates if processing is currently active
    @Published var isProcessing: Bool = false
    /// Log messages for display in the UI
    @Published var logMessages: [String] = [] {
        didSet {
            // Keep last 100 log messages
            if logMessages.count > 100 {
                logMessages.removeFirst(logMessages.count - 100)
            }
        }
    }

    /// Stops all active processing tasks.
    func stopProcessing() {
        #if DEBUG
            print("ImageProcessor: stopProcessing called. Cancelling all operations.")
        #endif
        processingQueue.cancelAllOperations()
        DispatchQueue.main.async {
            self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
            self.isProcessing = false
        }
    }

    /// Aggregates batch processing results
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) {
        resultsQueue.async {
            self.totalImagesProcessed += processedCount
            self.allFailedFiles.append(contentsOf: failedFiles)
        }
    }

    /// Splits image processing tasks into batches
    /// This method is for simple quantity-based splitting.
    private func splitIntoBatches(_ tasks: [ImageProcessingTask], batchSize: Int) -> [[ImageProcessingTask]] {
        guard batchSize > 0 else { return [] }
        guard !tasks.isEmpty else { return [] }
        var result: [[ImageProcessingTask]] = []
        var currentBatch: [ImageProcessingTask] = []

        result.reserveCapacity(tasks.count / batchSize + 1)
        currentBatch.reserveCapacity(batchSize)

        for task in tasks {
            currentBatch.append(task)
            if currentBatch.count >= batchSize {
                result.append(currentBatch)
                currentBatch = []
                currentBatch.reserveCapacity(batchSize)
            }
        }

        if !currentBatch.isEmpty {
            result.append(currentBatch)
        }

        return result
    }

    /// Splits image processing tasks into batches based on their processing weight.
    /// Aims to create batches with roughly equal total processing weight.
    /// - Parameters:
    ///   - tasks: All image processing tasks to be batched.
    ///   - targetThreadCount: The number of threads that will process these batches.
    /// - Returns: An array of arrays, where each inner array is a batch of tasks.
    private func splitTasksByWeight(_ tasks: [ImageProcessingTask], targetThreadCount: Int) -> [[ImageProcessingTask]] {
        guard !tasks.isEmpty else { return [] }
        
        // Calculate total processing weight for all tasks
        let totalWeight = tasks.reduce(0.0) { sum, task in
            // Safely unwrap requiresCropping, defaulting to false if nil
            sum + (task.requiresCropping ?? false ? AutoCalculator.TaskWeight.doublePage : AutoCalculator.TaskWeight.singlePage)
        }
        
        // Calculate the ideal target weight for each batch to ensure balanced distribution
        let targetWeightPerBatch = totalWeight / Double(targetThreadCount)
        
        var batches: [[ImageProcessingTask]] = []
        var currentBatch: [ImageProcessingTask] = []
        var currentWeight: Double = 0.0
        
        for task in tasks {
            // Safely unwrap requiresCropping, defaulting to false if nil
            let taskWeight = task.requiresCropping ?? false ? AutoCalculator.TaskWeight.doublePage : AutoCalculator.TaskWeight.singlePage
            
            // If adding the current task significantly exceeds the target batch weight,
            // and the current batch is not empty, finalize the current batch and start a new one.
            // The 1.2 factor allows for some flexibility to avoid creating too many small batches.
            if currentWeight + taskWeight > targetWeightPerBatch * 1.2 && !currentBatch.isEmpty {
                batches.append(currentBatch)
                currentBatch = [task]
                currentWeight = taskWeight
            } else {
                currentBatch.append(task)
                currentWeight += taskWeight
            }
        }
        
        // Add the last batch if it contains any tasks
        if !currentBatch.isEmpty {
            batches.append(currentBatch)
        }
        
        // If the number of created batches is less than the target thread count,
        // attempt to redistribute by splitting larger batches to better utilize threads.
        if batches.count < targetThreadCount {
            return redistributeBatches(batches, targetThreadCount: targetThreadCount)
        }
        
        return batches
    }

    /// Redistributes existing batches to achieve a number closer to the target thread count.
    /// This is done by splitting the largest batches until the target count is met or no more splits are possible.
    /// - Parameters:
    ///   - batches: The initial array of task batches.
    ///   - targetThreadCount: The desired number of batches (typically equal to thread count).
    /// - Returns: A new array of batches after redistribution.
    private func redistributeBatches(_ batches: [[ImageProcessingTask]], targetThreadCount: Int) -> [[ImageProcessingTask]] {
        guard batches.count < targetThreadCount else { return batches }
        
        var result = batches
        
        // Continue splitting the largest batch until the desired number of batches is reached
        // or no batch can be split further (i.e., all batches have only one task).
        while result.count < targetThreadCount {
            // Find the index of the batch with the maximum total weight
            let maxBatchIndex = result.enumerated().max { a, b in
                // Safely unwrap requiresCropping, defaulting to false if nil
                let weightA = a.element.reduce(0.0) { sum, task in
                    sum + (task.requiresCropping ?? false ? AutoCalculator.TaskWeight.doublePage : AutoCalculator.TaskWeight.singlePage)
                }
                let weightB = b.element.reduce(0.0) { sum, task in
                    sum + (task.requiresCropping ?? false ? AutoCalculator.TaskWeight.doublePage : AutoCalculator.TaskWeight.singlePage)
                }
                return weightA < weightB
            }?.offset
            
            // If no suitable batch is found (e.g., all batches have only one task), break the loop.
            guard let maxIndex = maxBatchIndex, result[maxIndex].count > 1 else {
                break
            }
            
            // Split the largest batch into two roughly equal halves.
            let batchToSplit = result[maxIndex]
            let midPoint = batchToSplit.count / 2
            let firstHalf = Array(batchToSplit[0..<midPoint])
            let secondHalf = Array(batchToSplit[midPoint...])
            
            // Replace the original large batch with its first half and add the second half as a new batch.
            result[maxIndex] = firstHalf
            result.append(secondHalf)
        }
        
        return result
    }

    /// Formats processing duration for display
    private func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: NSLocalizedString("ProcessingTimeSeconds", comment: ""), seconds)
        } else {
            let minutes = seconds / 60
            let remaining = seconds % 60
            return String(format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""), minutes, remaining)
        }
    }

    /// Rounds up a value to the nearest multiple of another value.
    /// - Parameters:
    ///   - value: The number to round up.
    ///   - multiple: The multiple to round to.
    /// - Returns: The rounded up value.
    private func roundUpToNearestMultiple(value: Int, multiple: Int) -> Int {
        guard multiple != 0 else { return value } // Avoid division by zero
        let remainder = value % multiple
        if remainder == 0 { return value }
        return value + (multiple - remainder)
    }

    /// Creates a directory, resolves symlinks, and logs errors on failure.
    /// - Returns: true if directory exists or was created successfully.
    private func createDirectoryAndLogErrors(directoryURL: URL, fileManager: FileManager) -> Bool {
        do {
            // Resolve symlinks to get the canonical path
            let canonicalDir = directoryURL.resolvingSymlinksInPath()
            try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
            return true
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""),
                                                error.localizedDescription))
                self?.isProcessing = false
            }
            return false
        }
    }

    /// Main processing workflow entry point.
    /// - Parameters:
    ///   - inputDir: The input directory containing images.
    ///   - outputDir: The output directory for processed images.
    ///   - parameters: The processing parameters.
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = true
        }
        resetProcessingState()
        logStartParameters(parameters.widthThreshold, parameters.resizeHeight, parameters.quality, parameters.threadCount, parameters.unsharpRadius, parameters.unsharpSigma, parameters.unsharpAmount, parameters.unsharpThreshold, parameters.useGrayColorspace)

        /// Verify GraphicsMagick installation
        guard verifyGraphicsMagick() else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return
        }

        /// Prepare main output directory
        guard createDirectoryAndLogErrors(directoryURL: outputDir, fileManager: FileManager.default) else {
            return
        }

        /// Start background processing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processDirectories(inputDir: inputDir, outputDir: outputDir, parameters: parameters)
        }
    }

    /// Resets internal processing state
    private func resetProcessingState() {
        processingQueue.cancelAllOperations()
        resultsQueue.sync {
            totalImagesProcessed = 0
            allFailedFiles.removeAll()
        }
        processingStartTime = Date()
    }

    /// Logs initial processing parameters
    private func logStartParameters(_ threshold: Int, _ resize: Int, _ qual: Int, _ threadCount: Int,
                                    _ radius: Float, _ sigma: Float, _ amount: Float, _ unsharpThreshold: Float,
                                    _ useGrayColorspace: Bool)
    {
        DispatchQueue.main.async { [weak self] in
            if amount > 0 {
                self?.logMessages.append(String(format: NSLocalizedString("StartProcessingWithUnsharp", comment: ""),
                                                threshold, resize, qual, threadCount, radius, sigma, amount, unsharpThreshold,
                                                NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
            } else {
                self?.logMessages.append(String(format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                                                threshold, resize, qual, threadCount,
                                                NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
            }
        }
    }

    /// Verifies GraphicsMagick installation
    private func verifyGraphicsMagick() -> Bool {
        guard let path = GraphicsMagickHelper.detectGMPathSafely(logHandler: { [weak self] message in
            DispatchQueue.main.async { self?.logMessages.append(message) }
        }) else {
            return false
        }
        gmPath = path
        return GraphicsMagickHelper.verifyGraphicsMagick(gmPath: gmPath, logHandler: { [weak self] message in
            DispatchQueue.main.async { self?.logMessages.append(message) }
        })
    }

    /// Processes all subdirectories in the input directory using unified batch processing.
    /// - Parameters:
    ///   - inputDir: The input directory URL.
    ///   - outputDir: The output directory URL.
    ///   - parameters: The raw processing parameters.
    private func processDirectories(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        let fileManager = FileManager.default

        // Initialize ImageDirectoryAnalyzer
        let analyzer = ImageDirectoryAnalyzer(logHandler: { [weak self] message in
            DispatchQueue.main.async { self?.logMessages.append(message) }
        }, isProcessingCheck: { [weak self] in
            return self?.isProcessing ?? false
        })

        let allScanResults = analyzer.analyze(inputDir: inputDir)
        guard !allScanResults.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return
        }

        var allProcessingTasks: [ImageProcessingTask] = []

        for scanResult in allScanResults {
            let originalSubdirName = scanResult.directoryURL.lastPathComponent
            let finalOutputDirForImage = outputDir.appendingPathComponent(originalSubdirName)

            for imageURL in scanResult.imageFiles {
                let outputBaseName = imageURL.deletingPathExtension().lastPathComponent
                // Dimensions will be fetched within BatchProcessOperation for each task
                let task = ImageProcessingTask(
                    imageURL: imageURL,
                    originalSubdirectoryName: originalSubdirName,
                    finalOutputDir: finalOutputDirForImage,
                    outputBaseName: outputBaseName
                )
                allProcessingTasks.append(task)
            }
        }

        guard !allProcessingTasks.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("NoImagesToProcess", comment: ""))
                self?.isProcessing = false
            }
            return
        }

        // Determine effective parameters based on auto mode or manual mode
        var effectiveThreadCount = parameters.threadCount
        var effectiveBatchSize = parameters.batchSize // Will be adjusted for auto mode

        if parameters.threadCount == 0 { // Auto mode
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("AutoModeEnabled", comment: ""))
            }
            // Use the enhanced AutoCalculator that considers task weights
            let autoCalculator: AutoCalculatable = AutoCalculator()
            let autoParams = autoCalculator.calculateAutoParameters(tasks: allProcessingTasks)
            effectiveThreadCount = autoParams.threadCount
            effectiveBatchSize = autoParams.batchSize // This batch size is an estimate for logging

            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("AutoAllocatedParameters", comment: ""), effectiveThreadCount, effectiveBatchSize))
            }
        }

        // Step 1: Pre-create all necessary output directories
        // Collect all unique final output directories from allProcessingTasks
        var uniqueFinalOutputDirs = Set<URL>()
        for task in allProcessingTasks {
            uniqueFinalOutputDirs.insert(task.finalOutputDir)
        }
        // Also include the main output directory if it's not already covered
        uniqueFinalOutputDirs.insert(outputDir)

        for dir in uniqueFinalOutputDirs {
            guard createDirectoryAndLogErrors(directoryURL: dir, fileManager: fileManager) else {
                // If any directory creation fails, stop the entire process
                return
            }
        }

        // Step 2: Configure concurrent processing
        processingQueue.maxConcurrentOperationCount = effectiveThreadCount
        processingQueue.underlyingQueue = processingDispatchQueue

        var allOps: [BatchProcessOperation] = []

        // Step 3: Split all processing tasks into batches and create operations
        let batchedTasks: [[ImageProcessingTask]]
        if parameters.threadCount == 0 { // Auto mode, use weight-based splitting
            batchedTasks = splitTasksByWeight(allProcessingTasks, targetThreadCount: effectiveThreadCount)
        } else { // Manual mode, use quantity-based splitting with the provided batch size
            // The original effectiveBatchSize calculation in manual mode is still valid
            // as it's based on user-provided batchSize.
            let totalTasks = allProcessingTasks.count
            let idealNumBatches = Int(ceil(Double(totalTasks) / Double(effectiveBatchSize)))
            // Define adjustedNumBatches here to ensure it's in scope
            let adjustedNumBatches = roundUpToNearestMultiple(value: idealNumBatches, multiple: effectiveThreadCount)
            let finalEffectiveBatchSize = max(1, min(1000, Int(ceil(Double(totalTasks) / Double(adjustedNumBatches)))))
            batchedTasks = splitIntoBatches(allProcessingTasks, batchSize: finalEffectiveBatchSize)
        }

        DispatchQueue.main.async { [weak self] in
            self?.logMessages.append(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
        }

        for batch in batchedTasks {
            let op = BatchProcessOperation(
                tasks: batch, // Pass the ImageProcessingTask batch
                widthThreshold: parameters.widthThreshold,
                resizeHeight: parameters.resizeHeight,
                quality: parameters.quality,
                unsharpRadius: parameters.unsharpRadius,
                unsharpSigma: parameters.unsharpSigma,
                unsharpAmount: parameters.unsharpAmount,
                unsharpThreshold: parameters.unsharpThreshold,
                useGrayColorspace: parameters.useGrayColorspace,
                gmPath: gmPath
            )

            op.onCompleted = { [weak self] processedCount, failedFiles in
                self?.handleBatchCompletion(processedCount: processedCount, failedFiles: failedFiles)
            }
            allOps.append(op)
            #if DEBUG
                print("ImageProcessor: Added BatchProcessOperation for \(batch.count) tasks.")
            #endif
        }

        #if DEBUG
            print("ImageProcessor: Adding \(allOps.count) operations to processingQueue.")
        #endif
        processingQueue.addOperations(allOps, waitUntilFinished: false)

        // Final completion handler
        processingQueue.addBarrierBlock { [weak self] in
            guard let self = self else { return }

            // Thread-safe state access
            var processedCount = 0
            var failedFiles: [String] = []
            self.resultsQueue.sync {
                processedCount = self.totalImagesProcessed
                failedFiles = self.allFailedFiles
            }

            let elapsed = Int(Date().timeIntervalSince(self.processingStartTime ?? Date()))
            let duration = self.formatProcessingTime(elapsed)

            DispatchQueue.main.async {
                if self.processingQueue.operationCount == 0 && processedCount == 0 {
                    self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
                } else {
                    // Unified logging for all processed images
                    self.logMessages.append(String(format: NSLocalizedString("CompletedGlobalBatchWithCount", comment: ""), processedCount))

                    // Error reporting
                    if !failedFiles.isEmpty {
                        self.logMessages.append(String(format: NSLocalizedString("FailedFiles", comment: ""), failedFiles.count))
                        for file in failedFiles.prefix(10) {
                            self.logMessages.append("- \(file)")
                        }
                        if failedFiles.count > 10 {
                            self.logMessages.append(String(format: ". %d more", failedFiles.count - 10))
                        }
                    }

                    // Log processing summary
                    self.logMessages.append(String(format: NSLocalizedString("TotalImagesProcessed", comment: ""), processedCount))
                    self.logMessages.append(duration)
                    self.logMessages.append(NSLocalizedString("ProcessingComplete", comment: ""))
                    self.sendCompletionNotification(totalProcessed: processedCount, failedCount: failedFiles.count)
                }

                self.isProcessing = false
            }
        }
    }

    /// Sends system notification when processing completes
    private func sendCompletionNotification(totalProcessed: Int, failedCount: Int) {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = NSLocalizedString("ProcessingCompleteTitle", comment: "")
        content.body = failedCount > 0 ?
            String(format: NSLocalizedString("ProcessingCompleteWithFailures", comment: ""), totalProcessed, failedCount) :
            String(format: NSLocalizedString("ProcessingCompleteSuccess", comment: ""), totalProcessed)
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}


