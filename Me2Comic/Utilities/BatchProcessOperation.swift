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

    private let batchImages: [URL] /// An array of `URL`s representing the image files to be processed in this batch.
    private let outputDir: URL
    private let widthThreshold: Int /// Width threshold for splitting images
    private let resizeHeight: Int /// Target height for resizing
    private let quality: Int /// Output quality (1-100)
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
        // Configure to ignore SIGPIPE signals to prevent crashes on broken pipes
        var oldSigpipeHandler = sigaction()
        var newSigpipeHandler = sigaction()
        newSigpipeHandler.__sigaction_u.__sa_handler = SIG_IGN
        _ = sigaction(SIGPIPE, &newSigpipeHandler, &oldSigpipeHandler)

        defer {
            // Restore original SIGPIPE handler when main() exits
            _ = sigaction(SIGPIPE, &oldSigpipeHandler, nil)
        }

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

        // Use a DispatchGroup to track completion of all dimension fetching and command building tasks
        let dimensionAndCommandGroup = DispatchGroup()
        let batchCommandsLock = NSLock() // Protects batchCommands
        var batchCommands = ""

        // Use a dedicated queue for command building to avoid blocking dimension fetching
        let commandBuildingQueue = DispatchQueue(label: "me2.comic.me2comic.commandBuildingQueue", qos: .userInitiated)

        for imageFile in batchImages {
            dimensionAndCommandGroup.enter()
            // Perform dimension fetching on a background queue (ImageIOHelper already uses concurrentPerform)
            DispatchQueue.global(qos: .userInitiated).async {
                guard !self.isCancelled else {
                    dimensionAndCommandGroup.leave()
                    return
                }

                let path = imageFile.path
                if let dimensions = ImageIOHelper.getImageDimensions(imagePath: path) { // Use single image dimension fetch
                    commandBuildingQueue.async { // Build command on a serial queue
                        guard !self.isCancelled else {
                            dimensionAndCommandGroup.leave()
                            return
                        }
                        autoreleasepool {
                            let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent

                            let originalSubdirName = imageFile.deletingLastPathComponent().lastPathComponent

                            let finalOutputDirForImage: URL
                            if self.outputDir.lastPathComponent == originalSubdirName {
                                finalOutputDirForImage = self.outputDir
                            } else {
                                finalOutputDirForImage = self.outputDir.appendingPathComponent(originalSubdirName)
                            }

                            let outputBasePath = finalOutputDirForImage
                                .appendingPathComponent(filenameWithoutExt)
                                .path

                            let (width, height) = dimensions
                            var command: String

                            if width < self.widthThreshold {
                                // Single image processing
                                command = GraphicsMagickHelper.buildConvertCommand(
                                    inputPath: imageFile.path,
                                    outputPath: "\(outputBasePath).jpg",
                                    cropParams: nil,
                                    resizeHeight: self.resizeHeight,
                                    quality: self.quality,
                                    unsharpRadius: self.unsharpRadius,
                                    unsharpSigma: self.unsharpSigma,
                                    unsharpAmount: self.unsharpAmount,
                                    unsharpThreshold: self.unsharpThreshold,
                                    useGrayColorspace: self.useGrayColorspace
                                )
                            } else {
                                // Split processing
                                let cropWidth = (width + 1) / 2
                                let rightCropWidth = width - cropWidth
                                // Right half
                                let command1 = GraphicsMagickHelper.buildConvertCommand(
                                    inputPath: imageFile.path,
                                    outputPath: "\(outputBasePath)-1.jpg",
                                    cropParams: "\(rightCropWidth)x\(height)+\(cropWidth)+0",
                                    resizeHeight: self.resizeHeight,
                                    quality: self.quality,
                                    unsharpRadius: self.unsharpRadius,
                                    unsharpSigma: self.unsharpSigma,
                                    unsharpAmount: self.unsharpAmount,
                                    unsharpThreshold: self.unsharpThreshold,
                                    useGrayColorspace: self.useGrayColorspace
                                )
                                // Left half
                                let command2 = GraphicsMagickHelper.buildConvertCommand(
                                    inputPath: imageFile.path,
                                    outputPath: "\(outputBasePath)-2.jpg",
                                    cropParams: "\(cropWidth)x\(height)+0+0",
                                    resizeHeight: self.resizeHeight,
                                    quality: self.quality,
                                    unsharpRadius: self.unsharpRadius,
                                    unsharpSigma: self.unsharpSigma,
                                    unsharpAmount: self.unsharpAmount,
                                    unsharpThreshold: self.unsharpThreshold,
                                    useGrayColorspace: self.useGrayColorspace
                                )
                                command = command1 + "\n" + command2
                            }
                            // Acquire lock before modifying shared `batchCommands` and `processedCount`.
                            batchCommandsLock.lock()
                            batchCommands.append(command + "\n")
                            processedCount += 1 // Increment local processedCount
                            batchCommandsLock.unlock()
                        }
                    }
                } else {
                    // If dimension fetching failed, add to failed files.
                    batchCommandsLock.lock()
                    failedFiles.append(imageFile.lastPathComponent)
                    batchCommandsLock.unlock()
                }
                dimensionAndCommandGroup.leave()
            }
        }

        // Wait for all dimension fetching and command building to complete
        dimensionAndCommandGroup.wait()

        guard !batchCommands.isEmpty, !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: No commands built or operation cancelled after command building.")
            #endif
            return
        }

        // Prepare temporary batch file
        let fileManager = FileManager.default
        let batchFilePath = fileManager.temporaryDirectory
            .appendingPathComponent("me2comic_batch_\(UUID().uuidString).txt")

        defer {
            try? fileManager.removeItem(at: batchFilePath)
        }

        do {
            try batchCommands.write(to: batchFilePath, atomically: true, encoding: .utf8)
            // Configure GraphicsMagick batch process
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
                processLock.lock()
                internalProcess = nil
                processLock.unlock()
                pipes.input.fileHandleForWriting.closeFile()
                return
            }

            try batchTask.run()

            guard !isCancelled else {
                processLock.lock()
                internalProcess?.terminate()
                (batchTask.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
                internalProcess = nil
                processLock.unlock()
                return
            }

            try safeWrite(data: Data(contentsOf: batchFilePath), to: pipes.input.fileHandleForWriting)
            pipes.input.fileHandleForWriting.closeFile()

            batchTask.waitUntilExit()
            // Process completion handling
            processLock.lock()
            internalProcess = nil
            processLock.unlock()

            if batchTask.terminationStatus != 0 {
                if !isCancelled {
                    // If GM process failed, all images in this batch are considered failed
                    failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                    processedCount = 0
                }
            }
        } catch {
            // Handle pipe errors gracefully
            if let posixError = error as? POSIXError, posixError.code == .EPIPE {
                #if DEBUG
                print("BatchProcessOperation: safeWrite encountered EPIPE (pipe closed), stopping write.")
                #endif
            } else {
                #if DEBUG
                print("BatchProcessOperation: Error during process execution: \(error.localizedDescription)")
                #endif
            }
            // If an error occurs, mark all images in the batch as failed.
            if !isCancelled {
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
        }
    }

    // MARK: - Safe Write Implementation

    //
    /// Safely writes data to a file handle with chunking and error recovery
    /// - Parameters:
    ///   - data: The data to be written
    ///   - fileHandle: Target file handle for writing
    private func safeWrite(data: Data, to fileHandle: FileHandle) throws {
        let chunkSize = 4096
        var bytesRemaining = data.count
        var currentOffset = 0

        while bytesRemaining > 0 {
            guard !isCancelled else {
                return
            }

            let chunkLength = min(chunkSize, bytesRemaining)
            let chunk = data.subdata(in: currentOffset ..< (currentOffset + chunkLength))

            var bytesWrittenForChunk = 0
            var writeAttempts = 0
            let maxWriteAttempts = 5 // Limit retries to prevent infinite loops
            // Retry logic for partial writes or interrupted system calls
            while bytesWrittenForChunk < chunkLength, writeAttempts < maxWriteAttempts {
                writeAttempts += 1
                do {
                    try chunk.withUnsafeBytes { ptr in
                        guard !isCancelled else {
                            return
                        }
                        // Use ptr.baseAddress directly as `chunk` is a subdata, and `advanced(by:)` for offset within the chunk.
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
            // Fail if unable to write complete chunk after retries
            if bytesWrittenForChunk == 0, chunkLength > 0, writeAttempts >= maxWriteAttempts {
                throw NSError(domain: "BatchProcessOperationErrorDomain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to write data to pipe after multiple retries."])
            }

            currentOffset += bytesWrittenForChunk
            bytesRemaining -= bytesWrittenForChunk
        }
    }

    // MARK: - Cancellation Mechanism

    /// Overrides the `cancel()` method from `Operation` to provide custom cancellation logic.
    /// When cancelled, it attempts to terminate the running GraphicsMagick process and cleans up resources.
    override func cancel() {
        super.cancel()

        processLock.lock()
        if let process = internalProcess, process.isRunning {
            process.terminate()
            // Immediately close pipe's write end
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
