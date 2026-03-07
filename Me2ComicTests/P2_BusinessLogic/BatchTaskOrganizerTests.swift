//
//  BatchTaskOrganizerTests.swift
//  Me2ComicTests
//
//  P2 Business logic tests for BatchTaskOrganizer
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("BatchTaskOrganizer 批任务组织边界测试")
@MainActor
struct BatchTaskOrganizerTests {

    @Test("对空数组的拆分应安全返回空批次")
    func testSplitEmptyArray() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)
        
        let emptyUrls: [URL] = []
        let batches = organizer.splitIntoBatches(emptyUrls, batchSize: 3)
        
        #expect(batches.isEmpty)
    }

    @Test("非法 batchSize (0或负数) 应返回空批次进行防崩溃保护")
    func testSplitInvalidBatchSize() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)
        
        let urls = (0..<5).map { URL(fileURLWithPath: "/tmp/img\($0).jpg") }
        
        let batchesZero = organizer.splitIntoBatches(urls, batchSize: 0)
        #expect(batchesZero.isEmpty)
        
        let batchesNeg = organizer.splitIntoBatches(urls, batchSize: -1)
        #expect(batchesNeg.isEmpty)
    }

    @Test("数量超出导致部分切割 (例如10个每批3个，切出4批：3,3,3,1)")
    func testSplitPartialBoundaries() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)
        
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/img\($0).jpg") }
        
        let batches = organizer.splitIntoBatches(urls, batchSize: 3)
        // 10 能够被拆分成 3, 3, 3, 1 -> 总共 4 批
        #expect(batches.count == 4)
        
        #expect(batches[0].count == 3)
        #expect(batches[1].count == 3)
        #expect(batches[2].count == 3)
        #expect(batches[3].count == 1)
        
        // 保证总元素完整不丢，顺序也没错
        let flatBatches = batches.flatMap { $0 }
        #expect(flatBatches == urls)
    }

    @Test("完美切割 (例如10个每批10个，或者10个每批5个，不能出现多余空批次)")
    func testSplitExactBoundaries() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)
        
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/img\($0).jpg") }
        
        // 分成一批 10
        let batches10 = organizer.splitIntoBatches(urls, batchSize: 10)
        #expect(batches10.count == 1)
        #expect(batches10[0].count == 10)
        
        // 分成两批，每批 5
        let batches5 = organizer.splitIntoBatches(urls, batchSize: 5)
        #expect(batches5.count == 2)
        #expect(batches5[0].count == 5)
        #expect(batches5[1].count == 5)
    }

    @Test("溢出切割 (例如10个每批15个，安全容错为1批)")
    func testSplitOverflowBoundaries() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)
        
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/img\($0).jpg") }
        
        let batches = organizer.splitIntoBatches(urls, batchSize: 15)
        #expect(batches.count == 1)
        #expect(batches[0].count == 10)
    }

    // MARK: - 重名文件预计算测试

    @Test("单目录同名文件(不同扩展名)：所有 batch 的 duplicateBaseNames 均应包含重名项")
    func testDuplicateBaseNamesPropagatedAcrossBatches() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)

        let images = [
            URL(fileURLWithPath: "/dir/cover.jpg"),
            URL(fileURLWithPath: "/dir/cover.png"),
            URL(fileURLWithPath: "/dir/cover.webp")
        ]
        let scanResult = DirectoryScanResult(
            directoryURL: URL(fileURLWithPath: "/dir"),
            imageFiles: images,
            category: .isolated,
            isHighResolution: false
        )
        // batchSize=1 强制每张独立一个 batch，模拟最极端的跨 batch 场景
        let params = ProcessingParameters(
            widthThreshold: 3000, resizeHeight: 1800, quality: 85,
            threadCount: 1,
            unsharpRadius: 0, unsharpSigma: 0, unsharpAmount: 0, unsharpThreshold: 0,
            batchSize: 1,
            useGrayColorspace: false
        )

        let tasks = organizer.prepareBatchTasks(
            scanResults: [scanResult],
            globalBatchImages: [],
            outputDir: URL(fileURLWithPath: "/output"),
            parameters: params,
            effectiveThreadCount: 1,
            effectiveBatchSize: 1
        )

        // 3 images × batchSize 1 → 3 tasks，每个 task 都应携带完整的目录级重名集合
        #expect(tasks.count == 3)
        for task in tasks {
            #expect(task.duplicateBaseNames.contains("cover"),
                    "每个 batch 的 duplicateBaseNames 必须包含 'cover'，不应因 batch 切分而丢失")
        }
    }

    @Test("无重名文件：duplicateBaseNames 应为空集合")
    func testNoDuplicatesWithUniqueNames() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)

        let images = [
            URL(fileURLWithPath: "/dir/img1.jpg"),
            URL(fileURLWithPath: "/dir/img2.png"),
            URL(fileURLWithPath: "/dir/img3.webp")
        ]
        let scanResult = DirectoryScanResult(
            directoryURL: URL(fileURLWithPath: "/dir"),
            imageFiles: images,
            category: .isolated,
            isHighResolution: false
        )
        let params = ProcessingParameters(
            widthThreshold: 3000, resizeHeight: 1800, quality: 85,
            threadCount: 1,
            unsharpRadius: 0, unsharpSigma: 0, unsharpAmount: 0, unsharpThreshold: 0,
            batchSize: 10,
            useGrayColorspace: false
        )

        let tasks = organizer.prepareBatchTasks(
            scanResults: [scanResult],
            globalBatchImages: [],
            outputDir: URL(fileURLWithPath: "/output"),
            parameters: params,
            effectiveThreadCount: 1,
            effectiveBatchSize: 10
        )

        #expect(tasks.count == 1)
        #expect(tasks[0].duplicateBaseNames.isEmpty)
    }

    @Test("大小写不敏感：cover.jpg 与 cover.JPG 应被识别为重名")
    func testDuplicateDetectionIsCaseInsensitive() {
        let logger = MockProcessingLogger()
        let organizer = BatchTaskOrganizer(logger: logger)

        let images = [
            URL(fileURLWithPath: "/dir/cover.jpg"),
            URL(fileURLWithPath: "/dir/cover.JPG")   // 大写扩展名 → 同 base name
        ]
        let scanResult = DirectoryScanResult(
            directoryURL: URL(fileURLWithPath: "/dir"),
            imageFiles: images,
            category: .isolated,
            isHighResolution: false
        )
        let params = ProcessingParameters(
            widthThreshold: 3000, resizeHeight: 1800, quality: 85,
            threadCount: 1,
            unsharpRadius: 0, unsharpSigma: 0, unsharpAmount: 0, unsharpThreshold: 0,
            batchSize: 10,
            useGrayColorspace: false
        )

        let tasks = organizer.prepareBatchTasks(
            scanResults: [scanResult],
            globalBatchImages: [],
            outputDir: URL(fileURLWithPath: "/output"),
            parameters: params,
            effectiveThreadCount: 1,
            effectiveBatchSize: 10
        )

        #expect(tasks.count == 1)
        #expect(tasks[0].duplicateBaseNames.contains("cover"))
    }
}
