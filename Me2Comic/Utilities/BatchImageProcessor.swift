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
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            candidate = "\(basePath)-\(timestamp)\(suffix)"
            candidateKey = candidate.lowercased()
        }
        
        reservedPaths.insert(candidateKey)
        return candidate
    }
    
    func reset() {
        reservedPaths.removeAll()
    }
}

// MARK: - Process Output Collector

/// Thread-safe collection of process output
private actor ProcessOutputCollector {
    private var stdout = Data()
    private var stderr = Data()
    
    func appendStdout(_ data: Data) {
        stdout.append(data)
    }
    
    func appendStderr(_ data: Data) {
        stderr.append(data)
    }
    
    func getOutput() -> (stdout: Data, stderr: Data) {
        (stdout, stderr)
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
    
    // MARK: - Constants
    
    private enum Constants {
        static let writeChunkSize = 16 * 1024 // 16KB
        static let maxWriteAttempts = 50
        static let processWaitInterval: UInt64 = 100_000_000 // 0.1s
        static let processTerminationTimeout = 10 // attempts
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
        useGrayColorspace: Bool
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
        
        // Fetch image dimensions
        let dimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: images.map { $0.path },
            asyncCancellationCheck: { !Task.isCancelled }
        )
        
        guard !Task.isCancelled, !dimensions.isEmpty else {
            return (0, images.map { $0.lastPathComponent })
        }
        
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
        let pathManager = PathCollisionManager()
        let outputCollector = ProcessOutputCollector()
        
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
            try process.run()
            
            guard !Task.isCancelled else {
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
            
            // Wait for process completion
            await waitForProcessTermination(process)
            
            // Check exit status
            let exitCode = getProcessExitCode(process)
            
            if let code = exitCode, code != 0, !Task.isCancelled {
                logProcessError(outputCollector: outputCollector)
                return (0, images.map { $0.lastPathComponent })
            }
            
            return result
            
        } catch {
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
        
        for image in images {
            guard !Task.isCancelled else { break }
            
            guard let dims = dimensions[image.path] else {
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
            
            do {
                for command in commands {
                    try await writeCommand(command, to: fileHandle)
                }
                processedCount += 1
            } catch {
                failedFiles.append(image.lastPathComponent)
                break // Stop on write error
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
        // let filename = image.lastPathComponent
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
    
    /// Write command to pipe with proper error handling
    private func writeCommand(_ command: String, to fileHandle: FileHandle) async throws {
        guard let data = (command + "\n").data(using: .utf8) else {
            throw NSError(
                domain: "BatchImageProcessor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode command"]
            )
        }
        
        // Extract buffer pointer synchronously - Fixed return type
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
            throw NSError(
                domain: "BatchImageProcessor",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to access data buffer"]
            )
        }
        
        defer {
            bufferPointer.deallocate()
        }
        
        let fd = fileHandle.fileDescriptor
        var written = 0
        var attempts = 0
        
        while written < bufferCount {
            try Task.checkCancellation()
            
            let remaining = bufferCount - written
            let chunkSize = min(remaining, Constants.writeChunkSize)
            let ptr = bufferPointer.advanced(by: written)
            
            let result = write(fd, ptr, chunkSize)
            
            if result > 0 {
                written += result
                attempts = 0
            } else if result == 0 {
                attempts += 1
                if attempts > 5 {
                    throw POSIXError(.EIO)
                }
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            } else {
                let err = errno
                switch err {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    attempts += 1
                    if attempts > Constants.maxWriteAttempts {
                        throw POSIXError(.EAGAIN)
                    }
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                case EPIPE:
                    throw POSIXError(.EPIPE)
                default:
                    throw POSIXError(POSIXError.Code(rawValue: err) ?? .EIO)
                }
            }
        }
    }
    
    /// Wait for process termination
    private func waitForProcessTermination(_ process: Process) async {
        var attempts = 0
        
        while process.isRunning, attempts < Constants.processTerminationTimeout * 10 {
            if Task.isCancelled {
                terminateProcess(process)
                break
            }
            
            do {
                try await Task.sleep(nanoseconds: Constants.processWaitInterval)
                attempts += 1
            } catch {
                terminateProcess(process)
                break
            }
        }
    }
    
    /// Safely get process exit code
    private func getProcessExitCode(_ process: Process) -> Int32? {
        guard !process.isRunning else { return nil }
        return process.terminationStatus
    }
    
    /// Create batch process
    private func createBatchProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gmPath)
        process.arguments = ["batch", "-stop-on-error", "off"]
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
    }
    
    /// Cleanup process and handlers
    private func cleanupProcess(_ process: Process?, outputPipe: Pipe, errorPipe: Pipe) {
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        
        if let process = process, process.isRunning {
            terminateProcess(process)
        }
    }
    
    /// Terminate process
    private func terminateProcess(_ process: Process?) {
        guard let process = process, process.isRunning else { return }
        
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
    
    /// Log process error for debugging
    private func logProcessError(outputCollector: ProcessOutputCollector) {
        #if DEBUG
        Task {
            let (_, stderr) = await outputCollector.getOutput()
            if !stderr.isEmpty, let errorString = String(data: stderr, encoding: .utf8) {
                print("BatchImageProcessor: Process error: \(errorString)")
            }
        }
        #endif
    }
}
