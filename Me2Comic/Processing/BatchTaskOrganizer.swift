//
//  BatchTaskOrganizer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

// MARK: - Types

/// Batch processing task descriptor
struct BatchTask {
    let images: [URL]
    let outputDir: URL
    let batchSize: Int
    let isGlobal: Bool
}

/// Batch processing result
struct BatchResult {
    let processed: Int
    let failed: [String]
    let isGlobal: Bool
    
    static var empty: BatchResult {
        BatchResult(processed: 0, failed: [], isGlobal: false)
    }
}

/// Organizes images into batch processing tasks
@MainActor
class BatchTaskOrganizer {
    // MARK: - Properties
    
    private let logger: ProcessingLogger
    
    // MARK: - Constants
    
    private enum Constants {
        static let autoModeThreadCount = 0
        static let defaultBatchSize = 40
        static let maxBatchSize = 1000
    }
    
    // MARK: - Initialization
    
    init(logger: ProcessingLogger) {
        self.logger = logger
        
        #if DEBUG
        logger.logDebug("BatchTaskOrganizer initialized", source: "BatchTaskOrganizer")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Prepare batch tasks for processing
    func prepareBatchTasks(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) -> [BatchTask] {
        var tasks: [BatchTask] = []
        
        #if DEBUG
        logger.logDebug("Preparing batch tasks: \(scanResults.count) scan results, \(globalBatchImages.count) global images", source: "BatchTaskOrganizer")
        #endif
        
        // Prepare isolated directory tasks
        for result in scanResults where result.category == .isolated {
            let subName = result.directoryURL.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)
            
            logger.appendLog(String(
                format: NSLocalizedString("StartProcessingSubdir", comment: ""),
                subName
            ))
            
            let batchSize = calculateBatchSize(
                imageCount: result.imageFiles.count,
                threadCount: effectiveThreadCount,
                isAuto: parameters.threadCount == Constants.autoModeThreadCount,
                defaultSize: parameters.batchSize
            )
            
            #if DEBUG
            logger.logDebug("Isolated directory \(subName): \(result.imageFiles.count) images, batch size \(batchSize)", source: "BatchTaskOrganizer")
            #endif
            
            let batches = splitIntoBatches(result.imageFiles, batchSize: batchSize)
            
            #if DEBUG
            logger.logDebug("Split \(subName) into \(batches.count) batches", source: "BatchTaskOrganizer")
            #endif
            
            for batch in batches {
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
            logger.appendLog(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            
            let globalBatchSize = calculateGlobalBatchSize(
                imageCount: globalBatchImages.count,
                threadCount: effectiveThreadCount,
                baseBatchSize: effectiveBatchSize
            )
            
            #if DEBUG
            logger.logDebug("Global batch: \(globalBatchImages.count) images, batch size \(globalBatchSize)", source: "BatchTaskOrganizer")
            #endif
            
            let globalBatches = splitIntoBatches(globalBatchImages, batchSize: globalBatchSize)
            
            #if DEBUG
            logger.logDebug("Split global images into \(globalBatches.count) batches", source: "BatchTaskOrganizer")
            #endif
            
            for batch in globalBatches {
                tasks.append(BatchTask(
                    images: batch,
                    outputDir: outputDir,
                    batchSize: globalBatchSize,
                    isGlobal: true
                ))
            }
        }
        
        #if DEBUG
        logger.logDebug("Total batch tasks prepared: \(tasks.count)", source: "BatchTaskOrganizer")
        #endif
        
        return tasks
    }
    
    /// Split array into batches
    func splitIntoBatches<T>(_ items: [T], batchSize: Int) -> [[T]] {
        guard batchSize > 0, !items.isEmpty else {
            #if DEBUG
            logger.logDebug("Invalid batch parameters: batchSize=\(batchSize), itemCount=\(items.count)", source: "BatchTaskOrganizer")
            #endif
            return []
        }
        
        let batches = stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }
        
        #if DEBUG
        logger.logDebug("Split \(items.count) items into \(batches.count) batches of size \(batchSize)", source: "BatchTaskOrganizer")
        #endif
        
        return batches
    }
    
    // MARK: - Private Methods
    
    /// Calculate batch size for isolated directories
    private func calculateBatchSize(
        imageCount: Int,
        threadCount: Int,
        isAuto: Bool,
        defaultSize: Int
    ) -> Int {
        guard isAuto else {
            #if DEBUG
            logger.logDebug("Manual batch size: \(defaultSize)", source: "BatchTaskOrganizer")
            #endif
            return max(1, defaultSize)
        }
        
        // Boundary safety: ensure sensible threadCount and imageCount values
        let safeThreadCount = max(1, threadCount)
        let safeImageCount = max(0, imageCount)
        
        guard safeImageCount > 0 else {
            #if DEBUG
            logger.logDebug("Image count is zero, returning batch size 1", source: "BatchTaskOrganizer")
            #endif
            return 1
        }
        
        let idealBatches = Int(ceil(Double(safeImageCount) / Double(Constants.defaultBatchSize)))
        let adjustedBatches = roundUpToNearestMultiple(
            value: max(1, idealBatches),
            multiple: safeThreadCount
        )
        
        let calculatedSize = max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(safeImageCount) / Double(max(1, adjustedBatches))))
        ))
        
        #if DEBUG
        logger.logDebug("Auto batch size calculation: \(safeImageCount) images, \(safeThreadCount) threads -> \(calculatedSize) batch size", source: "BatchTaskOrganizer")
        #endif
        
        return calculatedSize
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
        
        let calculatedSize = max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(imageCount) / Double(adjustedBatches)))
        ))
        
        #if DEBUG
        logger.logDebug("Global batch size calculation: \(imageCount) images, \(threadCount) threads, base=\(baseBatchSize) -> \(calculatedSize)", source: "BatchTaskOrganizer")
        #endif
        
        return calculatedSize
    }
    
    /// Round up to nearest multiple
    private func roundUpToNearestMultiple(value: Int, multiple: Int) -> Int {
        guard multiple > 0 else {
            #if DEBUG
            logger.logDebug("Invalid multiple value: \(multiple), returning original value \(value)", source: "BatchTaskOrganizer")
            #endif
            return value
        }
        
        let remainder = value % multiple
        let result = remainder == 0 ? value : value + (multiple - remainder)
        
        #if DEBUG
        if result != value {
            logger.logDebug("Rounded \(value) up to nearest multiple of \(multiple): \(result)", source: "BatchTaskOrganizer")
        }
        #endif
        
        return result
    }
}
