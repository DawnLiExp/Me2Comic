//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/17.
//

import CoreGraphics
import Foundation
import ImageIO

/// Helper for efficient image I/O operations
enum ImageIOHelper {
    // MARK: - Constants
    
    private enum Constants {
        static let smallBatchThreshold = 20
    }
    
    // MARK: - Public Methods
    
    /// Get pixel dimensions for single image
    /// - Parameters:
    ///   - imagePath: Absolute path to image file
    ///   - logger: Optional logger for debugging
    /// - Returns: Result with dimensions or error
    static func getImageDimensions(
        imagePath: String,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<(width: Int, height: Int), ProcessingError> {
        autoreleasepool {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                #if DEBUG
                logger?("File not found: \(imagePath)", .debug, "ImageIOHelper")
                #endif
                return .failure(.fileNotFound(path: imagePath))
            }
            
            let imageURL = URL(fileURLWithPath: imagePath) as CFURL
            guard let imageSource = CGImageSourceCreateWithURL(imageURL, nil) else {
                #if DEBUG
                logger?("Failed to create image source: \(imagePath)", .debug, "ImageIOHelper")
                #endif
                return .failure(.imageSourceCreationFailed(path: imagePath))
            }
            
            // Avoid caching when reading properties only
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
                #if DEBUG
                logger?("Failed to read properties: \(imagePath)", .debug, "ImageIOHelper")
                #endif
                return .failure(.filePropertiesUnavailable(path: imagePath))
            }
            
            guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int
            else {
                #if DEBUG
                logger?("Missing dimensions: \(imagePath)", .debug, "ImageIOHelper")
                #endif
                return .failure(.imageDimensionsUnavailable(path: imagePath))
            }
            
            return .success((width: width, height: height))
        }
    }
    
    /// Asynchronously get dimensions for multiple images with cancellation support
    /// - Parameters:
    ///   - imagePaths: Array of absolute image paths
    ///   - asyncCancellationCheck: Async closure returning true to continue processing
    ///   - logger: Optional logger for debugging
    /// - Returns: Dictionary mapping path to dimensions
    static func getBatchImageDimensionsAsync(
        imagePaths: [String],
        asyncCancellationCheck: @escaping @Sendable () async -> Bool,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) async -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }
        
        // Use serial processing for small batches
        if imagePaths.count < Constants.smallBatchThreshold {
            return await processSerially(
                imagePaths: imagePaths,
                cancellationCheck: asyncCancellationCheck,
                logger: logger
            )
        }
        
        // Use parallel processing for larger batches
        return await processInParallel(
            imagePaths: imagePaths,
            cancellationCheck: asyncCancellationCheck,
            logger: logger
        )
    }
    
    // MARK: - Private Methods
    
    /// Process images serially (for small batches)
    private static func processSerially(
        imagePaths: [String],
        cancellationCheck: @escaping @Sendable () async -> Bool,
        logger: (@Sendable (String, LogLevel, String?) -> Void)?
    ) async -> [String: (width: Int, height: Int)] {
        await Task.detached(priority: .userInitiated) { @Sendable in
            let store = DimensionsStore()
            
            for path in imagePaths {
                guard !Task.isCancelled else { break }
                guard await cancellationCheck() else { break }
                
                let result = getImageDimensions(imagePath: path, logger: logger)
                switch result {
                case .success(let dimensions):
                    await store.set(path, dimensions: dimensions)
                case .failure(let error):
                    #if DEBUG
                    logger?("Failed to get dimensions for \(path): \(error)", .debug, "ImageIOHelper")
                    #endif
                }
            }
            
            return await store.getAll()
        }.value
    }
    
    /// Process images in parallel (for large batches)
    private static func processInParallel(
        imagePaths: [String],
        cancellationCheck: @escaping @Sendable () async -> Bool,
        logger: (@Sendable (String, LogLevel, String?) -> Void)?
    ) async -> [String: (width: Int, height: Int)] {
        await Task.detached(priority: .userInitiated) { @Sendable in
            let store = DimensionsStore()
            let workerCount = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount)
            let chunkSize = (imagePaths.count + workerCount - 1) / workerCount
            
            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<workerCount {
                    let start = workerIndex * chunkSize
                    let end = min(start + chunkSize, imagePaths.count)
                    guard start < end else { continue }
                    
                    let chunk = Array(imagePaths[start..<end])
                    
                    group.addTask { @Sendable in
                        for path in chunk {
                            guard !Task.isCancelled else { break }
                            guard await cancellationCheck() else { break }
                            
                            let result = getImageDimensions(imagePath: path, logger: logger)
                            switch result {
                            case .success(let dimensions):
                                await store.set(path, dimensions: dimensions)
                            case .failure(let error):
                                #if DEBUG
                                logger?("Failed to get dimensions for \(path): \(error)", .debug, "ImageIOHelper")
                                #endif
                            }
                        }
                    }
                }
                
                await group.waitForAll()
            }
            
            return await store.getAll()
        }.value
    }
}

// MARK: - Private Types

/// Thread-safe storage for image dimensions
private actor DimensionsStore {
    private var dimensions: [String: (width: Int, height: Int)] = [:]
    
    func set(_ path: String, dimensions: (width: Int, height: Int)) {
        self.dimensions[path] = dimensions
    }
    
    func getAll() -> [String: (width: Int, height: Int)] {
        dimensions
    }
}
