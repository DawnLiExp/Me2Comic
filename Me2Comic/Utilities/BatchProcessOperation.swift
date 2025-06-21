//
//  BatchProcessOperation.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/19.
//
import Foundation

/// `BatchProcessOperation` is an `Operation` subclass that encapsulates the logic for batch processing images
/// using GraphicsMagick. It handles image dimension retrieval, conditional cropping/resizing, and command execution.
class BatchProcessOperation: Operation, @unchecked Sendable {
    // MARK: - Input Parameters

    private let batchImages: [URL] // Array of URLs for images in this batch.
    private let outputDir: URL
    private let widthThreshold: Int // Width threshold to determine if an image needs splitting.
    private let resizeHeight: Int
    private let quality: Int
    private let unsharpRadius: Float
    private let unsharpSigma: Float
    private let unsharpAmount: Float
    private let unsharpThreshold: Float
    private let useGrayColorspace: Bool
    private let gmPath: String // Path to the GraphicsMagick executable.

    // MARK: - Output Callbacks

    /// A closure that is called upon completion of the operation, providing the count of successfully processed images
    /// and a list of files that failed processing.
    var onCompleted: ((_ processedCount: Int, _ failedFiles: [String]) -> Void)?

    // MARK: - Internal State

    private var internalProcess: Process?
    private let processLock = NSLock()

    // MARK: - Initialization

    /// Initializes a new batch processing operation with the specified image processing parameters.
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

    /// The main execution logic for the operation. This method is called when the operation starts.
    /// It processes each image in the batch, generates GraphicsMagick commands, and executes them.
    override func main() {
        guard !isCancelled else { return }

        var processedCount = 0
        var failedFiles: [String] = []

        // Ensure the completion callback is always invoked, unless the operation was cancelled.
        defer {
            if !isCancelled {
                onCompleted?(processedCount, failedFiles)
            }
        }

        guard !batchImages.isEmpty else { return }

        // Filter for supported image extensions and get dimensions in batch for efficiency.
        let supportedExtensions = ["jpg", "jpeg", "png"]
        let validImages = batchImages.filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
        let batchDimensions = GraphicsMagickHelper.getBatchImageDimensions(
            imagePaths: validImages.map { $0.path }
        )

        // Prepare a temporary file to store batch commands for GraphicsMagick.
        let fileManager = FileManager.default
        let batchFilePath = fileManager.temporaryDirectory
            .appendingPathComponent("me2comic_batch_\(UUID().uuidString).txt")
        defer {
            try? fileManager.removeItem(at: batchFilePath)
        }

        var batchCommands = ""

        // Iterate through each image to determine processing logic and build commands.
        for imageFile in batchImages {
            guard !isCancelled else { break }

            let filename = imageFile.lastPathComponent
            let filenameWithoutExt = imageFile.deletingPathExtension().lastPathComponent
            let outputBasePath = outputDir.appendingPathComponent(filenameWithoutExt).path

            // Retrieve image dimensions, prioritizing batch results.
            var dimensions: (width: Int, height: Int)?
            if let batchDim = batchDimensions[imageFile.path] {
                dimensions = batchDim
            } else {
                dimensions = GraphicsMagickHelper.getImageDimensions(
                    imagePath: imageFile.path
                )
            }

            guard let dimensions = dimensions else {
                failedFiles.append(filename)
                continue
            }

            let (width, height) = dimensions

            // Apply processing based on image width threshold.
            if width < widthThreshold {
                // Single image processing: resize and apply effects.
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
                // Split processing: image is wider than threshold, split into two parts.
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

        // Execute the generated GraphicsMagick batch commands.
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

            // Store process reference for potential cancellation.
            processLock.lock()
            internalProcess = batchTask
            processLock.unlock()

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

            // Clear process reference after completion.
            processLock.lock()
            internalProcess = nil
            processLock.unlock()

            // Handle the outcome of the batch execution.
            if batchTask.terminationStatus != 0 {
                failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
                processedCount = 0
            }
        } catch {
            // Log any exceptions during process execution.
            failedFiles.append(contentsOf: batchImages.map { $0.lastPathComponent })
            processedCount = 0
            processLock.lock()
            internalProcess = nil
            processLock.unlock()
        }
    }

    // MARK: - Cancellation Mechanism

    /// Overrides the default `cancel` method to terminate the running GraphicsMagick process if the operation is cancelled.
    override func cancel() {
        super.cancel()
        processLock.lock()
        if let process = internalProcess, process.isRunning {
            process.terminate()
        }
        processLock.unlock()
    }
}
