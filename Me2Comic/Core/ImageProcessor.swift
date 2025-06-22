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
        let fileManager = FileManager.default
        let imageExtensions = ["jpg", "jpeg", "png"]
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        } catch {
            // Log error if directory contents cannot be read.
            // self.logMessages.append("Error reading directory: \(error.localizedDescription)")
            return []
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
        guard let batchSize = Int(batchSizeStr), batchSize >= 1, batchSize <= 618 else {
            DispatchQueue.main.async {
                self.logMessages.append(NSLocalizedString("InvalidBatchSize", comment: ""))
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

    /// Main processing workflow entry point
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        // Validate width threshold
        guard let threshold = Int(parameters.widthThreshold), threshold > 0 else {
            logMessages.append(NSLocalizedString("InvalidWidthThreshold", comment: ""))
            isProcessing = false
            return
        }
        guard let resize = Int(parameters.resizeHeight), resize > 0 else {
            logMessages.append(NSLocalizedString("InvalidResizeHeight", comment: ""))
            isProcessing = false
            return
        }
        guard let qual = Int(parameters.quality), qual >= 1, qual <= 100 else {
            logMessages.append(NSLocalizedString("InvalidOutputQuality", comment: ""))
            isProcessing = false
            return
        }
        guard let radius = Float(parameters.unsharpRadius), radius >= 0,
              let sigma = Float(parameters.unsharpSigma), sigma >= 0,
              let amount = Float(parameters.unsharpAmount), amount >= 0,
              let unsharpThreshold = Float(parameters.unsharpThreshold), unsharpThreshold >= 0
        else {
            logMessages.append(NSLocalizedString("InvalidUnsharpParameters", comment: ""))
            isProcessing = false
            return
        }

        isProcessing = true
        resetProcessingState()
        logStartParameters(threshold, resize, qual, parameters.threadCount, radius, sigma, amount, unsharpThreshold, parameters.useGrayColorspace)

        // Verify GraphicsMagick installation
        guard verifyGraphicsMagick() else {
            isProcessing = false
            return
        }

        // Prepare output directory
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logMessages.append(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""), error.localizedDescription))
            isProcessing = false
            return
        }

        // Start background processing
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
        if amount > 0 {
            logMessages.append(String(format: NSLocalizedString("StartProcessingWithUnsharp", comment: ""),
                                      threshold, resize, qual, threadCount, radius, sigma, amount, unsharpThreshold,
                                      NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
        } else {
            logMessages.append(String(format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                                      threshold, resize, qual, threadCount,
                                      NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
        }
    }

    /// Verifies GraphicsMagick installation
    private func verifyGraphicsMagick() -> Bool {
        guard let path = GraphicsMagickHelper.detectGMPathSafely(logHandler: { self.logMessages.append($0) }) else {
            return false
        }
        gmPath = path
        return GraphicsMagickHelper.verifyGraphicsMagick(gmPath: gmPath, logHandler: { self.logMessages.append($0) })
    }

    /// Processes all subdirectories in input directory
    private func processDirectories(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        let fileManager = FileManager.default
        do {
            // Discover subdirectories
            let subdirs = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }

            guard !subdirs.isEmpty else {
                DispatchQueue.main.async {
                    self.logMessages.append(NSLocalizedString("NoSubdirectories", comment: ""))
                    self.isProcessing = false
                }
                return
            }

            processSubdirectories(subdirectories: subdirs, outputDir: outputDir, parameters: parameters)

        } catch {
            DispatchQueue.main.async {
                self.logMessages.append(String(format: NSLocalizedString("ProcessingFailed", comment: ""), error.localizedDescription))
                self.isProcessing = false
            }
        }
    }

    /// Coordinates processing of multiple subdirectories
    private func processSubdirectories(subdirectories: [URL], outputDir: URL, parameters: ProcessingParameters) {
        guard let threshold = Int(parameters.widthThreshold),
              let resize = Int(parameters.resizeHeight),
              let qual = Int(parameters.quality),
              let radius = Float(parameters.unsharpRadius),
              let sigma = Float(parameters.unsharpSigma),
              let amount = Float(parameters.unsharpAmount),
              let unsharpThreshold = Float(parameters.unsharpThreshold) else { return }

        // Configure concurrent processing
        processingQueue.maxConcurrentOperationCount = parameters.threadCount
        processingQueue.underlyingQueue = processingDispatchQueue

        let batchSize = validateBatchSize(parameters.batchSize)
        var allOps: [BatchProcessOperation] = []

        for subdir in subdirectories {
            let subName = subdir.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)

            // Create output subdirectory
            do {
                if !FileManager.default.fileExists(atPath: outputSubdir.path) {
                    try FileManager.default.createDirectory(at: outputSubdir, withIntermediateDirectories: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.logMessages.append(String(format: NSLocalizedString("CannotCreateOutputSubdir", comment: ""), subName, error.localizedDescription))
                }
                continue
            }

            let imageFiles = getImageFiles(subdir)
            guard !imageFiles.isEmpty else {
                DispatchQueue.main.async {
                    self.logMessages.append(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subName))
                }
                continue
            }

            DispatchQueue.main.async {
                self.logMessages.append(String(format: NSLocalizedString("StartProcessingSubdir", comment: ""), subName))
            }

            // Create batch operations
            for batch in splitIntoBatches(imageFiles, batchSize: batchSize) {
                let op = BatchProcessOperation(
                    images: batch,
                    outputDir: outputSubdir,
                    widthThreshold: threshold,
                    resizeHeight: resize,
                    quality: qual,
                    unsharpRadius: radius,
                    unsharpSigma: sigma,
                    unsharpAmount: amount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: parameters.useGrayColorspace,
                    gmPath: gmPath
                )
                op.onCompleted = { [weak self] count, fails in
                    self?.handleBatchCompletion(processedCount: count, failedFiles: fails)
                }
                allOps.append(op)
                #if DEBUG
                    print("ImageProcessor: Added BatchProcessOperation for batch of \(batch.count) images from \(subdir.lastPathComponent).")
                #endif
            }
        }
        #if DEBUG
            print("ImageProcessor: Adding \(allOps.count) operations to processingQueue.")
        #endif
        processingQueue.addOperations(allOps, waitUntilFinished: false)

        // Final completion handler
        processingQueue.addBarrierBlock { [weak self, subdirectories] in
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
                    // Log processing results
                    for dir in subdirectories {
                        self.logMessages.append(String(format: NSLocalizedString("ProcessedSubdir", comment: ""), dir.lastPathComponent))
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
