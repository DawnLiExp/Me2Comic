//
//  BatchImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

import Foundation

/// Coordinates batch image processing workflow
struct BatchImageProcessor {
    // MARK: - Properties
    
    private let gmPath: String
    private let widthThreshold: Int
    private let resizeHeight: Int
    private let quality: Int
    private let unsharpRadius: Float
    private let unsharpSigma: Float
    private let unsharpAmount: Float
    private let unsharpThreshold: Float
    private let useGrayColorspace: Bool
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    // MARK: - Components
    
    private let processExecutor: GMProcessExecutor
    private let commandBuilder: GMCommandBuilder
    
    // MARK: - Initialization
    
    init(
        gmPath: String,
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
        self.gmPath = gmPath
        self.widthThreshold = widthThreshold
        self.resizeHeight = resizeHeight
        self.quality = quality
        self.unsharpRadius = unsharpRadius
        self.unsharpSigma = unsharpSigma
        self.unsharpAmount = unsharpAmount
        self.unsharpThreshold = unsharpThreshold
        self.useGrayColorspace = useGrayColorspace
        self.logger = logger
        
        // Initialize components
        self.processExecutor = GMProcessExecutor(
            gmPath: gmPath,
            logger: logger
        )
        
        self.commandBuilder = GMCommandBuilder(
            widthThreshold: widthThreshold,
            resizeHeight: resizeHeight,
            quality: quality,
            unsharpRadius: unsharpRadius,
            unsharpSigma: unsharpSigma,
            unsharpAmount: unsharpAmount,
            unsharpThreshold: unsharpThreshold,
            useGrayColorspace: useGrayColorspace,
            logger: logger
        )
    }
    
    // MARK: - Public Methods
    
    /// Process batch of images
    /// - Parameters:
    ///   - images: Array of image URLs to process
    ///   - outputDir: Output directory for processed images
    /// - Returns: Tuple of (processed count, failed filenames)
    func processBatch(images: [URL], outputDir: URL) async -> (processed: Int, failed: [String]) {
        guard !images.isEmpty, !Task.isCancelled else {
            return (0, [])
        }
        
        #if DEBUG
        logger?("Starting batch processing for \(images.count) images", .debug, "BatchImageProcessor")
        #endif
        
        // Fetch image dimensions
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: images.map { $0.path },
            asyncCancellationCheck: { !Task.isCancelled },
            logger: logger
        )
        
        guard !Task.isCancelled, !dimensions.isEmpty else {
            #if DEBUG
            logger?("Batch processing cancelled or no dimensions retrieved", .debug, "BatchImageProcessor")
            #endif
            return (0, images.map { $0.lastPathComponent })
        }
        
        #if DEBUG
        logger?("Retrieved dimensions for \(dimensions.count)/\(images.count) images", .debug, "BatchImageProcessor")
        #endif
        
        return await executeBatch(
            images: images,
            dimensions: dimensions,
            outputDir: outputDir
        )
    }
    
    // MARK: - Private Methods
    
    /// Execute batch processing with GraphicsMagick
    private func executeBatch(
        images: [URL],
        dimensions: [String: (width: Int, height: Int)],
        outputDir: URL
    ) async -> (processed: Int, failed: [String]) {
        let pathManager = PathCollisionManager(logger: logger)
        
        // Prepare command generator closure
        let commandGenerator: (FileHandle) async -> Result<Void, ProcessingError> = { [self] fileHandle in
            await self.generateAndWriteCommands(
                to: fileHandle,
                images: images,
                dimensions: dimensions,
                outputDir: outputDir,
                pathManager: pathManager
            )
        }
        
        // Execute batch process
        let executionResult = await processExecutor.executeBatch(
            commandGenerator: commandGenerator
        )
        
        switch executionResult {
        case .success:
            // Commands were written successfully
            let processedCount = dimensions.count
            let failedFiles = images.compactMap { image in
                dimensions[image.path] == nil ? image.lastPathComponent : nil
            }
            return (processedCount, failedFiles)
            
        case .failure:
            return (0, images.map { $0.lastPathComponent })
        }
    }
    
    /// Generate and write processing commands
    private func generateAndWriteCommands(
        to fileHandle: FileHandle,
        images: [URL],
        dimensions: [String: (width: Int, height: Int)],
        outputDir: URL,
        pathManager: PathCollisionManager
    ) async -> Result<Void, ProcessingError> {
        // Analyze duplicate base names
        let duplicateBaseNames = commandBuilder.analyzeDuplicateBaseNames(images: images)
        
        for image in images {
            guard !Task.isCancelled else {
                return .failure(.processingCancelled)
            }
            
            guard let dims = dimensions[image.path] else {
                #if DEBUG
                logger?("Missing dimensions for image: \(image.lastPathComponent)", .debug, "BatchImageProcessor")
                #endif
                continue
            }
            
            // Build commands for this image
            let commands = await commandBuilder.buildProcessingCommands(
                for: image,
                dimensions: dims,
                outputDir: outputDir,
                pathManager: pathManager,
                duplicateBaseNames: duplicateBaseNames
            )
            
            // Write each command
            for command in commands {
                let writeResult = await processExecutor.writeCommand(command, to: fileHandle)
                if case .failure(let error) = writeResult {
                    return .failure(error)
                }
            }
            
            #if DEBUG
            logger?("Generated \(commands.count) command(s) for \(image.lastPathComponent)", .debug, "BatchImageProcessor")
            #endif
        }
        
        return .success(())
    }
}
