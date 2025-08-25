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
    // Keep messages concise and structured for system logging.
    private static let logger = OSLog(subsystem: "me2.comic.me2comic", category: "ImageIOHelper")

    // Simple lock wrapper using os_unfair_lock for small critical sections.
    // Using a lightweight primitive for minimal contention in hot paths.
    private final class UnfairLock: @unchecked Sendable {
        private var _lock = os_unfair_lock()
        func withLock<R>(_ body: () throws -> R) rethrows -> R {
            os_unfair_lock_lock(&_lock)
            defer { os_unfair_lock_unlock(&_lock) }
            return try body()
        }
    }

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

    // MARK: - Async batch API

    /// Asynchronously retrieves pixel dimensions for multiple images.
    ///
    /// Behavior:
    /// - Uses a hybrid strategy: single-threaded for very small lists; otherwise uses
    ///   concurrent partitions equal to the active processor count.
    /// - Respects cooperative cancellation via Task.isCancelled and via an optional
    ///   `cancellationCheck` closure. The closure should return `true` to continue.
    /// - Returns partial results if cancelled; no exceptions are thrown for IO failures.
    ///
    /// - Parameters:
    ///   - imagePaths: Array of absolute image paths.
    ///   - cancellationCheck: Optional closure called frequently; return `true` to continue processing.
    ///                        Default checks `Task.isCancelled`.
    /// - Returns: Dictionary mapping path -> (width, height). Missing entries indicate failures.
    static func getBatchImageDimensionsAsync(
        imagePaths: [String],
        cancellationCheck: @escaping () -> Bool = { !Task.isCancelled }
    ) async -> [String: (width: Int, height: Int)] {
        // Fast path
        guard !imagePaths.isEmpty else { return [:] }

        // Run the heavy work on a detached task so that we don't block the caller actor.
        return await Task.detached(priority: .userInitiated) {
            var result: [String: (width: Int, height: Int)] = [:]
            let lock = UnfairLock()

            // Concurrency decision:
            // - Small batches run serially to avoid thread startup overhead.
            // - Larger batches partition into `taskCount` chunks and process concurrently.
            let taskCount: Int
            if imagePaths.count < 20 {
                taskCount = 1
            } else {
                taskCount = min(imagePaths.count, ProcessInfo.processInfo.activeProcessorCount)
            }

            // Partition size for roughly-even distribution.
            let imagesPerTask = (imagePaths.count + taskCount - 1) / taskCount

            DispatchQueue.concurrentPerform(iterations: taskCount) { taskIndex in
                // Cooperative cancellation check at chunk start.
                guard cancellationCheck() else { return }

                let start = taskIndex * imagesPerTask
                let end = min(start + imagesPerTask, imagePaths.count)
                guard start < end else { return }

                for i in start ..< end {
                    // Frequent cancellation point between images.
                    if !cancellationCheck() { return }

                    let path = imagePaths[i]
                    if let dims = getImageDimensions(imagePath: path) {
                        lock.withLock {
                            result[path] = dims
                        }
                    } else {
                        // Log at debug level; do not treat as fatal.
                        os_log("Unable to get dimensions for %{public}s", log: logger, type: .debug, path)
                    }
                }
            }

            return result
        }.value
    }

    // MARK: - Backwards-compatible synchronous wrapper

    /// Backwards-compatible synchronous API.
    ///
    /// This preserves existing call sites that expect a blocking call and the legacy `shouldContinue` closure.
    /// Internally it reuses the async implementation executed on a detached task to avoid duplicating logic.
    ///
    /// - Parameters:
    ///   - imagePaths: Array of absolute image paths.
    ///   - shouldContinue: Closure returning `true` to continue processing, `false` to stop.
    /// - Returns: Dictionary mapping path -> (width, height). Partial results possible on early stop.
    static func getBatchImageDimensions(
        imagePaths: [String],
        shouldContinue: @escaping () -> Bool
    ) -> [String: (width: Int, height: Int)] {
        if imagePaths.isEmpty { return [:] }
        var result: [String: (width: Int, height: Int)] = [:]
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            let r = await getBatchImageDimensionsAsync(
                imagePaths: imagePaths,
                cancellationCheck: shouldContinue
            )
            result = r
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }
}
