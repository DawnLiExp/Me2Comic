//
//  BatchImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

import Darwin
import Foundation

// MARK: - Path Collision Manager

/// Thread-safe output path management
private actor PathCollisionManager {
    private var reservedPaths: Set<String> = []
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    /// Generate unique output path with collision avoidance
    /// - Parameters:
    ///   - basePath: Base path without extension
    ///   - suffix: Suffix including extension (e.g., ".jpg", "-1.jpg")
    /// - Returns: Unique path guaranteed not to collide
    func generateUniquePath(basePath: String, suffix: String) -> String {
        var candidate = basePath + suffix
        var candidateKey = candidate.lowercased()
        var attempt = 0
        
        while reservedPaths.contains(candidateKey) && attempt < 10000 {
            attempt += 1
            candidate = "\(basePath)-\(attempt)\(suffix)"
            candidateKey = candidate.lowercased()
        }
        
        // Fallback to timestamp if too many collisions
        if reservedPaths.contains(candidateKey) {
            #if DEBUG
            logger?("Excessive path collisions detected, using timestamp fallback", .debug, "PathCollisionManager")
            #endif
            
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            candidate = "\(basePath)-\(timestamp)\(suffix)"
            candidateKey = candidate.lowercased()
        }
        
        reservedPaths.insert(candidateKey)
        
        #if DEBUG
        if attempt > 0 {
            logger?("Path collision resolved: \(attempt) attempts for \(basePath)", .debug, "PathCollisionManager")
        }
        #endif
        
        return candidate
    }
    
    func reset() {
        #if DEBUG
        logger?("Path collision manager reset, cleared \(reservedPaths.count) reserved paths", .debug, "PathCollisionManager")
        #endif
        reservedPaths.removeAll()
    }
}

// MARK: - Process Output Collector

/// Thread-safe collection of process output
private actor ProcessOutputCollector {
    private var stdout = Data()
    private var stderr = Data()
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    func appendStdout(_ data: Data) {
        stdout.append(data)
        #if DEBUG
        if !data.isEmpty {
            logger?("Collected \(data.count) bytes of stdout", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    func appendStderr(_ data: Data) {
        stderr.append(data)
        #if DEBUG
        if !data.isEmpty {
            logger?("Collected \(data.count) bytes of stderr", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    func getOutput() -> (stdout: Data, stderr: Data) {
        return (stdout, stderr)
    }
}

// MARK: - Batch Image Processor

/// Handles batch image processing via GraphicsMagick
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
    
    // MARK: - Constants
    
    private enum Constants {
        static let writeChunkSize = 16 * 1024 // 16KB
        static let maxWriteAttempts = 50
    }
    
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
        let outputCollector = ProcessOutputCollector(logger: logger)
        
        // Setup process
        let process = createBatchProcess()
        
        // Setup pipes
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        // Setup output handlers
        setupOutputHandlers(
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            collector: outputCollector
        )
        
        defer {
            cleanupProcess(process, outputPipe: outputPipe, errorPipe: errorPipe)
        }
        
        // Execute with cancellation support
        return await withTaskCancellationHandler {
            await performBatchProcessing(
                process: process,
                inputPipe: inputPipe,
                images: images,
                dimensions: dimensions,
                outputDir: outputDir,
                pathManager: pathManager,
                outputCollector: outputCollector
            )
        } onCancel: {
            terminateProcess(process)
        }
    }
    
    /// Perform batch processing
    private func performBatchProcessing(
        process: Process,
        inputPipe: Pipe,
        images: [URL],
        dimensions: [String: (width: Int, height: Int)],
        outputDir: URL,
        pathManager: PathCollisionManager,
        outputCollector: ProcessOutputCollector
    ) async -> (processed: Int, failed: [String]) {
        do {
            #if DEBUG
            logger?("Starting GraphicsMagick batch process", .debug, "BatchImageProcessor")
            #endif
            
            try process.run()
            
            guard !Task.isCancelled else {
                #if DEBUG
                logger?("Processing cancelled, terminating GM process", .debug, "BatchImageProcessor")
                #endif
                terminateProcess(process)
                return (0, [])
            }
            
            let writeHandle = inputPipe.fileHandleForWriting
            defer { try? writeHandle.close() }
            
            // Generate and write commands
            let result = await generateAndWriteCommands(
                to: writeHandle,
                images: images,
                dimensions: dimensions,
                outputDir: outputDir,
                pathManager: pathManager
            )
            
            // Close input to signal completion
            try? writeHandle.close()
            
            #if DEBUG
            logger?("Commands written, waiting for process completion", .debug, "BatchImageProcessor")
            #endif
            
            // Wait for process completion using event-driven approach
            await waitForProcessTermination(process)
            
            // Process is guaranteed to be terminated, safe to read exit code
            let exitCode = process.terminationStatus
            
            #if DEBUG
            logger?("GraphicsMagick process completed with exit code: \(exitCode)", .debug, "BatchImageProcessor")
            #endif
            
            if exitCode != 0, !Task.isCancelled {
                let stderrString = await getProcessError(outputCollector: outputCollector)
                let error = ProcessingError.graphicsMagickExecutionFailed(
                    exitCode: exitCode,
                    stderr: stderrString
                )
                logger?(error.localizedDescription, .error, "BatchImageProcessor")
                return (0, images.map { $0.lastPathComponent })
            }
            
            return result
            
        } catch {
            #if DEBUG
            logger?("BatchImageProcessor execution error: \(error.localizedDescription)", .debug, "BatchImageProcessor")
            #endif
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
    ) async -> (processed: Int, failed: [String]) {
        var processedCount = 0
        var failedFiles: [String] = []
        
        // Analyze duplicate base names
        let duplicateBaseNames = analyzeDuplicateBaseNames(images: images)
        
        #if DEBUG
        if !duplicateBaseNames.isEmpty {
            logger?("Found \(duplicateBaseNames.count) duplicate base names requiring safe naming", .debug, "BatchImageProcessor")
        }
        #endif
        
        for image in images {
            guard !Task.isCancelled else { break }
            
            guard let dims = dimensions[image.path] else {
                #if DEBUG
                logger?("Missing dimensions for image: \(image.lastPathComponent)", .debug, "BatchImageProcessor")
                #endif
                failedFiles.append(image.lastPathComponent)
                continue
            }
            
            let commands = await buildProcessingCommands(
                for: image,
                dimensions: dims,
                outputDir: outputDir,
                pathManager: pathManager,
                duplicateBaseNames: duplicateBaseNames
            )
            
            let writeResult = await writeCommands(commands, to: fileHandle)
            switch writeResult {
            case .success:
                processedCount += 1
                #if DEBUG
                logger?("Generated \(commands.count) command(s) for \(image.lastPathComponent)", .debug, "BatchImageProcessor")
                #endif
            case .failure(let error):
                #if DEBUG
                logger?("Failed to write commands for \(image.lastPathComponent): \(error)", .debug, "BatchImageProcessor")
                #endif
                failedFiles.append(image.lastPathComponent)
                // Stop on write error
            }
        }
        
        return (processedCount, failedFiles)
    }
    
    /// Build processing commands for single image
    private func buildProcessingCommands(
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
            logger?("Single image processing: \(image.lastPathComponent) (\(width)x\(height))", .debug, "BatchImageProcessor")
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
            logger?("Split image processing: \(image.lastPathComponent) (\(width)x\(height)) -> L:\(leftWidth) R:\(rightWidth)", .debug, "BatchImageProcessor")
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
    
    /// Write commands to pipe
    private func writeCommands(_ commands: [String], to fileHandle: FileHandle) async -> Result<Void, ProcessingError> {
        for command in commands {
            let result = await writeCommand(command, to: fileHandle)
            if case .failure(let error) = result {
                return .failure(error)
            }
        }
        return .success(())
    }
    
    /// Write command to pipe with proper error handling
    private func writeCommand(_ command: String, to fileHandle: FileHandle) async -> Result<Void, ProcessingError> {
        guard let data = (command + "\n").data(using: .utf8) else {
            #if DEBUG
            logger?("Failed to encode command to UTF-8", .debug, "BatchImageProcessor")
            #endif
            return .failure(.commandEncodingFailed)
        }
        
        // Extract buffer pointer synchronously
        let bufferCopy: (UnsafeMutableRawPointer, Int)? = data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return nil
            }
            // Create a copy of the data to use outside the closure
            let copy = UnsafeMutableRawPointer.allocate(
                byteCount: buffer.count,
                alignment: 1
            )
            copy.copyMemory(from: baseAddress, byteCount: buffer.count)
            return (copy, buffer.count)
        }
        
        guard let (bufferPointer, bufferCount) = bufferCopy else {
            #if DEBUG
            logger?("Failed to access data buffer for command write", .debug, "BatchImageProcessor")
            #endif
            return .failure(.commandEncodingFailed)
        }
        
        defer {
            bufferPointer.deallocate()
        }
        
        let fd = fileHandle.fileDescriptor
        var written = 0
        var attempts = 0
        
        while written < bufferCount {
            guard !Task.isCancelled else {
                return .failure(.processingCancelled)
            }
            
            let remaining = bufferCount - written
            let chunkSize = min(remaining, Constants.writeChunkSize)
            let ptr = bufferPointer.advanced(by: written)
            
            let result = write(fd, ptr, chunkSize)
            
            if result > 0 {
                written += result
                attempts = 0
                
                #if DEBUG
                if written == bufferCount {
                    logger?("Command write completed: \(bufferCount) bytes", .debug, "BatchImageProcessor")
                }
                #endif
            } else if result == 0 {
                attempts += 1
                if attempts > 5 {
                    #if DEBUG
                    logger?("Write failed: no progress after 5 attempts", .debug, "BatchImageProcessor")
                    #endif
                    return .failure(.pipeWriteFailed(POSIXError: POSIXError(.EIO)))
                }
                try? await Task.sleep(nanoseconds: 10000000) // 10ms
            } else {
                let err = errno
                switch err {
                case EINTR:
                    #if DEBUG
                    logger?("Write interrupted (EINTR), retrying", .debug, "BatchImageProcessor")
                    #endif
                    continue
                case EAGAIN, EWOULDBLOCK:
                    attempts += 1
                    if attempts > Constants.maxWriteAttempts {
                        #if DEBUG
                        logger?("Write timeout after \(Constants.maxWriteAttempts) attempts", .debug, "BatchImageProcessor")
                        #endif
                        return .failure(.processIOTimeout)
                    }
                    try? await Task.sleep(nanoseconds: 10000000) // 10ms
                case EPIPE:
                    #if DEBUG
                    logger?("Broken pipe detected (EPIPE)", .debug, "BatchImageProcessor")
                    #endif
                    return .failure(.pipeBroken)
                default:
                    #if DEBUG
                    logger?("Write error: errno \(err)", .debug, "BatchImageProcessor")
                    #endif
                    return .failure(.pipeWriteFailed(POSIXError: POSIXError(POSIXError.Code(rawValue: err) ?? .EIO)))
                }
            }
        }
        
        return .success(())
    }
    
    /// Wait for process termination using event-driven approach
    private func waitForProcessTermination(_ process: Process) async {
        guard process.isRunning else { return }
        
        #if DEBUG
        logger?("Waiting for GraphicsMagick process termination", .debug, "BatchImageProcessor")
        #endif
        
        // Bridge callback-based terminationHandler to async/await
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { proc in
                // Resume continuation exactly once and then clear handler to avoid retaining closure/process
                continuation.resume()
                proc.terminationHandler = nil
            }
        }
        
        #if DEBUG
        logger?("GraphicsMagick process terminated", .debug, "BatchImageProcessor")
        #endif
    }
    
    /// Create batch process
    private func createBatchProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gmPath)
        process.arguments = ["batch", "-stop-on-error", "off"]
        
        #if DEBUG
        logger?("Created GM batch process: \(gmPath) batch -stop-on-error off", .debug, "BatchImageProcessor")
        #endif
        
        return process
    }
    
    /// Setup output handlers
    private func setupOutputHandlers(
        outputPipe: Pipe,
        errorPipe: Pipe,
        collector: ProcessOutputCollector
    ) {
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await collector.appendStdout(data) }
        }
        
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await collector.appendStderr(data) }
        }
        
        #if DEBUG
        logger?("Setup GM process output handlers", .debug, "BatchImageProcessor")
        #endif
    }
    
    /// Cleanup process and handlers
    private func cleanupProcess(_ process: Process?, outputPipe: Pipe, errorPipe: Pipe) {
        #if DEBUG
        logger?("Cleaning up GM process and handlers", .debug, "BatchImageProcessor")
        #endif
        
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        
        if let proc = process {
            // Clear termination handler to avoid retaining closure
            proc.terminationHandler = nil
            
            if proc.isRunning {
                terminateProcess(proc)
            }
        }
    }
    
    /// Terminate process
    private func terminateProcess(_ process: Process?) {
        guard let process = process, process.isRunning else { return }
        
        #if DEBUG
        logger?("Terminating GraphicsMagick process", .debug, "BatchImageProcessor")
        #endif
        
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        process.terminate()
    }
    
    /// Analyze duplicate base names
    private func analyzeDuplicateBaseNames(images: [URL]) -> Set<String> {
        var counts: [String: Int] = [:]
        
        for url in images {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            counts[base, default: 0] += 1
        }
        
        return Set(counts.compactMap { $0.value > 1 ? $0.key : nil })
    }
    
    /// Get process error for debugging
    private func getProcessError(outputCollector: ProcessOutputCollector) async -> String? {
        let (_, stderr) = await outputCollector.getOutput()
        if !stderr.isEmpty, let errorString = String(data: stderr, encoding: .utf8) {
            #if DEBUG
            logger?("GraphicsMagick stderr: \(errorString)", .debug, "BatchImageProcessor")
            #endif
            return errorString
        }
        return nil
    }
}
