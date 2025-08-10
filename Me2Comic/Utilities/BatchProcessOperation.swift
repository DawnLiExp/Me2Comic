//
//  BatchProcessOperation.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

import Darwin
import Foundation

class BatchProcessOperation: Operation, @unchecked Sendable {
    // MARK: - Input Parameters

    private let batchImages: [URL]
    private let outputDir: URL
    private let widthThreshold: Int
    private let resizeHeight: Int
    private let quality: Int
    private let unsharpRadius: Float
    private let unsharpSigma: Float
    private let unsharpAmount: Float
    private let unsharpThreshold: Float
    private let useGrayColorspace: Bool
    private let gmPath: String

    // MARK: - Output Callbacks

    var onCompleted: ((_ processedCount: Int, _ failedFiles: [String]) -> Void)?

    // MARK: - Internal State

    private var internalProcess: Process?
    private let processLock = NSLock()

    // MARK: - Initialization

    init(
        images: [URL],
        outputDir: URL,
        widthThreshold: Int,
        resizeHeight: Int,
        quality: Int,
        unsharpRadius: Float,
        unsharpSigma: Float,
        unsharpAmount: Float,
        unsharpThreshold: Float,
        useGrayColorspace: Bool,
        gmPath: String
    ) {
        self.batchImages = images
        self.outputDir = outputDir
        self.widthThreshold = widthThreshold
        self.resizeHeight = resizeHeight
        self.quality = quality
        self.unsharpRadius = unsharpRadius
        self.unsharpSigma = unsharpSigma
        self.unsharpAmount = unsharpAmount
        self.unsharpThreshold = unsharpThreshold
        self.useGrayColorspace = useGrayColorspace
        self.gmPath = gmPath
        super.init()
    }

    // MARK: - Core Execution Method

    override func main() {
        guard !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: Operation cancelled before starting.")
            #endif
            return
        }

        var processedCount = 0
        var failedFiles: [String] = []

        // Ensure onCompleted is called if not cancelled
        defer {
            if !isCancelled {
                onCompleted?(processedCount, failedFiles)
            }
        }

        guard !batchImages.isEmpty else {
            return
        }

        // Pass a closure to ImageIOHelper to check for cancellation.
        let batchDimensions = ImageIOHelper.getBatchImageDimensions(
            imagePaths: batchImages.map { $0.path },
            shouldContinue: { [weak self] in
                // Check if the operation itself has been cancelled
                self?.isCancelled == false
            }
        )

        // Return early if cancelled during ImageIO dimension fetching
        guard !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: Operation cancelled during ImageIO dimension fetching.")
            #endif
            return
        }

        if batchDimensions.isEmpty {
            // If no dimensions could be retrieved (e.g., all files invalid or cancelled early)
            // Report all original batch images as failed if not cancelled, otherwise just return.
            if !isCancelled {
                onCompleted?(0, batchImages.map { $0.lastPathComponent })
            }
            return
        }

        let batchTask = Process()
        batchTask.executableURL = URL(fileURLWithPath: gmPath)
        batchTask.arguments = ["batch", "-stop-on-error", "off"]

        let pipes = (input: Pipe(), output: Pipe(), error: Pipe())
        batchTask.standardInput = pipes.input
        batchTask.standardOutput = pipes.output
        batchTask.standardError = pipes.error

        // Store process reference
        processLock.lock()
        internalProcess = batchTask
        processLock.unlock()

        guard !isCancelled else {
            // Return if cancelled after process setup but before run
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
            pipes.input.fileHandleForWriting.closeFile()
            return
        }

        do {
            try batchTask.run()

            guard !isCancelled else {
                // Return if cancelled immediately after run()
                processLock.lock()
                internalProcess?.terminate()
                // Ensure pipe write end is closed as fallback
                (batchTask.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
                internalProcess = nil
                processLock.unlock()
                return
            }

            // Stream commands directly to the pipe
            let pipeFileHandle = pipes.input.fileHandleForWriting
            defer { try? pipeFileHandle.close() }

            // Thread-safe tracking for generated output paths to prevent collisions.
            var generatedPaths = Set<String>()
            let pathLock = NSLock()

            for imageFile in batchImages {
                autoreleasepool {
                    guard !isCancelled else { return } // Check cancellation before processing each image

                    let filename = imageFile.lastPathComponent
                    let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent

                    // Determine the original subdirectory name for the image
                    let originalSubdirName = imageFile.deletingLastPathComponent().lastPathComponent

                    // Decide final output directory: avoid duplicate subdir when outputDir already ends with it
                    let finalOutputDirForImage: URL
                    if self.outputDir.lastPathComponent == originalSubdirName {
                        // Already in the correct subdirectory (Isolated case)
                        finalOutputDirForImage = self.outputDir
                    } else {
                        // Append subdirectory for GlobalBatch case
                        finalOutputDirForImage = self.outputDir.appendingPathComponent(originalSubdirName)
                    }

                    let outputBasePath = finalOutputDirForImage
                        .appendingPathComponent(filenameWithoutExt)
                        .path

                    // Get dimensions from batch
                    guard let dimensions = batchDimensions[imageFile.path] else {
                        #if DEBUG
                        print("BatchProcessOperation: Could not get dimensions for \(filename) from batchDimensions.")
                        #endif
                        failedFiles.append(filename)
                        return
                    }

                    let (width, height) = dimensions

                    var commandsForImage: [String] = []

                    if width < widthThreshold {
                        // Single image processing
                        let singleOutputPath = resolveOutputPath(basePath: outputBasePath, suffix: ".jpg", generatedPaths: &generatedPaths, lock: pathLock)
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

                        let rightOutputPath = resolveOutputPath(basePath: outputBasePath, suffix: "-1.jpg", generatedPaths: &generatedPaths, lock: pathLock)
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

                        let leftOutputPath = resolveOutputPath(basePath: outputBasePath, suffix: "-2.jpg", generatedPaths: &generatedPaths, lock: pathLock)
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

                    // Write commands for the current image to the pipe
                    for command in commandsForImage {
                        if let data = (command + "\n").data(using: .utf8) {
                            do {
                                try safeWrite(data: data, to: pipeFileHandle)
                            } catch {
                                // Handle error during write, e.g., pipe closed due to cancellation
                                #if DEBUG
                                print("BatchProcessOperation: Error writing command to pipe: \(error.localizedDescription)")
                                #endif
                                // If an error occurs during writing, it's likely the pipe is broken or the process terminated.
                                // We should stop trying to write and let the main catch block handle the overall process termination.
                                return // Exit autoreleasepool and outer loop
                            }
                        }
                    }
                    processedCount += 1
                }
            }

            // Close the write end of the pipe to signal EOF to the child process
            pipeFileHandle.closeFile()

            batchTask.waitUntilExit()

            processLock.lock()
            internalProcess = nil
            processLock.unlock()

            if batchTask.terminationStatus != 0 {
                // Append failed files if not cancelled
                if !isCancelled {
                    failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                    processedCount = 0
                }
            }
        } catch {
            if let posixError = error as? POSIXError, posixError.code == .EPIPE {
                // Broken pipe is expected during cancellation or if the child process exits early
                #if DEBUG
                print("BatchProcessOperation: Broken pipe during write (expected during cancellation or early exit): \(posixError.localizedDescription)")
                #endif
            } else {
                #if DEBUG
                print("BatchProcessOperation: Error during process execution: \(error.localizedDescription)")
                #endif
            }
            // Append failed files if not cancelled
            if !isCancelled {
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
        }
    }

    // MARK: - Path Collision Resolution

    /// Generates a unique output path by appending a suffix if a collision is detected.
    private func resolveOutputPath(basePath: String, suffix: String, generatedPaths: inout Set<String>, lock: NSLock) -> String {
        lock.lock()
        defer { lock.unlock() }

        var finalPath = basePath + suffix
        var attempt = 0
        let maxAttempts = 26 // a-z

        while generatedPaths.contains(finalPath.lowercased()) {
            attempt += 1
            if attempt > maxAttempts {
                // Fallback to a timestamp if letter suffixes are exhausted
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                finalPath = "\(basePath)-\(timestamp)\(suffix)"
                break
            }
            // Append -a, -b, ...
            let letter = String(UnicodeScalar(UInt8(ascii: "a") + UInt8(attempt - 1)))
            finalPath = "\(basePath)-\(letter)\(suffix)"
        }

        generatedPaths.insert(finalPath.lowercased())
        return finalPath
    }

    // MARK: - Safe Write Implementation

    /// Writes data to file handle in chunks with cancellation checks
    private func safeWrite(data: Data, to fileHandle: FileHandle) throws {
        let chunkSize = 4096
        var bytesRemaining = data.count
        var currentOffset = 0

        while bytesRemaining > 0 {
            guard !isCancelled else {
                #if DEBUG
                print("BatchProcessOperation: safeWrite cancelled.")
                #endif
                return
            }

            let chunkLength = min(chunkSize, bytesRemaining)
            let chunk = data.subdata(in: currentOffset ..< (currentOffset + chunkLength))

            var bytesWrittenForChunk = 0
            var writeAttempts = 0
            let maxWriteAttempts = 5 // Limit retries to prevent infinite loops

            while bytesWrittenForChunk < chunkLength, writeAttempts < maxWriteAttempts {
                writeAttempts += 1
                do {
                    try chunk.withUnsafeBytes { ptr in
                        guard !isCancelled else {
                            #if DEBUG
                            print("BatchProcessOperation: safeWrite inner loop cancelled.")
                            #endif
                            return
                        }

                        let result = write(fileHandle.fileDescriptor,
                                           ptr.baseAddress!.advanced(by: bytesWrittenForChunk),
                                           chunkLength - bytesWrittenForChunk)

                        if result == -1 {
                            let currentErrno = errno
                            if currentErrno == EPIPE {
                                #if DEBUG
                                print("BatchProcessOperation: safeWrite encountered EPIPE (pipe closed), stopping write.")
                                #endif
                                throw POSIXError(.EPIPE)
                            } else if currentErrno == EINTR {
                                #if DEBUG
                                print("BatchProcessOperation: safeWrite encountered EINTR, retrying write.")
                                #endif
                                // EINTR: Interrupted system call. Retry the write operation.
                                // Do not increment bytesWrittenForChunk as no bytes were successfully written.
                            } else {
                                throw NSError(domain: NSPOSIXErrorDomain,
                                              code: Int(currentErrno),
                                              userInfo: nil)
                            }
                        } else {
                            bytesWrittenForChunk += result
                        }
                    }
                } catch let error as POSIXError where error.code == .EPIPE {
                    #if DEBUG
                    print("BatchProcessOperation: safeWrite caught EPIPE, stopping write.")
                    #endif
                    return
                } catch {
                    throw error
                }
            }

            if bytesWrittenForChunk == 0, chunkLength > 0, writeAttempts >= maxWriteAttempts {
                // If no bytes were written after max attempts, indicate a write failure.
                throw NSError(domain: "BatchProcessOperationErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write data to pipe after multiple retries."])
            }

            currentOffset += bytesWrittenForChunk
            bytesRemaining -= bytesWrittenForChunk
        }
    }

    // MARK: - Cancellation Mechanism

    override func cancel() {
        super.cancel()

        processLock.lock()
        if let process = internalProcess, process.isRunning {
            process.terminate()
            // Immediately close pipe's write end to unblock safeWrite and terminate the child process
            (process.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
        }
        internalProcess = nil
        processLock.unlock()
    }

    deinit {
        #if DEBUG
        print("BatchProcessOperation deinitialized.")
        #endif
    }
}
