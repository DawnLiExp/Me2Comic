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
    
    private func processImagesAsync(
        inputDir: URL, outputDir: URL, parameters: ProcessingParameters,
        cancellationToken: ProcessingCancellationToken
    ) async {
        do {
            let report = try await ImageProcessingRunner(gmPath: gmPath, logger: logger).run(
                inputs: [inputDir], output: outputDir, parameters: parameters,
                cancellationToken: cancellationToken,
                eventSink: { [stateManager] event in
                    switch event {
                    case .total(let count): await stateManager.setTotalImages(count)
                    case .completed(let processed, let failed):
                        await stateManager.handleBatchCompletion(processedCount: processed, failedFiles: failed)
                    }
                }
            )
            await handleProcessingCompletion(scanResults: report.directories, globalProcessedCount: report.globalProcessed)
        } catch is CancellationError {
            // The owning cancellation task resets UI state after the runner finishes.
        } catch {
            logger.logError(error.localizedDescription, source: "ImageProcessor")
            stateManager.stopProcessing()
        }
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
