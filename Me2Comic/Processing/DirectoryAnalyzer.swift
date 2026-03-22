//
//  DirectoryAnalyzer.swift
//  Me2Comic
//
//  目录扫描：子目录枚举、图片分类、采样检测
//  支持 Mode A（子目录模式）和 Mode B（根目录直含图片模式）
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
        static let highResolutionThreshold = 3000 // Pixel threshold for high resolution detection
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
    
    /// Analyze input directory and categorize subdirectories.
    ///
    /// - Mode B: If the input directory itself contains supported image files,
    ///   treat it as a single processing unit (subdirectories are ignored).
    /// - Mode A: Otherwise, enumerate first-level subdirectories as usual.
    ///
    /// - Parameters:
    ///   - inputDir: Parent directory containing subdirectories or images directly
    ///   - widthThreshold: Threshold for determining if images need splitting
    /// - Returns: Array of scan results
    func analyzeAsync(inputDir: URL, widthThreshold: Int) async -> [DirectoryScanResult] {
        #if DEBUG
        logHandler("Starting directory analysis for: \(inputDir.path)", .debug, "DirectoryAnalyzer")
        #endif

        // ── Mode B Detection ─────────────────────────────────────────────────
        let rootImages = detectRootImages(in: inputDir)

        if !rootImages.isEmpty {
            logHandler(
                String(format: String(localized: "ModeBDetected"), rootImages.count, inputDir.lastPathComponent),
                .info,
                "DirectoryAnalyzer"
            )

            // Warn if subdirectories also exist (they will be silently ignored)
            let fileManager = FileManager.default
            let subdirectoriesResult = getSubdirectories(in: inputDir, fileManager: fileManager)
            if case .success(let subdirs) = subdirectoriesResult, !subdirs.isEmpty {
                logHandler(
                    String(format: String(localized: "ModeBSubdirIgnored"), subdirs.count),
                    .warning,
                    "DirectoryAnalyzer"
                )
            }

            let (category, isHighResolution) = await categorizeDirectory(
                imageFiles: rootImages,
                widthThreshold: widthThreshold,
                directoryName: inputDir.lastPathComponent
            )

            return [DirectoryScanResult(
                directoryURL: inputDir,
                imageFiles: rootImages,
                category: category,
                isHighResolution: isHighResolution
            )]
        }

        // ── Mode A: Original subdirectory logic (unchanged) ──────────────────
        let fileManager = FileManager.default
        let subdirectoriesResult = getSubdirectories(in: inputDir, fileManager: fileManager)
        
        switch subdirectoriesResult {
        case .success(let subdirectories):
            guard !subdirectories.isEmpty else {
                logHandler(String(localized: "NoSubdirectories"), .warning, "DirectoryAnalyzer")
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

    /// Detect supported image files directly inside the given directory (non-recursive).
    /// Reuses `getImageFiles(in:)` which already applies `skipsSubdirectoryDescendants`.
    private func detectRootImages(in directory: URL) -> [URL] {
        getImageFiles(in: directory)
    }

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
            
            let (category, isHighResolution) = await categorizeDirectory(
                imageFiles: imageFiles,
                widthThreshold: widthThreshold,
                directoryName: subdirectory.lastPathComponent
            )
            
            #if DEBUG
            logHandler("Categorized \(subdirectory.lastPathComponent) as \(category)\(isHighResolution ? " [High Resolution]" : "")", .debug, "DirectoryAnalyzer")
            #endif
            
            results.append(DirectoryScanResult(
                directoryURL: subdirectory,
                imageFiles: imageFiles,
                category: category,
                isHighResolution: isHighResolution
            ))
        }
        
        return results
    }
    
    /// Categorize directory based on sample images
    private func categorizeDirectory(
        imageFiles: [URL],
        widthThreshold: Int,
        directoryName: String
    ) async -> (category: ProcessingCategory, isHighResolution: Bool) {
        let sampleImages = Array(imageFiles.prefix(Constants.sampleSize))
        let samplePaths = sampleImages.map(\.path)
        
        #if DEBUG
        logHandler("Sampling \(sampleImages.count) images from \(directoryName) for categorization", .debug, "DirectoryAnalyzer")
        #endif
        
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: samplePaths,
            asyncCancellationCheck: isProcessingCheck,
            logger: logHandler
        )
        
        var exceedsThreshold = false
        var isHighResolution = false
        
        // Check dimensions for categorization and high resolution detection
        for imageURL in sampleImages {
            guard await isProcessingCheck() else {
                #if DEBUG
                logHandler("Categorization cancelled for \(directoryName)", .debug, "DirectoryAnalyzer")
                #endif
                return (.isolated, false)
            }
            
            guard let dims = dimensions[imageURL.path] else {
                // Conservative: treat as isolated if dimensions unavailable
                #if DEBUG
                logHandler("Missing dimensions for \(imageURL.lastPathComponent) in \(directoryName), treating as isolated", .debug, "DirectoryAnalyzer")
                #endif
                return (.isolated, false)
            }
            
            #if DEBUG
            logHandler("Sample image \(imageURL.lastPathComponent): \(dims.width)x\(dims.height)", .debug, "DirectoryAnalyzer")
            #endif
            
            // Check for width threshold (existing logic)
            if dims.width >= widthThreshold {
                exceedsThreshold = true
                #if DEBUG
                logHandler("\(directoryName) requires isolation (width \(dims.width) >= \(widthThreshold))", .debug, "DirectoryAnalyzer")
                #endif
            }
            
            // Check for high resolution
            if dims.width >= Constants.highResolutionThreshold || dims.height >= Constants.highResolutionThreshold {
                isHighResolution = true
                #if DEBUG
                logHandler("High resolution detected in \(directoryName): \(dims.width)x\(dims.height)", .debug, "DirectoryAnalyzer")
                #endif
            }
        }
        
        let category: ProcessingCategory = exceedsThreshold ? .isolated : .globalBatch
        
        #if DEBUG
        if !exceedsThreshold {
            logHandler("\(directoryName) categorized as global batch (all samples < \(widthThreshold)px wide)", .debug, "DirectoryAnalyzer")
        }
        #endif
        
        return (category, isHighResolution)
    }
    
    /// Get image files from directory (non-recursive)
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
