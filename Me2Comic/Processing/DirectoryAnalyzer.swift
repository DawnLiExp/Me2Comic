//
//  DirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by Me2 on 2025/7/9.
//

import Foundation

// MARK: - Image Directory Analyzer

/// Analyzes image directories for processing categorization
final class DirectoryAnalyzer: Sendable {
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
            logHandler: { message, level, _ in
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
        logHandler("Starting directory analysis for: \(inputDir.path)", .debug, "DirectoryAnalyzer")
        #endif
        
        let fileManager = FileManager.default
        
        let subdirectoriesResult = getSubdirectories(in: inputDir, fileManager: fileManager)
        
        switch subdirectoriesResult {
        case .success(let subdirectories):
            guard !subdirectories.isEmpty else {
                logHandler(NSLocalizedString("NoSubdirectories", comment: ""), .warning, "DirectoryAnalyzer")
                return []
            }
            
            #if DEBUG
            logHandler("Found \(subdirectories.count) subdirectories to analyze", .debug, "DirectoryAnalyzer")
            #endif
            
            return await analyzeSubdirectories(
                subdirectories,
                widthThreshold: widthThreshold
            )
            
        case .failure(let error):
            logHandler(error.localizedDescription, .error, "DirectoryAnalyzer")
            return []
        }
    }
    
    // MARK: - Private Methods
    
    /// Get subdirectories from parent directory
    private func getSubdirectories(
        in directory: URL,
        fileManager: FileManager
    ) -> Result<[URL], ProcessingError> {
        do {
            let subdirectories = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            }
            
            #if DEBUG
            logHandler("Retrieved \(subdirectories.count) subdirectories from \(directory.lastPathComponent)", .debug, "DirectoryAnalyzer")
            #endif
            
            return .success(subdirectories)
        } catch {
            #if DEBUG
            logHandler("Failed to enumerate subdirectories: \(error)", .debug, "DirectoryAnalyzer")
            #endif
            return .failure(.directoryReadFailed(path: directory.path, underlyingError: error))
        }
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
                logHandler("Directory analysis cancelled", .debug, "DirectoryAnalyzer")
                #endif
                return results
            }
            
            let imageFiles = getImageFiles(in: subdirectory)
            
            guard !imageFiles.isEmpty else {
                logHandler(
                    ProcessingError.noImagesFound(directory: subdirectory.lastPathComponent).localizedDescription,
                    .warning,
                    "DirectoryAnalyzer"
                )
                continue
            }
            
            #if DEBUG
            logHandler("Found \(imageFiles.count) images in \(subdirectory.lastPathComponent)", .debug, "DirectoryAnalyzer")
            #endif
            
            let category = await categorizeDirectory(
                imageFiles: imageFiles,
                widthThreshold: widthThreshold,
                directoryName: subdirectory.lastPathComponent
            )
            
            #if DEBUG
            logHandler("Categorized \(subdirectory.lastPathComponent) as \(category)", .debug, "DirectoryAnalyzer")
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
        logHandler("Sampling \(sampleImages.count) images from \(directoryName) for categorization", .debug, "DirectoryAnalyzer")
        #endif
        
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: samplePaths,
            asyncCancellationCheck: isProcessingCheck,
            logger: logHandler
        )
        
        // Check if any sample exceeds width threshold
        for imageURL in sampleImages {
            guard await isProcessingCheck() else {
                #if DEBUG
                logHandler("Categorization cancelled for \(directoryName)", .debug, "DirectoryAnalyzer")
                #endif
                return .isolated
            }
            
            guard let dims = dimensions[imageURL.path] else {
                // Conservative: treat as isolated if dimensions unavailable
                #if DEBUG
                logHandler("Missing dimensions for \(imageURL.lastPathComponent) in \(directoryName), treating as isolated", .debug, "DirectoryAnalyzer")
                #endif
                return .isolated
            }
            
            #if DEBUG
            logHandler("Sample image \(imageURL.lastPathComponent): \(dims.width)x\(dims.height)", .debug, "DirectoryAnalyzer")
            #endif
            
            if dims.width >= widthThreshold {
                #if DEBUG
                logHandler("\(directoryName) categorized as isolated (width \(dims.width) >= \(widthThreshold))", .debug, "DirectoryAnalyzer")
                #endif
                return .isolated
            }
        }
        
        #if DEBUG
        logHandler("\(directoryName) categorized as global batch (all samples < \(widthThreshold)px wide)", .debug, "DirectoryAnalyzer")
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
            let error = ProcessingError.directoryReadFailed(
                path: directory.path,
                underlyingError: CocoaError(.fileReadUnknown)
            )
            logHandler(error.localizedDescription, .error, "DirectoryAnalyzer")
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
        logHandler("Enumerated \(imageFiles.count) supported image files in \(directory.lastPathComponent)", .debug, "DirectoryAnalyzer")
        #endif
        
        return imageFiles
    }
}
