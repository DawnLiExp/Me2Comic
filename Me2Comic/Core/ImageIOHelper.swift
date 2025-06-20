//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by me2 on 2025/6/17.
//

import CoreGraphics // Required for kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight
import Foundation
import ImageIO
import os.lock

enum ImageIOHelper {
    /// Retrieves image dimensions (width and height) using the ImageIO framework.
    /// - Parameter imagePath: The full path to the image file.
    /// - Returns: A tuple containing the image's width and height, or nil if dimensions cannot be retrieved.
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        // Ensure the file exists at the given path.
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return nil
        }

        let imageURL = URL(fileURLWithPath: imagePath)

        // Create an image source from the URL.
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            return nil
        }

        // Get image properties. kCGImageSourceShouldCache: false prevents caching image data, improving performance
        // when only metadata (like dimensions) is needed.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
            return nil
        }

        // Extract pixel width and height from the properties.
        guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }

        return (width: pixelWidth, height: pixelHeight)
    }

    /// Retrieves dimensions for multiple images in a batch using the ImageIO framework with concurrent processing.
    /// This function leverages `DispatchQueue.concurrentPerform` for efficient parallel execution,
    /// automatically optimizing concurrency based on available system resources.
    /// - Parameter imagePaths: An array of full paths to the image files.
    /// - Returns: A dictionary mapping image paths to their dimensions (width and height).
    static func getBatchImageDimensions(imagePaths: [String]) -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }

        // Pre-allocate dictionary with expected capacity
        var result: [String: (width: Int, height: Int)] = Dictionary(minimumCapacity: imagePaths.count)

        // Use os_unfair_lock wrapped in a class for Swift compatibility
        final class UnfairLock {
            private var _lock = os_unfair_lock()

            func withLock<R>(_ body: () throws -> R) rethrows -> R {
                os_unfair_lock_lock(&_lock)
                defer { os_unfair_lock_unlock(&_lock) }
                return try body()
            }
        }

        let lock = UnfairLock()
        // Set stride length based on CPU cores to balance task granularity and reduce scheduling overhead.
        let strideLength = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount * 2)
        // Use concurrentPerform for parallel processing, with stride-based task distribution for efficiency.
        DispatchQueue.concurrentPerform(iterations: imagePaths.count) { index in
            // Process images in chunks (stride) to reduce the number of concurrent tasks.
            for realIndex in stride(from: index, to: imagePaths.count, by: strideLength) {
                // Use autoreleasepool to manage memory and prevent memory spikes during image processing.
                autoreleasepool {
                    let path = imagePaths[realIndex]
                    if let dims = getImageDimensions(imagePath: path) {
                        // Thread-safe dictionary update using os_unfair_lock for minimal contention.
                        lock.withLock {
                            result[path] = dims
                        }
                    }
                }
            }
        }

        return result
    }
}
