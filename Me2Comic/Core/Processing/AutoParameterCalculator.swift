//
//  AutoParameterCalculator.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

/// Calculates optimal processing parameters based on workload
@MainActor
class AutoParameterCalculator {
    // MARK: - Properties
    
    private let logger: ProcessingLogger
    
    // MARK: - Constants
    
    private enum Constants {
        static let autoModeThreadCount = 0
        static let maxThreadCount = 6
        static let defaultBatchSize = 40
        static let maxBatchSize = 1000
    }
    
    // MARK: - Initialization
    
    init(logger: ProcessingLogger) {
        self.logger = logger
    }
    
    // MARK: - Public Methods
    
    /// Determine effective parameters based on auto mode
    /// - Parameters:
    ///   - parameters: User-specified parameters
    ///   - totalImages: Total number of images to process
    /// - Returns: Tuple of effective thread count and batch size
    func determineParameters(
        parameters: ProcessingParameters,
        totalImages: Int
    ) -> (threadCount: Int, batchSize: Int) {
        guard parameters.threadCount == Constants.autoModeThreadCount else {
            return (parameters.threadCount, parameters.batchSize)
        }
        
        logger.appendLog(NSLocalizedString("AutoModeEnabled", comment: ""))
        
        let autoParams = calculateAutoParameters(totalImageCount: totalImages)
        
        logger.appendLog(String(
            format: NSLocalizedString("AutoAllocatedParameters", comment: ""),
            autoParams.threadCount,
            autoParams.batchSize
        ))
        
        return autoParams
    }
    
    // MARK: - Private Methods
    
    /// Calculate auto-allocated parameters based on image count
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
}
