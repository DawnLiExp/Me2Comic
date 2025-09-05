//
//  GMProcessExecutor.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

import Darwin
import Foundation

/// Manages GraphicsMagick process execution and lifecycle
struct GMProcessExecutor {
    // MARK: - Properties
    
    private let gmPath: String
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    // MARK: - Constants
    
    private enum Constants {
        static let writeChunkSize = 16 * 1024 // 16KB
        static let maxWriteAttempts = 50
    }
    
    // MARK: - Initialization
    
    init(
        gmPath: String,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) {
        self.gmPath = gmPath
        self.logger = logger
    }
    
    // MARK: - Public Methods
    
    /// Execute GraphicsMagick batch process with commands
    /// - Parameters:
    ///   - commands: Commands to execute
    ///   - commandGenerator: Async closure that generates and writes commands
    /// - Returns: Result indicating success or collected output
    func executeBatch(
        commandGenerator: @escaping (FileHandle) async -> Result<Void, ProcessingError>
    ) async -> Result<(stdout: Data, stderr: Data), ProcessingError> {
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
            await performExecution(
                process: process,
                inputPipe: inputPipe,
                outputCollector: outputCollector,
                commandGenerator: commandGenerator
            )
        } onCancel: {
            terminateProcess(process)
        }
    }
    
    /// Write single command to file handle
    func writeCommand(_ command: String, to fileHandle: FileHandle) async -> Result<Void, ProcessingError> {
        guard let data = (command + "\n").data(using: .utf8) else {
            #if DEBUG
            logger?("Failed to encode command to UTF-8", .debug, "GMProcessExecutor")
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
            logger?("Failed to access data buffer for command write", .debug, "GMProcessExecutor")
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
                    logger?("Command write completed: \(bufferCount) bytes", .debug, "GMProcessExecutor")
                }
                #endif
            } else if result == 0 {
                attempts += 1
                if attempts > 5 {
                    #if DEBUG
                    logger?("Write failed: no progress after 5 attempts", .debug, "GMProcessExecutor")
                    #endif
                    return .failure(.pipeWriteFailed(POSIXError: POSIXError(.EIO)))
                }
                try? await Task.sleep(nanoseconds: 10000000) // 10ms
            } else {
                let err = errno
                switch err {
                case EINTR:
                    #if DEBUG
                    logger?("Write interrupted (EINTR), retrying", .debug, "GMProcessExecutor")
                    #endif
                    continue
                case EAGAIN, EWOULDBLOCK:
                    attempts += 1
                    if attempts > Constants.maxWriteAttempts {
                        #if DEBUG
                        logger?("Write timeout after \(Constants.maxWriteAttempts) attempts", .debug, "GMProcessExecutor")
                        #endif
                        return .failure(.processIOTimeout)
                    }
                    try? await Task.sleep(nanoseconds: 10000000) // 10ms
                case EPIPE:
                    #if DEBUG
                    logger?("Broken pipe detected (EPIPE)", .debug, "GMProcessExecutor")
                    #endif
                    return .failure(.pipeBroken)
                default:
                    #if DEBUG
                    logger?("Write error: errno \(err)", .debug, "GMProcessExecutor")
                    #endif
                    return .failure(.pipeWriteFailed(POSIXError: POSIXError(POSIXError.Code(rawValue: err) ?? .EIO)))
                }
            }
        }
        
        return .success(())
    }
    
    // MARK: - Private Methods
    
    /// Perform the actual execution
    private func performExecution(
        process: Process,
        inputPipe: Pipe,
        outputCollector: ProcessOutputCollector,
        commandGenerator: @escaping (FileHandle) async -> Result<Void, ProcessingError>
    ) async -> Result<(stdout: Data, stderr: Data), ProcessingError> {
        do {
            #if DEBUG
            logger?("Starting GraphicsMagick batch process", .debug, "GMProcessExecutor")
            #endif
            
            try process.run()
            
            guard !Task.isCancelled else {
                #if DEBUG
                logger?("Processing cancelled, terminating GM process", .debug, "GMProcessExecutor")
                #endif
                terminateProcess(process)
                return .failure(.processingCancelled)
            }
            
            let writeHandle = inputPipe.fileHandleForWriting
            defer { try? writeHandle.close() }
            
            // Generate and write commands
            let writeResult = await commandGenerator(writeHandle)
            
            // Close input to signal completion
            try? writeHandle.close()
            
            if case .failure(let error) = writeResult {
                terminateProcess(process)
                return .failure(error)
            }
            
            #if DEBUG
            logger?("Commands written, waiting for process completion", .debug, "GMProcessExecutor")
            #endif
            
            // Wait for process completion
            await waitForProcessTermination(process)
            
            // Process is guaranteed to be terminated, safe to read exit code
            let exitCode = process.terminationStatus
            
            #if DEBUG
            logger?("GraphicsMagick process completed with exit code: \(exitCode)", .debug, "GMProcessExecutor")
            #endif
            
            let output = await outputCollector.getOutput()
            
            if exitCode != 0, !Task.isCancelled {
                let stderrString = String(data: output.stderr, encoding: .utf8)
                let error = ProcessingError.graphicsMagickExecutionFailed(
                    exitCode: exitCode,
                    stderr: stderrString
                )
                logger?(error.localizedDescription, .error, "GMProcessExecutor")
                return .failure(error)
            }
            
            return .success(output)
            
        } catch {
            #if DEBUG
            logger?("GMProcessExecutor execution error: \(error.localizedDescription)", .debug, "GMProcessExecutor")
            #endif
            return .failure(.graphicsMagickExecutionFailed(exitCode: -1, stderr: error.localizedDescription))
        }
    }
    
    /// Create GraphicsMagick batch process
    private func createBatchProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gmPath)
        process.arguments = ["batch", "-stop-on-error", "off"]
        
        #if DEBUG
        logger?("Created GM batch process: \(gmPath) batch -stop-on-error off", .debug, "GMProcessExecutor")
        #endif
        
        return process
    }
    
    /// Setup output handlers for process
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
        logger?("Setup GM process output handlers", .debug, "GMProcessExecutor")
        #endif
    }
    
    /// Wait for process termination using event-driven approach
    private func waitForProcessTermination(_ process: Process) async {
        guard process.isRunning else { return }
        
        #if DEBUG
        logger?("Waiting for GraphicsMagick process termination", .debug, "GMProcessExecutor")
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
        logger?("GraphicsMagick process terminated", .debug, "GMProcessExecutor")
        #endif
    }
    
    /// Cleanup process and handlers
    private func cleanupProcess(_ process: Process?, outputPipe: Pipe, errorPipe: Pipe) {
        #if DEBUG
        logger?("Cleaning up GM process and handlers", .debug, "GMProcessExecutor")
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
        logger?("Terminating GraphicsMagick process", .debug, "GMProcessExecutor")
        #endif
        
        (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        process.terminate()
    }
}
