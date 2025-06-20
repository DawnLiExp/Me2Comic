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

/// Container for all image processing configuration parameters
struct ProcessingParameters {
    let widthThreshold: String // The width threshold for determining if an image needs to be split.
    let resizeHeight: String // The target height for resizing images.
    let quality: String
    let threadCount: Int // The number of concurrent threads to use for processing (1-6).
    let unsharpRadius: String
    let unsharpSigma: String
    let unsharpAmount: String
    let unsharpThreshold: String
    let batchSize: String // The number of images to process in each batch (1-618).
    let useGrayColorspace: Bool
}

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

    // Published property to indicate if processing is currently active
    @Published var isProcessing: Bool = false

    // Published property to store and display log messages, limited to 100 messages
    @Published var logMessages: [String] = [] {
        didSet {
            if logMessages.count > 100 {
                logMessages.removeFirst(logMessages.count - 100)
            }
        }
    }

    /// Stops all ongoing and pending image processing tasks.
    /// Resets the processing state and updates the UI accordingly.
    func stopProcessing() {
        processingQueue.cancelAllOperations()
        DispatchQueue.main.async {
            self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
            self.isProcessing = false
        }
    }

    /// Handles the completion of a batch of image processing operations.
    /// Aggregates processed counts and failed files from concurrent operations.
    /// - Parameters:
    ///   - processedCount: The number of images successfully processed in the batch.
    ///   - failedFiles: An array of file paths that failed to process in the batch.
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) {
        resultsQueue.async {
            self.totalImagesProcessed += processedCount
            self.allFailedFiles.append(contentsOf: failedFiles)
        }
    }

    /// Retrieves image files with supported extensions (JPG, JPEG, PNG) from a specified directory.
    /// - Parameter directory: The URL of the directory to scan.
    /// - Returns: An array of URLs pointing to the found image files.
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

    /// Splits a list of image URLs into smaller batches for concurrent processing.
    /// - Parameters:
    ///   - images: An array of URLs representing all image files to be processed.
    ///   - batchSize: The maximum number of images per batch.
    /// - Returns: A 2D array where each inner array is a batch of image URLs.
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

    /// Validates the provided batch size string and converts it to an integer.
    /// If the input is invalid (not a number, less than 1, or greater than 1000), it logs a message and returns a default batch size of 40.
    /// - Parameter batchSizeStr: The batch size as a string, typically from user input.
    /// - Returns: A validated integer batch size.
    private func validateBatchSize(_ batchSizeStr: String) -> Int {
        guard let batchSize = Int(batchSizeStr), batchSize >= 1, batchSize <= 618 else {
            DispatchQueue.main.async {
                self.logMessages.append(NSLocalizedString("InvalidBatchSize", comment: ""))
            }
            return 40
        }
        return batchSize
    }

    /// Formats the given number of seconds into a human-readable string (e.g., "X seconds" or "Y minutes Z seconds").
    /// - Parameter seconds: The total duration in seconds.
    /// - Returns: A formatted string representing the processing time.
    private func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: NSLocalizedString("ProcessingTimeSeconds", comment: ""), seconds)
        } else {
            let minutes = seconds / 60
            let remaining = seconds % 60
            return String(format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""), minutes, remaining)
        }
    }

    /// Initiates the image processing workflow.
    /// Validates input directories and processing parameters before starting the main processing logic.
    /// - Parameters:
    ///   - inputDir: The URL of the input directory containing subdirectories of images.
    ///   - outputDir: The URL of the output directory where processed images will be saved.
    ///   - parameters: A `ProcessingParameters` struct containing all necessary processing settings.
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        // Validate width threshold
        guard let threshold = Int(parameters.widthThreshold), threshold > 0 else {
            logMessages.append(NSLocalizedString("InvalidWidthThreshold", comment: ""))
            isProcessing = false
            return
        }
        // Validate resize height
        guard let resize = Int(parameters.resizeHeight), resize > 0 else {
            logMessages.append(NSLocalizedString("InvalidResizeHeight", comment: ""))
            isProcessing = false
            return
        }
        // Validate quality
        guard let qual = Int(parameters.quality), qual >= 1, qual <= 100 else {
            logMessages.append(NSLocalizedString("InvalidOutputQuality", comment: ""))
            isProcessing = false
            return
        }
        // Validate unsharp mask parameters
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

        // Create output directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logMessages.append(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""), error.localizedDescription))
            isProcessing = false
            return
        }

        // Start processing in a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.processDirectories(inputDir: inputDir, outputDir: outputDir, parameters: parameters)
        }
    }

    /// Resets the internal state variables and cancels any ongoing processing operations.
    /// This prepares the processor for a new batch of images.
    private func resetProcessingState() {
        processingQueue.cancelAllOperations()
        resultsQueue.sync {
            totalImagesProcessed = 0
            allFailedFiles.removeAll()
        }
        processingStartTime = Date()
    }

    /// Logs the initial processing parameters to the console.
    /// - Parameters:
    ///   - threshold: The width threshold for image processing.
    ///   - resize: The target height for resizing images.
    ///   - qual: The output quality for processed images.
    ///   - threadCount: The number of concurrent threads to use for processing.
    ///   - radius: The unsharp mask radius.
    ///   - sigma: The unsharp mask sigma.
    ///   - amount: The unsharp mask amount.
    ///   - unsharpThreshold: The unsharp mask threshold.
    ///   - useGrayColorspace: A boolean indicating whether to use grayscale color space.
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

    /// Verifies the presence and version of GraphicsMagick on the system.
    /// - Returns: `true` if GraphicsMagick is successfully detected and verified, `false` otherwise.
    private func verifyGraphicsMagick() -> Bool {
        guard let path = GraphicsMagickHelper.detectGMPathSafely(logHandler: { self.logMessages.append($0) }) else {
            return false
        }
        gmPath = path
        return GraphicsMagickHelper.verifyGraphicsMagick(gmPath: gmPath, logHandler: { self.logMessages.append($0) })
    }

    /// Processes subdirectories within the input directory.
    /// Dispatches batch jobs for image processing in each subdirectory.
    /// - Parameters:
    ///   - inputDir: The main input directory.
    ///   - outputDir: The main output directory.
    ///   - parameters: The processing parameters.
    private func processDirectories(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        let fileManager = FileManager.default
        do {
            // Get all subdirectories within the input directory
            let subdirs = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }

            // If no subdirectories are found, log a message and stop processing
            guard !subdirs.isEmpty else {
                DispatchQueue.main.async {
                    self.logMessages.append(NSLocalizedString("NoSubdirectories", comment: ""))
                    self.isProcessing = false
                }
                return
            }

            // Process each subdirectory
            processSubdirectories(subdirectories: subdirs, outputDir: outputDir, parameters: parameters)

        } catch {
            // Log error if directory contents cannot be read
            DispatchQueue.main.async {
                self.logMessages.append(String(format: NSLocalizedString("ProcessingFailed", comment: ""), error.localizedDescription))
                self.isProcessing = false
            }
        }
    }

    /// Creates and dispatches operations for each subdirectory found.
    /// Each subdirectory's images are split into batches and processed concurrently.
    /// - Parameters:
    ///   - subdirectories: An array of URLs representing the subdirectories to process.
    ///   - outputDir: The base output directory.
    ///   - parameters: The processing parameters.
    private func processSubdirectories(subdirectories: [URL], outputDir: URL, parameters: ProcessingParameters) {
        // Safely unwrap and convert string parameters to their respective types
        guard let threshold = Int(parameters.widthThreshold),
              let resize = Int(parameters.resizeHeight),
              let qual = Int(parameters.quality),
              let radius = Float(parameters.unsharpRadius),
              let sigma = Float(parameters.unsharpSigma),
              let amount = Float(parameters.unsharpAmount),
              let unsharpThreshold = Float(parameters.unsharpThreshold) else { return }

        // Configure the operation queue for concurrent processing
        processingQueue.maxConcurrentOperationCount = parameters.threadCount
        processingQueue.qualityOfService = .userInitiated

        let batchSize = validateBatchSize(parameters.batchSize)
        var allOps: [BatchProcessOperation] = []

        for subdir in subdirectories {
            let subName = subdir.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)

            // Create output subdirectory if it doesn't exist
            do {
                if !FileManager.default.fileExists(atPath: outputSubdir.path) {
                    try FileManager.default.createDirectory(at: outputSubdir, withIntermediateDirectories: true)
                }
            } catch {
                DispatchQueue.main.async {
                    self.logMessages.append(String(format: NSLocalizedString("CannotCreateOutputSubdir", comment: ""), subName, error.localizedDescription))
                }
                continue // Skip to the next subdirectory if creation fails
            }

            let imageFiles = getImageFiles(subdir)
            // Skip if no images are found in the subdirectory
            guard !imageFiles.isEmpty else {
                DispatchQueue.main.async {
                    self.logMessages.append(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subName))
                }
                continue
            }

            DispatchQueue.main.async {
                self.logMessages.append(String(format: NSLocalizedString("StartProcessingSubdir", comment: ""), subName))
            }

            // Create batch operations for each set of images
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
                // Set completion handler to aggregate results
                op.onCompleted = { [weak self] count, fails in
                    self?.handleBatchCompletion(processedCount: count, failedFiles: fails)
                }
                allOps.append(op)
            }
        }

        // Add all batch operations to the queue
        processingQueue.addOperations(allOps, waitUntilFinished: false)

        // Add barrier block for final processing
        processingQueue.addBarrierBlock { [weak self, subdirectories] in
            guard let self = self else { return }

            // Safely access shared state using resultsQueue
            var processedCount = 0
            var failedFiles: [String] = []
            self.resultsQueue.sync {
                processedCount = self.totalImagesProcessed
                failedFiles = self.allFailedFiles
            }

            let elapsed = Int(Date().timeIntervalSince(self.processingStartTime ?? Date()))
            let duration = self.formatProcessingTime(elapsed)

            DispatchQueue.main.async {
                // Preserve original logging structure and flow
                if self.processingQueue.operationCount == 0 && processedCount == 0 {
                    self.logMessages.append(NSLocalizedString("ProcessingStopped", comment: ""))
                } else {
                    // Log processed subdirectories
                    for dir in subdirectories {
                        self.logMessages.append(String(format: NSLocalizedString("ProcessedSubdir", comment: ""), dir.lastPathComponent))
                    }

                    // Log failed files
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

    /// Sends a local user notification upon completion of image processing.
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
