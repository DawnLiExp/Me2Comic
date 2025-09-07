//
//  ImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/5/12.
//

import Combine
import Foundation

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
        
        #if DEBUG
        logger.logDebug("ImageProcessor initialized", source: "ImageProcessor")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Appends log message (forwarded to logger)
    func appendLog(_ message: String) {
        logger.appendLog(message)
    }
    
    /// Stops all active processing
    func stopProcessing() {
        #if DEBUG
        logger.logDebug("Stop processing requested", source: "ImageProcessor")
        #endif
        
        activeProcessingTask?.cancel()
        activeProcessingTask = nil
        
        logger.appendLog(NSLocalizedString("ProcessingStopRequested", comment: ""))
        logger.appendLog(NSLocalizedString("ProcessingStopped", comment: ""))
        
        stateManager.stopProcessing()
    }
    
    /// Initiates image processing workflow
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        #if DEBUG
        logger.logDebug("Starting image processing workflow", source: "ImageProcessor")
        logger.logDebug("Input: \(inputDir.path)", source: "ImageProcessor")
        logger.logDebug("Output: \(outputDir.path)", source: "ImageProcessor")
        #endif
        
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
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        
        let gmResult = await GraphicsMagickHelper.verifyGraphicsMagickAsync(logger: loggerClosure)
        switch gmResult {
        case .success(let path):
            gmPath = path
        case .failure(let error):
            #if DEBUG
            logger.logDebug("GraphicsMagick verification failed: \(error)", source: "ImageProcessor")
            #endif
            logger.logError(error.localizedDescription, source: "ImageProcessor")
            stateManager.stopProcessing()
            return
        }
        
        let dirResult = FileSystemHelper.createDirectory(at: outputDir)
        if case .failure(let error) = dirResult {
            #if DEBUG
            logger.logDebug("Output directory creation failed: \(error)", source: "ImageProcessor")
            #endif
            logger.logError(error.localizedDescription, source: "ImageProcessor")
            stateManager.stopProcessing()
            return
        }
        
        guard !Task.isCancelled else {
            #if DEBUG
            logger.logDebug("Processing task cancelled before directory processing", source: "ImageProcessor")
            #endif
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
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        
        let analyzer = DirectoryAnalyzer(
            logHandler: loggerClosure,
            isProcessingCheck: { @Sendable [weak self] in
                guard let self = self else { return false }
                return await MainActor.run {
                    self.stateManager.isProcessing && !Task.isCancelled
                }
            }
        )
        
        let scanResults = await analyzer.analyzeAsync(
            inputDir: inputDir,
            widthThreshold: parameters.widthThreshold
        )
        
        guard !scanResults.isEmpty else {
            #if DEBUG
            logger.logDebug("No scan results available, stopping processing", source: "ImageProcessor")
            #endif
            stateManager.stopProcessing()
            return
        }
        
        let totalImages = scanResults.reduce(0) { $0 + $1.imageFiles.count }
        stateManager.setTotalImages(totalImages)
        logger.appendLog(String(format: NSLocalizedString("TotalImagesToProcess", comment: ""), totalImages))
        
        #if DEBUG
        logger.logDebug("Processing \(totalImages) total images across \(scanResults.count) directories", source: "ImageProcessor")
        #endif
        
        // Check if any directory contains high resolution images
        let hasHighResolution = scanResults.contains { $0.isHighResolution }
        
        let globalBatchImages = scanResults
            .filter { $0.category == .globalBatch }
            .flatMap { $0.imageFiles }
        
        let (effectiveThreadCount, effectiveBatchSize) = autoCalculator.determineParameters(
            parameters: parameters,
            totalImages: totalImages,
            hasHighResolution: hasHighResolution
        )
        
        #if DEBUG
        logger.logDebug("Effective parameters: threads=\(effectiveThreadCount), batchSize=\(effectiveBatchSize)\(hasHighResolution ? " [High Resolution Mode]" : "")", source: "ImageProcessor")
        #endif
        
        let createResult = FileSystemHelper.createOutputDirectories(
            scanResults: scanResults,
            outputDir: outputDir
        )
        if case .failure(let error) = createResult {
            #if DEBUG
            logger.logDebug("Output directory setup failed: \(error)", source: "ImageProcessor")
            #endif
            logger.logError(error.localizedDescription, source: "ImageProcessor")
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
    
    /// Process batches with controlled concurrency and work-stealing
    private func processBatches(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) async {
        guard stateManager.isProcessing && !Task.isCancelled else {
            #if DEBUG
            logger.logDebug("Batch processing skipped due to cancellation or state", source: "ImageProcessor")
            #endif
            return
        }
        
        let batchTasks = taskOrganizer.prepareBatchTasks(
            scanResults: scanResults,
            globalBatchImages: globalBatchImages,
            outputDir: outputDir,
            parameters: parameters,
            effectiveThreadCount: effectiveThreadCount,
            effectiveBatchSize: effectiveBatchSize
        )
        
        guard !batchTasks.isEmpty else {
            #if DEBUG
            logger.logDebug("No batch tasks generated", source: "ImageProcessor")
            #endif
            return
        }
        
        #if DEBUG
        logger.logDebug("Generated \(batchTasks.count) batch tasks for concurrent processing", source: "ImageProcessor")
        #endif
        
        // Initialize task queue with priority sorting
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        let taskQueue = TaskQueue(logger: loggerClosure)
        await taskQueue.initialize(with: batchTasks)
        
        var globalProcessedCount = 0
        
        await withTaskGroup(of: BatchResult.self) { group in
            // Start worker threads
            for threadId in 0 ..< effectiveThreadCount {
                group.addTask { [weak self] in
                    guard let self = self else { return BatchResult.empty }
                    
                    var localResults = BatchResult.empty
                    
                    // Work-stealing loop: keep processing until no tasks remain
                    while !Task.isCancelled {
                        // Check processing state
                        let shouldContinue = await MainActor.run {
                            self.stateManager.isProcessing
                        }
                        guard shouldContinue else { break }
                        
                        // Get next task from queue (work-stealing enabled)
                        guard let task = await taskQueue.getNextTask(threadId: threadId) else {
                            break // No more tasks available
                        }
                        
                        // Process the task
                        let (processed, failed) = await self.processBatch(
                            images: task.images,
                            outputDir: task.outputDir,
                            parameters: parameters
                        )
                        
                        // Mark task completed
                        await taskQueue.markCompleted()
                        
                        // Accumulate results for this thread
                        localResults = BatchResult(
                            processed: localResults.processed + processed,
                            failed: localResults.failed + failed,
                            isGlobal: task.isGlobal || localResults.isGlobal
                        )
                        
                        #if DEBUG
                        let progress = await taskQueue.getProgress()
                        await MainActor.run {
                            self.logger.logDebug("Thread \(threadId) completed task: \(progress.completed)/\(progress.total) done, \(progress.remaining) remaining", source: "ImageProcessor")
                        }
                        #endif
                    }
                    
                    return localResults
                }
            }
            
            // Collect results from all threads
            for await result in group {
                guard !Task.isCancelled && stateManager.isProcessing else { break }
                
                await stateManager.handleBatchCompletion(
                    processedCount: result.processed,
                    failedFiles: result.failed
                )
                
                if result.isGlobal {
                    globalProcessedCount += result.processed
                }
                
                #if DEBUG
                logger.logDebug("Worker thread completed: processed=\(result.processed), failed=\(result.failed.count)", source: "ImageProcessor")
                #endif
            }
        }
        
        #if DEBUG
        let stats = await taskQueue.getStatistics()
        logger.logDebug("Work distribution: \(stats.distribution), steal operations: \(stats.stealCount)", source: "ImageProcessor")
        #endif
        
        guard !Task.isCancelled && stateManager.isProcessing else {
            #if DEBUG
            logger.logDebug("Batch processing completed due to cancellation", source: "ImageProcessor")
            #endif
            return
        }
        
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
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        
        let processor = BatchImageProcessor(
            gmPath: gmPath,
            widthThreshold: parameters.widthThreshold,
            resizeHeight: parameters.resizeHeight,
            quality: parameters.quality,
            unsharpRadius: parameters.unsharpRadius,
            unsharpSigma: parameters.unsharpSigma,
            unsharpAmount: parameters.unsharpAmount,
            unsharpThreshold: parameters.unsharpThreshold,
            useGrayColorspace: parameters.useGrayColorspace,
            logger: loggerClosure
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
        
        #if DEBUG
        logger.logDebug("Processing completion: processed=\(processedCount), failed=\(failedFiles.count), duration=\(elapsed)s", source: "ImageProcessor")
        #endif
        
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
            try? await notificationManager.sendCompletionNotification(
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
}
