//
//  BatchProcessOperation.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//

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
    private var shouldIgnoreSIGPIPE = false

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
        signal(SIGPIPE, SIG_IGN)
        defer {
            signal(SIGPIPE, SIG_DFL)
        }
        guard !isCancelled else {
            #if DEBUG
            print("BatchProcessOperation: Operation cancelled before starting.")
            #endif
            return
        }

        var processedCount = 0
        var failedFiles: [String] = []

        defer {
            if !isCancelled {
                onCompleted?(processedCount, failedFiles)
            }
        }

        guard !batchImages.isEmpty else {
            return
        }

        // Filter for supported image extensions
        let supportedExtensions = ["jpg", "jpeg", "png"]
        let validImages = batchImages.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let batchDimensions = GraphicsMagickHelper.getBatchImageDimensions(
            imagePaths: validImages.map { $0.path }
        )

        if batchDimensions.isEmpty {
            onCompleted?(0, validImages.map { $0.lastPathComponent })
            return
        }

        // Prepare temporary batch file
        let fileManager = FileManager.default
        let batchFilePath = fileManager.temporaryDirectory
            .appendingPathComponent("me2comic_batch_\(UUID().uuidString).txt")

        defer {
            try? fileManager.removeItem(at: batchFilePath)
        }

        var batchCommands = ""

        // Build batch commands
        for imageFile in batchImages {
            guard !isCancelled else { break }

            let filename = imageFile.lastPathComponent
            let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent
            let outputBasePath = outputDir.appendingPathComponent(filenameWithoutExt).path

            // Get dimensions (from batch or individually)
            var dimensions: (width: Int, height: Int)?
            if let batchDim = batchDimensions[imageFile.path] {
                dimensions = batchDim
            } else {
                dimensions = GraphicsMagickHelper.getImageDimensions(imagePath: imageFile.path)
            }

            guard let dimensions = dimensions else {
                failedFiles.append(filename)
                continue
            }

            let (width, height) = dimensions

            if width < widthThreshold {
                // Single image processing
                let command = GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: "\(outputBasePath).jpg",
                    cropParams: nil,
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                )
                batchCommands.append(command + "\n")
                processedCount += 1
            } else {
                // Split processing
                let cropWidth = width / 2
                // Right half.
                batchCommands.append(GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: "\(outputBasePath)-1.jpg",
                    cropParams: "\(cropWidth)x\(height)+\(cropWidth)+0",
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                ) + "\n")
                // Left half.
                batchCommands.append(GraphicsMagickHelper.buildConvertCommand(
                    inputPath: imageFile.path,
                    outputPath: "\(outputBasePath)-2.jpg",
                    cropParams: "\(cropWidth)x\(height)+0+0",
                    resizeHeight: resizeHeight,
                    quality: quality,
                    unsharpRadius: unsharpRadius,
                    unsharpSigma: unsharpSigma,
                    unsharpAmount: unsharpAmount,
                    unsharpThreshold: unsharpThreshold,
                    useGrayColorspace: useGrayColorspace
                ) + "\n")
                processedCount += 1
            }
        }

        guard !batchCommands.isEmpty, !isCancelled else {
            return
        }

        do {
            try batchCommands.write(to: batchFilePath, atomically: true, encoding: .utf8)

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

            // Ignore SIGPIPE signal to prevent app termination
            signal(SIGPIPE, SIG_IGN)
            shouldIgnoreSIGPIPE = true

            try batchTask.run()

            guard !isCancelled else {
                processLock.lock()
                internalProcess?.terminate()
                internalProcess = nil
                processLock.unlock()
                pipes.input.fileHandleForWriting.closeFile()
                return
            }

            // Safe write implementation
            try safeWrite(data: Data(contentsOf: batchFilePath), to: pipes.input.fileHandleForWriting)
            pipes.input.fileHandleForWriting.closeFile()

            batchTask.waitUntilExit()

            processLock.lock()
            internalProcess = nil
            processLock.unlock()

            if batchTask.terminationStatus != 0 {
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
        } catch {
            if let posixError = error as? POSIXError, posixError.code == .EPIPE {
                // Broken pipe is expected during cancellation
                #if DEBUG
                print("BatchProcessOperation: Broken pipe during write (expected during cancellation)")
                #endif
            } else {
                #if DEBUG
                print("BatchProcessOperation: Error during process execution: \(error.localizedDescription)")
                #endif
            }
            failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
            processedCount = 0
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
        }
    }

    // MARK: - Safe Write Implementation

    private func safeWrite(data: Data, to fileHandle: FileHandle) throws {
        let chunkSize = 4096
        var bytesRemaining = data.count
        var offset = 0

        while bytesRemaining > 0, !isCancelled {
            let chunkLength = min(chunkSize, bytesRemaining)
            let chunk = data.subdata(in: offset ..< (offset + chunkLength))

            try chunk.withUnsafeBytes { ptr in
                let bytesWritten = write(fileHandle.fileDescriptor,
                                         ptr.baseAddress,
                                         chunkLength)
                if bytesWritten == -1 {
                    if errno == EPIPE {
                        throw POSIXError(.EPIPE)
                    } else {
                        throw NSError(domain: NSPOSIXErrorDomain,
                                      code: Int(errno),
                                      userInfo: nil)
                    }
                }
                offset += bytesWritten
                bytesRemaining -= bytesWritten
            }
        }
    }

    // MARK: - Cancellation Mechanism

    override func cancel() {
        super.cancel()

        processLock.lock()
        if let process = internalProcess, process.isRunning {
            process.terminate()
        }
        processLock.unlock()
    }

    deinit {
        if shouldIgnoreSIGPIPE {
            // Restore default SIGPIPE handler when operation is deallocated
            signal(SIGPIPE, SIG_DFL)
        }
    }
}
