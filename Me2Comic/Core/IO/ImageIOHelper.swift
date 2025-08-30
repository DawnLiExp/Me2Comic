//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/17.
//

import CoreGraphics
import Foundation
import ImageIO
import os.log

/// Helper for efficient image I/O operations
enum ImageIOHelper {
    // MARK: - Properties
    
    private static let logger = OSLog(subsystem: "me2.comic.me2comic", category: "ImageIOHelper")
    
    // MARK: - Constants
    
    private enum Constants {
        static let smallBatchThreshold = 20
    }
    
    // MARK: - Public Methods
    
    /// Get pixel dimensions for single image
    /// - Parameter imagePath: Absolute path to image file
    /// - Returns: Tuple of (width, height) or nil if unavailable
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        autoreleasepool {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                os_log("File not found: %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }
            
            let imageURL = URL(fileURLWithPath: imagePath) as CFURL
            guard let imageSource = CGImageSourceCreateWithURL(imageURL, nil) else {
                os_log("Failed to create image source: %{public}s", log: logger, type: .error, imagePath)
                return nil
            }
            
            // Avoid caching when reading properties only
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
                os_log("Failed to read properties: %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }
            
            guard let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight as String] as? Int
            else {
                os_log("Missing dimensions: %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }
            
            return (width: width, height: height)
        }
    }
    
    /// Asynchronously get dimensions for multiple images with cancellation support
    /// - Parameters:
    ///   - imagePaths: Array of absolute image paths
    ///   - asyncCancellationCheck: Async closure returning true to continue processing
    /// - Returns: Dictionary mapping path to dimensions
    static func getBatchImageDimensionsAsync(
        imagePaths: [String],
        asyncCancellationCheck: @escaping @Sendable () async -> Bool
    ) async -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }
        
        // Use serial processing for small batches
        if imagePaths.count < Constants.smallBatchThreshold {
            return await processSerially(
                imagePaths: imagePaths,
                cancellationCheck: asyncCancellationCheck
            )
        }
        
        // Use parallel processing for larger batches
        return await processInParallel(
            imagePaths: imagePaths,
            cancellationCheck: asyncCancellationCheck
        )
    }
    
    // MARK: - Private Methods
    
    /// Process images serially (for small batches)
    private static func processSerially(
        imagePaths: [String],
        cancellationCheck: @escaping @Sendable () async -> Bool
    ) async -> [String: (width: Int, height: Int)] {
        await Task.detached(priority: .userInitiated) { @Sendable in
            let store = DimensionsStore()
            
            for path in imagePaths {
                guard !Task.isCancelled else { break }
                guard await cancellationCheck() else { break }
                
                if let dimensions = getImageDimensions(imagePath: path) {
                    await store.set(path, dimensions: dimensions)
                } else {
                    os_log("Failed to get dimensions: %{public}s", log: logger, type: .debug, path)
                }
            }
            
            return await store.getAll()
        }.value
    }
    
    /// Process images in parallel (for large batches)
    private static func processInParallel(
        imagePaths: [String],
        cancellationCheck: @escaping @Sendable () async -> Bool
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
                            
                            if let dimensions = getImageDimensions(imagePath: path) {
                                await store.set(path, dimensions: dimensions)
                            } else {
                                os_log("Failed to get dimensions: %{public}s", log: logger, type: .debug, path)
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
