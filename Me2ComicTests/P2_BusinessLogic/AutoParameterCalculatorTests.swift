//
//  AutoParameterCalculatorTests.swift
//  Me2ComicTests
//
//  P2 Business logic tests for AutoParameterCalculator
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("AutoParameterCalculator 自动参数计算测试")
@MainActor
struct AutoParameterCalculatorTests {

    // 辅助参数工厂
    private func createParams(threadCount: Int = 0, batchSize: Int = 40) -> ProcessingParameters {
        ProcessingParameters(
            widthThreshold: 2000,
            resizeHeight: 3000,
            quality: 85,
            threadCount: threadCount,
            unsharpRadius: 0,
            unsharpSigma: 0,
            unsharpAmount: 0,
            unsharpThreshold: 0,
            batchSize: batchSize,
            useGrayColorspace: false
        )
    }

    @Test("手动模式下应直接返回预设参数")
    func testManualMode() {
        let mockLogger = MockProcessingLogger()
        let calculator = AutoParameterCalculator(logger: mockLogger)
        
        // 当 threadCount 不为 0 时，视为手动模式
        let manualParams = createParams(threadCount: 4, batchSize: 20)
        let result = calculator.determineParameters(parameters: manualParams, totalImages: 100)
        
        #expect(result.threadCount == 4)
        #expect(result.batchSize == 20)
    }

    @Test("自动模式：验证图片数量阈值分配策略")
    func testAutoModeThresholds() {
        let mockLogger = MockProcessingLogger()
        let calculator = AutoParameterCalculator(logger: mockLogger)
        let autoParams = createParams(threadCount: 0)
        
        // 用例 1: < 10 张大体量的图片，只分 1 线程
        let res1 = calculator.determineParameters(parameters: autoParams, totalImages: 5)
        #expect(res1.threadCount == 1)
        
        // 用例 2: 10-49 逐渐增加
        let res2 = calculator.determineParameters(parameters: autoParams, totalImages: 10)
        #expect(res2.threadCount >= 1)
        
        let res3 = calculator.determineParameters(parameters: autoParams, totalImages: 30)
        #expect(res3.threadCount <= 3) // 根据内部公式 min(3, 1 + Int(ceil(Double(totalImages - 10) / 20.0)))
        
        // 用例 3: 50-299 继续增加
        let res4 = calculator.determineParameters(parameters: autoParams, totalImages: 50)
        #expect(res4.threadCount >= 3)
        
        // 用例 4: >= 300 极多图片，分满最大可用核心 (在不同机器上不同，但一定会是最大值)
        let maxThreads = SystemInfoHelper.getMaxThreadCount()
        let res5 = calculator.determineParameters(parameters: autoParams, totalImages: 300)
        #expect(res5.threadCount == maxThreads)
    }

    @Test("自动模式：高分辨率应触发激进并发优化")
    func testHighResolutionOptimization() {
        let mockLogger = MockProcessingLogger()
        let calculator = AutoParameterCalculator(logger: mockLogger)
        let autoParams = createParams(threadCount: 0)
        let maxThreads = SystemInfoHelper.getMaxThreadCount()
        
        // 有高分 && 张数 >= 10 -> 直接满核并计算相应 batch
        let res1 = calculator.determineParameters(parameters: autoParams, totalImages: 15, hasHighResolution: true)
        #expect(res1.threadCount == maxThreads)
        
        // 有高分 但 张数 < 10 -> 不触发高分优化，退回正常的数量型策略
        let res2 = calculator.determineParameters(parameters: autoParams, totalImages: 5, hasHighResolution: true)
        #expect(res2.threadCount == 1)
    }

    @Test("自动模式：计算得出的批大小应符合边界规范")
    func testBatchSizeBoundaries() {
        let mockLogger = MockProcessingLogger()
        let calculator = AutoParameterCalculator(logger: mockLogger)
        let autoParams = createParams(threadCount: 0)
        
        // 测试下界 (极少任务也不应挂起，至少为 1)
        let res1 = calculator.determineParameters(parameters: autoParams, totalImages: 1)
        #expect(res1.batchSize >= 1)
        
        // 测试上限 (即使超过成千上万任务，批大小也不会无尽膨胀或小于 1)
        let res2 = calculator.determineParameters(parameters: autoParams, totalImages: 5000)
        #expect(res2.batchSize >= 1)
        // AutoParameterCalculator.Constants.maxBatchSize 为 1000
        #expect(res2.batchSize <= 1000)
    }
}
