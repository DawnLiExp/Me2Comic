//
//  ImageDirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/9.
//

import Foundation

// MARK: - Image Directory Analyzer

/// Analyzes image directories for processing categorization
final class ImageDirectoryAnalyzer: Sendable {
    // MARK: - Properties
    
    private let logHandler: @Sendable (String, LogLevel, String?) -> Void
    private let isProcessingCheck: @Sendable () async -> Bool
    
    // MARK: - Constants
    
    private enum Constants {
        static let supportedExtensions = Set(["jpg", "jpeg", "png", "webp", "bmp"])
        static let sampleSize = 5
    }
    
    // MARK: - Initialization
    
    /// Initialize analyzer with logging and cancellation support
    /// - Parameters:
    ///   - logHandler: Closure for logging messages with level and source
    ///   - isProcessingCheck: Async closure to check if processing should continue
    init(
        logHandler: @escaping @Sendable (String, LogLevel, String?) -> Void,
        isProcessingCheck: @escaping @Sendable () async -> Bool
    ) {
        self.logHandler = logHandler
        self.isProcessingCheck = isProcessingCheck
    }
    
    /// Initialize analyzer with simple log handler (backward compatibility)
    convenience init(
        logHandler: @escaping @Sendable (String) -> Void,
        isProcessingCheck: @escaping @Sendable () async -> Bool
    ) {
        self.init(
            logHandler: { message, level, source in
                if level.isUserVisible {
                    logHandler(message)
                }
            },
            isProcessingCheck: isProcessingCheck
        )
    }
    
    // MARK: - Public Methods
    
    /// Analyze input directory and categorize subdirectories
    /// - Parameters:
    ///   - inputDir: Parent directory containing subdirectories
    ///   - widthThreshold: Threshold for determining if images need splitting
    /// - Returns: Array of scan results
    func analyzeAsync(inputDir: URL, widthThreshold: Int) async -> [DirectoryScanResult] {
        #if DEBUG
        logHandler("Starting directory analysis for: \(inputDir.path)", .debug, "ImageDirectoryAnalyzer")
        #endif
        
        let fileManager = FileManager.default
        
        do {
            let subdirectories = try getSubdirectories(in: inputDir, fileManager: fileManager)
            
            guard !subdirectories.isEmpty else {
                logHandler(NSLocalizedString("NoSubdirectories", comment: ""), .warning, "ImageDirectoryAnalyzer")
                return []
            }
            
            #if DEBUG
            logHandler("Found \(subdirectories.count) subdirectories to analyze", .debug, "ImageDirectoryAnalyzer")
            #endif
            
            return await analyzeSubdirectories(
                subdirectories,
                widthThreshold: widthThreshold
            )
            
        } catch {
            logHandler(String(
                format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                inputDir.lastPathComponent,
                error.localizedDescription
            ), .error, "ImageDirectoryAnalyzer")
            return []
        }
    }
    
    // MARK: - Private Methods
    
    /// Get subdirectories from parent directory
    private func getSubdirectories(in directory: URL, fileManager: FileManager) throws -> [URL] {
        let subdirectories = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        }
        
        #if DEBUG
        logHandler("Retrieved \(subdirectories.count) subdirectories from \(directory.lastPathComponent)", .debug, "ImageDirectoryAnalyzer")
        #endif
        
        return subdirectories
    }
    
    /// Analyze subdirectories for processing
    private func analyzeSubdirectories(
        _ subdirectories: [URL],
        widthThreshold: Int
    ) async -> [DirectoryScanResult] {
        var results: [DirectoryScanResult] = []
        
        for subdirectory in subdirectories {
            guard await isProcessingCheck() else {
                #if DEBUG
                logHandler("Directory analysis cancelled", .debug, "ImageDirectoryAnalyzer")
                #endif
                return results
            }
            
            let imageFiles = getImageFiles(in: subdirectory)
            
            guard !imageFiles.isEmpty else {
                logHandler(String(
                    format: NSLocalizedString("NoImagesInDir", comment: ""),
                    subdirectory.lastPathComponent
                ), .warning, "ImageDirectoryAnalyzer")
                continue
            }
            
            #if DEBUG
            logHandler("Found \(imageFiles.count) images in \(subdirectory.lastPathComponent)", .debug, "ImageDirectoryAnalyzer")
            #endif
            
            let category = await categorizeDirectory(
                imageFiles: imageFiles,
                widthThreshold: widthThreshold,
                directoryName: subdirectory.lastPathComponent
            )
            
            #if DEBUG
            logHandler("Categorized \(subdirectory.lastPathComponent) as \(category)", .debug, "ImageDirectoryAnalyzer")
            #endif
            
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
        widthThreshold: Int,
        directoryName: String
    ) async -> ProcessingCategory {
        let sampleImages = Array(imageFiles.prefix(Constants.sampleSize))
        let samplePaths = sampleImages.map { $0.path }
        
        #if DEBUG
        logHandler("Sampling \(sampleImages.count) images from \(directoryName) for categorization", .debug, "ImageDirectoryAnalyzer")
        #endif
        
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: samplePaths,
            asyncCancellationCheck: isProcessingCheck
        )
        
        // Check if any sample exceeds width threshold
        for imageURL in sampleImages {
            guard await isProcessingCheck() else {
                #if DEBUG
                logHandler("Categorization cancelled for \(directoryName)", .debug, "ImageDirectoryAnalyzer")
                #endif
                return .isolated
            }
            
            guard let dims = dimensions[imageURL.path] else {
                // Conservative: treat as isolated if dimensions unavailable
                #if DEBUG
                logHandler("Missing dimensions for \(imageURL.lastPathComponent) in \(directoryName), treating as isolated", .debug, "ImageDirectoryAnalyzer")
                #endif
                return .isolated
            }
            
            #if DEBUG
            logHandler("Sample image \(imageURL.lastPathComponent): \(dims.width)x\(dims.height)", .debug, "ImageDirectoryAnalyzer")
            #endif
            
            if dims.width >= widthThreshold {
                #if DEBUG
                logHandler("\(directoryName) categorized as isolated (width \(dims.width) >= \(widthThreshold))", .debug, "ImageDirectoryAnalyzer")
                #endif
                return .isolated
            }
        }
        
        #if DEBUG
        logHandler("\(directoryName) categorized as global batch (all samples < \(widthThreshold)px wide)", .debug, "ImageDirectoryAnalyzer")
        #endif
        
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
            ) + ": " + NSLocalizedString("FailedToCreateEnumerator", comment: ""), .error, "ImageDirectoryAnalyzer")
            return []
        }
        
        var imageFiles: [URL] = []
        
        // Use while loop instead of compactMap to avoid type inference issues
        while let element = enumerator.nextObject() {
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  Constants.supportedExtensions.contains(url.pathExtension.lowercased())
            else {
                continue
            }
            imageFiles.append(url)
        }
        
        #if DEBUG
        logHandler("Enumerated \(imageFiles.count) supported image files in \(directory.lastPathComponent)", .debug, "ImageDirectoryAnalyzer")
        #endif
        
        return imageFiles
    }
}
