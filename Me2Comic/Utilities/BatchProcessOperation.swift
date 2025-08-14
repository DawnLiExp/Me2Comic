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
        // Always ensure onCompleted is called so UI/upstream can finalize state.
        var processedCount = 0
        var failedFiles: [String] = []
        defer {
            onCompleted?(processedCount, failedFiles)
        }

        guard !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: Operation cancelled before starting.")
            #endif
            return
        }

        guard !batchImages.isEmpty else { return }

        // Pass a closure to ImageIOHelper to check for cancellation.
        let batchDimensions = ImageIOHelper.getBatchImageDimensions(
            imagePaths: batchImages.map { $0.path },
            shouldContinue: { [weak self] in
                return self?.isCancelled == false
            }
        )

        guard !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: Operation cancelled during ImageIO dimension fetching.")
            #endif
            return
        }

        if batchDimensions.isEmpty {
            // nothing valid to process
            failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
            return
        }

        let batchTask = Process()
        batchTask.executableURL = URL(fileURLWithPath: gmPath)
        batchTask.arguments = ["batch", "-stop-on-error", "off"]

        let pipes = (input: Pipe(), output: Pipe(), error: Pipe())
        batchTask.standardInput = pipes.input
        batchTask.standardOutput = pipes.output
        batchTask.standardError = pipes.error

        // Collect stdout/stderr for diagnostics
        var stdoutData = Data()
        var stderrData = Data()
        let stdoutHandle = pipes.output.fileHandleForReading
        let stderrHandle = pipes.error.fileHandleForReading

        stdoutHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { stdoutData.append(d) }
        }
        stderrHandle.readabilityHandler = { handle in
            let d = handle.availableData
            if !d.isEmpty { stderrData.append(d) }
        }

        processLock.lock()
        internalProcess = batchTask
        processLock.unlock()

        guard !isCancelled else {
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
            try? pipes.input.fileHandleForWriting.close()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            return
        }

        var shouldStop = false // flag to break outer loop on write error

        do {
            try batchTask.run()

            guard !isCancelled else {
                processLock.lock()
                internalProcess?.terminate()
                (batchTask.standardInput as? Pipe)?.fileHandleForWriting.closeFile()
                internalProcess = nil
                processLock.unlock()
                stdoutHandle.readabilityHandler = nil
                stderrHandle.readabilityHandler = nil
                return
            }

            let pipeFileHandle = pipes.input.fileHandleForWriting
            defer {
                // ensure we always close write end
                try? pipeFileHandle.close()
            }

            // Thread-safe tracking for generated output paths to prevent collisions.
            var generatedPaths = Set<String>()
            let pathLock = NSLock()

            // Light-weight pre-scan for duplicate base names (within this batch).
            var baseNameCounts: [String: Int] = [:]
            for url in batchImages {
                let base = url.deletingPathExtension().lastPathComponent.lowercased()
                baseNameCounts[base, default: 0] += 1
            }
            let duplicateBaseNames = Set(baseNameCounts.compactMap { $0.value > 1 ? $0.key : nil })

            for imageFile in batchImages {
                autoreleasepool {
                    if shouldStop || isCancelled { return }
                    let filename = imageFile.lastPathComponent
                    let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent
                    let srcExt = imageFile.pathExtension.lowercased() // Original extension in lowercase
                    let originalSubdirName = imageFile.deletingLastPathComponent().lastPathComponent

                    let finalOutputDirForImage: URL
                    if self.outputDir.lastPathComponent == originalSubdirName {
                        finalOutputDirForImage = self.outputDir
                    } else {
                        finalOutputDirForImage = self.outputDir.appendingPathComponent(originalSubdirName)
                    }

                    // Appends source extension to base name to avoid filename collisions
                    // E.g., cut01.jpg -> cut01_jpg; cut01.png -> cut01_png
                    let useSafeBase = duplicateBaseNames.contains(filenameWithoutExt.lowercased())
                    let baseNameForOutput = useSafeBase ? "\(filenameWithoutExt)_\(srcExt)" : filenameWithoutExt
                    let outputBasePath = finalOutputDirForImage.appendingPathComponent(baseNameForOutput).path

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

                    // Write commands; on error set shouldStop and record failure
                    for command in commandsForImage {
                        if let data = (command + "\n").data(using: .utf8) {
                            do {
                                try safeWrite(data: data, to: pipeFileHandle)
                            } catch {
                                #if DEBUG
                                print("BatchProcessOperation: Error writing command to pipe: \(error.localizedDescription)")
                                #endif
                                // mark this image as failed and stop further processing
                                failedFiles.append(filename)
                                shouldStop = true
                                return
                            }
                        }
                    }

                    processedCount += 1
                } // autoreleasepool end

                if shouldStop { break } // break outer for loop
            }

            // After writing all commands (or stopping), close write end to signal EOF.
            try? pipeFileHandle.close()

            // Wait child to exit and stop collecting readabilityHandler
            batchTask.waitUntilExit()
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil

            processLock.lock()
            internalProcess = nil
            processLock.unlock()

            if batchTask.terminationStatus != 0 {
                // gm returned non-zero: append all files in this batch that haven't failed yet
                if !isCancelled {
                    // try to parse stderrData to find more info (kept in stderrData variable)
                    #if DEBUG
                    if !stderrData.isEmpty, let s = String(data: stderrData, encoding: .utf8) {
                        print("BatchProcessOperation: gm stderr: \(s)")
                    }
                    #endif
                    // Conservative approach: mark any remaining unmarked images as failed
                    let remaining = batchImages.map { $0.lastPathComponent }.filter { !failedFiles.contains($0) }
                    failedFiles.append(contentsOf: remaining)
                    processedCount = 0
                }
            }
        } catch {
            // Handle run()/spawn errors and EPIPE explicitly
            #if DEBUG
            print("BatchProcessOperation: Error during process execution: \(error.localizedDescription)")
            #endif
            if !isCancelled {
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
            // Ensure readabilityHandlers cleaned up
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }
    }

    // MARK: - Path Collision Resolution

    /// Generates a unique output path by appending a numeric suffix if a collision is detected.
    /// - Parameters:
    ///   - basePath: path without extension or trailing part (e.g. /out/dir/cut01_jpg)
    ///   - suffix: desired suffix including leading dash if any and extension (e.g. ".jpg" or "-1.jpg")
    ///   - generatedPaths: set tracking already-reserved paths within this operation (case-insensitive)
    ///   - lock: NSLock protecting access to generatedPaths
    private func resolveOutputPath(basePath: String, suffix: String, generatedPaths: inout Set<String>, lock: NSLock) -> String {
        lock.lock()
        defer { lock.unlock() }

        // initial candidate
        var candidate = basePath + suffix
        // lowercased key for case-insensitive comparison
        var candidateKey = candidate.lowercased()

        // If candidate conflicts with already-reserved path or file already exists on disk,
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

    // MARK: - Safe Write Implementation

    /// Writes data to file handle in chunks with cancellation checks
    private func safeWrite(data: Data, to fileHandle: FileHandle) throws {
        let fd = fileHandle.fileDescriptor
        var bytesRemaining = data.count
        var offset = 0
        // Write once using withUnsafeBytes and manage EINTR/EPIPE explicitly
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            while bytesRemaining > 0 {
                guard !isCancelled else {
                    #if DEBUG
                    print("BatchProcessOperation: safeWrite cancelled.")
                    #endif
                    return
                }

                let ptr = base.advanced(by: offset)
                var attemptsForThisChunk = 0
                // Attempt to write the remaining bytes; handle partial writes
                while bytesRemaining > 0 {
                    let writeLen = bytesRemaining
                    let written = write(fd, ptr, writeLen)
                    if written > 0 {
                        offset += written
                        bytesRemaining -= written
                        // move pointer forward
                        continue
                    } else if written == 0 {
                        // unusual: no progress; treat as temporary and retry a few times
                        attemptsForThisChunk += 1
                        if attemptsForThisChunk > 5 {
                            throw NSError(domain: "BatchProcessOperationErrorDomain", code: 2, userInfo: [NSLocalizedDescriptionKey: "No progress writing to pipe."])
                        }
                        continue
                    } else {
                        let currentErrno = errno
                        if currentErrno == EINTR {
                            // interrupted by signal; retry
                            continue
                        } else if currentErrno == EPIPE {
                            // Broken pipe — child closed; propagate as POSIXError(EPIPE)
                            #if DEBUG
                            print("BatchProcessOperation: safeWrite encountered EPIPE.")
                            #endif
                            throw POSIXError(.EPIPE)
                        } else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(currentErrno), userInfo: nil)
                        }
                    }
                }
            }
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
