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
    let threadCount: Int // Concurrent threads (0=auto, 1-physical CPU cores)
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

/// Task priority levels for scheduling
enum TaskPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3

    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Enhanced batch task with priority
struct PrioritizedBatchTask {
    let images: [URL]
    let outputDir: URL
    let batchSize: Int
    let isGlobal: Bool
    let priority: TaskPriority
    let estimatedCost: Int // Estimated processing cost based on resolution

    var id: UUID = .init()
}
