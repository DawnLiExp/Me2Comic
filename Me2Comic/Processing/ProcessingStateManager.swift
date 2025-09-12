//
//  ProcessingStateManager.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

/// Thread-safe aggregation of batch processing results
actor BatchResultAggregator {
    private var totalProcessed = 0
    private var failedFiles: [String] = []
    
    func addResult(processed: Int, failed: [String]) {
        totalProcessed += processed
        failedFiles.append(contentsOf: failed)
    }
    
    func getResults() -> (processed: Int, failed: [String]) {
        (totalProcessed, failedFiles)
    }
    
    func reset() {
        totalProcessed = 0
        failedFiles.removeAll()
    }
}

/// Manages processing state and progress for image batch operations
@MainActor
class ProcessingStateManager: ObservableObject {
    // MARK: - Published State
    
    @Published var isProcessing = false
    @Published var totalImagesToProcess = 0
    @Published var currentProcessedImages = 0
    @Published var processingProgress = 0.0
    @Published var didFinishAllTasks = false
    
    // MARK: - Properties
    
    private(set) var processingStartTime: Date?
    private let batchResultAggregator = BatchResultAggregator()
    
    // MARK: - State Management
    
    /// Reset all processing state for new operation
    func resetProcessingState() {
        Task { await batchResultAggregator.reset() }
        processingStartTime = Date()
        totalImagesToProcess = 0
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Reset UI state after processing completion
    func resetUIState() {
        isProcessing = false
        totalImagesToProcess = 0
        currentProcessedImages = 0
        processingProgress = 0.0
    }
    
    /// Mark processing as started
    func startProcessing() {
        isProcessing = true
        resetProcessingState()
    }
    
    /// Mark processing as stopped
    func stopProcessing() {
        resetUIState()
    }
    
    // MARK: - Progress Updates
    
    /// Update total images to process
    func setTotalImages(_ count: Int) {
        totalImagesToProcess = count
    }
    
    /// Update progress after batch completion
    /// - Parameters:
    ///   - processedCount: Number of images processed in this batch
    ///   - failedFiles: List of failed file names
    func handleBatchCompletion(processedCount: Int, failedFiles: [String]) async {
        await batchResultAggregator.addResult(
            processed: processedCount,
            failed: failedFiles
        )
        
        currentProcessedImages += processedCount
        processingProgress = totalImagesToProcess > 0
            ? Double(currentProcessedImages) / Double(totalImagesToProcess)
            : 0.0
    }
    
    /// Get aggregated results
    func getAggregatedResults() async -> (processed: Int, failed: [String]) {
        await batchResultAggregator.getResults()
    }
    
    /// Calculate elapsed processing time
    func getElapsedTime() -> Int {
        guard let startTime = processingStartTime else { return 0 }
        return Int(Date().timeIntervalSince(startTime))
    }
    
    /// Mark all tasks as finished with delay
    /// - Parameter delay: Delay in nanoseconds before resetting state
    func markTasksFinished(withDelay delay: UInt64 = 1_500_000_000) {
        // Ensure 100% progress display without triggering didSet loops
        if processingProgress < 1.0 {
            processingProgress = 1.0
            currentProcessedImages = totalImagesToProcess
        }
        didFinishAllTasks = true
        
        Task {
            // Wait for a short duration to allow UI to update to 100%
            try? await Task.sleep(nanoseconds: delay)
            
            // Only reset UI if still in processing state (not manually stopped)
            if isProcessing {
                resetUIState()
            }
            didFinishAllTasks = false
        }
    }
}
