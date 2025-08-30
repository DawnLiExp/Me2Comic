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
            logger.appendLog(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            
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
    
    /// Split array into batches
    func splitIntoBatches<T>(_ items: [T], batchSize: Int) -> [[T]] {
        guard batchSize > 0, !items.isEmpty else { return [] }
        
        return stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }
    }
    
    // MARK: - Private Methods
    
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
    
    /// Round up to nearest multiple
    private func roundUpToNearestMultiple(value: Int, multiple: Int) -> Int {
        guard multiple > 0 else { return value }
        let remainder = value % multiple
        return remainder == 0 ? value : value + (multiple - remainder)
    }
}
