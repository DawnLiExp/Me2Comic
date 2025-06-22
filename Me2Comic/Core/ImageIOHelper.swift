//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by me2 on 2025/6/17.
//

import CoreGraphics
import Foundation
import ImageIO
import os.lock

enum ImageIOHelper {
    // Thread-safe lock wrapper for os_unfair_lock
    private final class UnfairLock {
        private var _lock = os_unfair_lock()

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
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return nil
        }

        let imageURL = URL(fileURLWithPath: imagePath)

        // Retain the URL strongly to ensure it's not deallocated while ImageIO is using it.
        let retainedURL = imageURL as CFURL

        guard let imageSource = CGImageSourceCreateWithURL(retainedURL, nil) else {
            return nil
        }

        // Prevent caching image data for performance when only metadata is needed.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
            return nil
        }

        guard let pixelWidth = imageProperties[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = imageProperties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }

        return (width: pixelWidth, height: pixelHeight)
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

        // Calculate optimal task distribution based on CPU cores
        let taskCount = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount)
        let imagesPerTask = (imagePaths.count + taskCount - 1) / taskCount

        DispatchQueue.concurrentPerform(iterations: taskCount) { taskIndex in
            // Check for cancellation before processing each task chunk
            guard shouldContinue() else { return }

            // Determine the range of images this task should process
            let start = taskIndex * imagesPerTask
            let end = min(start + imagesPerTask, imagePaths.count)

            // Add this check to prevent invalid ranges
            guard start < end else { return }

            // Process assigned image chunk
            for index in start ..< end {
                // Check for cancellation before processing each individual image
                guard shouldContinue() else { return }

                // Use autoreleasepool to manage memory for each image processing
                autoreleasepool {
                    let path = imagePaths[index]
                    if let dims = getImageDimensions(imagePath: path) {
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
