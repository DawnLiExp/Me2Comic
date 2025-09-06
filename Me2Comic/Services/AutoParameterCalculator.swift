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
        static let highResolutionMinImages = 10 // Minimum images for high resolution optimization
    }
    
    // MARK: - Initialization
    
    init(logger: ProcessingLogger) {
        self.logger = logger
        
        #if DEBUG
        logger.logDebug("AutoParameterCalculator initialized", source: "AutoParameterCalculator")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Determine effective parameters based on auto mode
    /// - Parameters:
    ///   - parameters: User-specified parameters
    ///   - totalImages: Total number of images to process
    ///   - hasHighResolution: Whether high resolution images are detected
    /// - Returns: Tuple of effective thread count and batch size
    func determineParameters(
        parameters: ProcessingParameters,
        totalImages: Int,
        hasHighResolution: Bool = false
    ) -> (threadCount: Int, batchSize: Int) {
        guard parameters.threadCount == Constants.autoModeThreadCount else {
            #if DEBUG
            logger.logDebug("Manual mode: threads=\(parameters.threadCount), batch=\(parameters.batchSize)", source: "AutoParameterCalculator")
            #endif
            return (parameters.threadCount, parameters.batchSize)
        }
        
        logger.appendLog(NSLocalizedString("AutoModeEnabled", comment: ""))
        
        #if DEBUG
        logger.logDebug("Auto mode enabled for \(totalImages) images\(hasHighResolution ? " [High Resolution Detected]" : "")", source: "AutoParameterCalculator")
        #endif
        
        // High resolution optimization: use maximum threads if conditions met
        if hasHighResolution, totalImages >= Constants.highResolutionMinImages {
            let threadCount = Constants.maxThreadCount
            let batchSize = calculateBatchSizeForThreads(
                totalImages: totalImages,
                threadCount: threadCount
            )
            
            logger.appendLog(String(
                format: NSLocalizedString("AutoAllocatedParameters", comment: ""),
                threadCount,
                batchSize
            ))
            
            #if DEBUG
            logger.logDebug("High resolution optimization: threads=\(threadCount), batch=\(batchSize)", source: "AutoParameterCalculator")
            #endif
            
            return (threadCount, batchSize)
        }
        
        // Standard auto parameter calculation
        let autoParams = calculateAutoParameters(totalImageCount: totalImages)
        
        logger.appendLog(String(
            format: NSLocalizedString("AutoAllocatedParameters", comment: ""),
            autoParams.threadCount,
            autoParams.batchSize
        ))
        
        #if DEBUG
        logger.logDebug("Auto-calculated parameters: threads=\(autoParams.threadCount), batch=\(autoParams.batchSize)", source: "AutoParameterCalculator")
        #endif
        
        return autoParams
    }
    
    // MARK: - Private Methods
    
    /// Calculate batch size for given thread count
    private func calculateBatchSizeForThreads(totalImages: Int, threadCount: Int) -> Int {
        max(1, min(
            Constants.maxBatchSize,
            Int(ceil(Double(totalImages) / Double(threadCount)))
        ))
    }
    
    /// Calculate auto-allocated parameters based on image count
    private func calculateAutoParameters(totalImageCount: Int) -> (threadCount: Int, batchSize: Int) {
        let threadCount: Int = {
            switch totalImageCount {
            case ..<10:
                #if DEBUG
                logger.logDebug("Small workload (<10 images): allocating 1 thread", source: "AutoParameterCalculator")
                #endif
                return 1
            case 10..<50:
                let calculatedThreads = min(3, 1 + Int(ceil(Double(totalImageCount - 10) / 20.0)))
                #if DEBUG
                logger.logDebug("Medium workload (10-49 images): allocating \(calculatedThreads) threads", source: "AutoParameterCalculator")
                #endif
                return calculatedThreads
            case 50..<300:
                let calculatedThreads = min(Constants.maxThreadCount, 3 + Int(ceil(Double(totalImageCount - 50) / 50.0)))
                #if DEBUG
                logger.logDebug("Large workload (50-299 images): allocating \(calculatedThreads) threads", source: "AutoParameterCalculator")
                #endif
                return calculatedThreads
            default:
                #if DEBUG
                logger.logDebug("Very large workload (≥300 images): allocating maximum \(Constants.maxThreadCount) threads", source: "AutoParameterCalculator")
                #endif
                return Constants.maxThreadCount
            }
        }()
        
        let batchSize = calculateBatchSizeForThreads(
            totalImages: totalImageCount,
            threadCount: threadCount
        )
        
        #if DEBUG
        logger.logDebug("Calculated batch size: \(batchSize) (images per thread: ~\(Double(totalImageCount) / Double(threadCount)))", source: "AutoParameterCalculator")
        #endif
        
        return (threadCount, batchSize)
    }
}
