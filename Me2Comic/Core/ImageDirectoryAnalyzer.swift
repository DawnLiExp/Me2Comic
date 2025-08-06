//
//  ImageDirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/9.
//

import Foundation

/// Defines categories for directory processing.
enum ProcessingCategory {
    case globalBatch /// For images that do not require cropping; included in global batch.
    case isolated /// For images requiring cropping or with unclear classification; processed separately.
}

/// Represents the result of a directory scan.
struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
    let category: ProcessingCategory
}

class ImageDirectoryAnalyzer {
    private let logHandler: (String) -> Void
    private let isProcessingCheck: () -> Bool

    init(logHandler: @escaping (String) -> Void, isProcessingCheck: @escaping () -> Bool) {
        self.logHandler = logHandler
        self.isProcessingCheck = isProcessingCheck
    }

    /// Scans a directory for supported image files.
    private func getImageFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else {
            DispatchQueue.main.async { [self] in
                logHandler(String(format: NSLocalizedString("ErrorReadingDirectory", comment: ""), directory.lastPathComponent)
                    + ": "
                    + NSLocalizedString("FailedToCreateEnumerator", comment: ""))
            }
            return []
        }

        let imageExtensions = Set(["jpg", "jpeg", "png"])
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
    }

    /// Scans the input directory and classifies subdirectories based on image properties.
    /// - Parameters:
    ///   - inputDir: The input directory URL.
    ///   - widthThreshold: The width threshold for image classification.
    /// - Returns: An array of `DirectoryScanResult` containing classified directories.
    func analyze(inputDir: URL, widthThreshold: Int) -> [DirectoryScanResult] {
        let fileManager = FileManager.default
        var allScanResults: [DirectoryScanResult] = []

        do {
            let subdirs = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }

            guard !subdirs.isEmpty else {
                DispatchQueue.main.async { [self] in
                    logHandler(NSLocalizedString("NoSubdirectories", comment: ""))
                }
                return []
            }

            for subdir in subdirs {
                // Check for cancellation before processing each subdirectory
                guard isProcessingCheck() else { return [] }

                let imageFiles = getImageFiles(subdir)
                guard !imageFiles.isEmpty else {
                    DispatchQueue.main.async { [self] in
                        logHandler(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subdir.lastPathComponent))
                    }
                    continue
                }

                let sampleImages = Array(imageFiles.prefix(5))
                let sampleImagePaths = sampleImages.map { $0.path }

                // Use ImageIOHelper to get dimensions for sample images.
                let sampleDimensions = ImageIOHelper.getBatchImageDimensions(imagePaths: sampleImagePaths) {
                    // Pass the isProcessingCheck closure to ImageIOHelper for cancellation support
                    self.isProcessingCheck()
                }

                var isGlobalBatchCandidate = true

                for imageURL in sampleImages {
                    if let dims = sampleDimensions[imageURL.path] {
                        if dims.width >= widthThreshold {
                            isGlobalBatchCandidate = false
                            break
                        }
                    } else {
                        // If sample image dimensions cannot be retrieved, conservatively treat as isolated.
                        isGlobalBatchCandidate = false
                        #if DEBUG
                            print("ImageDirectoryAnalyzer: Could not get dimensions for sample image \(imageURL.lastPathComponent), treating as isolated.")
                        #endif
                        break
                    }
                }

                let category: ProcessingCategory = isGlobalBatchCandidate ? .globalBatch : .isolated
                allScanResults.append(DirectoryScanResult(directoryURL: subdir, imageFiles: imageFiles, category: category))
            }
        } catch {
            DispatchQueue.main.async { [self] in
                logHandler(String(format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                                  inputDir.lastPathComponent,
                                  error.localizedDescription))
            }
            return []
        }
        return allScanResults
    }
}
