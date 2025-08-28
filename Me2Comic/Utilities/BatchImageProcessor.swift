//
//  BatchImageProcessor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

import Darwin
import Foundation

// MARK: - Path Collision Manager

/// Actor for thread-safe output path management
private actor PathCollisionManager {
    private var generatedPaths: Set<String> = []
    
    /// Generates a unique output path by appending a numeric suffix if a collision is detected.
    /// - Parameters:
    ///   - basePath: path without extension or trailing part (e.g. /out/dir/cut01_jpg)
    ///   - suffix: desired suffix including leading dash if any and extension (e.g. ".jpg" or "-1.jpg")
    /// - Returns: unique path guaranteed not to collide with previously generated paths
    func resolveOutputPath(basePath: String, suffix: String) -> String {
        // initial candidate
        var candidate = basePath + suffix
        // lowercased key for case-insensitive comparison
        var candidateKey = candidate.lowercased()
        
        // If candidate conflicts with already-reserved path,
        // iterate numeric suffixes until a free name is found.
        var attempt = 0
        let maxAttempts = 9999
        
        while generatedPaths.contains(candidateKey) {
            attempt += 1
            if attempt <= maxAttempts {
                // produce deterministic numeric candidate: basePath + "-" + attempt + suffix
                // example:
                //  basePath = /out/cut01_jpg, suffix = "-1.jpg"
                //  attempt=1 -> /out/cut01_jpg-1-1.jpg
                // This keeps the original "-1"/"-2" semantic (if any) and appends a numeric discriminator.
                candidate = "\(basePath)-\(attempt)\(suffix)"
                candidateKey = candidate.lowercased()
            } else {
                // fallback to timestamp to avoid infinite loop
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                candidate = "\(basePath)-\(timestamp)\(suffix)"
                candidateKey = candidate.lowercased()
                break
            }
        }
        
        // reserve this candidate
        generatedPaths.insert(candidateKey)
        return candidate
    }
    
    func reset() {
        generatedPaths.removeAll()
    }
}

// MARK: - Data Collector

/// Actor for thread-safe collection of stdout and stderr data
private actor DataCollector {
    private var stdoutData: Data = .init()
    private var stderrData: Data = .init()
    
    func appendStdout(_ data: Data) {
        stdoutData.append(data)
    }
    
    func appendStderr(_ data: Data) {
        stderrData.append(data)
    }
    
    func getStdout() -> Data {
        return stdoutData
    }
    
    func getStderr() -> Data {
        return stderrData
    }
}

// MARK: - Batch Image Processor

/// Handles batch image processing with GraphicsMagick
struct BatchImageProcessor {
    private let gmPath: String
    private let widthThreshold: Int
    private let resizeHeight: Int
    private let quality: Int
    private let unsharpRadius: Float
    private let unsharpSigma: Float
    private let unsharpAmount: Float
    private let unsharpThreshold: Float
    private let useGrayColorspace: Bool
    
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
    
    // MARK: - Main Processing Method
    
    /// Process a batch of images
    /// - Parameters:
    ///   - images: Array of image URLs to process
    ///   - outputDir: Output directory for processed images
    /// - Returns: Tuple of (processed count, failed files)
    func processBatch(images: [URL], outputDir: URL) async -> (processed: Int, failed: [String]) {
        guard !images.isEmpty else { return (0, []) }
        guard !Task.isCancelled else {
            #if DEBUG
            print("BatchImageProcessor: Task cancelled before starting.")
            #endif
            return (0, [])
        }
        
        // Get image dimensions with cancellation support
        let batchDimensions = await ImageIOHelper.getBatchImageDimensionsAsync(
            imagePaths: images.map { $0.path },
            asyncCancellationCheck: { !Task.isCancelled }
        )
        
        guard !Task.isCancelled else {
            #if DEBUG
            print("BatchImageProcessor: Task cancelled during ImageIO dimension fetching.")
            #endif
            return (0, [])
        }
        
        guard !batchDimensions.isEmpty else {
            // nothing valid to process
            return (0, images.map { $0.lastPathComponent })
        }
        
        // Process batch with proper cancellation handling
        return await withTaskCancellationHandler {
            await executeBatchProcess(
                images: images,
                batchDimensions: batchDimensions,
                outputDir: outputDir
            )
        } onCancel: {
            // This handler is called synchronously when task is cancelled
            // We'll handle process termination inside executeBatchProcess
            #if DEBUG
            print("BatchImageProcessor: Task cancellation requested")
            #endif
        }
    }
    
    // MARK: - Private Processing Implementation
    
    /// Execute the batch process with GraphicsMagick
    private func executeBatchProcess(
        images: [URL],
        batchDimensions: [String: (width: Int, height: Int)],
        outputDir: URL
    ) async -> (processed: Int, failed: [String]) {
        let pathCollisionManager = PathCollisionManager()
        let dataCollector = DataCollector() // use actor
        var processedCount = 0
        var failedFiles: [String] = []
        
        // Create process
        let batchTask = Process()
        batchTask.executableURL = URL(fileURLWithPath: gmPath)
        batchTask.arguments = ["batch", "-stop-on-error", "off"]
        
        // Setup pipes
        let pipes = (input: Pipe(), output: Pipe(), error: Pipe())
        batchTask.standardInput = pipes.input
        batchTask.standardOutput = pipes.output
        batchTask.standardError = pipes.error
        
        // Set up readability handlers
        let stdoutHandle = pipes.output.fileHandleForReading
        let stderrHandle = pipes.error.fileHandleForReading
        
        stdoutHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                Task { await dataCollector.appendStdout(d) }
            }
        }
        stderrHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty {
                Task { await dataCollector.appendStderr(d) }
            }
        }
        
        defer {
            // Clean up handlers
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }
        
        // Start process with cancellation handler
        return await withTaskCancellationHandler {
            do {
                try batchTask.run()
                
                guard !Task.isCancelled else {
                    terminateProcess(batchTask)
                    return (0, [])
                }
                
                let pipeFileHandle = pipes.input.fileHandleForWriting
                defer {
                    // ensure we always close write end
                    try? pipeFileHandle.close()
                }
                
                // Generate and write commands
                let result = await generateAndWriteCommands(
                    images: images,
                    batchDimensions: batchDimensions,
                    outputDir: outputDir,
                    pathCollisionManager: pathCollisionManager,
                    pipeFileHandle: pipeFileHandle
                )
                
                processedCount = result.processed
                failedFiles = result.failed
                
                // Close pipe to signal EOF
                try? pipeFileHandle.close()
                
                // Wait for process to exit (this function already uses Task-aware polling)
                await waitForProcessCompletion(batchTask)
                
                // --- Safely obtain terminationStatus: only read it if process is confirmed not running.
                // There is a race: cancellation handler may have called terminate() but process
                // can still be in the process of exiting. Accessing terminationStatus while the task
                // is still running triggers an Objective-C exception. So we only read it when
                // process.isRunning == false, otherwise we try to wait a short bounded time; if
                // still running, we avoid reading terminationStatus.
                var exitCode: Int32?
                if !batchTask.isRunning {
                    // safe to read
                    exitCode = batchTask.terminationStatus
                } else {
                    // Try bounded polling (total ~1s) for the process to actually exit
                    var attempts = 0
                    while batchTask.isRunning, attempts < 10 {
                        // If task was cancelled, ensure we let terminateProcess do its work.
                        // Sleep briefly (100ms) between checks to avoid busy-looping.
                        do {
                            try await Task.sleep(nanoseconds: 100000000) // 0.1s
                        } catch {
                            // Task.sleep can throw on cancellation — break out to avoid blocking.
                            break
                        }
                        attempts += 1
                    }
                    if !batchTask.isRunning {
                        exitCode = batchTask.terminationStatus
                    } else {
                        // Still running after bounded wait -> avoid calling terminationStatus to prevent exception.
                        exitCode = nil
                    }
                }
                
                // If we have a real exit code and it's non-zero, and the current Task is not cancelled,
                // treat it as failure for remaining items (keep original behavior).
                if let code = exitCode, code != 0, !Task.isCancelled {
                    #if DEBUG
                    let stderrData = await dataCollector.getStderr()
                    if !stderrData.isEmpty, let s = String(data: stderrData, encoding: .utf8) {
                        print("BatchImageProcessor: gm stderr: \(s)")
                    }
                    #endif
                    // Conservative approach: mark any remaining unmarked images as failed
                    let remaining = images.map { $0.lastPathComponent }.filter { !failedFiles.contains($0) }
                    failedFiles.append(contentsOf: remaining)
                    processedCount = 0
                }
                
                return (processedCount, failedFiles)
                
            } catch {
                #if DEBUG
                print("BatchImageProcessor: Error during process execution: \(error.localizedDescription)")
                #endif
                if !Task.isCancelled {
                    failedFiles = images.map { $0.lastPathComponent }
                }
                return (0, failedFiles)
            }
        } onCancel: {
            // Critical: Immediately terminate process on cancellation
            terminateProcess(batchTask)
        }
    }
    
    /// Generate commands and write them to the pipe
    private func generateAndWriteCommands(
        images: [URL],
        batchDimensions: [String: (width: Int, height: Int)],
        outputDir: URL,
        pathCollisionManager: PathCollisionManager,
        pipeFileHandle: FileHandle
    ) async -> (processed: Int, failed: [String]) {
        var processedCount = 0
        var failedFiles: [String] = []
        
        // Light-weight pre-scan for duplicate base names (within this batch)
        var baseNameCounts: [String: Int] = [:]
        for url in images {
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            baseNameCounts[base, default: 0] += 1
        }
        let duplicateBaseNames = Set(baseNameCounts.compactMap { $0.value > 1 ? $0.key : nil })
        
        for imageFile in images {
            guard !Task.isCancelled else { break }
            
            let filename = imageFile.lastPathComponent
            let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent
            let srcExt = imageFile.pathExtension.lowercased() // Original extension in lowercase
            let originalSubdirName = imageFile.deletingLastPathComponent().lastPathComponent
            
            let finalOutputDirForImage: URL
            if outputDir.lastPathComponent == originalSubdirName {
                finalOutputDirForImage = outputDir
            } else {
                finalOutputDirForImage = outputDir.appendingPathComponent(originalSubdirName)
            }
            
            // Appends source extension to base name to avoid filename collisions
            // E.g., cut01.jpg -> cut01_jpg; cut01.png -> cut01_png
            let useSafeBase = duplicateBaseNames.contains(filenameWithoutExt.lowercased())
            let baseNameForOutput = useSafeBase ? "\(filenameWithoutExt)_\(srcExt)" : filenameWithoutExt
            let outputBasePath = finalOutputDirForImage.appendingPathComponent(baseNameForOutput).path
            
            guard let dimensions = batchDimensions[imageFile.path] else {
                #if DEBUG
                print("BatchImageProcessor: Could not get dimensions for \(filename) from batchDimensions.")
                #endif
                failedFiles.append(filename)
                continue
            }
            
            let (width, height) = dimensions
            var commandsForImage: [String] = []
            
            if width < widthThreshold {
                // Single image processing
                let singleOutputPath = await pathCollisionManager.resolveOutputPath(
                    basePath: outputBasePath,
                    suffix: ".jpg"
                )
                let command = GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: singleOutputPath,
                    cropParams: nil,
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                )
                commandsForImage.append(command)
            } else {
                // Split processing
                let cropWidth = (width + 1) / 2
                let rightCropWidth = width - cropWidth
                
                let rightOutputPath = await pathCollisionManager.resolveOutputPath(
                    basePath: outputBasePath,
                    suffix: "-1.jpg"
                )
                // Right half
                commandsForImage.append(GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: rightOutputPath,
                    cropParams: "\(rightCropWidth)x\(height)+\(cropWidth)+0",
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                ))
                
                let leftOutputPath = await pathCollisionManager.resolveOutputPath(
                    basePath: outputBasePath,
                    suffix: "-2.jpg"
                )
                // Left half
                commandsForImage.append(GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: leftOutputPath,
                    cropParams: "\(cropWidth)x\(height)+0+0",
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                ))
            }
            
            // Write commands
            for command in commandsForImage {
                guard let data = (command + "\n").data(using: .utf8) else { continue }
                
                do {
                    try await safeAsyncWrite(data: data, to: pipeFileHandle)
                } catch {
                    #if DEBUG
                    print("BatchImageProcessor: Error writing command to pipe: \(error.localizedDescription)")
                    #endif
                    failedFiles.append(filename)
                    return (processedCount, failedFiles) // Stop on write error
                }
            }
            
            processedCount += 1
        }
        
        return (processedCount, failedFiles)
    }
    
    // MARK: - Helper Methods
    
    /// Safe async write with proper error handling
    private func safeAsyncWrite(data: Data, to fileHandle: FileHandle) async throws {
        let fd = fileHandle.fileDescriptor
        var bytesRemaining = data.count
        var offset = 0
        
        // reasonable chunk size to avoid huge single write (16KB)
        let chunkSize = 16 * 1024

        var bytePtr: UnsafePointer<UInt8>!
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw NSError(domain: "BatchImageProcessorErrorDomain", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Failed to access data buffer."])
            }
            // bind to UInt8 for pointer arithmetic compatible with write()
            bytePtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        }
        
        // 确保 bytePtr 已赋值
        guard bytePtr != nil else {
            throw NSError(domain: "BatchImageProcessorErrorDomain", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to initialize bytePtr."])
        }
        
        // 异步写逻辑
        while bytesRemaining > 0 {
            try Task.checkCancellation()
            
            let thisChunk = min(bytesRemaining, chunkSize)
            var attemptsForChunk = 0
            
            // pointer to current offset
            let currentPtr = bytePtr.advanced(by: offset)
            
            while true {
                // Attempt write
                let written = write(fd, currentPtr, thisChunk)
                if written > 0 {
                    // progress made
                    offset += written
                    bytesRemaining -= written
                    break
                } else if written == 0 {
                    // no progress, try a few times
                    attemptsForChunk += 1
                    if attemptsForChunk > 5 {
                        throw NSError(domain: "BatchImageProcessorErrorDomain", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "No progress writing to pipe."])
                    }
                    // slight pause to avoid busy loop
                    try await Task.sleep(nanoseconds: 10000000) // 0.01 seconds
                    continue
                } else {
                    let currentErrno = errno
                    if currentErrno == EINTR {
                        // interrupted, retry immediately
                        continue
                    } else if currentErrno == EAGAIN || currentErrno == EWOULDBLOCK {
                        // would block - retry briefly
                        attemptsForChunk += 1
                        if attemptsForChunk > 50 {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(currentErrno),
                                          userInfo: [NSLocalizedDescriptionKey: "Write would block repeatedly."])
                        }
                        try await Task.sleep(nanoseconds: 10000000) // 0.01 seconds
                        continue
                    } else if currentErrno == EPIPE {
                        // Broken pipe – child closed
                        #if DEBUG
                        print("BatchImageProcessor: safeAsyncWrite encountered EPIPE.")
                        #endif
                        throw POSIXError(.EPIPE)
                    } else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(currentErrno), userInfo: nil)
                    }
                }
            }
        }
    }
    
    /// Wait for process to complete (compatible with Swift structured concurrency)
    private func waitForProcessCompletion(_ process: Process) async {
        while process.isRunning {
            if Task.isCancelled {
                if process.isRunning {
                    terminateProcess(process)
                }
                break
            }
            do {
                try await Task.sleep(nanoseconds: 100000000) // 0.1s
            } catch {
                if process.isRunning {
                    terminateProcess(process)
                }
                break
            }
        }

        do {
            try await Task.sleep(nanoseconds: 50000000) // 0.05s
        } catch {}
    }
    
    /// Terminate process and close pipes
    private func terminateProcess(_ process: Process?) {
        guard let process = process else { return }
        
        if process.isRunning {
            // Close the input pipe first to prevent further writes
            (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
            
            // Then terminate the process
            process.terminate()
            
            #if DEBUG
            print("BatchImageProcessor: Process terminated")
            #endif
        }
    }
}
