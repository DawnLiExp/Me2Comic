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

enum ImageIOHelper {
    // Shared logger instance for ImageIO operations.
    private static let logger = OSLog(subsystem: "me2.comic.me2comic", category: "ImageIOHelper")

    // MARK: - Low-level helper: read single image dimensions (synchronous)

    /// Synchronously obtains single image pixel dimensions using Image I/O.
    /// - Parameter imagePath: Absolute path to the image file.
    /// - Returns: (width, height) or nil when the dimensions cannot be determined.
    static func getImageDimensions(imagePath: String) -> (width: Int, height: Int)? {
        autoreleasepool {
            guard FileManager.default.fileExists(atPath: imagePath) else {
                os_log("File not found: %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }

            let imageURL = URL(fileURLWithPath: imagePath) as CFURL
            guard let imageSource = CGImageSourceCreateWithURL(imageURL, nil) else {
                os_log("Unable to create CGImageSource for %{public}s", log: logger, type: .error, imagePath)
                return nil
            }

            // Avoid caching full image data when only properties are required.
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, options) as NSDictionary? else {
                os_log("Could not read properties for %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }

            if let w = props[kCGImagePropertyPixelWidth as String] as? Int,
               let h = props[kCGImagePropertyPixelHeight as String] as? Int
            {
                return (width: w, height: h)
            } else {
                os_log("Pixel dimensions absent for %{public}s", log: logger, type: .debug, imagePath)
                return nil
            }
        }
    }

    // MARK: - Thread-safe result aggregator (actor)

    private actor DimensionsStore {
        private var dict: [String: (width: Int, height: Int)] = [:]
        func set(_ path: String, dims: (Int, Int)) {
            dict[path] = dims
        }

        func getAll() -> [String: (width: Int, height: Int)] {
            return dict
        }
    }

    // MARK: - Async batch API (preferred): supports async cancellation check

    /// Asynchronously retrieves pixel dimensions for multiple images.
    ///
    /// - Uses structured concurrency (`TaskGroup`) to create workers and cooperatively checks the provided
    ///   async cancellation closure frequently.
    /// - Returns partial results if the cancellation closure indicates stop or the Task is cancelled.
    ///
    /// - Parameters:
    ///   - imagePaths: Array of absolute image paths.
    ///   - asyncCancellationCheck: async closure called frequently; return `true` to continue.
    /// - Returns: Dictionary mapping path -> (width, height). Missing entries indicate failures.
    static func getBatchImageDimensionsAsync(
        imagePaths: [String],
        asyncCancellationCheck: @escaping () async -> Bool
    ) async -> [String: (width: Int, height: Int)] {
        guard !imagePaths.isEmpty else { return [:] }

        // Fast path for small lists: process serially on a detached task (less overhead).
        if imagePaths.count < 20 {
            return await Task.detached(priority: .userInitiated) {
                let store = DimensionsStore()
                for path in imagePaths {
                    // Cooperative cancellation points
                    if Task.isCancelled { break }
                    if !(await asyncCancellationCheck()) { break }

                    if let dims = getImageDimensions(imagePath: path) {
                        await store.set(path, dims: (dims.width, dims.height))
                    } else {
                        os_log("Unable to get dimensions for %{public}s (serial small-batch)", log: logger, type: .debug, path)
                    }
                }
                return await store.getAll()
            }.value
        }

        // For larger lists use structured concurrency and partition work among child tasks.
        return await Task.detached(priority: .userInitiated) {
            let store = DimensionsStore()
            // Determine concurrency level
            let workerCount = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount)
            // Partition roughly evenly
            let chunkSize = (imagePaths.count + workerCount - 1) / workerCount

            await withTaskGroup(of: Void.self) { group in
                for workerIndex in 0 ..< workerCount {
                    let start = workerIndex * chunkSize
                    let end = min(start + chunkSize, imagePaths.count)
                    if start >= end { continue }
                    let subrange = imagePaths[start ..< end]

                    group.addTask {
                        // Each child cooperatively checks cancellation and the asyncCancellationCheck frequently
                        for path in subrange {
                            if Task.isCancelled { break }
                            if !(await asyncCancellationCheck()) { break }

                            if let dims = getImageDimensions(imagePath: path) {
                                await store.set(path, dims: (dims.width, dims.height))
                            } else {
                                os_log("Unable to get dimensions for %{public}s (worker)", log: logger, type: .debug, path)
                            }
                        }
                    }
                }

                // Await all children (they can exit early on cancellation)
                await group.waitForAll()
            }

            return await store.getAll()
        }.value
    }

    // MARK: - Backwards-compatible variants

    /// Legacy synchronous wrapper that accepts a synchronous `shouldContinue` closure.
    /// Preserves existing synchronous call sites by running the async implementation on a detached Task.
    static func getBatchImageDimensions(
        imagePaths: [String],
        shouldContinue: @escaping () -> Bool
    ) -> [String: (width: Int, height: Int)] {
        if imagePaths.isEmpty { return [:] }
        var result: [String: (width: Int, height: Int)] = [:]
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let r = await getBatchImageDimensionsAsync(imagePaths: imagePaths, asyncCancellationCheck: {
                shouldContinue()
            })
            result = r
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    /// Backwards-compatible async wrapper that accepts a synchronous `cancellationCheck`.
    /// (Keeps existing internal callers that supply a sync closure working.)
    static func getBatchImageDimensionsAsync(
        imagePaths: [String],
        cancellationCheck: @escaping () -> Bool
    ) async -> [String: (width: Int, height: Int)] {
        return await getBatchImageDimensionsAsync(imagePaths: imagePaths, asyncCancellationCheck: {
            cancellationCheck()
        })
    }
}
