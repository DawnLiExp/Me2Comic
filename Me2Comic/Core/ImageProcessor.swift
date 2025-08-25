//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation

// MARK: - Processing Parameters

/// Container for image processing configuration
struct ProcessingParameters {
    let widthThreshold: Int
    let resizeHeight: Int
    let quality: Int
    let threadCount: Int /// Concurrent threads (1-6)
    let unsharpRadius: Float
    let unsharpSigma: Float
    let unsharpAmount: Float
    let unsharpThreshold: Float
    let batchSize: Int /// Images per batch (1-1000)
    let useGrayColorspace: Bool
}

/// Actor responsible for managing the image processing workflow
@MainActor
class ImageProcessor: ObservableObject {
    private let notificationManager = NotificationManager()
    private var gmPath: String = ""
    
    /// Operation queue for batch processing (retained for Process management)
    private let processingQueue = OperationQueue()
    private let processingDispatchQueue = DispatchQueue(
        label: "me2.comic.me2comic.processing",
        qos: .userInitiated,
        attributes: .concurrent
    )
    
    private var totalImagesProcessed: Int = 0
    private var processingStartTime: Date?
    
    /// List of files that failed processing
    private var allFailedFiles: [String] = []
    
    // UI state
    /// Indicates if processing is currently active
    @Published var isProcessing: Bool = false
    
    /// Log messages for display in the UI
    @Published var logMessages: [String] = []
    
    // Progress tracking
    /// Total number of images to process
    @Published var totalImagesToProcess: Int = 0
    /// Current number of processed images
    @Published var currentProcessedImages: Int = 0
    /// Processing progress (0.0 - 1.0)
    @Published var processingProgress: Double = 0.0
    /// Flag indicating all processing tasks have finished
    @Published var didFinishAllTasks: Bool = false
    
    /// Active processing task for cancellation
    private var activeProcessingTask: Task<Void, Never>?
    
    /// Log stream for ordered message delivery
    private var logStream: AsyncStream<String>?
    private var logContinuation: AsyncStream<String>.Continuation?
    
    // MARK: - Initialization
    
    init() {
        setupLogStream()
    }
    
    // MARK: - Logging
    
    /// Sets up the async log stream
    private func setupLogStream() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        logStream = stream
        logContinuation = continuation
        
        // Start consuming log messages
        Task {
            guard let stream = logStream else { return }
            for await message in stream {
                addLogMessageAndTrim(message)
            }
        }
    }
    
    /// Centralized log trimming logic to maintain maximum 100 entries
    private func addLogMessageAndTrim(_ message: String) {
        logMessages.append(message)
        if logMessages.count > 100 {
            logMessages.removeFirst(logMessages.count - 100)
        }
    }
    
    /// Append a log message through the async stream
    func appendLog(_ message: String) {
        logContinuation?.yield(message)
    }
    
    /// Synchronously append multiple log messages in order
    private func appendLogsInOrder(_ messages: [String]) {
        for message in messages {
            addLogMessageAndTrim(message)
        }
    }
    
    // MARK: - Processing Control
    
    /// Stops all active processing tasks
    func stopProcessing() {
        #if DEBUG
        print("ImageProcessor: stopProcessing called. Cancelling all operations.")
        #endif
        
        // Cancel async task
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        
        // Cancel operations in queue
        processingQueue.cancelAllOperations()
        
        appendLog(NSLocalizedString("ProcessingStopRequested", comment: "User requested stop"))
        appendLog(NSLocalizedString("ProcessingStopped", comment: "Processing has been stopped"))
        
        isProcessing = false
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Main processing workflow entry point
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        // Cancel any existing processing
        activeProcessingTask?.cancel()
        
        // Mark processing started
        isProcessing = true
        resetProcessingState()
        logStartParameters(
            parameters.widthThreshold, parameters.resizeHeight, parameters.quality,
            parameters.threadCount, parameters.unsharpRadius, parameters.unsharpSigma,
            parameters.unsharpAmount, parameters.unsharpThreshold, parameters.useGrayColorspace
        )
        
        // Start async processing
        activeProcessingTask = Task {
            await processImagesAsync(inputDir: inputDir, outputDir: outputDir, parameters: parameters)
        }
    }
    
    // MARK: - Private Processing Methods
    
    /// Async processing implementation
    private func processImagesAsync(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) async {
        // Verify GraphicsMagick installation
        guard await verifyGraphicsMagickAsync() else {
            isProcessing = false
            return
        }
        
        // Prepare main output directory
        guard createDirectoryAndLogErrors(directoryURL: outputDir, fileManager: FileManager.default) else {
            isProcessing = false
            return
        }
        
        // Check for cancellation
        guard !Task.isCancelled else {
            isProcessing = false
            return
        }
        
        // Process directories
        await processDirectoriesAsync(inputDir: inputDir, outputDir: outputDir, parameters: parameters)
    }
    
    /// Async directory processing
    private func processDirectoriesAsync(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) async {
        let fileManager = FileManager.default
        
        // Initialize analyzer with async support
        let analyzer = ImageDirectoryAnalyzer(
            logHandler: { [weak self] message in
                self?.appendLog(message)
            },
            isProcessingCheck: { [weak self] in
                guard let self = self else { return false }
                return self.isProcessing && !Task.isCancelled
            }
        )
        
        let allScanResults = await analyzer.analyzeAsync(inputDir: inputDir, widthThreshold: parameters.widthThreshold)
        
        guard !allScanResults.isEmpty else {
            isProcessing = false
            return
        }
        
        // Calculate total images
        let totalImages = allScanResults.flatMap { $0.imageFiles }.count
        totalImagesToProcess = totalImages
        appendLog(String(format: NSLocalizedString("TotalImagesToProcess", comment: ""), totalImages))
        
        // Collect global batch images
        var globalBatchImages: [URL] = []
        for scanResult in allScanResults {
            if scanResult.category == .globalBatch {
                globalBatchImages.append(contentsOf: scanResult.imageFiles)
            }
        }
        
        // Determine effective parameters
        var effectiveThreadCount = parameters.threadCount
        var effectiveBatchSize = parameters.batchSize
        
        if parameters.threadCount == 0 { // Auto mode
            appendLog(NSLocalizedString("AutoModeEnabled", comment: ""))
            let autoParams = calculateAutoParameters(totalImageCount: totalImages)
            effectiveThreadCount = autoParams.threadCount
            effectiveBatchSize = autoParams.batchSize
            appendLog(String(format: NSLocalizedString("AutoAllocatedParameters", comment: ""), effectiveThreadCount, autoParams.batchSize))
        }
        
        // Pre-create output directories
        var uniqueOutputPaths = Set<String>()
        for scanResult in allScanResults {
            let subName = scanResult.directoryURL.lastPathComponent
            let dirURL = outputDir
                .appendingPathComponent(subName)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            uniqueOutputPaths.insert(dirURL.path)
        }
        
        for path in uniqueOutputPaths {
            let dirURL = URL(fileURLWithPath: path)
            guard createDirectoryAndLogErrors(directoryURL: dirURL, fileManager: fileManager) else {
                isProcessing = false
                return
            }
        }
        
        // Configure operation queue for batch operations
        processingQueue.maxConcurrentOperationCount = effectiveThreadCount
        processingQueue.underlyingQueue = processingDispatchQueue
        
        // Process using hybrid approach
        await processWithHybridApproach(
            allScanResults: allScanResults,
            globalBatchImages: globalBatchImages,
            outputDir: outputDir,
            parameters: parameters,
            effectiveThreadCount: effectiveThreadCount,
            effectiveBatchSize: effectiveBatchSize
        )
    }
    
    /// Hybrid processing using Operations with async coordination
    private func processWithHybridApproach(
        allScanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) async {
        var allOps: [BatchProcessOperation] = []
        
        // Process Isolated category
        for scanResult in allScanResults where scanResult.category == .isolated {
            let subName = scanResult.directoryURL.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)
            
            appendLog(String(format: NSLocalizedString("StartProcessingSubdir", comment: ""), subName))
            
            let batchSize: Int
            if parameters.threadCount == 0 { // Auto mode
                let isolatedDirImageCount = scanResult.imageFiles.count
                let baseIdealBatchSize = 40
                let idealNumBatchesForIsolated = Int(ceil(Double(isolatedDirImageCount) / Double(baseIdealBatchSize)))
                let adjustedNumBatchesForIsolated = roundUpToNearestMultiple(value: idealNumBatchesForIsolated, multiple: effectiveThreadCount)
                batchSize = max(1, min(1000, Int(ceil(Double(isolatedDirImageCount) / Double(adjustedNumBatchesForIsolated)))))
            } else {
                batchSize = parameters.batchSize
            }
            
            for batch in splitIntoBatches(scanResult.imageFiles, batchSize: batchSize) {
                let op = createBatchOperation(
                    images: batch,
                    outputDir: outputSubdir,
                    parameters: parameters
                )
                allOps.append(op)
            }
        }
        
        var globalProcessedCount = 0
        // Process Global Batch category
        if !globalBatchImages.isEmpty {
            appendLog(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            
            let idealNumBatchesForGlobal = Int(ceil(Double(globalBatchImages.count) / Double(effectiveBatchSize)))
            let adjustedNumBatchesForGlobal = roundUpToNearestMultiple(value: idealNumBatchesForGlobal, multiple: effectiveThreadCount)
            let effectiveGlobalBatchSize = max(1, min(1000, Int(ceil(Double(globalBatchImages.count) / Double(adjustedNumBatchesForGlobal)))))
            let globalBatches = splitIntoBatches(globalBatchImages, batchSize: effectiveGlobalBatchSize)
            
            var completedGlobalBatches = 0
            let totalGlobalBatches = globalBatches.count
            let globalBatchLock = NSLock()
            
            for batch in globalBatches {
                let op = createBatchOperation(
                    images: batch,
                    outputDir: outputDir,
                    parameters: parameters
                )
                
                let originalCompletion = op.onCompleted
                op.onCompleted = { count, fails in
                    originalCompletion?(count, fails)
                    
                    globalBatchLock.lock()
                    globalProcessedCount += count
                    completedGlobalBatches += 1
                    let isLast = (completedGlobalBatches == totalGlobalBatches)
                    globalBatchLock.unlock()
                    
                    if isLast {
                        // Defer logging of CompletedGlobalBatchWithCount until handleProcessingCompletion
                    }
                }
                
                allOps.append(op)
            }
        }
        
        // Add operations to queue
        await withCheckedContinuation { continuation in
            processingQueue.addOperations(allOps, waitUntilFinished: false)
            
            // Wait for completion using async wrapper
            processingQueue.addBarrierBlock { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.handleProcessingCompletion(scanResults: allScanResults, globalProcessedCount: globalProcessedCount)
                    continuation.resume()
                }
            }
        }
    }
    
    /// Creates a batch operation with completion handler
    private func createBatchOperation(
        images: [URL],
        outputDir: URL,
        parameters: ProcessingParameters
    ) -> BatchProcessOperation {
        let op = BatchProcessOperation(
            images: images,
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
            Task { @MainActor [weak self] in
                self?.handleBatchCompletion(processedCount: count, failedFiles: fails)
            }
        }
        
        return op
    }
    
    /// Handles batch completion
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) {
        totalImagesProcessed += processedCount
        allFailedFiles.append(contentsOf: failedFiles)
        
        currentProcessedImages += processedCount
        if totalImagesToProcess > 0 {
            processingProgress = Double(currentProcessedImages) / Double(totalImagesToProcess)
        } else {
            processingProgress = 0.0
        }
    }
    
    /// Handles final processing completion
    private func handleProcessingCompletion(scanResults: [DirectoryScanResult], globalProcessedCount: Int) async {
        let elapsed = Int(Date().timeIntervalSince(processingStartTime ?? Date()))
        let duration = formatProcessingTime(elapsed)
        
        let processedCount = totalImagesProcessed
        let failedFiles = allFailedFiles
        
        var completionLogs: [String] = []
        
        if processedCount == 0 {
            completionLogs.append(NSLocalizedString("ProcessingComplete", comment: ""))
        } else {
            // Add per-directory results
            for scanResult in scanResults where scanResult.category == .isolated {
                let logMessage = String(format: NSLocalizedString("ProcessedSubdir", comment: ""),
                                        scanResult.directoryURL.lastPathComponent)
                completionLogs.append(logMessage)
            }
            // Add global batch completion message if applicable
            if globalProcessedCount > 0 {
                completionLogs.append(String(format: NSLocalizedString("CompletedGlobalBatchWithCount", comment: ""), globalProcessedCount))
            }
            
            // Add failed files summary
            if !failedFiles.isEmpty {
                completionLogs.append(String(format: NSLocalizedString("FailedFiles", comment: ""), failedFiles.count))
                for file in failedFiles.prefix(10) {
                    completionLogs.append("- \(file)")
                }
                if failedFiles.count > 10 {
                    completionLogs.append(String(format: ". %d more", failedFiles.count - 10))
                }
            }
            
            // Add final summary logs
            completionLogs.append(String(format: NSLocalizedString("TotalImagesProcessed", comment: ""), processedCount))
            completionLogs.append(duration)
            completionLogs.append(NSLocalizedString("ProcessingComplete", comment: ""))
        }
        
        // Send logs in order
        appendLogsInOrder(completionLogs)
        
        // Send notification
        if processedCount > 0 {
            notificationManager.sendNotification(
                title: NSLocalizedString("ProcessingCompleteTitle", comment: ""),
                subtitle: failedFiles.count > 0 ?
                    String(format: NSLocalizedString("ProcessingCompleteWithFailures", comment: ""),
                           processedCount, failedFiles.count) :
                    String(format: NSLocalizedString("ProcessingCompleteSuccess", comment: ""), processedCount),
                body: duration
            )
        }
        
        // Update completion state
        didFinishAllTasks = true
        
        // Schedule final reset
        Task {
            try? await Task.sleep(nanoseconds: 500000000) // 0.5 seconds
            
            guard isProcessing else {
                didFinishAllTasks = false
                return
            }
            
            isProcessing = false
            totalImagesToProcess = 0
            currentProcessedImages = 0
            processingProgress = 0.0
            didFinishAllTasks = false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Resets internal processing state
    private func resetProcessingState() {
        processingQueue.cancelAllOperations()
        totalImagesProcessed = 0
        allFailedFiles.removeAll()
        processingStartTime = Date()
        totalImagesToProcess = 0
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Logs initial processing parameters
    private func logStartParameters(_ threshold: Int, _ resize: Int, _ qual: Int, _ threadCount: Int,
                                    _ radius: Float, _ sigma: Float, _ amount: Float, _ unsharpThreshold: Float,
                                    _ useGrayColorspace: Bool)
    {
        if amount > 0 {
            appendLog(String(format: NSLocalizedString("StartProcessingWithUnsharp", comment: ""),
                             threshold, resize, qual, threadCount, radius, sigma, amount, unsharpThreshold,
                             NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
        } else {
            appendLog(String(format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                             threshold, resize, qual, threadCount,
                             NSLocalizedString(useGrayColorspace ? "GrayEnabled" : "GrayDisabled", comment: "")))
        }
    }
    
    /// Async GraphicsMagick verification
    private func verifyGraphicsMagickAsync() async -> Bool {
        let path = await Task.detached {
            GraphicsMagickHelper.detectGMPathSafely(logHandler: { message in
                Task { @MainActor [weak self] in
                    self?.appendLog(message)
                }
            })
        }.value
        
        guard let path = path else {
            return false
        }
        
        gmPath = path
        
        return await Task.detached {
            GraphicsMagickHelper.verifyGraphicsMagick(gmPath: path, logHandler: { message in
                Task { @MainActor [weak self] in
                    self?.appendLog(message)
                }
            })
        }.value
    }
    
    /// Creates a directory with error logging
    private func createDirectoryAndLogErrors(directoryURL: URL, fileManager: FileManager) -> Bool {
        do {
            let canonicalDir = directoryURL.resolvingSymlinksInPath()
            try fileManager.createDirectory(at: canonicalDir, withIntermediateDirectories: true)
            return true
        } catch {
            appendLog(String(format: NSLocalizedString("CannotCreateOutputDir", comment: ""),
                             error.localizedDescription))
            return false
        }
    }
    
    /// Calculates auto-allocated thread count and batch size
    private func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        var effectiveThreadCount: Int
        let maxThreadCount = 6
        
        if totalImageCount < 10 {
            effectiveThreadCount = 1
        } else if totalImageCount <= 50 {
            effectiveThreadCount = 1 + Int(ceil(Double(totalImageCount - 10) / 20.0))
            effectiveThreadCount = min(3, effectiveThreadCount)
        } else if totalImageCount <= 300 {
            effectiveThreadCount = 3 + Int(ceil(Double(totalImageCount - 50) / 50.0))
            effectiveThreadCount = min(maxThreadCount, effectiveThreadCount)
        } else {
            effectiveThreadCount = maxThreadCount
        }
        
        effectiveThreadCount = max(1, min(maxThreadCount, effectiveThreadCount))
        let effectiveBatchSize = max(1, min(1000, Int(ceil(Double(totalImageCount) / Double(effectiveThreadCount)))))
        
        return (threadCount: effectiveThreadCount, batchSize: effectiveBatchSize)
    }
    
    /// Rounds up to nearest multiple
    private func roundUpToNearestMultiple(value: Int, multiple: Int) -> Int {
        guard multiple != 0 else { return value }
        let remainder = value % multiple
        if remainder == 0 { return value }
        return value + (multiple - remainder)
    }
    
    /// Splits images into batches
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
    
    /// Formats processing time
    private func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(format: NSLocalizedString("ProcessingTimeSeconds", comment: ""), seconds)
        } else {
            let minutes = seconds / 60
            let remaining = seconds % 60
            return String(format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""), minutes, remaining)
        }
    }
}
