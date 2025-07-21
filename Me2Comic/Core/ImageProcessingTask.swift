//
//  v2.1-ImageProcessingTask.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/20.
//

import Foundation

/// Represents a single image processing unit within the unified batch processing system.
/// This class encapsulates all necessary information for processing an image,
/// regardless of whether it requires cropping or not.
/// Using a class allows for safe, concurrent updates to its properties (dimensions, requiresCropping).
class ImageProcessingTask {
    /// The URL of the original image file.
    let imageURL: URL

    /// The original subdirectory name from which the image was sourced.
    /// This is crucial for reconstructing the correct output path, especially for Isolated-like scenarios.
    let originalSubdirectoryName: String

    /// The dimensions (width and height) of the image.
    /// This property will be updated asynchronously after initial creation.
    var dimensions: (width: Int, height: Int)

    /// A boolean indicating whether the image requires cropping based on the width threshold.
    /// This property will be updated asynchronously after initial creation.
    var requiresCropping: Bool

    /// The pre-calculated final output directory for this specific image.
    /// This eliminates complex path resolution logic within BatchProcessOperation.
    let finalOutputDir: URL

    /// The base name for the output file, without extension.
    /// This is derived from the original image's filename.
    let outputBaseName: String

    init(
        imageURL: URL,
        originalSubdirectoryName: String,
        dimensions: (width: Int, height: Int) = (width: 0, height: 0), // Default to dummy values
        requiresCropping: Bool = false, // Default to false
        finalOutputDir: URL,
        outputBaseName: String
    ) {
        self.imageURL = imageURL
        self.originalSubdirectoryName = originalSubdirectoryName
        self.dimensions = dimensions
        self.requiresCropping = requiresCropping
        self.finalOutputDir = finalOutputDir
        self.outputBaseName = outputBaseName
    }
}
