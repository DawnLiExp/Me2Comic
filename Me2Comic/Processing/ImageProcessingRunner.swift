import Foundation

enum ImageProcessingEvent: Sendable {
    case total(Int)
    case completed(processed: Int, failed: [String])
}

struct ImageProcessingReport: Sendable {
    let directories: [DirectoryScanResult]
    let globalProcessed: Int
}

/// Shared execution path for the GUI and the command-line target.
@MainActor
struct ImageProcessingRunner {
    let gmPath: String
    let logger: any LoggingProtocol

    func run(
        inputs: [URL], output: URL, parameters: ProcessingParameters,
        cancellationToken: ProcessingCancellationToken,
        eventSink: @escaping @Sendable (ImageProcessingEvent) async -> Void
    ) async throws -> ImageProcessingReport {
        let log: @Sendable (String, LogLevel, String?) -> Void = { logger.log($0, level: $1, source: $2) }
        try FileSystemHelper.createDirectory(at: output).get()
        let canContinue: @Sendable () async -> Bool = { await cancellationToken.canContinue() }
        let analyzer = DirectoryAnalyzer(logHandler: log, isProcessingCheck: canContinue)
        var directories: [DirectoryScanResult] = []
        for input in inputs {
            try Task.checkCancellation()
            directories += await analyzer.analyzeAsync(inputDir: input, widthThreshold: parameters.widthThreshold)
        }
        try Task.checkCancellation()
        guard !directories.isEmpty else {
            throw ProcessingError.noImagesFound(directory: inputs.first?.path ?? "")
        }
        let total = directories.reduce(0) { $0 + $1.imageFiles.count }
        await eventSink(.total(total))
        logger.log(String(format: String(localized: "TotalImagesToProcess"), total), level: .info, source: "ImageProcessingRunner")

        let (threads, batchSize) = AutoParameterCalculator(logger: logger).determineParameters(
            parameters: parameters, totalImages: total,
            hasHighResolution: directories.contains { $0.isHighResolution }
        )
        try FileSystemHelper.createOutputDirectories(scanResults: directories, outputDir: output).get()
        let tasks = BatchTaskOrganizer(logger: logger).prepareBatchTasks(
            scanResults: directories,
            globalBatchImages: directories.filter { $0.category == .globalBatch }.flatMap(\.imageFiles),
            outputDir: output, parameters: parameters, effectiveThreadCount: threads, effectiveBatchSize: batchSize
        )
        // Preserve the existing high-resolution queue priority.
        let isolatedCount = directories.filter { $0.category == .isolated }.reduce(0) {
            $0 + Int(ceil(Double($1.imageFiles.count) / Double(batchSize)))
        }
        let highResCount = directories.filter { $0.category == .globalBatch && $0.isHighResolution }
            .reduce(0) { $0 + $1.imageFiles.count }
        let highResBatches = Int(ceil(Double(highResCount) / Double(batchSize)))
        let queue = TaskQueue(logger: log)
        await queue.initialize(with: tasks, highResGlobalIndices: Set(isolatedCount..<(isolatedCount + highResBatches)))
        let processor = BatchImageProcessor(
            gmPath: gmPath, widthThreshold: parameters.widthThreshold, resizeHeight: parameters.resizeHeight,
            quality: parameters.quality, unsharpRadius: parameters.unsharpRadius,
            unsharpSigma: parameters.unsharpSigma, unsharpAmount: parameters.unsharpAmount,
            unsharpThreshold: parameters.unsharpThreshold, useGrayColorspace: parameters.useGrayColorspace,
            cancellationCheck: canContinue, logger: log
        )
        let globalProcessed = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for thread in 0..<threads {
                group.addTask {
                    var global = 0
                    while !Task.isCancelled, let task = await queue.getNextTask(threadId: thread) {
                        let result = await processor.processBatch(
                            images: task.images, outputDir: task.outputDir, duplicateBaseNames: task.duplicateBaseNames
                        )
                        await queue.markCompleted()
                        await eventSink(.completed(processed: result.processed, failed: result.failed))
                        if task.isGlobal { global += result.processed }
                    }
                    return global
                }
            }
            var count = 0
            for await value in group { count += value }
            return count
        }
        try Task.checkCancellation()
        return ImageProcessingReport(directories: directories, globalProcessed: globalProcessed)
    }
}
