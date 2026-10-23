//
//  GraphicsMagickHelperTests.swift
//  Me2ComicTests
//
//  P0 Pure function tests for GraphicsMagickHelper
//

import Foundation
import Testing
@testable import Me2Comic

@Suite("GraphicsMagickHelper 单元测试")
struct GraphicsMagickHelperTests {

    @Test("escapePathForShell 正确转义 Shell 路径")
    func testEscapePathForShell() {
        // 普通路径
        #expect(GraphicsMagickHelper.escapePathForShell("/tmp/file.jpg") == "'/tmp/file.jpg'")
        // 含空格路径
        #expect(GraphicsMagickHelper.escapePathForShell("/tmp/my file.jpg") == "'/tmp/my file.jpg'")
        // 含单引号路径
        #expect(GraphicsMagickHelper.escapePathForShell("/tmp/it's.jpg") == "'/tmp/it'\\''s.jpg'")
        // 含双引号路径
        #expect(GraphicsMagickHelper.escapePathForShell("/tmp/test\"file.jpg") == "'/tmp/test\"file.jpg'")
    }

    @Test("buildConvertCommand 构建不含切图参数的命令")
    func testBuildConvertCommandNoCrop() {
        let cmd = GraphicsMagickHelper.buildConvertCommand(
            inputPath: "/tmp/in.jpg",
            outputPath: "/tmp/out.jpg",
            cropParams: nil,
            resizeHeight: 2000,
            quality: 85,
            unsharpRadius: 1.0,
            unsharpSigma: 1.0,
            unsharpAmount: 0.0,
            unsharpThreshold: 0.0,
            useGrayColorspace: false
        )

        #expect(cmd.hasPrefix("convert "))
        #expect(cmd.contains("'/tmp/in.jpg'"))
        #expect(cmd.hasSuffix("'/tmp/out.jpg'"))
        #expect(!cmd.contains("-crop"))
        #expect(cmd.contains("-resize x2000"))
        #expect(cmd.contains("-quality 85"))
        #expect(!cmd.contains("-colorspace GRAY"))
        #expect(!cmd.contains("-unsharp"))
    }

    @Test("buildConvertCommand 构建包含切图和所有功能的命令")
    func testBuildConvertCommandWithFeatures() {
        let cmd = GraphicsMagickHelper.buildConvertCommand(
            inputPath: "/tmp/my file.jpg",
            outputPath: "/tmp/out's.jpg",
            cropParams: "800x1200+0+0",
            resizeHeight: 2500,
            quality: 90,
            unsharpRadius: 1.0,
            unsharpSigma: 1.2,
            unsharpAmount: 1.5,
            unsharpThreshold: 0.05,
            useGrayColorspace: true
        )

        #expect(cmd.contains("-crop 800x1200+0+0"))
        #expect(cmd.contains("-colorspace GRAY"))
        #expect(cmd.contains("-unsharp 1.0x1.2+1.5+0.05"))
        #expect(cmd.contains("'/tmp/my file.jpg'"))
        #expect(cmd.contains("'/tmp/out'\\''s.jpg'"))
    }
}

private actor DetectionGate {
    private var requests: [Int: CheckedContinuation<Result<String, ProcessingError>, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var calls = 0

    func detect() async -> Result<String, ProcessingError> {
        calls += 1
        let index = calls
        return await withCheckedContinuation { continuation in
            requests[index] = continuation
            let ready = observers.filter { $0.0 <= calls }
            observers.removeAll { $0.0 <= calls }
            for item in ready { item.1.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func finish(_ index: Int, result: Result<String, ProcessingError>) {
        requests.removeValue(forKey: index)?.resume(returning: result)
    }
}

@Suite("GraphicsMagick 界面检测状态")
@MainActor
struct GraphicsMagickStatusTests {
    @Test("重复检测合并，失败后可以重新检测")
    func retry() async {
        let gate = DetectionGate()
        let processor = ImageProcessor(stateManager: ProcessingStateManager(), logger: ProcessingLogger(), detector: { await gate.detect() })
        processor.retryGraphicsMagickDetection()
        await gate.waitForCalls(1)
        #expect(processor.gmStatus.isChecking)
        #expect(await gate.calls == 1)
        await gate.finish(1, result: .failure(.graphicsMagickNotFound))
        await processor.waitForDetection()
        if case .failed = processor.gmStatus {} else { Issue.record("Expected failure") }
        processor.retryGraphicsMagickDetection()
        await gate.waitForCalls(2)
        await gate.finish(2, result: .success("/fixture/gm"))
        await processor.waitForDetection()
        if case .ready(let path) = processor.gmStatus { #expect(path == "/fixture/gm") }
        else { Issue.record("Expected ready") }
    }

    @Test("已取消检测的旧结果不会覆盖新请求")
    func obsoleteResult() async {
        let gate = DetectionGate()
        let processor = ImageProcessor(stateManager: ProcessingStateManager(), logger: ProcessingLogger(), detector: { await gate.detect() })
        await gate.waitForCalls(1)
        let previous = processor.cancelDetection()
        processor.retryGraphicsMagickDetection()
        await gate.waitForCalls(2)
        await gate.finish(2, result: .success("/new/gm"))
        await processor.waitForDetection()
        await gate.finish(1, result: .failure(.graphicsMagickNotFound))
        // The old callback must pass its request identity check before any state write.
        await previous?.value
        if case .ready(let path) = processor.gmStatus { #expect(path == "/new/gm") }
        else { Issue.record("Obsolete request overwrote current state") }
    }
}

@Suite("依赖检测子进程回收")
struct GraphicsMagickProbeTests {
    @Test("检测同时排空输出，保留失败退出码", .timeLimit(.minutes(1)))
    func outputAndFailure() async throws {
        let verbose = try await GraphicsMagickHelper.runProbe(executable: "/usr/bin/head", arguments: ["-c", "131072", "/dev/zero"])
        #expect(verbose.status == 0 && verbose.output.utf8.count == 131072)
        let failure = try await GraphicsMagickHelper.runProbe(executable: "/bin/sh", arguments: ["-c", "echo fixture-error; exit 7"])
        #expect(failure.status == 7 && failure.output.contains("fixture-error"))
    }

    @Test("取消检测等待子进程退出", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let task = Task { try await GraphicsMagickHelper.runProbe(executable: "/bin/sleep", arguments: ["20"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
