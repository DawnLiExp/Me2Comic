//
//  TaskQueueTests.swift
//  Me2ComicTests
//
//  P1 Actor concurrency tests for TaskQueue
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("任务优先级队列测试")
struct TaskQueueTests {

    // 辅助方法：创建测试用 BatchTask
    private func createTestTask(id: Int, isGlobal: Bool = true, imageCount: Int = 10) -> BatchTask {
        BatchTask(
            images: (0..<imageCount).map { URL(fileURLWithPath: "/tmp/img\($0)_task\(id).jpg") },
            outputDir: URL(fileURLWithPath: "/tmp/out"),
            batchSize: 40,
            isGlobal: isGlobal
        )
    }

    @Test("初始化时应正确分配优先级并排序")
    func testPrioritySorting() async {
        let queue = TaskQueue()
        
        // 任务清单：
        // 0: Global (Normal)
        // 1: Isolated (High)
        // 2: Global (Normal)
        // 3: Global (Normal, 但被标记为 HighRes -> Medium)
        let tasks = [
            createTestTask(id: 0, isGlobal: true),
            createTestTask(id: 1, isGlobal: false),
            createTestTask(id: 2, isGlobal: true),
            createTestTask(id: 3, isGlobal: true)
        ]
        
        await queue.initialize(with: tasks, highResGlobalIndices: [3])
        
        // 预期顺序：
        // 1. Task 1 (High)
        // 2. Task 3 (Medium)
        // 3. Task 0 (Normal) - 索引小
        // 4. Task 2 (Normal)
        
        let t1 = await queue.getNextTask(threadId: 1)
        #expect(t1?.images.first?.path.contains("task1") == true)
        
        let t2 = await queue.getNextTask(threadId: 1)
        #expect(t2?.images.first?.path.contains("task3") == true)
        
        let t3 = await queue.getNextTask(threadId: 1)
        #expect(t3?.images.first?.path.contains("task0") == true)
        
        let t4 = await queue.getNextTask(threadId: 1)
        #expect(t4?.images.first?.path.contains("task2") == true)
        
        let t5 = await queue.getNextTask(threadId: 1)
        #expect(t5 == nil)
    }

    @Test("同优先级下，图片多（成本大）的任务应优先")
    func testCostSorting() async {
        let queue = TaskQueue()
        
        let tasks = [
            createTestTask(id: 0, isGlobal: true, imageCount: 10), // Normal, Cost 100
            createTestTask(id: 1, isGlobal: true, imageCount: 50)  // Normal, Cost 500
        ]
        
        await queue.initialize(with: tasks)
        
        // Task 1 应该先出队
        let first = await queue.getNextTask(threadId: 1)
        #expect(first?.images.count == 50)
        
        let second = await queue.getNextTask(threadId: 1)
        #expect(second?.images.count == 10)
    }

    @Test("进度追踪应正确反映完成情况")
    func testProgressTracking() async {
        let queue = TaskQueue()
        let tasks = [createTestTask(id: 0), createTestTask(id: 1)]
        
        await queue.initialize(with: tasks)
        
        var progress = await queue.getProgress()
        #expect(progress.completed == 0)
        #expect(progress.total == 2)
        #expect(progress.remaining == 2)
        
        _ = await queue.getNextTask(threadId: 1)
        progress = await queue.getProgress()
        #expect(progress.remaining == 1, "取出任务后剩余数应减少")
        #expect(progress.completed == 0, "未标记完成前 completed 应为 0")
        
        await queue.markCompleted()
        progress = await queue.getProgress()
        #expect(progress.completed == 1)
    }

    @Test("工作分配统计应能识别任务窃取")
    func testWorkStealingStats() async {
        let queue = TaskQueue()
        let tasks = (0..<10).map { createTestTask(id: $0) }
        
        await queue.initialize(with: tasks)
        
        // 关键修复：先让线程 2 取一个任务，确立参与线程数为 2，从而降低分发阈值 (10/2 + 1 = 6)
        _ = await queue.getNextTask(threadId: 2) // t2: 1
        
        // 模拟线程 1 取走了大部分任务
        for _ in 0..<8 {
            _ = await queue.getNextTask(threadId: 1)
        }
        // t1: 8, t2: 1. 剩余 1 个由 t2 取走
        _ = await queue.getNextTask(threadId: 2) // t2: 2
        
        let stats = await queue.getStatistics()
        #expect(stats.distribution[1] == 8)
        #expect(stats.distribution[2] == 2)
        #expect(stats.stealCount > 0, "线程 1 取走了 8/10，在已知 2 个线程的情况下应触发窃取计数 (8 > 6)")
    }
}
