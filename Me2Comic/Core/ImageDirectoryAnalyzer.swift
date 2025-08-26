//
//  ImageDirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/9.
//

import Foundation

/// Defines categories for directory processing
enum ProcessingCategory {
    case globalBatch /// For images that do not require cropping; included in global batch
    case isolated /// For images requiring cropping or with unclear classification; processed separately
}

/// Represents the result of a directory scan
struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
    let category: ProcessingCategory
}

/// Analyzer for image directories with async support
class ImageDirectoryAnalyzer {
    private let logHandler: (String) -> Void
    private let isProcessingCheck: () async -> Bool
    
    /// - Parameters:
    ///   - logHandler: closure used to emit ordered log messages (kept sync for caller to decide threading)
    ///   - isProcessingCheck: async closure returning whether processing should continue
    init(logHandler: @escaping (String) -> Void, isProcessingCheck: @escaping () async -> Bool) {
        self.logHandler = logHandler
        self.isProcessingCheck = isProcessingCheck
    }
    
    // MARK: - Directory file enumeration

    /// Scans a directory for supported image files (non-recursive per-subdirectory)
    private func getImageFiles(_ directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            logHandler(
                String(format: NSLocalizedString("ErrorReadingDirectory", comment: ""), directory.lastPathComponent)
                    + ": "
                    + NSLocalizedString("FailedToCreateEnumerator", comment: "")
            )
            return []
        }
        
        let imageExtensions = Set(["jpg", "jpeg", "png", "webp", "bmp"])
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
    }
    
    // MARK: - Async version of directory analysis

    /// Scans inputDir's immediate subdirectories, samples images and classifies directories.
    ///
    /// - Parameters:
    ///   - inputDir: parent directory containing subdirectories to analyze
    ///   - widthThreshold: threshold used to decide whether images are "wide" and thus isolated
    /// - Returns: array of DirectoryScanResult
    func analyzeAsync(inputDir: URL, widthThreshold: Int) async -> [DirectoryScanResult] {
        let fileManager = FileManager.default
        var allScanResults: [DirectoryScanResult] = []
        
        do {
            let subdirs = try fileManager.contentsOfDirectory(
                at: inputDir,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            
            guard !subdirs.isEmpty else {
                logHandler(NSLocalizedString("NoSubdirectories", comment: ""))
                return []
            }
            
            for subdir in subdirs {
                // Cooperative cancellation: check via provided async closure
                guard await isProcessingCheck() else { return [] }
                
                let imageFiles = getImageFiles(subdir)
                guard !imageFiles.isEmpty else {
                    logHandler(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subdir.lastPathComponent))
                    continue
                }
                
                // Sample first up to 5 images for quick classification
                let sampleImages = Array(imageFiles.prefix(5))
                let sampleImagePaths = sampleImages.map { $0.path }

                // Use the async cancellation-aware batch dimensions API
                let sampleDimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
                    imagePaths: sampleImagePaths,
                    asyncCancellationCheck: { [weak self] in
                        guard let self = self else { return false }
                        return await self.isProcessingCheck()
                    }
                )
                
                var isGlobalBatchCandidate = true
                
                for imageURL in sampleImages {
                    // Cooperative cancellation check between samples
                    guard await isProcessingCheck() else { return [] }

                    if let dims = sampleDimensions[imageURL.path] {
                        if dims.width >= widthThreshold {
                            isGlobalBatchCandidate = false
                            break
                        }
                    } else {
                        // Conservative: treat as isolated if dimensions unavailable
                        isGlobalBatchCandidate = false
                        #if DEBUG
                        print("ImageDirectoryAnalyzer: Could not get dimensions for sample image \(imageURL.lastPathComponent), treating as isolated.")
                        #endif
                        break
                    }
                }
                
                let category: ProcessingCategory = isGlobalBatchCandidate ? .globalBatch : .isolated
                allScanResults.append(
                    DirectoryScanResult(
                        directoryURL: subdir,
                        imageFiles: imageFiles,
                        category: category
                    )
                )
            }
        } catch {
            logHandler(
                String(format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                       inputDir.lastPathComponent,
                       error.localizedDescription)
            )
            return []
        }
        
        return allScanResults
    }
    
    // MARK: - Legacy synchronous version for compatibility

    /// Synchronous wrapper for callers that expect blocking behavior.
    func analyze(inputDir: URL, widthThreshold: Int) -> [DirectoryScanResult] {
        let semaphore = DispatchSemaphore(value: 0)
        var result: [DirectoryScanResult] = []
        
        Task {
            result = await analyzeAsync(inputDir: inputDir, widthThreshold: widthThreshold)
            semaphore.signal()
        }
        
        semaphore.wait()
        return result
    }
}
