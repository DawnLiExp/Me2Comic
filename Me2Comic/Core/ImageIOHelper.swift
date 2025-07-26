//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/17.
//

import CoreGraphics
import Foundation
import ImageIO
import os.lock
import os.log

enum ImageIOHelper {
    /// Shared logger instance for ImageIO operations
    private static let logger = OSLog(subsystem: "me2.comic.me2comic", category: "ImageIOHelper")

    /// Thread-safe lock wrapper for os_unfair_lock
    private final class UnfairLock {
        private var _lock = os_unfair_lock()

        /// Executes a closure while holding the lock.
        /// - Parameter body: The closure to execute.
        /// - Returns: The result of the closure.
        /// - Throws: Rethrows any error thrown by the closure.
        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return try body()
        }
    }

    /// Retrieves image dimensions (width and height) using the ImageIO framework.
    /// - Parameter imagePath: The full path to the image file.
    /// - Returns: A tuple containing the image's width and height, or nil if dimensions cannot be retrieved.
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        // Use autoreleasepool to manage memory for each image processing
        autoreleasepool {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                os_log("File does not exist at path: %{public}s", log: logger, type: .error, imagePath)
                return nil
            }

            let imageURL = URL(fileURLWithPath: imagePath)
            let retainedURL = imageURL as CFURL

            guard let imageSource = CGImageSourceCreateWithURL(retainedURL, nil) else {
                os_log("Could not create image source for URL: %{public}s", log: logger, type: .error, imageURL.lastPathComponent)
                return nil
            }

            // Prevent caching image data for performance when only metadata is needed.
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
                os_log("Could not copy image properties for %{public}s", log: logger, type: .error, imageURL.lastPathComponent)
                return nil
            }

            guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth as String] as? Int,
                  let pixelHeight = imageProperties[kCGImagePropertyPixelHeight as String] as? Int
            else {
                os_log("Could not retrieve pixel dimensions for %{public}s", log: logger, type: .error, imageURL.lastPathComponent)
                return nil
            }

            return (width: pixelWidth, height: pixelHeight)
        }
    }

    /// Retrieves dimensions for multiple images in parallel using concurrent processing.
    /// Uses optimized task distribution based on available CPU cores and thread-safe result collection.
    /// - Parameter imagePaths: An array of full paths to the image files.
    /// - Parameter shouldContinue: A closure that returns `true` if processing should continue, `false` otherwise.
    /// - Returns: A dictionary mapping image paths to their dimensions (width and height).
    static func getBatchImageDimensions(imagePaths: [String], shouldContinue: () -> Bool) -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }

        var result: [String: (width: Int, height: Int)] = [:]
        let lock = UnfairLock()

        // Calculate task distribution:
        // - Serial for small batches (<20 images)
        // - Parallel up to CPU core count
        let taskCount: Int
        if imagePaths.count < 20 {
            taskCount = 1
        } else {
            // Utilize all available active processor cores
            taskCount = min(
                imagePaths.count,
                ProcessInfo.processInfo.activeProcessorCount
            )
        }

        // Distribute images as evenly as possible among tasks.
        let imagesPerTask = (imagePaths.count + taskCount - 1) / taskCount

        DispatchQueue.concurrentPerform(iterations: taskCount) { taskIndex in
            // Check for cancellation before processing each task chunk
            guard shouldContinue() else { return }

            // Determine the range of images this task should process
            let start = taskIndex * imagesPerTask
            let end = min(start + imagesPerTask, imagePaths.count)

            // Prevent invalid ranges (e.g., when imagesPerTask is 0 or start >= end).
            guard start < end else { return }

            // Process assigned image chunk
            for index in start ..< end {
                // Check for cancellation before processing each individual image
                guard shouldContinue() else { return }

                let path = imagePaths[index]
                if let dims = getImageDimensions(imagePath: path) {
                    lock.withLock {
                        result[path] = dims
                    }
                }
            }
        }

        return result
    }
}
