//
//  ImageProcessor.swift
//  Me2Comic
//
//  纯处理流程协调器：组件依赖注入、工作窃取并发管理
//

import Foundation
import Observation

enum GraphicsMagickStatus {
    case checking
    case ready(path: String)
    case failed(ProcessingError)

    var isReady: Bool { if case .ready = self { true } else { false } }
    var isChecking: Bool { if case .checking = self { true } else { false } }
}

/// Manages the image processing workflow
@MainActor
@Observable
class ImageProcessor {
    // MARK: - Properties
    
    private let notificationManager = NotificationManager()
    private let stateManager: ProcessingStateManager
    let logger: ProcessingLogger
    private let taskOrganizer: BatchTaskOrganizer
    private let autoCalculator: AutoParameterCalculator
    
    private let detector: @Sendable () async -> Result<String, ProcessingError>
    private var detectionTask: Task<Void, Never>?
    private var detectionID = UUID()
    private(set) var gmStatus: GraphicsMagickStatus = .checking
    private var gmPath: String {
        if case .ready(let path) = gmStatus { path } else { "" }
    }
    private var activeProcessingTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var activeCancellationToken: ProcessingCancellationToken?
    
    private(set) var isStopping = false
    var isClosing = false
    var hasActiveWork: Bool { activeProcessingTask != nil || isStopping }
    
    // MARK: - Initialization
    
    init(stateManager: ProcessingStateManager, logger: ProcessingLogger,
         detector: (@Sendable () async -> Result<String, ProcessingError>)? = nil) {
        self.stateManager = stateManager
        self.logger = logger
        taskOrganizer = BatchTaskOrganizer(logger: logger)
        autoCalculator = AutoParameterCalculator(logger: logger)
        
        let log = LoggerFactory.createLoggerClosure(from: logger)
        self.detector = detector ?? { await GraphicsMagickHelper.verifyGraphicsMagickAsync(logger: log) }
        retryGraphicsMagickDetection()
        
        #if DEBUG
        logger.logDebug("ImageProcessor initialized", source: "ImageProcessor")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Appends log message (forwarded to logger)
    func appendLog(_ message: String) {
        logger.log(message, level: .info, source: "ImageProcessor")
    }

    func retryGraphicsMagickDetection() {
        guard detectionTask == nil, !hasActiveWork, !isClosing else { return }
        let requestID = UUID()
        detectionID = requestID
        gmStatus = .checking
        detectionTask = Task {
            let result = await detector()
            guard !Task.isCancelled, detectionID == requestID else { return }
            switch result {
            case .success(let path):
                gmStatus = .ready(path: path)
                logger.log(String(localized: "GMReady"), level: .success, source: "ImageProcessor")
            case .failure(let error):
                gmStatus = .failed(error)
                logger.logError(error.localizedDescription, source: "ImageProcessor")
            }
            detectionTask = nil
        }
    }

    func waitForDetection() async { await detectionTask?.value }

    @discardableResult
    func cancelDetection() -> Task<Void, Never>? {
        let previous = detectionTask
        detectionID = UUID()
        detectionTask?.cancel()
        detectionTask = nil
        return previous
    }

    /// Requests cancellation while retaining ownership until all children are reaped.
    func stopProcessing() {
        _ = beginCancellation()
    }

    func cancelAndWait() async {
        let detection = cancelDetection()
        let cleanup = beginCancellation()
        await detection?.value
        await cleanup?.value
    }

    private func beginCancellation() -> Task<Void, Never>? {
        if let stopTask { return stopTask }
        guard let task = activeProcessingTask else { return nil }
        isStopping = true
        task.cancel()
        let token = activeCancellationToken
        let cleanup = Task {
            await token?.cancel()
            await task.value
            activeProcessingTask = nil
            activeCancellationToken = nil
            stateManager.stopProcessing()
            isStopping = false
            stopTask = nil
            logger.log(String(localized: "ProcessingStopped"), level: .warning, source: "ImageProcessor")
        }
        stopTask = cleanup
        return cleanup
    }

    /// Initiates image processing workflow
    func processImages(inputDir: URL, outputDir: URL, parameters: ProcessingParameters) {
        #if DEBUG
        logger.logDebug("Starting image processing workflow", source: "ImageProcessor")
        logger.logDebug("Input: \(inputDir.path)", source: "ImageProcessor")
        logger.logDebug("Output: \(outputDir.path)", source: "ImageProcessor")
        #endif
        
        guard !hasActiveWork, !isClosing, gmStatus.isReady else { return }
        let cancellationToken = ProcessingCancellationToken()
        activeCancellationToken = cancellationToken
        
        stateManager.startProcessing()
        logger.logStartParameters(parameters)
        
        activeProcessingTask = Task {
            await processImagesAsync(
                inputDir: inputDir,
                outputDir: outputDir,
                parameters: parameters,
                cancellationToken: cancellationToken
            )
            if !isStopping {
                activeProcessingTask = nil
                activeCancellationToken = nil
            }
        }
    }
    
    // MARK: - Private Processing Methods
    
    /// Main async processing implementation
    private func processImagesAsync(
        inputDir: URL,
        outputDir: URL,
        parameters: ProcessingParameters,
        cancellationToken: ProcessingCancellationToken
    ) async {
        guard gmStatus.isReady else {
            logger.logError(String(localized: "GMNotReady"), source: "ImageProcessor")
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
            parameters: parameters,
            cancellationToken: cancellationToken
        )
    }
    
    /// Process directories with categorization
    private func processDirectoriesAsync(
        inputDir: URL,
        outputDir: URL,
        parameters: ProcessingParameters,
        cancellationToken: ProcessingCancellationToken
    ) async {
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        
        let analyzer = DirectoryAnalyzer(
            logHandler: loggerClosure,
            isProcessingCheck: { @Sendable in
                await cancellationToken.canContinue()
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
        logger.log(String(format: String(localized: "TotalImagesToProcess"), totalImages), level: .info, source: "ImageProcessor")
        
        #if DEBUG
        logger.logDebug("Processing \(totalImages) total images across \(scanResults.count) directories", source: "ImageProcessor")
        #endif
        
        // Check if any directory contains high resolution images
        let hasHighResolution = scanResults.contains { $0.isHighResolution }
        
        let globalBatchImages = scanResults
            .filter { $0.category == .globalBatch }
            .flatMap(\.imageFiles)
        
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
            effectiveBatchSize: effectiveBatchSize,
            cancellationToken: cancellationToken
        )
    }
    
    /// Process batches with controlled concurrency and work-stealing
    private func processBatches(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int,
        cancellationToken: ProcessingCancellationToken
    ) async {
        guard stateManager.isProcessing, !Task.isCancelled else {
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
        // Track which tasks are high-resolution global batches
        var highResGlobalIndices = Set<Int>()
        var currentIndex = 0

        // Mark isolated tasks first (they're added first in prepareBatchTasks)
        for result in scanResults where result.category == .isolated {
            let subBatchCount = Int(ceil(Double(result.imageFiles.count) / Double(effectiveBatchSize)))
            currentIndex += subBatchCount
        }

        // Mark high-resolution global batch tasks
        let highResGlobalResults = scanResults.filter {
            $0.category == .globalBatch && $0.isHighResolution
        }
        if !highResGlobalResults.isEmpty {
            let highResImageCount = highResGlobalResults.flatMap(\.imageFiles).count
            let highResBatchCount = Int(ceil(Double(highResImageCount) / Double(effectiveBatchSize)))
            for i in currentIndex ..< (currentIndex + highResBatchCount) {
                highResGlobalIndices.insert(i)
            }
        }
        // Initialize task queue with priority information
        let loggerClosure = LoggerFactory.createLoggerClosure(from: logger)
        let taskQueue = TaskQueue(logger: loggerClosure)
        await taskQueue.initialize(with: batchTasks, highResGlobalIndices: highResGlobalIndices)
        let gmPath = self.gmPath
        let batchParameters = parameters
        let cancellationCheck: @Sendable () async -> Bool = {
            await cancellationToken.canContinue()
        }
        
        var globalProcessedCount = 0
        
        await withTaskGroup(of: BatchResult.self) { group in
            // Start worker threads
            for threadId in 0 ..< effectiveThreadCount {
                group.addTask {
                    var localResults = BatchResult.empty
                    
                    // Work-stealing loop: keep processing until no tasks remain
                    while !Task.isCancelled {
                        // Get next task from queue (work-stealing enabled)
                        guard let task = await taskQueue.getNextTask(threadId: threadId) else {
                            break // No more tasks available
                        }
                        
                        // Process the task
                        let (processed, failed) = await ImageProcessor.processBatch(
                            gmPath: gmPath,
                            images: task.images,
                            outputDir: task.outputDir,
                            parameters: batchParameters,
                            duplicateBaseNames: task.duplicateBaseNames,
                            cancellationCheck: cancellationCheck,
                            logger: loggerClosure
                        )
                        
                        // Mark task completed
                        await taskQueue.markCompleted()
                        
                        // Accumulate results for this thread
                        localResults = BatchResult(
                            processed: localResults.processed + processed,
                            failed: localResults.failed + failed,
                            isGlobal: task.isGlobal || localResults.isGlobal,
                            globalProcessed: localResults.globalProcessed + (task.isGlobal ? processed : 0)
                        )
                        
                        #if DEBUG
                        let progress = await taskQueue.getProgress()
                        loggerClosure(
                            "Thread \(threadId) completed task: \(progress.completed)/\(progress.total) done, \(progress.remaining) remaining",
                            .debug,
                            "ImageProcessor"
                        )
                        #endif
                    }
                    
                    return localResults
                }
            }
            
            // Collect results from all threads
            for await result in group {
                guard !Task.isCancelled, stateManager.isProcessing else { break }
                
                await stateManager.handleBatchCompletion(
                    processedCount: result.processed,
                    failedFiles: result.failed
                )
                
                if result.isGlobal {
                    globalProcessedCount += result.globalProcessed
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
        
        guard !Task.isCancelled, stateManager.isProcessing else {
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
    nonisolated private static func processBatch(
        gmPath: String,
        images: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        duplicateBaseNames: Set<String>,
        cancellationCheck: @escaping @Sendable () async -> Bool,
        logger: (@Sendable (String, LogLevel, String?) -> Void)?
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
            useGrayColorspace: parameters.useGrayColorspace,
            cancellationCheck: cancellationCheck,
            logger: logger
        )
        
        return await processor.processBatch(
            images: images,
            outputDir: outputDir,
            duplicateBaseNames: duplicateBaseNames
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
        
        if processedCount > 0 {
            // Add per-directory results
            scanResults
                .filter { $0.category == .isolated }
                .forEach { result in
                    logger.log(String(format: String(localized: "ProcessedSubdir"), result.directoryURL.lastPathComponent), level: .success, source: "ImageProcessor")
                }
            
            // Add global batch results
            if globalProcessedCount > 0 {
                logger.log(String(format: String(localized: "CompletedGlobalBatchWithCount"), globalProcessedCount), level: .success, source: "ImageProcessor")
            }
            
            // Add failure summary
            if !failedFiles.isEmpty {
                logger.log(String(format: String(localized: "FailedFiles"), failedFiles.count), level: .error, source: "ImageProcessor")
                for item in failedFiles.prefix(10) {
                    logger.log("  - \(item)", level: .error, source: "ImageProcessor")
                }
                
                if failedFiles.count > 10 {
                    logger.log("... \(failedFiles.count - 10) more", level: .error, source: "ImageProcessor")
                }
            }
            
            // Success: Total images processed
            logger.log(String(format: String(localized: "TotalImagesProcessed"), processedCount), level: .info, source: "ImageProcessor")
                
            // Success: Processing time
            logger.log(duration, level: .info, source: "ImageProcessor")
                
            // Success: Processing complete
            logger.log(String(localized: "ProcessingComplete"), level: .success, source: "ImageProcessor")
        }
        
        // Ensure all logs are processed before marking completion
        await logger.flushLogs()
        guard !Task.isCancelled else { return }

        Task {
            try? await notificationManager.sendCompletionNotification(
                processedCount: processedCount,
                failedCount: failedFiles.count,
                duration: duration
            )
        }
        
        // Mark tasks as finished with extended delay to show 100% progress
        stateManager.markTasksFinished(withDelay: 700_000_000)
    }
}
