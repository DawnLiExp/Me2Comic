//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation

// MARK: - Processing Parameters

/// Configuration for image processing
struct ProcessingParameters {
    let widthThreshold: Int
    let resizeHeight: Int
    let quality: Int
    let threadCount: Int // Concurrent threads (0=auto, 1-6)
    let unsharpRadius: Float
    let unsharpSigma: Float
    let unsharpAmount: Float
    let unsharpThreshold: Float
    let batchSize: Int // Images per batch (1-1000)
    let useGrayColorspace: Bool
}

// MARK: - Batch Result Aggregator

/// Thread-safe aggregation of batch processing results
private actor BatchResultAggregator {
    private var totalProcessed = 0
    private var failedFiles: [String] = []
    
    func addResult(processed: Int, failed: [String]) {
        totalProcessed += processed
        failedFiles.append(contentsOf: failed)
    }
    
    func getResults() -> (processed: Int, failed: [String]) {
        (totalProcessed, failedFiles)
    }
    
    func reset() {
        totalProcessed = 0
        failedFiles.removeAll()
    }
}

// MARK: - Image Processor

/// Manages the image processing workflow
@MainActor
class ImageProcessor: ObservableObject {
    // MARK: - Properties
    
    private let notificationManager = NotificationManager()
    private let batchResultAggregator = BatchResultAggregator()
    private var gmPath = ""
    private var processingStartTime: Date?
    private var activeProcessingTask: Task<Void, Never>?
    private var logContinuation: AsyncStream<String>.Continuation?
    
    // MARK: - Published State
    
    @Published var isProcessing = false
    @Published var logMessages: [String] = []
    @Published var totalImagesToProcess = 0
    @Published var currentProcessedImages = 0
    @Published var processingProgress = 0.0
    @Published var didFinishAllTasks = false
    
    // MARK: - Constants
    
    private enum Constants {
        static let maxLogMessages = 100
        static let autoModeThreadCount = 0
        static let maxThreadCount = 6
        static let defaultBatchSize = 40
        static let maxBatchSize = 1000
        static let completionDelay: UInt64 = 500_000_000 // 0.5 seconds
    }
    
    // MARK: - Initialization
    
    init() {
        setupLogStream()
    }
    
    // MARK: - Logging
    
    /// Configures async log stream for ordered message delivery
    private func setupLogStream() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        logContinuation = continuation
        
        Task {
            for await message in stream {
                logMessages.append(message)
                if logMessages.count > Constants.maxLogMessages {
                    logMessages.removeFirst(logMessages.count - Constants.maxLogMessages)
                }
            }
        }
    }
    
    /// Appends log message via async stream
    func appendLog(_ message: String) {
        logContinuation?.yield(message)
    }
    
    /// Appends multiple log messages synchronously
    private func appendLogsBatch(_ messages: [String]) {
        messages.forEach { logContinuation?.yield($0) }
    }
    
    // MARK: - Processing Control
    
    /// Stops all active processing
    func stopProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        
        appendLog(NSLocalizedString("ProcessingStopRequested", comment: ""))
        appendLog(NSLocalizedString("ProcessingStopped", comment: ""))
        
        resetUIState()
    }
    
    /// Initiates image processing workflow
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        activeProcessingTask?.cancel()
        
        isProcessing = true
        resetProcessingState()
        logStartParameters(parameters)
        
        activeProcessingTask = Task {
            await processImagesAsync(
                inputDir: inputDir,
                outputDir: outputDir,
                parameters: parameters
            )
        }
    }
    
    // MARK: - Private Processing Methods
    
    /// Main async processing implementation
    private func processImagesAsync(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) async {
        guard await verifyGraphicsMagickAsync() else {
            isProcessing = false
            return
        }
        
        guard createDirectory(at: outputDir) else {
            isProcessing = false
            return
        }
        
        guard !Task.isCancelled else {
            isProcessing = false
            return
        }
        
        await processDirectoriesAsync(
            inputDir: inputDir,
            outputDir: outputDir,
            parameters: parameters
        )
    }
    
    /// Process directories with categorization
    private func processDirectoriesAsync(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) async {
        let analyzer = ImageDirectoryAnalyzer(
            logHandler: { [weak self] in self?.appendLog($0) },
            isProcessingCheck: { [weak self] in
                guard let self = self else { return false }
                return self.isProcessing && !Task.isCancelled
            }
        )
        
        let scanResults = await analyzer.analyzeAsync(
            inputDir: inputDir,
            widthThreshold: parameters.widthThreshold
        )
        
        guard !scanResults.isEmpty else {
            isProcessing = false
            return
        }
        
        let totalImages = scanResults.reduce(0) { $0 + $1.imageFiles.count }
        totalImagesToProcess = totalImages
        appendLog(String(format: NSLocalizedString("TotalImagesToProcess", comment: ""), totalImages))
        
        let globalBatchImages = scanResults
            .filter { $0.category == .globalBatch }
            .flatMap { $0.imageFiles }
        
        let (effectiveThreadCount, effectiveBatchSize) = determineParameters(
            parameters: parameters,
            totalImages: totalImages
        )
        
        guard await createOutputDirectories(scanResults: scanResults, outputDir: outputDir) else {
            isProcessing = false
            return
        }
        
        await processBatches(
            scanResults: scanResults,
            globalBatchImages: globalBatchImages,
            outputDir: outputDir,
            parameters: parameters,
            effectiveThreadCount: effectiveThreadCount,
            effectiveBatchSize: effectiveBatchSize
        )
    }
    
    /// Process batches with controlled concurrency
    private func processBatches(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) async {
        guard isProcessing && !Task.isCancelled else { return }
        
        let batchTasks = prepareBatchTasks(
            scanResults: scanResults,
            globalBatchImages: globalBatchImages,
            outputDir: outputDir,
            parameters: parameters,
            effectiveThreadCount: effectiveThreadCount,
            effectiveBatchSize: effectiveBatchSize
        )
        
        guard !batchTasks.isEmpty else { return }
        
        var globalProcessedCount = 0
        
        await withTaskGroup(of: BatchResult.self) { group in
            let semaphore = AsyncSemaphore(limit: effectiveThreadCount)
            
            for task in batchTasks {
                guard !Task.isCancelled else { break }
                
                group.addTask { [weak self] in
                    guard let self = self else { return BatchResult.empty }
                    
                    await semaphore.wait()
                    defer { Task { await semaphore.signal() } }
  
                    let shouldContinue = await MainActor.run {
                        !Task.isCancelled && self.isProcessing
                    }
                    
                    guard shouldContinue else {
                        return BatchResult.empty
                    }
                    
                    let (processed, failed) = await self.processBatch(
                        images: task.images,
                        outputDir: task.outputDir,
                        parameters: parameters
                    )
                    
                    return BatchResult(
                        processed: processed,
                        failed: failed,
                        isGlobal: task.isGlobal
                    )
                }
            }
            
            for await result in group {
                guard !Task.isCancelled && isProcessing else { break }
                
                await handleBatchCompletion(
                    processedCount: result.processed,
                    failedFiles: result.failed
                )
                
                if result.isGlobal {
                    globalProcessedCount += result.processed
                }
            }
        }
        
        guard !Task.isCancelled && isProcessing else { return }
        
        await handleProcessingCompletion(
            scanResults: scanResults,
            globalProcessedCount: globalProcessedCount
        )
    }
    
    /// Process single batch
    private func processBatch(
        images: [URL],
        outputDir: URL,
        parameters: ProcessingParameters
    ) async -> (processed: Int, failed: [String]) {
        let processor = BatchImageProcessor(
            gmPath: gmPath,
            widthThreshold: parameters.widthThreshold,
            resizeHeight: parameters.resizeHeight,
            quality: parameters.quality,
            unsharpRadius: parameters.unsharpRadius,
            unsharpSigma: parameters.unsharpSigma,
            unsharpAmount: parameters.unsharpAmount,
            unsharpThreshold: parameters.unsharpThreshold,
            useGrayColorspace: parameters.useGrayColorspace
        )
        
        return await processor.processBatch(
            images: images,
            outputDir: outputDir
        )
    }
    
    /// Update progress after batch completion
    private func handleBatchCompletion(processedCount: Int, failedFiles: [String]) async {
        await batchResultAggregator.addResult(
            processed: processedCount,
            failed: failedFiles
        )
        
        currentProcessedImages += processedCount
        processingProgress = totalImagesToProcess > 0
            ? Double(currentProcessedImages) / Double(totalImagesToProcess)
            : 0.0
    }
    
    /// Handle final completion
    private func handleProcessingCompletion(
        scanResults: [DirectoryScanResult],
        globalProcessedCount: Int
    ) async {
        let elapsed = Int(Date().timeIntervalSince(processingStartTime ?? Date()))
        let duration = formatProcessingTime(elapsed)
        let (processedCount, failedFiles) = await batchResultAggregator.getResults()
        
        var completionLogs: [String] = []
        
        if processedCount > 0 {
            // Add per-directory results
            scanResults
                .filter { $0.category == .isolated }
                .forEach { result in
                    completionLogs.append(String(
                        format: NSLocalizedString("ProcessedSubdir", comment: ""),
                        result.directoryURL.lastPathComponent
                    ))
                }
            
            // Add global batch results
            if globalProcessedCount > 0 {
                completionLogs.append(String(
                    format: NSLocalizedString("CompletedGlobalBatchWithCount", comment: ""),
                    globalProcessedCount
                ))
            }
            
            // Add failure summary
            if !failedFiles.isEmpty {
                completionLogs.append(String(
                    format: NSLocalizedString("FailedFiles", comment: ""),
                    failedFiles.count
                ))
                
                for item in failedFiles.prefix(10) {
                    completionLogs.append("- \(item)")
                }
                
                if failedFiles.count > 10 {
                    completionLogs.append("... \(failedFiles.count - 10) more")
                }
            }
            
            // Add summary
            completionLogs.append(String(
                format: NSLocalizedString("TotalImagesProcessed", comment: ""),
                processedCount
            ))
            completionLogs.append(duration)
        }
        
        completionLogs.append(NSLocalizedString("ProcessingComplete", comment: ""))
        appendLogsBatch(completionLogs)
        
        // Send notification
        if processedCount > 0 {
            await sendCompletionNotification(
                processedCount: processedCount,
                failedCount: failedFiles.count,
                duration: duration
            )
        }
        
        didFinishAllTasks = true
        
        // Schedule cleanup
        Task {
            try? await Task.sleep(nanoseconds: Constants.completionDelay)
            guard isProcessing else {
                didFinishAllTasks = false
                return
            }
            resetUIState()
            didFinishAllTasks = false
        }
    }
    
    // MARK: - Helper Methods
    
    /// Prepare batch tasks for processing
    private func prepareBatchTasks(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) -> [BatchTask] {
        var tasks: [BatchTask] = []
        
        // Prepare isolated directory tasks
        for result in scanResults where result.category == .isolated {
            let subName = result.directoryURL.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)
            
            appendLog(String(
                format: NSLocalizedString("StartProcessingSubdir", comment: ""),
                subName
            ))
            
            let batchSize = calculateBatchSize(
                imageCount: result.imageFiles.count,
                threadCount: effectiveThreadCount,
                isAuto: parameters.threadCount == Constants.autoModeThreadCount,
                defaultSize: parameters.batchSize
            )
            
            for batch in splitIntoBatches(result.imageFiles, batchSize: batchSize) {
                tasks.append(BatchTask(
                    images: batch,
                    outputDir: outputSubdir,
                    batchSize: batchSize,
                    isGlobal: false
                ))
            }
        }
        
        // Prepare global batch tasks
        if !globalBatchImages.isEmpty {
            appendLog(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            
            let globalBatchSize = calculateGlobalBatchSize(
                imageCount: globalBatchImages.count,
                threadCount: effectiveThreadCount,
                baseBatchSize: effectiveBatchSize
            )
            
            for batch in splitIntoBatches(globalBatchImages, batchSize: globalBatchSize) {
                tasks.append(BatchTask(
                    images: batch,
                    outputDir: outputDir,
                    batchSize: globalBatchSize,
                    isGlobal: true
                ))
            }
        }
        
        return tasks
    }
    
    /// Calculate batch size for isolated directories
    private func calculateBatchSize(
        imageCount: Int,
        threadCount: Int,
        isAuto: Bool,
        defaultSize: Int
    ) -> Int {
        guard isAuto else { return defaultSize }
        
        let idealBatches = Int(ceil(Double(imageCount) / Double(Constants.defaultBatchSize)))
        let adjustedBatches = roundUpToNearestMultiple(
            value: idealBatches,
            multiple: threadCount
        )
        
        return max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(imageCount) / Double(adjustedBatches)))
        ))
    }
    
    /// Calculate batch size for global processing
    private func calculateGlobalBatchSize(
        imageCount: Int,
        threadCount: Int,
        baseBatchSize: Int
    ) -> Int {
        let idealBatches = Int(ceil(Double(imageCount) / Double(baseBatchSize)))
        let adjustedBatches = roundUpToNearestMultiple(
            value: idealBatches,
            multiple: threadCount
        )
        
        return max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(imageCount) / Double(adjustedBatches)))
        ))
    }
    
    /// Determine effective parameters based on auto mode
    private func determineParameters(
        parameters: ProcessingParameters,
        totalImages: Int
    ) -> (threadCount: Int, batchSize: Int) {
        guard parameters.threadCount == Constants.autoModeThreadCount else {
            return (parameters.threadCount, parameters.batchSize)
        }
        
        appendLog(NSLocalizedString("AutoModeEnabled", comment: ""))
        
        let autoParams = calculateAutoParameters(totalImageCount: totalImages)
        
        appendLog(String(
            format: NSLocalizedString("AutoAllocatedParameters", comment: ""),
            autoParams.threadCount,
            autoParams.batchSize
        ))
        
        return autoParams
    }
    
    /// Calculate auto-allocated parameters
    private func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        let threadCount: Int = {
            switch totalImageCount {
            case ..<10:
                return 1
            case 10..<50:
                return min(3, 1 + Int(ceil(Double(totalImageCount - 10) / 20.0)))
            case 50..<300:
                return min(Constants.maxThreadCount, 3 + Int(ceil(Double(totalImageCount - 50) / 50.0)))
            default:
                return Constants.maxThreadCount
            }
        }()
        
        let batchSize = max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(totalImageCount) / Double(threadCount)))
        ))
        
        return (threadCount, batchSize)
    }
    
    /// Reset processing state
    private func resetProcessingState() {
        Task { await batchResultAggregator.reset() }
        processingStartTime = Date()
        totalImagesToProcess = 0
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Reset UI state
    private func resetUIState() {
        isProcessing = false
        totalImagesToProcess = 0
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Log processing parameters
    private func logStartParameters(_ parameters: ProcessingParameters) {
        let grayStatus = NSLocalizedString(
            parameters.useGrayColorspace ? "GrayEnabled" : "GrayDisabled",
            comment: ""
        )
        
        if parameters.unsharpAmount > 0 {
            appendLog(String(
                format: NSLocalizedString("StartProcessingWithUnsharp", comment: ""),
                parameters.widthThreshold,
                parameters.resizeHeight,
                parameters.quality,
                parameters.threadCount,
                parameters.unsharpRadius,
                parameters.unsharpSigma,
                parameters.unsharpAmount,
                parameters.unsharpThreshold,
                grayStatus
            ))
        } else {
            appendLog(String(
                format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                parameters.widthThreshold,
                parameters.resizeHeight,
                parameters.quality,
                parameters.threadCount,
                grayStatus
            ))
        }
    }
    
    /// Verify GraphicsMagick installation
    private func verifyGraphicsMagickAsync() async -> Bool {
        let path = await Task.detached {
            GraphicsMagickHelper.detectGMPathSafely { message in
                Task { @MainActor [weak self] in
                    self?.appendLog(message)
                }
            }
        }.value
        
        guard let path = path else { return false }
        
        gmPath = path
        
        return await Task.detached {
            GraphicsMagickHelper.verifyGraphicsMagick(
                gmPath: path,
                logHandler: { message in
                    Task { @MainActor [weak self] in
                        self?.appendLog(message)
                    }
                }
            )
        }.value
    }
    
    /// Create directory with error handling
    private func createDirectory(at url: URL) -> Bool {
        do {
            let canonicalURL = url.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: canonicalURL,
                withIntermediateDirectories: true
            )
            return true
        } catch {
            appendLog(String(
                format: NSLocalizedString("CannotCreateOutputDir", comment: ""),
                error.localizedDescription
            ))
            return false
        }
    }
    
    /// Create output directories for scan results
    private func createOutputDirectories(
        scanResults: [DirectoryScanResult],
        outputDir: URL
    ) async -> Bool {
        let uniquePaths = Set(scanResults.map { result in
            outputDir
                .appendingPathComponent(result.directoryURL.lastPathComponent)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        })
        
        for path in uniquePaths {
            guard createDirectory(at: URL(fileURLWithPath: path)) else {
                return false
            }
        }
        
        return true
    }
    
    /// Send completion notification
    private func sendCompletionNotification(
        processedCount: Int,
        failedCount: Int,
        duration: String
    ) async {
        let subtitle = failedCount > 0
            ? String(
                format: NSLocalizedString("ProcessingCompleteWithFailures", comment: ""),
                processedCount,
                failedCount
            )
            : String(
                format: NSLocalizedString("ProcessingCompleteSuccess", comment: ""),
                processedCount
            )
        
        try? await notificationManager.sendNotification(
            title: NSLocalizedString("ProcessingCompleteTitle", comment: ""),
            subtitle: subtitle,
            body: duration
        )
    }
    
    /// Round up to nearest multiple
    private func roundUpToNearestMultiple(value: Int, multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        let remainder = value % multiple
        return remainder == 0 ? value : value + (multiple - remainder)
    }
    
    /// Split array into batches
    private func splitIntoBatches<T>(_ items: [T], batchSize: Int) -> [[T]] {
        guard batchSize > 0, !items.isEmpty else { return [] }
        
        return stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0..<min($0 + batchSize, items.count)])
        }
    }
    
    /// Format processing time for display
    private func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(
                format: NSLocalizedString("ProcessingTimeSeconds", comment: ""),
                seconds
            )
        } else {
            return String(
                format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""),
                seconds / 60,
                seconds % 60
            )
        }
    }
}

// MARK: - Supporting Types

/// Batch processing task descriptor
private struct BatchTask {
    let images: [URL]
    let outputDir: URL
    let batchSize: Int
    let isGlobal: Bool
}

/// Batch processing result
private struct BatchResult {
    let processed: Int
    let failed: [String]
    let isGlobal: Bool
    
    static var empty: BatchResult {
        BatchResult(processed: 0, failed: [], isGlobal: false)
    }
}

/// Async semaphore for concurrency control
private actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(limit: Int) {
        self.limit = limit
        available = limit
    }
    
    func wait() async {
        if available > 0 {
            available -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }
    
    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            available = min(available + 1, limit)
        }
    }
}
