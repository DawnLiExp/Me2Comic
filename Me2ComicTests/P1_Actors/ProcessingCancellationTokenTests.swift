//
//  ProcessingCancellationTokenTests.swift
//  Me2ComicTests
//
//  P1 Actor concurrency tests for ProcessingCancellationToken
//

import Foundation
import Testing
@testable import Me2Comic

@Suite("处理取消令牌测试")
struct ProcessingCancellationTokenTests {
    @Test("初始状态应允许继续")
    func initialStateAllowsContinuation() async {
        let token = ProcessingCancellationToken()

        let canContinue = await token.canContinue()

        #expect(canContinue)
    }

    @Test("取消后应停止继续")
    func cancellationStopsContinuation() async {
        let token = ProcessingCancellationToken()

        await token.cancel()
        let canContinue = await token.canContinue()

        #expect(!canContinue)
    }

    @Test("并发取消后应稳定停止继续")
    func concurrentCancellationStopsContinuation() async {
        let token = ProcessingCancellationToken()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await token.cancel()
                }
            }
        }

        let canContinue = await token.canContinue()

        #expect(!canContinue)
    }

    @Test("批处理取消检查失败时应提前停止")
    func batchProcessorStopsWhenCancellationCheckFails() async {
        let processor = BatchImageProcessor(
            gmPath: "/path/does/not/exist/gm",
            widthThreshold: 3000,
            resizeHeight: 1648,
            quality: 85,
            unsharpRadius: 1.5,
            unsharpSigma: 1,
            unsharpAmount: 0.7,
            unsharpThreshold: 0.02,
            useGrayColorspace: true,
            cancellationCheck: { false }
        )
        let image = URL(fileURLWithPath: "/tmp/cancelled-test-image.jpg")

        let result = await processor.processBatch(
            images: [image],
            outputDir: URL(fileURLWithPath: "/tmp/out"),
            duplicateBaseNames: []
        )

        #expect(result.processed == 0)
        #expect(result.failed == ["cancelled-test-image.jpg"])
    }
}

@Suite("子进程退出与取消")
struct ManagedChildProcessTests {
    private func child(_ script: String, grace: Duration = .seconds(3)) -> ManagedChildProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return ManagedChildProcess(process: process, gracePeriod: grace)
    }

    @Test("快速退出在登记等待前完成也不会丢失通知")
    func immediateExit() async throws {
        for _ in 0..<20 {
            let child = child("exit 0")
            try child.start()
            #expect(await child.waitForExit() == 0)
            #expect(await child.waitForExit() == 0)
        }
    }

    @Test("取消前尚未启动的子进程不再启动")
    func cancelledBeforeStart() {
        let child = child("exit 0")
        child.cancel()
        #expect(throws: CancellationError.self) { try child.start() }
    }

    @Test("重复取消仍等待正常回收")
    func repeatedCancellation() async throws {
        let child = child("exec /bin/sleep 30")
        try child.start()
        child.cancel()
        child.cancel()
        _ = await child.waitForExit()
        #expect(!child.process.isRunning)
    }

    @Test("忽略 TERM 的子进程超时后回收")
    func escalatedCancellation() async throws {
        let child = child("trap '' TERM; printf ready; exec /bin/sleep 30", grace: .milliseconds(100))
        let ready = Pipe()
        child.process.standardOutput = ready
        try child.start()
        let data = try await Task.detached { try ready.fileHandleForReading.read(upToCount: 5) }.value
        #expect(data == Data("ready".utf8))
        child.cancel()
        #expect(await child.waitForExit() == 9)
        #expect(!child.process.isRunning)
    }
}
