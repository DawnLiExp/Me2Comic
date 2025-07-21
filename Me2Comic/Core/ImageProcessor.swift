//
//  v2.2-ImageProcessor.swift
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
}

/// Calculates auto-allocated thread count and batch size based on total image count.
struct AutoCalculator: AutoCalculatable {
    /// Calculates auto-allocated thread count and batch size based on total image count.
    /// - Parameter totalImageCount: The total number of images to process.
    /// - Returns: A tuple containing the calculated thread count and batch size.
    func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        var effectiveThreadCount: Int
        let maxThreadCount = 6

        // Dynamically adjusts thread count based on total image count
        if totalImageCount < 10 {
            effectiveThreadCount = 1
        } else if totalImageCount <= 50 {
            // For 10-50 images, thread count smoothly increases from 1 to 3
            effectiveThreadCount = 1 + Int(ceil(Double(totalImageCount - 10) / 20.0))
            effectiveThreadCount = min(3, effectiveThreadCount) // Cap at 3 threads
        } else if totalImageCount <= 300 {
            // For 50-300 images, thread count smoothly increases from 3 to maxThreadCount
            effectiveThreadCount = 3 + Int(ceil(Double(totalImageCount - 50) / 50.0))
            effectiveThreadCount = min(maxThreadCount, effectiveThreadCount) // Respect max thread limit
        } else {
            // Large workload - use maximum available threads
            effectiveThreadCount = maxThreadCount
        }

        // Final thread count validation (1...maxThreadCount)
        effectiveThreadCount = max(1, min(maxThreadCount, effectiveThreadCount))

        // Unified batch size calculation for all images
        let effectiveBatchSize = max(1, min(1000, Int(ceil(Double(totalImageCount) / Double(effectiveThreadCount)))))

        return (threadCount: effectiveThreadCount, batchSize: effectiveBatchSize)
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

    /// Concurrent dispatch queue for image dimension fetching
    private let imageDimensionQueue = DispatchQueue(
        label: "me2.comic.imageDimensionFetching",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Semaphore to limit concurrent dimension fetching operations
    private let dimensionFetchSemaphore = DispatchSemaphore(value: 8) // Limit to 8 concurrent fetches

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
                self?.logMessages.append(NSLocalizedString("NoImagesToProcess", comment: ""))
                self?.isProcessing = false
            }
            return
        }

        var allProcessingTasks: [ImageProcessingTask] = []
        let tasksLock = NSLock() // For thread-safe access to allProcessingTasks
        let totalImageCount = allScanResults.reduce(0) { $0 + $1.imageFiles.count }
        let dimensionGroup = DispatchGroup()

        // Determine effective parameters based on auto mode or manual mode
        var effectiveThreadCount = parameters.threadCount
        var effectiveBatchSize = parameters.batchSize // Will be adjusted for auto mode

        if parameters.threadCount == 0 { // Auto mode
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("AutoModeEnabled", comment: ""))
            }
            let autoCalculator: AutoCalculatable = AutoCalculator()
            let autoParams = autoCalculator.calculateAutoParameters(totalImageCount: totalImageCount)
            effectiveThreadCount = autoParams.threadCount
            effectiveBatchSize = autoParams.batchSize // Use auto-calculated batch size

            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("AutoAllocatedParameters", comment: ""), effectiveThreadCount, effectiveBatchSize))
            }
        }

        // Step 1: Pre-create all necessary output directories
        // Collect all unique final output directories from allProcessingTasks
        var uniqueFinalOutputDirs = Set<URL>()
        uniqueFinalOutputDirs.insert(outputDir) // Always include the main output directory

        // MARK: - Image Dimension Fetching Phase

        #if DEBUG
            let dimensionFetchingStartTime = Date()
            print("ImageProcessor: Starting image dimension fetching for \(totalImageCount) images.")
        #endif

        for scanResult in allScanResults {
            let originalSubdirName = scanResult.directoryURL.lastPathComponent
            let finalOutputDirForImage = outputDir.appendingPathComponent(originalSubdirName)
            uniqueFinalOutputDirs.insert(finalOutputDirForImage)

            for imageURL in scanResult.imageFiles {
                let outputBaseName = imageURL.deletingPathExtension().lastPathComponent
                let task = ImageProcessingTask(
                    imageURL: imageURL,
                    originalSubdirectoryName: originalSubdirName,
                    finalOutputDir: finalOutputDirForImage,
                    outputBaseName: outputBaseName
                )
                tasksLock.lock()
                allProcessingTasks.append(task)
                tasksLock.unlock()

                dimensionGroup.enter()
                imageDimensionQueue.async { [weak self] in
                    guard let self = self else { dimensionGroup.leave(); return }
                    guard self.isProcessing else { dimensionGroup.leave(); return } // Check for cancellation

                    // Wait for semaphore, ensuring the wait operation inherits the userInitiated QoS.
                    self.dimensionFetchSemaphore.wait()
                    defer { self.dimensionFetchSemaphore.signal() } // Release semaphore

                    if let dimensions = ImageIOHelper.getImageDimensions(imagePath: imageURL.path) {
                        task.dimensions = dimensions
                        task.requiresCropping = dimensions.width >= parameters.widthThreshold
                    } else {
                        #if DEBUG
                            print("ImageProcessor: Could not get dimensions for \(imageURL.lastPathComponent)")
                        #endif
                        // Optionally handle error or mark task as failed
                    }
                    dimensionGroup.leave()
                }
            }
        }

        // Pre-create all unique output directories before starting processing operations
        for dir in uniqueFinalOutputDirs {
            guard createDirectoryAndLogErrors(directoryURL: dir, fileManager: fileManager) else {
                // If any directory creation fails, stop the entire process
                return
            }
        }

        // Configure concurrent processing
        processingQueue.maxConcurrentOperationCount = effectiveThreadCount
        processingQueue.underlyingQueue = processingDispatchQueue

        // Use a separate queue for adding operations to avoid blocking the dimension fetching loop
        let operationCreationQueue = DispatchQueue(label: "me2.comic.operationCreation")

        // This part needs to be refactored to be truly streaming.
        // For now, we'll keep the DispatchGroup.wait() for simplicity, but it's the bottleneck.
        // The goal is to remove this wait and add operations as dimensions become available.
        dimensionGroup.notify(queue: operationCreationQueue) { [weak self] in
            guard let self = self else { return }

            #if DEBUG
                let dimensionFetchingElapsedTime = Date().timeIntervalSince(dimensionFetchingStartTime)
                print("ImageProcessor: Image dimension fetching completed in \(String(format: "%.4f", dimensionFetchingElapsedTime)) seconds.")
            #endif

            // Check for cancellation after dimension fetching
            guard self.isProcessing else {
                DispatchQueue.main.async { [weak self] in
                    self?.isProcessing = false
                }
                return
            }

            guard !allProcessingTasks.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    self?.logMessages.append(NSLocalizedString("NoImagesToProcess", comment: ""))
                    self?.isProcessing = false
                }
                return
            }

            var allOps: [BatchProcessOperation] = []

            // Split all processing tasks into batches and create operations
            let idealNumBatches = Int(ceil(Double(totalImageCount) / Double(effectiveBatchSize)))
            let adjustedNumBatches = self.roundUpToNearestMultiple(value: idealNumBatches, multiple: effectiveThreadCount)
            let finalEffectiveBatchSize = max(1, min(1000, Int(ceil(Double(totalImageCount) / Double(adjustedNumBatches)))))

            let batchedTasks = self.splitIntoBatches(allProcessingTasks, batchSize: finalEffectiveBatchSize)

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
                    gmPath: self.gmPath
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
            self.processingQueue.addOperations(allOps, waitUntilFinished: false)

            // Final completion handler
            self.processingQueue.addBarrierBlock { [weak self] in
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
