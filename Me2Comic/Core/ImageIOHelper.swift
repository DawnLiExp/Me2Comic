//
//  ImageIOHelper.swift
//  Me2Comic
//
//  Created by me2 on 2025/6/17.
//

import CoreGraphics // Required for kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight
import Foundation
import ImageIO

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

        var result: [String: (width: Int, height: Int)] = [:]
        // Use NSLock to ensure thread-safe access when updating the 'result' dictionary
        // from multiple concurrent operations.
        let lock = NSLock()

        // `DispatchQueue.concurrentPerform` is ideal here. It executes the provided block
        // concurrently for each iteration, automatically managing the number of threads
        // to optimally utilize CPU cores. This avoids over-concurrency while ensuring
        // efficient parallel processing for ImageIO operations within this batch.
        // The higher-level `ImageProcessor` already limits the number of concurrent batches
        // using a DispatchSemaphore based on `threadCount`.
        DispatchQueue.concurrentPerform(iterations: imagePaths.count) { index in
            let imagePath = imagePaths[index]
            if let dimensions = getImageDimensions(imagePath: imagePath) {
                lock.lock()
                result[imagePath] = dimensions
                lock.unlock()
            }
        }
        return result
    }
}
