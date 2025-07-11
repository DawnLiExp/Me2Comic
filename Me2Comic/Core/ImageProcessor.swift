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
    let widthThreshold: String // Width threshold for splitting images
    let resizeHeight: String // Target height for resizing
    let quality: String // Output quality (1-100)
    let threadCount: Int // Concurrent threads (1-6)
    let unsharpRadius: String // Unsharp mask parameters
    let unsharpSigma: String
    let unsharpAmount: String
    let unsharpThreshold: String
    let batchSize: String // Images per batch (1-618)
    let useGrayColorspace: Bool // Grayscale conversion flag
}

// MARK: - New Data Structures for Directory Classification

enum ProcessingCategory {
    case globalBatch // For images that do not require cropping; included in globalbatch
    case isolated // For images requiring cropping or with unclear classification; processed separately
}

struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
    let category: ProcessingCategory
}

class ImageProcessor: ObservableObject {
    // Path to GraphicsMagick executable
    private var gmPath: String = ""

    // Operation queue for batch processing
    private let processingQueue = OperationQueue()

    // Concurrent dispatch queue
    private let processingDispatchQueue = DispatchQueue(
        label: "me2.comic.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // Processing statistics
    private var totalImagesProcessed: Int = 0
    private var processingStartTime: Date?

    // Thread-safe results collection
    private let resultsQueue = DispatchQueue(label: "me2.comic.me2comic.results")
    private var allFailedFiles: [String] = []

    // UI state
    @Published var isProcessing: Bool = false
    @Published var logMessages: [String] = [] {
        didSet {
            // Keep last 100 log messages
            if logMessages.count > 100 {
                logMessages.removeFirst(logMessages.count - 100)
            }
        }
    }

    /// Stops all active processing tasks
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

    /// Scans directory for supported image files
    private func getImageFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("ErrorReadingDirectory", comment: ""), directory.lastPathComponent) + ": " + NSLocalizedString("FailedToCreateEnumerator", comment: ""))
            }
            return []
        }

        let imageExtensions = Set(["jpg", "jpeg", "png"])
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
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

    /// Validates and sanitizes batch size input
    private func validateBatchSize(_ batchSizeStr: String) -> Int {
        guard let batchSize = Int(batchSizeStr), batchSize >= 1, batchSize <= 1000 else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("InvalidBatchSize", comment: ""))
            }
            return 40
        }
        return batchSize
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
    private func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        var effectiveThreadCount: Int
        let maxThreadCount = 6

        // Smoothly adjust thread count based on total image count
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

        // For GlobalBatch, batch size is total images divided by effectiveThreadCount, with a cap of 1000
        // For isolated directories, batch size will be calculated per directory based on its image count
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

    /// Main processing workflow entry point
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        // Validate width threshold
        guard let threshold = Int(parameters.widthThreshold), threshold > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("InvalidWidthThreshold", comment: ""))
                self?.isProcessing = false
            }
            return
        }
        guard let resize = Int(parameters.resizeHeight), resize > 0 else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("InvalidResizeHeight", comment: ""))
                self?.isProcessing = false
            }
            return
        }
        guard let qual = Int(parameters.quality), qual >= 1, qual <= 100 else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("InvalidOutputQuality", comment: ""))
                self?.isProcessing = false
            }
            return
        }
        guard let radius = Float(parameters.unsharpRadius), radius >= 0,
              let sigma = Float(parameters.unsharpSigma), sigma >= 0,
              let amount = Float(parameters.unsharpAmount), amount >= 0,
              let unsharpThreshold = Float(parameters.unsharpThreshold), unsharpThreshold >= 0
        else {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(NSLocalizedString("InvalidUnsharpParameters", comment: ""))
                self?.isProcessing = false
            }
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.isProcessing = true
        }
        resetProcessingState()
        logStartParameters(threshold, resize, qual, parameters.threadCount, radius, sigma, amount, unsharpThreshold, parameters.useGrayColorspace)

        // Verify GraphicsMagick installation
        guard verifyGraphicsMagick() else {
            DispatchQueue.main.async { [weak self] in
                self?.isProcessing = false
            }
            return
        }

        // Prepare output directory
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""), error.localizedDescription))
                self?.isProcessing = false
            }
            return
        }

        // Start background processing
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processDirectories(inputDir: inputDir, outputDir: outputDir, parameters: parameters,
                                     validatedThreshold: threshold, validatedResize: resize, validatedQuality: qual,
                                     validatedRadius: radius, validatedSigma: sigma, validatedAmount: amount, validatedUnsharpThreshold: unsharpThreshold)
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

    /// Processes all subdirectories in input directory
    private func processDirectories(inputDir: URL, outputDir: URL, parameters: ProcessingParameters,
                                    validatedThreshold: Int, validatedResize: Int, validatedQuality: Int,
                                    validatedRadius: Float, validatedSigma: Float, validatedAmount: Float, validatedUnsharpThreshold: Float)
    {
        let fileManager = FileManager.default
        do {
            // Discover subdirectories
            let subdirs = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }

            guard !subdirs.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    self?.logMessages.append(NSLocalizedString("NoSubdirectories", comment: ""))
                    self?.isProcessing = false
                }
                return
            }

            // --- New Logic for Directory Classification and Task Distribution ---
            var allScanResults: [DirectoryScanResult] = []
            var globalBatchImages: [URL] = []

            // Determine effective parameters based on auto mode or manual mode
            var effectiveThreadCount = parameters.threadCount
            var effectiveBatchSize = validateBatchSize(parameters.batchSize)

            if parameters.threadCount == 0 { // Auto mode
                DispatchQueue.main.async { [weak self] in
                    self?.logMessages.append(NSLocalizedString("AutoModeEnabled", comment: ""))
                }
                let allImageFiles = subdirs.flatMap { self.getImageFiles($0) }
                let totalImages = allImageFiles.count

                let autoParams = calculateAutoParameters(totalImageCount: totalImages)
                effectiveThreadCount = autoParams.threadCount
                effectiveBatchSize = autoParams.batchSize

                DispatchQueue.main.async { [weak self] in
                    self?.logMessages.append(String(format: NSLocalizedString("AutoAllocatedParameters", comment: ""), effectiveThreadCount, effectiveBatchSize))
                }
            }

            // Step 1: Classify subdirectories
            for subdir in subdirs {
                let imageFiles = getImageFiles(subdir)
                guard !imageFiles.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        self?.logMessages.append(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subdir.lastPathComponent))
                    }
                    continue
                }

                let sampleImages = Array(imageFiles.prefix(5))
                let sampleImagePaths = sampleImages.map { $0.path }

                // Use ImageIOHelper to get dimensions for sample images
                let sampleDimensions = GraphicsMagickHelper.getBatchImageDimensions(imagePaths: sampleImagePaths) { [weak self] in
                    // Check if the ImageProcessor itself has been cancelled
                    return self?.isProcessing ?? false
                }

                var isGlobalBatchCandidate = true
                // Use the already validated threshold
                let threshold = validatedThreshold

                for imageURL in sampleImages {
                    if let dims = sampleDimensions[imageURL.path] {
                        if dims.width >= threshold {
                            isGlobalBatchCandidate = false
                            break
                        }
                    } else {
                        // If sample image dimensions cannot be retrieved, conservatively treat as isolated
                        isGlobalBatchCandidate = false
                        #if DEBUG
                            print("ImageProcessor: Could not get dimensions for sample image \(imageURL.lastPathComponent), treating as isolated.")
                        #endif
                        break
                    }
                }

                let category: ProcessingCategory = isGlobalBatchCandidate ? .globalBatch : .isolated
                allScanResults.append(DirectoryScanResult(directoryURL: subdir, imageFiles: imageFiles, category: category))

                if category == .globalBatch {
                    globalBatchImages.append(contentsOf: imageFiles)
                }
            }

            // Step 2: Configure concurrent processing
            processingQueue.maxConcurrentOperationCount = effectiveThreadCount
            processingQueue.underlyingQueue = processingDispatchQueue

            var allOps: [BatchProcessOperation] = []

            // Step 3: Process Global Batch category images
            if !globalBatchImages.isEmpty {
                // Calculate new batchSize based on total global images and thread count
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
                        widthThreshold: validatedThreshold,
                        resizeHeight: validatedResize,
                        quality: validatedQuality,
                        unsharpRadius: validatedRadius,
                        unsharpSigma: validatedSigma,
                        unsharpAmount: validatedAmount,
                        unsharpThreshold: validatedUnsharpThreshold,
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

                    allOps.append(op)
                    #if DEBUG
                        print("ImageProcessor: Added Global BatchProcessOperation for \(batch.count) images.")
                    #endif
                }
            }

            // Step 4: Process Isolated category images
            for scanResult in allScanResults where scanResult.category == .isolated {
                let subName = scanResult.directoryURL.lastPathComponent
                let outputSubdir = outputDir.appendingPathComponent(subName)

                // Create output subdirectory if it does not exist
                do {
                    if !fileManager.fileExists(atPath: outputSubdir.path) {
                        try fileManager.createDirectory(at: outputSubdir, withIntermediateDirectories: true)
                    }
                } catch {
                    DispatchQueue.main.async { [weak self] in
                        self?.logMessages.append(String(format: NSLocalizedString("CannotCreateOutputSubdir", comment: ""), subName, error.localizedDescription))
                    }
                    continue
                }

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
                    batchSize = validateBatchSize(parameters.batchSize) // Use original batchSize for isolated directories
                }
                for batch in splitIntoBatches(scanResult.imageFiles, batchSize: batchSize) {
                    let op = BatchProcessOperation(
                        images: batch,
                        outputDir: outputSubdir,
                        widthThreshold: validatedThreshold,
                        resizeHeight: validatedResize,
                        quality: validatedQuality,
                        unsharpRadius: validatedRadius,
                        unsharpSigma: validatedSigma,
                        unsharpAmount: validatedAmount,
                        unsharpThreshold: validatedUnsharpThreshold,
                        useGrayColorspace: parameters.useGrayColorspace,
                        gmPath: gmPath
                    )
                    op.onCompleted = { [weak self] count, fails in
                        self?.handleBatchCompletion(processedCount: count, failedFiles: fails)
                    }
                    allOps.append(op)
                    #if DEBUG
                        print("ImageProcessor: Added Isolated BatchProcessOperation for \(batch.count) images from \(subName).")
                    #endif
                }
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
                        // Log processing results - only log for isolated directories as global batch doesn\"t have a single subdir log
                        // For global batch, the overall summary will cover it.
                        for scanResult in allScanResults where scanResult.category == .isolated {
                            self.logMessages.append(String(format: NSLocalizedString("ProcessedSubdir", comment: ""), scanResult.directoryURL.lastPathComponent))
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

        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.logMessages.append(String(format: NSLocalizedString("ProcessingFailed", comment: ""), error.localizedDescription))
                self?.isProcessing = false
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
