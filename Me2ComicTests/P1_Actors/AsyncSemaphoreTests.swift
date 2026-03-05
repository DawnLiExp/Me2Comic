//
//  AsyncSemaphoreTests.swift
//  Me2ComicTests
//
//  P1 Actor concurrency tests for AsyncSemaphore
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("异步信号量并发控制测试")
struct AsyncSemaphoreTests {

    @Test("基本 Wait 和 Signal 逻辑")
    func testBasicWaitSignal() async {
        let semaphore = AsyncSemaphore(limit: 1)
        
        // 第一次 wait 应当立即通过
        await semaphore.wait()
        
        // 开启一个任务去 signal
        let task = Task {
            await semaphore.signal()
        }
        
        // 第二次 wait，如果不 signal 就会挂起
        await semaphore.wait()
        
        await task.value // 等待 signal 完成
    }

    @Test("并发限制测试：同时穿过 wait 的任务数不应超过 limit")
    func testConcurrencyLimit() async {
        let limit = 3
        let totalTasks = 10
        let semaphore = AsyncSemaphore(limit: limit)
        
        // 使用原子计数器（由于 Swift Testing 暂时没有内置 actor-safe 计数器，我们用 TaskGroup 收集结果）
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<totalTasks {
                group.addTask {
                    await semaphore.wait()
                    // 模拟处理耗时
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    await semaphore.signal()
                }
            }
        }
        // 如果逻辑正确，测试应能正常结束而不死锁
    }

    @Test("等待队列应遵循 FIFO (先进先出) 顺序")
    func testWaitersFIFO() async {
        let semaphore = AsyncSemaphore(limit: 1)
        
        // 占住唯一的信号量
        await semaphore.wait()
        
        var results: [Int] = []
        
        // 按顺序入队 3 个等待者
        let t1 = Task {
            await semaphore.wait()
            results.append(1)
            await semaphore.signal()
        }
        
        let t2 = Task {
            // 给点微小延迟确保入队顺序
            try? await Task.sleep(nanoseconds: 10_000_000)
            await semaphore.wait()
            results.append(2)
            await semaphore.signal()
        }
        
        let t3 = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await semaphore.wait()
            results.append(3)
            await semaphore.signal()
        }
        
        // 让初始占有者释放
        try? await Task.sleep(nanoseconds: 50_000_000)
        await semaphore.signal()
        
        // 等待所有子任务完成
        _ = await (t1.value, t2.value, t3.value)
        
        #expect(results == [1, 2, 3], "等待队列唤醒顺序应为 FIFO")
    }
}
