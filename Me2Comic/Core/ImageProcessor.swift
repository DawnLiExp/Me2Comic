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

    // Progress tracking
    /// Total number of images to process
    @Published var totalImagesToProcess: Int = 0
    /// Current number of processed images
    @Published var currentProcessedImages: Int = 0
    /// Processing progress (0.0 - 1.0)
    @Published var processingProgress: Double = 0.0

    /// Stops all active processing tasks.
    func stopProcessing() {
        #if DEBUG
            print("ImageProcessor: stopProcessing called. Cancelling all operations.")
        #endif
        processingQueue.cancelAllOperations()
        DispatchQueue.main.async {
            self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
            self.isProcessing = false
            // Reset progress
            self.currentProcessedImages = 0
            self.processingProgress = 0.0
        }
    }

    /// Aggregates batch processing results
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) {
        resultsQueue.async {
            self.totalImagesProcessed += processedCount
            self.allFailedFiles.append(contentsOf: failedFiles)

            // Update progress
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.currentProcessedImages += processedCount
                if self.totalImagesToProcess > 0 {
                    self.processingProgress = Double(self.currentProcessedImages) / Double(self.totalImagesToProcess)
                } else {
                    self.processingProgress = 0.0
                }
            }
        }
    }

    /// Splits image array into processing batches
    private func splitIntoBatches(_ images: [URL], batchSize: Int) -> [[URL]] {
        guard batchSize > 0 else { return [] }
        guard !images.isEmpty else { return [] }
        var result: [[URL]] = []
        var currentBatch: [URL] = []

        result.reserveCapacity(images.count / batchSize + 1)
        currentBatch.reserveCapacity(batchSize)

        for image in images {
            currentBatch.append(image)
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

    /// Calculates auto-allocated thread count and batch size based on total image count.
    /// - Parameter totalImageCount: The total number of images to process.
    /// - Returns: A tuple containing the calculated thread count and batch size.
    private func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
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

        // For GlobalBatch, batch size is total images divided by effectiveThreadCount, with a cap of 1000.
        // For isolated directories, batch size will be calculated per directory based on its image count.
        let effectiveBatchSize = max(1, min(1000, Int(ceil(Double(totalImageCount) / Double(effectiveThreadCount)))))

        return (threadCount: effectiveThreadCount, batchSize: effectiveBatchSize)
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

        // Reset progress tracking
        DispatchQueue.main.async { [weak self] in
            self?.totalImagesToProcess = 0
            self?.currentProcessedImages = 0
            self?.processingProgress = 0.0
        }
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

    /// Processes all subdirectories in the input directory.
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

        let allScanResults = analyzer.analyze(inputDir: inputDir, widthThreshold: parameters.widthThreshold)

        guard !allScanResults.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return
        }

        // Calculate total images to process
        let totalImages = allScanResults.flatMap { $0.imageFiles }.count
        DispatchQueue.main.async { [weak self] in
            self?.totalImagesToProcess = totalImages
            self?.logMessages.append(String(format: NSLocalizedString("TotalImagesToProcess", comment: ""), totalImages))
        }

        var globalBatchImages: [URL] = []
        for scanResult in allScanResults {
            if scanResult.category == .globalBatch {
                globalBatchImages.append(contentsOf: scanResult.imageFiles)
            }
        }

        // Determine effective parameters based on auto mode or manual mode
        var effectiveThreadCount = parameters.threadCount
        var effectiveBatchSize = parameters.batchSize

        if parameters.threadCount == 0 { // Auto mode
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("AutoModeEnabled", comment: ""))
            }
            let totalImages = allScanResults.flatMap { $0.imageFiles }.count

            let autoParams = calculateAutoParameters(totalImageCount: totalImages)
            effectiveThreadCount = autoParams.threadCount
            effectiveBatchSize = autoParams.batchSize

            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("AutoAllocatedParameters", comment: ""), effectiveThreadCount, autoParams.batchSize))
            }
        }

        // Step 1: Collect all unique output directories and pre-create them
        var uniqueOutputDirs = Set<URL>()
        for scanResult in allScanResults {
            let subName = scanResult.directoryURL.lastPathComponent
            uniqueOutputDirs.insert(outputDir.appendingPathComponent(subName))
        }

        // Include main output directory for empty cases requiring creation
        uniqueOutputDirs.insert(outputDir)

        for dir in uniqueOutputDirs {
            guard createDirectoryAndLogErrors(directoryURL: dir, fileManager: fileManager) else {
                return
            }
        }

        // Step 2: Configure concurrent processing
        processingQueue.maxConcurrentOperationCount = effectiveThreadCount
        processingQueue.underlyingQueue = processingDispatchQueue

        var allOps: [BatchProcessOperation] = []
        var isolatedOps: [BatchProcessOperation] = []
        var globalBatchOps: [BatchProcessOperation] = []

        // Step 3: Process Isolated category images
        for scanResult in allScanResults where scanResult.category == .isolated {
            let subName = scanResult.directoryURL.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)

            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("StartProcessingSubdir", comment: ""), subName))
            }

            let batchSize: Int
            if parameters.threadCount == 0 { // Auto mode for isolated directories
                let isolatedDirImageCount = scanResult.imageFiles.count
                // For Isolated directories, if the number of images is small, use a smaller fixed batch size to avoid orphan processes, e.g., 30-40.
                // If the number of images is large, dynamically calculate based on total images and thread count to ensure even batches.
                let baseIdealBatchSize = 40 // A sensible default for isolated directories
                let idealNumBatchesForIsolated = Int(ceil(Double(isolatedDirImageCount) / Double(baseIdealBatchSize)))
                let adjustedNumBatchesForIsolated = roundUpToNearestMultiple(value: idealNumBatchesForIsolated, multiple: effectiveThreadCount)
                batchSize = max(1, min(1000, Int(ceil(Double(isolatedDirImageCount) / Double(adjustedNumBatchesForIsolated)))))
            } else {
                batchSize = parameters.batchSize // Use original batchSize for isolated directories, fallback to default.
            }
            for batch in splitIntoBatches(scanResult.imageFiles, batchSize: batchSize) {
                let op = BatchProcessOperation(
                    images: batch,
                    outputDir: outputSubdir,
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
                op.onCompleted = { [weak self] count, fails in
                    self?.handleBatchCompletion(processedCount: count, failedFiles: fails)
                }
                isolatedOps.append(op)
                #if DEBUG
                    print("ImageProcessor: Added Isolated BatchProcessOperation for \(batch.count) images from \(subName).")
                #endif
            }
        }

        // Step 4: Process Global Batch category images
        if !globalBatchImages.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            }

            let idealNumBatchesForGlobal = Int(ceil(Double(globalBatchImages.count) / Double(effectiveBatchSize))) // Use effectiveBatchSize as a base ideal batch size
            let adjustedNumBatchesForGlobal = roundUpToNearestMultiple(value: idealNumBatchesForGlobal, multiple: effectiveThreadCount)
            let effectiveGlobalBatchSize = max(1, min(1000, Int(ceil(Double(globalBatchImages.count) / Double(adjustedNumBatchesForGlobal)))))
            let globalBatches = splitIntoBatches(globalBatchImages, batchSize: effectiveGlobalBatchSize)
            var completedGlobalBatches = 0
            let totalGlobalBatches = globalBatches.count
            var globalProcessedCount = 0
            var globalFailedFiles: [String] = []
            let globalBatchLock = NSLock()

            for batch in globalBatches {
                let op = BatchProcessOperation(
                    images: batch,
                    outputDir: outputDir,
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

                op.onCompleted = { [weak self] count, fails in
                    guard let self = self else { return }
                    self.handleBatchCompletion(processedCount: count, failedFiles: fails)

                    globalBatchLock.lock()
                    globalProcessedCount += count
                    globalFailedFiles.append(contentsOf: fails)
                    completedGlobalBatches += 1
                    let isLast = (completedGlobalBatches == totalGlobalBatches)
                    globalBatchLock.unlock()

                    if isLast {
                        DispatchQueue.main.async {
                            let formatted = String(
                                format: NSLocalizedString("CompletedGlobalBatchWithCount", comment: ""),
                                globalProcessedCount
                            )
                            self.logMessages.append(formatted)
                        }
                    }
                }

                globalBatchOps.append(op)
                #if DEBUG
                    print("ImageProcessor: Added Global BatchProcessOperation for \(batch.count) images.")
                #endif
            }
        }

        // Combine and add operations to the queue, prioritizing Isolated operations
        allOps.append(contentsOf: isolatedOps)
        allOps.append(contentsOf: globalBatchOps)

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
                    // Log processing results per directory category.
                    for scanResult in allScanResults {
                        let logMessage: String
                        switch scanResult.category {
                        case .isolated:
                            logMessage = String(format: NSLocalizedString("ProcessedSubdir", comment: ""), scanResult.directoryURL.lastPathComponent)
                        case .globalBatch:
                            // Global batch results are aggregated and logged upon operation completion.
                            // Per-directory logging for global batch is omitted here to prevent redundancy.
                            continue
                        }
                        self.logMessages.append(logMessage)
                    }

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
