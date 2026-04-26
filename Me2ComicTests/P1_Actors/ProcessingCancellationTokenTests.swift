//
//  ProcessingCancellationTokenTests.swift
//  Me2ComicTests
//
//  P1 Actor concurrency tests for ProcessingCancellationToken
//

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
}
