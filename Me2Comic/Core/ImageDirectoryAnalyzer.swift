//
//  ImageDirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/9.
//

import Foundation

// MARK: - Types

/// Processing category for directories
enum ProcessingCategory {
    case globalBatch // Images not requiring cropping
    case isolated // Images requiring cropping or unclear classification
}

/// Result of directory scan
struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
    let category: ProcessingCategory
}

// MARK: - Image Directory Analyzer

/// Analyzes image directories for processing categorization
class ImageDirectoryAnalyzer {
    // MARK: - Properties
    
    private let logHandler: (String) -> Void
    private let isProcessingCheck: () async -> Bool
    
    // MARK: - Constants
    
    private enum Constants {
        static let supportedExtensions = Set(["jpg", "jpeg", "png", "webp", "bmp"])
        static let sampleSize = 5
    }
    
    // MARK: - Initialization
    
    /// Initialize analyzer with logging and cancellation support
    /// - Parameters:
    ///   - logHandler: Closure for logging messages
    ///   - isProcessingCheck: Async closure to check if processing should continue
    init(
        logHandler: @escaping (String) -> Void,
        isProcessingCheck: @escaping () async -> Bool
    ) {
        self.logHandler = logHandler
        self.isProcessingCheck = isProcessingCheck
    }
    
    // MARK: - Public Methods
    
    /// Analyze input directory and categorize subdirectories
    /// - Parameters:
    ///   - inputDir: Parent directory containing subdirectories
    ///   - widthThreshold: Threshold for determining if images need splitting
    /// - Returns: Array of scan results
    func analyzeAsync(inputDir: URL, widthThreshold: Int) async -> [DirectoryScanResult] {
        let fileManager = FileManager.default
        
        do {
            let subdirectories = try getSubdirectories(in: inputDir, fileManager: fileManager)
            
            guard !subdirectories.isEmpty else {
                logHandler(NSLocalizedString("NoSubdirectories", comment: ""))
                return []
            }
            
            return await analyzeSubdirectories(
                subdirectories,
                widthThreshold: widthThreshold
            )
            
        } catch {
            logHandler(String(
                format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                inputDir.lastPathComponent,
                error.localizedDescription
            ))
            return []
        }
    }
    
    // MARK: - Private Methods
    
    /// Get subdirectories from parent directory
    private func getSubdirectories(in directory: URL, fileManager: FileManager) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
    }
    
    /// Analyze subdirectories for processing
    private func analyzeSubdirectories(
        _ subdirectories: [URL],
        widthThreshold: Int
    ) async -> [DirectoryScanResult] {
        var results: [DirectoryScanResult] = []
        
        for subdirectory in subdirectories {
            guard await isProcessingCheck() else { return results }
            
            let imageFiles = getImageFiles(in: subdirectory)
            
            guard !imageFiles.isEmpty else {
                logHandler(String(
                    format: NSLocalizedString("NoImagesInDir", comment: ""),
                    subdirectory.lastPathComponent
                ))
                continue
            }
            
            let category = await categorizeDirectory(
                imageFiles: imageFiles,
                widthThreshold: widthThreshold
            )
            
            results.append(DirectoryScanResult(
                directoryURL: subdirectory,
                imageFiles: imageFiles,
                category: category
            ))
        }
        
        return results
    }
    
    /// Categorize directory based on sample images
    private func categorizeDirectory(
        imageFiles: [URL],
        widthThreshold: Int
    ) async -> ProcessingCategory {
        let sampleImages = Array(imageFiles.prefix(Constants.sampleSize))
        let samplePaths = sampleImages.map { $0.path }
        
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: samplePaths,
            asyncCancellationCheck: { [weak self] in
                guard let self = self else { return false }
                return await self.isProcessingCheck()
            }
        )
        
        // Check if any sample exceeds width threshold
        for imageURL in sampleImages {
            guard await isProcessingCheck() else { return .isolated }
            
            guard let dims = dimensions[imageURL.path] else {
                // Conservative: treat as isolated if dimensions unavailable
                #if DEBUG
                print("ImageDirectoryAnalyzer: Missing dimensions for \(imageURL.lastPathComponent), treating as isolated")
                #endif
                return .isolated
            }
            
            if dims.width >= widthThreshold {
                return .isolated
            }
        }
        
        return .globalBatch
    }
    
    /// Get image files from directory
    private func getImageFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            logHandler(String(
                format: NSLocalizedString("ErrorReadingDirectory", comment: ""),
                directory.lastPathComponent
            ) + ": " + NSLocalizedString("FailedToCreateEnumerator", comment: ""))
            return []
        }
        
        return enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  Constants.supportedExtensions.contains(url.pathExtension.lowercased())
            else {
                return nil
            }
            return url
        }
    }
}
