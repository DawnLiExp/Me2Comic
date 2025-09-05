//
//  GMCommandBuilder.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Builds GraphicsMagick processing commands based on image parameters
struct GMCommandBuilder {
    // MARK: - Properties
    
    private let widthThreshold: Int
    private let resizeHeight: Int
    private let quality: Int
    private let unsharpRadius: Float
    private let unsharpSigma: Float
    private let unsharpAmount: Float
    private let unsharpThreshold: Float
    private let useGrayColorspace: Bool
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    // MARK: - Initialization
    
    init(
        widthThreshold: Int,
        resizeHeight: Int,
        quality: Int,
        unsharpRadius: Float,
        unsharpSigma: Float,
        unsharpAmount: Float,
        unsharpThreshold: Float,
        useGrayColorspace: Bool,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) {
        self.widthThreshold = widthThreshold
        self.resizeHeight = resizeHeight
        self.quality = quality
        self.unsharpRadius = unsharpRadius
        self.unsharpSigma = unsharpSigma
        self.unsharpAmount = unsharpAmount
        self.unsharpThreshold = unsharpThreshold
        self.useGrayColorspace = useGrayColorspace
        self.logger = logger
    }
    
    // MARK: - Public Methods
    
    /// Build processing commands for an image
    /// - Parameters:
    ///   - image: Image URL to process
    ///   - dimensions: Image dimensions (width, height)
    ///   - outputDir: Output directory for processed images
    ///   - pathManager: Path collision manager for unique naming
    ///   - duplicateBaseNames: Set of duplicate base names requiring safe naming
    /// - Returns: Array of GraphicsMagick commands
    func buildProcessingCommands(
        for image: URL,
        dimensions: (width: Int, height: Int),
        outputDir: URL,
        pathManager: PathCollisionManager,
        duplicateBaseNames: Set<String>
    ) async -> [String] {
        let (width, height) = dimensions
        let filenameWithoutExt = image.deletingPathExtension().lastPathComponent
        let srcExt = image.pathExtension.lowercased()
        let originalSubdir = image.deletingLastPathComponent().lastPathComponent
        
        // Determine output directory
        let finalOutputDir = outputDir.lastPathComponent == originalSubdir
            ? outputDir
            : outputDir.appendingPathComponent(originalSubdir)
        
        // Generate safe base name
        let useSafeBase = duplicateBaseNames.contains(filenameWithoutExt.lowercased())
        let baseName = useSafeBase ? "\(filenameWithoutExt)_\(srcExt)" : filenameWithoutExt
        let outputBasePath = finalOutputDir.appendingPathComponent(baseName).path
        
        var commands: [String] = []
        
        if width < widthThreshold {
            // Single image processing
            let outputPath = await pathManager.generateUniquePath(
                basePath: outputBasePath,
                suffix: ".jpg"
            )
            
            #if DEBUG
            logger?("Single image processing: \(image.lastPathComponent) (\(width)x\(height))", .debug, "GMCommandBuilder")
            #endif
            
            commands.append(GraphicsMagickHelper.buildConvertCommand(
                inputPath: image.path,
                outputPath: outputPath,
                cropParams: nil,
                resizeHeight: resizeHeight,
                quality: quality,
                unsharpRadius: unsharpRadius,
                unsharpSigma: unsharpSigma,
                unsharpAmount: unsharpAmount,
                unsharpThreshold: unsharpThreshold,
                useGrayColorspace: useGrayColorspace
            ))
        } else {
            // Split image processing
            let leftWidth = (width + 1) / 2
            let rightWidth = width - leftWidth
            
            #if DEBUG
            logger?("Split image processing: \(image.lastPathComponent) (\(width)x\(height)) -> L:\(leftWidth) R:\(rightWidth)", .debug, "GMCommandBuilder")
            #endif
            
            // Right half
            let rightPath = await pathManager.generateUniquePath(
                basePath: outputBasePath,
                suffix: "-1.jpg"
            )
            
            commands.append(GraphicsMagickHelper.buildConvertCommand(
                inputPath: image.path,
                outputPath: rightPath,
                cropParams: "\(rightWidth)x\(height)+\(leftWidth)+0",
                resizeHeight: resizeHeight,
                quality: quality,
                unsharpRadius: unsharpRadius,
                unsharpSigma: unsharpSigma,
                unsharpAmount: unsharpAmount,
                unsharpThreshold: unsharpThreshold,
                useGrayColorspace: useGrayColorspace
            ))
            
            // Left half
            let leftPath = await pathManager.generateUniquePath(
                basePath: outputBasePath,
                suffix: "-2.jpg"
            )
            
            commands.append(GraphicsMagickHelper.buildConvertCommand(
                inputPath: image.path,
                outputPath: leftPath,
                cropParams: "\(leftWidth)x\(height)+0+0",
                resizeHeight: resizeHeight,
                quality: quality,
                unsharpRadius: unsharpRadius,
                unsharpSigma: unsharpSigma,
                unsharpAmount: unsharpAmount,
                unsharpThreshold: unsharpThreshold,
                useGrayColorspace: useGrayColorspace
            ))
        }
        
        return commands
    }
    
    /// Analyze images for duplicate base names
    /// - Parameter images: Array of image URLs
    /// - Returns: Set of lowercase base names that appear multiple times
    func analyzeDuplicateBaseNames(images: [URL]) -> Set<String> {
        var counts: [String: Int] = [:]
        
        for url in images {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            counts[base, default: 0] += 1
        }
        
        #if DEBUG
        let duplicates = counts.filter { $0.value > 1 }
        if !duplicates.isEmpty {
            logger?("Found \(duplicates.count) duplicate base names requiring safe naming", .debug, "GMCommandBuilder")
        }
        #endif
        
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
}
