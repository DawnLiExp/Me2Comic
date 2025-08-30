//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation

/// Async semaphore for concurrency control
actor AsyncSemaphore {
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

/// Manages the image processing workflow
@MainActor
class ImageProcessor: ObservableObject {
    // MARK: - Properties
    
    private let notificationManager = NotificationManager()
    private let stateManager = ProcessingStateManager()
    private let logger = ProcessingLogger()
    private let taskOrganizer: BatchTaskOrganizer
    private let autoCalculator: AutoParameterCalculator
    
    private var gmPath = ""
    private var activeProcessingTask: Task<Void, Never>?
    
    // MARK: - Published State (Forwarded from components)
    
    @Published var isProcessing = false { didSet { stateManager.isProcessing = isProcessing } }
    @Published var logMessages: [String] = [] { didSet { logger.logMessages = logMessages } }
    @Published var totalImagesToProcess = 0 { didSet { stateManager.totalImagesToProcess = totalImagesToProcess } }
    @Published var currentProcessedImages = 0 { didSet { stateManager.currentProcessedImages = currentProcessedImages } }
    @Published var processingProgress = 0.0 { didSet { stateManager.processingProgress = processingProgress } }
    @Published var didFinishAllTasks = false { didSet { stateManager.didFinishAllTasks = didFinishAllTasks } }
    
    // MARK: - Initialization
    
    init() {
        taskOrganizer = BatchTaskOrganizer(logger: logger)
        autoCalculator = AutoParameterCalculator(logger: logger)
        
        // Bind state changes
        setupBindings()
    }
    
    // MARK: - Public Methods
    
    /// Appends log message (forwarded to logger)
    func appendLog(_ message: String) {
        logger.appendLog(message)
    }
    
    /// Stops all active processing
    func stopProcessing() {
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        
        logger.appendLog(NSLocalizedString("ProcessingStopRequested", comment: ""))
        logger.appendLog(NSLocalizedString("ProcessingStopped", comment: ""))
        
        stateManager.stopProcessing()
    }
    
    /// Initiates image processing workflow
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        activeProcessingTask?.cancel()
        
        stateManager.startProcessing()
        logger.logStartParameters(parameters)
        
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
            stateManager.stopProcessing()
            return
        }
        
        guard createDirectory(at: outputDir) else {
            stateManager.stopProcessing()
            return
        }
        
        guard !Task.isCancelled else {
            stateManager.stopProcessing()
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
            logHandler: { [weak self] in self?.logger.appendLog($0) },
            isProcessingCheck: { [weak self] in
                guard let self = self else { return false }
                return self.stateManager.isProcessing && !Task.isCancelled
            }
        )
        
        let scanResults = await analyzer.analyzeAsync(
            inputDir: inputDir,
            widthThreshold: parameters.widthThreshold
        )
        
        guard !scanResults.isEmpty else {
            stateManager.stopProcessing()
            return
        }
        
        let totalImages = scanResults.reduce(0) { $0 + $1.imageFiles.count }
        stateManager.setTotalImages(totalImages)
        logger.appendLog(String(format: NSLocalizedString("TotalImagesToProcess", comment: ""), totalImages))
        
        let globalBatchImages = scanResults
            .filter { $0.category == .globalBatch }
            .flatMap { $0.imageFiles }
        
        let (effectiveThreadCount, effectiveBatchSize) = autoCalculator.determineParameters(
            parameters: parameters,
            totalImages: totalImages
        )
        
        guard await createOutputDirectories(scanResults: scanResults, outputDir: outputDir) else {
            stateManager.stopProcessing()
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
        guard stateManager.isProcessing && !Task.isCancelled else { return }
        
        let batchTasks = taskOrganizer.prepareBatchTasks(
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
                        !Task.isCancelled && self.stateManager.isProcessing
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
                guard !Task.isCancelled && stateManager.isProcessing else { break }
                
                await stateManager.handleBatchCompletion(
                    processedCount: result.processed,
                    failedFiles: result.failed
                )
                
                if result.isGlobal {
                    globalProcessedCount += result.processed
                }
            }
        }
        
        guard !Task.isCancelled && stateManager.isProcessing else { return }
        
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
    
    /// Handle final completion
    private func handleProcessingCompletion(
        scanResults: [DirectoryScanResult],
        globalProcessedCount: Int
    ) async {
        let elapsed = stateManager.getElapsedTime()
        let duration = logger.formatProcessingTime(elapsed)
        let (processedCount, failedFiles) = await stateManager.getAggregatedResults()
        
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
        logger.appendLogsBatch(completionLogs)
        
        // Send notification
        if processedCount > 0 {
            await sendCompletionNotification(
                processedCount: processedCount,
                failedCount: failedFiles.count,
                duration: duration
            )
        }
        
        stateManager.markTasksFinished()
    }
    
    // MARK: - Helper Methods
    
    /// Setup property bindings between components
    private func setupBindings() {
        stateManager.$isProcessing
            .receive(on: DispatchQueue.main)
            .assign(to: &$isProcessing)
        
        stateManager.$totalImagesToProcess
            .receive(on: DispatchQueue.main)
            .assign(to: &$totalImagesToProcess)
        
        stateManager.$currentProcessedImages
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentProcessedImages)
        
        stateManager.$processingProgress
            .receive(on: DispatchQueue.main)
            .assign(to: &$processingProgress)
        
        stateManager.$didFinishAllTasks
            .receive(on: DispatchQueue.main)
            .assign(to: &$didFinishAllTasks)
        
        logger.$logMessages
            .receive(on: DispatchQueue.main)
            .assign(to: &$logMessages)
    }
    
    /// Verify GraphicsMagick installation
    private func verifyGraphicsMagickAsync() async -> Bool {
        let path = await Task.detached {
            GraphicsMagickHelper.detectGMPathSafely { message in
                Task { @MainActor [weak self] in
                    self?.logger.appendLog(message)
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
                        self?.logger.appendLog(message)
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
            logger.appendLog(String(
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
}
