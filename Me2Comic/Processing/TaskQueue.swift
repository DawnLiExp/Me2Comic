//
//  TaskQueue.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/7.
//

import Foundation

/// Priority levels for batch processing tasks
enum TaskPriority: Int, Comparable {
    case high = 0 // Isolated directories (double-page, requires splitting)
    case normal = 1 // Global batch (single-page)
    
    static func < (lhs: TaskPriority, rhs: TaskPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Enhanced batch task with priority
struct PrioritizedTask {
    let task: BatchTask
    let priority: TaskPriority
    let index: Int // Original index for stable sorting
    
    var estimatedCost: Int {
        // Isolated tasks cost ~2.5x more processing time
        switch priority {
        case .high:
            return task.images.count * 25 // 2.5x weight
        case .normal:
            return task.images.count * 10 // 1x weight
        }
    }
}

/// Thread-safe priority queue for work-stealing task distribution
actor TaskQueue {
    // MARK: - Properties
    
    private var tasks: [PrioritizedTask] = []
    private var completedTasks = 0
    private var totalTasks = 0
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    // MARK: - Statistics
    
    private var taskDistribution: [Int: Int] = [:] // Thread ID -> Task count
    private var stealCount = 0
    
    // MARK: - Initialization
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    // MARK: - Task Management
    
    /// Initialize queue with prioritized tasks
    func initialize(with tasks: [BatchTask]) {
        self.tasks = tasks.enumerated().map { index, task in
            let priority: TaskPriority = task.isGlobal ? .normal : .high
            return PrioritizedTask(task: task, priority: priority, index: index)
        }
        
        // Sort by priority first, then by estimated cost (largest first), maintain stable order for same priority
        self.tasks.sort { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority < rhs.priority
            }
            if lhs.estimatedCost != rhs.estimatedCost {
                return lhs.estimatedCost > rhs.estimatedCost // Larger tasks first
            }
            return lhs.index < rhs.index // Stable sort
        }
        
        totalTasks = self.tasks.count
        completedTasks = 0
        taskDistribution.removeAll()
        stealCount = 0
        
        #if DEBUG
        let highPriorityCount = self.tasks.filter { $0.priority == .high }.count
        let totalEstimatedCost = self.tasks.reduce(0) { $0 + $1.estimatedCost }
        logger?("TaskQueue initialized: \(totalTasks) tasks (\(highPriorityCount) high priority), estimated cost: \(totalEstimatedCost)", .debug, "TaskQueue")
        #endif
    }
    
    /// Get next available task (work-stealing enabled)
    func getNextTask(threadId: Int) -> BatchTask? {
        guard !tasks.isEmpty else {
            #if DEBUG
            if completedTasks < totalTasks {
                logger?("Thread \(threadId) found no tasks (work-stealing active)", .debug, "TaskQueue")
            }
            #endif
            return nil
        }
        
        let prioritizedTask = tasks.removeFirst()
        
        // Track distribution
        taskDistribution[threadId, default: 0] += 1
        
        // Detect work-stealing (thread getting extra tasks)
        if taskDistribution[threadId]! > (totalTasks / max(1, taskDistribution.count)) + 1 {
            stealCount += 1
            #if DEBUG
            logger?("Thread \(threadId) stealing task (priority: \(prioritizedTask.priority), images: \(prioritizedTask.task.images.count))", .debug, "TaskQueue")
            #endif
        }
        
        #if DEBUG
        logger?("Thread \(threadId) assigned task: priority=\(prioritizedTask.priority), images=\(prioritizedTask.task.images.count), remaining=\(tasks.count)", .debug, "TaskQueue")
        #endif
        
        return prioritizedTask.task
    }
    
    /// Mark task as completed
    func markCompleted() {
        completedTasks += 1
    }
    
    /// Get current progress
    func getProgress() -> (completed: Int, total: Int, remaining: Int) {
        return (completedTasks, totalTasks, tasks.count)
    }
    
    /// Get work distribution statistics
    func getStatistics() -> (distribution: [Int: Int], stealCount: Int) {
        return (taskDistribution, stealCount)
    }
}
