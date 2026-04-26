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
