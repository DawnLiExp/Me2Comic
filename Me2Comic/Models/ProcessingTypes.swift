//
//  ProcessingTypes.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

// MARK: - Processing Parameters

/// Configuration for image processing
struct ProcessingParameters {
    let widthThreshold: Int
    let resizeHeight: Int
    let quality: Int
    let threadCount: Int // Concurrent threads (0=auto, 1-6)
    let unsharpRadius: Float
    let unsharpSigma: Float
    let unsharpAmount: Float
    let unsharpThreshold: Float
    let batchSize: Int // Images per batch (1-1000)
    let useGrayColorspace: Bool
}

// MARK: - Processing Category

/// Processing category for directories
enum ProcessingCategory {
    case globalBatch // Images not requiring cropping
    case isolated // Images requiring cropping or unclear classification
}

// MARK: - Directory Scan Result

/// Result of directory scan
struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
    let category: ProcessingCategory
    let isHighResolution: Bool // High resolution images detected in sampling
}
