//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation
import UserNotifications

class ImageProcessor: ObservableObject {
    // Path to verified GraphicsMagick executable
    private var gmPath: String = ""

    // Queue for executing image batch tasks
    private let processingQueue = OperationQueue()

    // Total number of processed images
    private var totalImagesProcessed: Int = 0

    // Start time for measuring duration
    private var processingStartTime: Date?

    // Queue for safely collecting results from concurrent operations
    private let resultsQueue = DispatchQueue(label: "me2.comic.me2comic.results")

    // File paths that failed to process
    private var allFailedFiles: [String] = []

    @Published var isProcessing: Bool = false

    @Published var logMessages: [String] = [] {
        didSet {
            if logMessages.count > 100 {
                logMessages.removeFirst(logMessages.count - 100)
            }
        }
    }

    /// Cancel all pending/running tasks and clean up observer
    func stopProcessing() {
        processingQueue.cancelAllOperations()
        DispatchQueue.main.async {
            self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
            self.isProcessing = false
        }
    }

    /// Merge results from each completed batch
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) {
        resultsQueue.async {
            self.totalImagesProcessed += processedCount
            self.allFailedFiles.append(contentsOf: failedFiles)
        }
    }

    /// Retrieve image files with supported extensions from a directory
    private func getImageFiles(_ directory: URL) -> [URL] {
        let fileManager = FileManager.default
        let imageExtensions = ["jpg", "jpeg", "png"]
        do {
            let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            return files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        } catch {
            return []
        }
    }

    /// Split image list into batches of specified size
    private func splitIntoBatches(_ images: [URL], batchSize: Int) -> [[URL]] {
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

    /// Validate user input for batch size, fallback to default if invalid
    private func validateBatchSize(_ batchSizeStr: String) -> Int {
        guard let batchSize = Int(batchSizeStr), batchSize >= 1, batchSize <= 1000 else {
            DispatchQueue.main.async {
                self.logMessages.append(NSLocalizedString("InvalidBatchSize", comment: ""))
            }
            return 40
        }
        return batchSize
    }

    /// Format duration for display in logs
    private func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: NSLocalizedString("ProcessingTimeSeconds", comment: ""), seconds)
        } else {
            let minutes = seconds / 60
            let remaining = seconds % 60
            return String(format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""), minutes, remaining)
        }
    }

    /// Main function to validate parameters and begin processing
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
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

        guard verifyGraphicsMagick() else {
            isProcessing = false
            return
        }

        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logMessages.append(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""), error.localizedDescription))
            isProcessing = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processDirectories(inputDir: inputDir, outputDir: outputDir, parameters: parameters)
        }
    }

    /// Reset counters and internal states
    private func resetProcessingState() {
        processingQueue.cancelAllOperations()
        resultsQueue.sync {
            totalImagesProcessed = 0
            allFailedFiles.removeAll()
        }
        processingStartTime = Date()
    }

    /// Log processing settings to console
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

    /// Validate GM path and version
    private func verifyGraphicsMagick() -> Bool {
        guard let path = GraphicsMagickHelper.detectGMPathSafely(logHandler: { self.logMessages.append($0) }) else {
            return false
        }
        gmPath = path
        return GraphicsMagickHelper.verifyGraphicsMagick(gmPath: gmPath, logHandler: { self.logMessages.append($0) })
    }

    /// Collect subdirectories and dispatch batch jobs
    private func processDirectories(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        let fileManager = FileManager.default
        do {
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

    /// Create and dispatch operations for each subdirectory
    private func processSubdirectories(subdirectories: [URL], outputDir: URL, parameters: ProcessingParameters) {
        guard let threshold = Int(parameters.widthThreshold),
              let resize = Int(parameters.resizeHeight),
              let qual = Int(parameters.quality),
              let radius = Float(parameters.unsharpRadius),
              let sigma = Float(parameters.unsharpSigma),
              let amount = Float(parameters.unsharpAmount),
              let unsharpThreshold = Float(parameters.unsharpThreshold) else { return }

        processingQueue.maxConcurrentOperationCount = parameters.threadCount
        processingQueue.qualityOfService = .userInitiated

        let batchSize = validateBatchSize(parameters.batchSize)
        var allOps: [BatchProcessOperation] = []

        for subdir in subdirectories {
            let subName = subdir.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)

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
            }
        }

        let completion = BlockOperation { [weak self] in
            self?.finalizeProcessing(subdirectories: subdirectories)
        }
        allOps.forEach { completion.addDependency($0) }

        processingQueue.addOperations(allOps + [completion], waitUntilFinished: false)
    }

    /// Final log reporting after all operations complete
    private func finalizeProcessing(subdirectories: [URL]) {
        var processedCount = 0
        var failed: [String] = []

        resultsQueue.sync {
            processedCount = totalImagesProcessed
            failed = allFailedFiles
        }

        let elapsed = Int(Date().timeIntervalSince(processingStartTime ?? Date()))
        let duration = formatProcessingTime(elapsed)

        DispatchQueue.main.async {
            if self.processingQueue.operationCount == 0 && processedCount == 0 {
                self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
            } else {
                for dir in subdirectories {
                    self.logMessages.append(String(format: NSLocalizedString("ProcessedSubdir", comment: ""), dir.lastPathComponent))
                }

                if !failed.isEmpty {
                    self.logMessages.append(String(format: NSLocalizedString("FailedFiles", comment: ""), failed.count))
                    for file in failed.prefix(10) {
                        self.logMessages.append("- \(file)")
                    }
                    if failed.count > 10 {
                        self.logMessages.append(String(format: ". %d more", failed.count - 10))
                    }
                }

                self.logMessages.append(String(format: NSLocalizedString("TotalImagesProcessed", comment: ""), processedCount))
                self.logMessages.append(duration)
                self.logMessages.append(NSLocalizedString("ProcessingComplete", comment: ""))
                self.sendCompletionNotification(totalProcessed: processedCount, failedCount: failed.count)
            }
            self.isProcessing = false
        }
    }

    /// macOS system notification on completion
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
