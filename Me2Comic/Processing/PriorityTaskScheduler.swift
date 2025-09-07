//
//  PriorityTaskScheduler.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/7.
//

import Foundation

/// Thread-safe priority task queue with dynamic rebalancing
actor PriorityTaskQueue {
    // MARK: - Properties
    
    private var tasks: [PrioritizedBatchTask] = []
    private var activeTaskCount = 0
    private let maxConcurrency: Int
    
    // Track high-resolution processing for dynamic adjustment
    private var highResolutionInProgress = 0
    
    // MARK: - Initialization
    
    init(maxConcurrency: Int) {
        self.maxConcurrency = maxConcurrency
    }
    
    // MARK: - Task Management
    
    /// Add tasks to queue with automatic sorting
    func addTasks(_ newTasks: [PrioritizedBatchTask]) {
        tasks.append(contentsOf: newTasks)
        sortTasks()
    }
    
    /// Get next highest priority task
    func getNextTask() -> PrioritizedBatchTask? {
        guard !tasks.isEmpty else { return nil }
        
        // Prioritize high-resolution tasks when few are in progress
        if highResolutionInProgress < maxConcurrency / 2 {
            // Try to find a high-priority task first
            if let index = tasks.firstIndex(where: { $0.priority >= .high }) {
                let task = tasks.remove(at: index)
                activeTaskCount += 1
                if task.priority >= .high {
                    highResolutionInProgress += 1
                }
                return task
            }
        }
        
        // Otherwise take the first task
        let task = tasks.removeFirst()
        activeTaskCount += 1
        if task.priority >= .high {
            highResolutionInProgress += 1
        }
        return task
    }
    
    /// Mark task as completed
    func taskCompleted(priority: TaskPriority) {
        activeTaskCount = max(0, activeTaskCount - 1)
        if priority >= .high {
            highResolutionInProgress = max(0, highResolutionInProgress - 1)
        }
    }
    
    /// Check if more tasks available
    var hasAvailableTasks: Bool {
        !tasks.isEmpty
    }
    
    /// Get queue statistics
    func getStatistics() -> (pending: Int, active: Int, highRes: Int) {
        (tasks.count, activeTaskCount, highResolutionInProgress)
    }
    
    // MARK: - Private Methods
    
    /// Sort tasks by priority and estimated cost
    private func sortTasks() {
        tasks.sort { lhs, rhs in
            // First sort by priority
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            // Then by estimated cost (process heavy tasks first)
            return lhs.estimatedCost > rhs.estimatedCost
        }
    }
}

/// Scheduler for priority-based task execution with resolution awareness
@MainActor
class PriorityTaskScheduler {
    // MARK: - Properties
    
    private let logger: ProcessingLogger
    private let taskQueue: PriorityTaskQueue
    
    // MARK: - Constants
    
    private enum Constants {
        static let highResolutionThreshold = 3000
        static let highResolutionBatchSize = 2 // Smaller batches for high-res
        static let normalBatchSize = 10
        static let mixedModeBatchSize = 5
    }
    
    // MARK: - Initialization
    
    init(maxConcurrency: Int, logger: ProcessingLogger) {
        self.logger = logger
        self.taskQueue = PriorityTaskQueue(maxConcurrency: maxConcurrency)
        
        #if DEBUG
        logger.logDebug("PriorityTaskScheduler initialized with max concurrency: \(maxConcurrency)", source: "PriorityTaskScheduler")
        #endif
    }
    
    // MARK: - Public Methods
    
    /// Prepare prioritized tasks from scan results
    func preparePrioritizedTasks(
        scanResults: [DirectoryScanResult],
        globalBatchImages: [URL],
        outputDir: URL,
        parameters: ProcessingParameters,
        effectiveThreadCount: Int,
        effectiveBatchSize: Int
    ) async -> [PrioritizedBatchTask] {
        var prioritizedTasks: [PrioritizedBatchTask] = []
        
        #if DEBUG
        logger.logDebug("Preparing prioritized tasks for \(scanResults.count) scan results", source: "PriorityTaskScheduler")
        #endif
        
        // Separate high-resolution directories for special handling
        let highResolutionDirs = scanResults.filter { $0.isHighResolution }
        let hasHighResolution = !highResolutionDirs.isEmpty
        
        // Process isolated directories with higher priority
        for result in scanResults where result.category == .isolated {
            let subName = result.directoryURL.lastPathComponent
            let outputSubdir = outputDir.appendingPathComponent(subName)
            
            // Determine priority based on resolution
            let priority: TaskPriority = result.isHighResolution ? .critical : .high
            
            // Calculate adaptive batch size for isolated tasks
            let adaptiveBatchSize = calculateAdaptiveBatchSize(
                imageCount: result.imageFiles.count,
                isHighResolution: result.isHighResolution,
                hasGlobalHighResolution: hasHighResolution,
                threadCount: effectiveThreadCount
            )
            
            let batches = splitIntoBatches(result.imageFiles, batchSize: adaptiveBatchSize)
            
            logger.appendLog(String(
                format: NSLocalizedString("StartProcessingSubdir", comment: ""),
                subName + (result.isHighResolution ? " [High Resolution]" : "")
            ))
            
            #if DEBUG
            logger.logDebug(
                "Isolated directory \(subName): \(result.imageFiles.count) images, " +
                    "priority=\(priority), batchSize=\(adaptiveBatchSize), batches=\(batches.count)",
                source: "PriorityTaskScheduler"
            )
            #endif
            
            for batch in batches {
                let estimatedCost = estimateProcessingCost(
                    imageCount: batch.count,
                    isHighResolution: result.isHighResolution
                )
                
                prioritizedTasks.append(PrioritizedBatchTask(
                    images: batch,
                    outputDir: outputSubdir,
                    batchSize: batch.count,
                    isGlobal: false,
                    priority: priority,
                    estimatedCost: estimatedCost
                ))
            }
        }
        
        // Process global batch with resolution-aware splitting
        if !globalBatchImages.isEmpty {
            logger.appendLog(NSLocalizedString("StartProcessingGlobalBatch", comment: ""))
            
            // Separate high-resolution and normal images in global batch
            let (highResImages, normalImages) = await separateByResolution(
                images: globalBatchImages,
                scanResults: scanResults
            )
            
            // Create tasks for high-resolution images with higher priority
            if !highResImages.isEmpty {
                let highResBatchSize = Constants.highResolutionBatchSize
                let highResBatches = splitIntoBatches(highResImages, batchSize: highResBatchSize)
                
                #if DEBUG
                logger.logDebug(
                    "Global high-resolution: \(highResImages.count) images, " +
                        "batchSize=\(highResBatchSize), batches=\(highResBatches.count)",
                    source: "PriorityTaskScheduler"
                )
                #endif
                
                for batch in highResBatches {
                    let estimatedCost = estimateProcessingCost(
                        imageCount: batch.count,
                        isHighResolution: true
                    )
                    
                    prioritizedTasks.append(PrioritizedBatchTask(
                        images: batch,
                        outputDir: outputDir,
                        batchSize: batch.count,
                        isGlobal: true,
                        priority: .high, // Higher priority for high-res in global
                        estimatedCost: estimatedCost
                    ))
                }
            }
            
            // Create tasks for normal resolution images
            if !normalImages.isEmpty {
                let normalBatchSize = hasHighResolution ? Constants.mixedModeBatchSize : effectiveBatchSize
                let normalBatches = splitIntoBatches(normalImages, batchSize: normalBatchSize)
                
                #if DEBUG
                logger.logDebug(
                    "Global normal resolution: \(normalImages.count) images, " +
                        "batchSize=\(normalBatchSize), batches=\(normalBatches.count)",
                    source: "PriorityTaskScheduler"
                )
                #endif
                
                for batch in normalBatches {
                    let estimatedCost = estimateProcessingCost(
                        imageCount: batch.count,
                        isHighResolution: false
                    )
                    
                    prioritizedTasks.append(PrioritizedBatchTask(
                        images: batch,
                        outputDir: outputDir,
                        batchSize: batch.count,
                        isGlobal: true,
                        priority: .normal,
                        estimatedCost: estimatedCost
                    ))
                }
            }
        }
        
        // Add tasks to priority queue
        await taskQueue.addTasks(prioritizedTasks)
        
        #if DEBUG
        let stats = await taskQueue.getStatistics()
        logger.logDebug(
            "Priority queue initialized with \(stats.pending) tasks (highRes in progress: \(stats.highRes))",
            source: "PriorityTaskScheduler"
        )
        #endif
        
        return prioritizedTasks
    }
    
    /// Get next task from priority queue
    func getNextTask() async -> PrioritizedBatchTask? {
        await taskQueue.getNextTask()
    }
    
    /// Mark task as completed
    func markTaskCompleted(priority: TaskPriority) async {
        await taskQueue.taskCompleted(priority: priority)
    }
    
    /// Check if tasks available
    func hasAvailableTasks() async -> Bool {
        await taskQueue.hasAvailableTasks
    }
    
    // MARK: - Private Methods
    
    /// Separate images by resolution
    private func separateByResolution(
        images: [URL],
        scanResults: [DirectoryScanResult]
    ) async -> (highRes: [URL], normal: [URL]) {
        var highResImages: [URL] = []
        var normalImages: [URL] = []
        
        // Build a set of high-resolution directories
        let highResDirs = Set(scanResults.filter { $0.isHighResolution }.map { $0.directoryURL })
        
        for image in images {
            // Check if image belongs to a high-resolution directory
            let imageDir = image.deletingLastPathComponent()
            if highResDirs.contains(imageDir) {
                highResImages.append(image)
            } else {
                normalImages.append(image)
            }
        }
        
        return (highResImages, normalImages)
    }
    
    /// Calculate adaptive batch size based on resolution and workload
    private func calculateAdaptiveBatchSize(
        imageCount: Int,
        isHighResolution: Bool,
        hasGlobalHighResolution: Bool,
        threadCount: Int
    ) -> Int {
        if isHighResolution {
            // Very small batches for high-resolution to enable better load balancing
            let targetBatches = max(threadCount * 2, imageCount / 2)
            let batchSize = max(1, imageCount / targetBatches)
            return min(Constants.highResolutionBatchSize, batchSize)
        } else if hasGlobalHighResolution {
            // Medium batches when mixed with high-resolution
            return Constants.mixedModeBatchSize
        } else {
            // Normal batches for uniform low-resolution
            return min(Constants.normalBatchSize, max(1, imageCount / threadCount))
        }
    }
    
    /// Estimate processing cost for scheduling
    private func estimateProcessingCost(
        imageCount: Int,
        isHighResolution: Bool
    ) -> Int {
        let baseCost = imageCount
        let resolutionMultiplier = isHighResolution ? 5 : 1 // High-res takes ~5x longer
        return baseCost * resolutionMultiplier
    }
    
    /// Split array into batches
    private func splitIntoBatches<T>(_ items: [T], batchSize: Int) -> [[T]] {
        guard batchSize > 0, !items.isEmpty else { return [] }
        
        return stride(from: 0, to: items.count, by: batchSize).map {
            Array(items[$0 ..< min($0 + batchSize, items.count)])
        }
    }
}
