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
    /// Retrieves image dimensions (width and height) using the ImageIO framework.
    /// - Parameter imagePath: The full path to the image file.
    /// - Returns: A tuple containing the image's width and height, or nil if dimensions cannot be retrieved.
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            return nil
        }

        let imageURL = URL(fileURLWithPath: imagePath)

        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
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

    /// Retrieves dimensions for multiple images in a batch using ImageIO with concurrent processing.
    /// This function uses `DispatchQueue.concurrentPerform` for parallel execution and `os_unfair_lock` for thread safety.
    /// - Parameter imagePaths: An array of full paths to the image files.
    /// - Returns: A dictionary mapping image paths to their dimensions (width and height).
    static func getBatchImageDimensions(imagePaths: [String]) -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }

        var result: [String: (width: Int, height: Int)] = Dictionary(minimumCapacity: imagePaths.count)

        // Wrapper for os_unfair_lock to ensure Swift compatibility and proper lock management.
        final class UnfairLock {
            private var _lock = os_unfair_lock()

            func withLock<R>(_ body: () throws -> R) rethrows -> R {
                os_unfair_lock_lock(&_lock)
                defer { os_unfair_lock_unlock(&_lock) }
                return try body()
            }
        }

        let lock = UnfairLock()
        // Determine stride length to optimize task granularity for concurrent processing.
        let strideLength = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount * 2)

        DispatchQueue.concurrentPerform(iterations: imagePaths.count) { index in
            // Process images in chunks to reduce scheduling overhead.
            for realIndex in stride(from: index, to: imagePaths.count, by: strideLength) {
                // Use autoreleasepool to manage memory during image processing.
                autoreleasepool {
                    let path = imagePaths[realIndex]
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
