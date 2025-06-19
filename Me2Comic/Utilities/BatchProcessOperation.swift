//
//  BatchProcessOperation.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//
import Foundation

/// Batch processing operation class, encapsulates GraphicsMagick batch processing logic.
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

    /// Completion callback, returns the number of successfully processed images and a list of failed filenames.
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
        // Check if the operation was cancelled before starting.
        guard !isCancelled else { return }
        var processedCount = 0
        var failedFiles: [String] = []
        // The defer block ensures the callback is always called upon completion.
        defer {
            if !isCancelled {
                onCompleted?(processedCount, failedFiles)
            }
        }
        // Early exit check.
        if batchImages.isEmpty { return }
        // Batch get image dimensions.
        let supportedExtensions = ["jpg", "jpeg", "png"]
        let validImages = batchImages.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let batchDimensions = GraphicsMagickHelper.getBatchImageDimensions(
            imagePaths: validImages.map { $0.path },
            gmPath: gmPath
        )
        // Prepare batch file.
        let fileManager = FileManager.default
        let batchFilePath = fileManager.temporaryDirectory
            .appendingPathComponent("me2comic_batch_\(UUID().uuidString).txt")
        defer {
            try? fileManager.removeItem(at: batchFilePath)
        }
        var batchCommands = ""
        // Process each image.
        for imageFile in batchImages {
            // Check cancellation status.
            guard !isCancelled else { break }
            let filename = imageFile.lastPathComponent
            let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent
            let outputBasePath = outputDir.appendingPathComponent(filenameWithoutExt).path
            // Get image dimensions.
            var dimensions: (width: Int, height: Int)?
            if let batchDim = batchDimensions[imageFile.path] {
                dimensions = batchDim
            } else {
                dimensions = GraphicsMagickHelper.getImageDimensions(
                    imagePath: imageFile.path,
                    gmPath: gmPath
                )
            }
            guard let dimensions = dimensions else {
                failedFiles.append(filename)
                continue
            }
            let (width, height) = dimensions
            if width < widthThreshold {
                // Single image processing.
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
                // Split processing.
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
        // If cancelled or no commands, exit early.
        guard !batchCommands.isEmpty, !isCancelled else {
            return
        }
        // Execute batch processing.
        do {
            try batchCommands.write(to: batchFilePath, atomically: true, encoding: .utf8)
            let batchTask = Process()
            batchTask.executableURL = URL(fileURLWithPath: gmPath)
            batchTask.arguments = ["batch", "-stop-on-error", "off"]
            let pipes = (input: Pipe(), output: Pipe(), error: Pipe())
            batchTask.standardInput = pipes.input
            batchTask.standardOutput = pipes.output
            batchTask.standardError = pipes.error
            // Save process reference for cancellation.
            processLock.lock()
            internalProcess = batchTask
            processLock.unlock()
            // Check cancellation status again.
            guard !isCancelled else {
                processLock.lock()
                internalProcess = nil
                processLock.unlock()
                return
            }
            try batchTask.run()
            try pipes.input.fileHandleForWriting.write(Data(contentsOf: batchFilePath))
            pipes.input.fileHandleForWriting.closeFile()
            batchTask.waitUntilExit()
            // Clean up process reference.
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
            // Handle execution result.
            if batchTask.terminationStatus != 0 {
                // Batch processing failed.
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
        } catch {
            // Execution exception.
            failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
            processedCount = 0
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
        }
    }

    // MARK: - Cancellation Mechanism

    override func cancel() {
        super.cancel()
        // Terminate the internally running Process.
        processLock.lock()
        if let process = internalProcess, process.isRunning {
            process.terminate()
        }
        processLock.unlock()
    }
}
