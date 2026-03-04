//
//  GMCommandBuilderTests.swift
//  Me2ComicTests
//
//  P0 Pure function tests for GMCommandBuilder
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("GMCommandBuilder 单元测试")
struct GMCommandBuilderTests {

    @Test("analyzeDuplicateBaseNames 正确识别重名文件")
    func testAnalyzeDuplicateBaseNames() {
        let builder = GMCommandBuilder(
            widthThreshold: 2000,
            resizeHeight: 3000,
            quality: 85,
            unsharpRadius: 0,
            unsharpSigma: 0,
            unsharpAmount: 0,
            unsharpThreshold: 0,
            useGrayColorspace: false
        )

        // Empty array
        #expect(builder.analyzeDuplicateBaseNames(images: []).isEmpty)

        // No duplicates
        let noDups = [
            URL(fileURLWithPath: "/a/Image1.jpg"),
            URL(fileURLWithPath: "/a/Image2.png")
        ]
        #expect(builder.analyzeDuplicateBaseNames(images: noDups).isEmpty)

        // Same base name, different extension
        let exactDups = [
            URL(fileURLWithPath: "/a/Image.jpg"),
            URL(fileURLWithPath: "/b/Image.png")
        ]
        #expect(builder.analyzeDuplicateBaseNames(images: exactDups) == ["image"])

        // Case insensitivity
        let caseInsensitiveDups = [
            URL(fileURLWithPath: "/a/Image.JPG"),
            URL(fileURLWithPath: "/a/image.png")
        ]
        #expect(builder.analyzeDuplicateBaseNames(images: caseInsensitiveDups) == ["image"])

        // Mixed duplicates
        let mixed = [
            URL(fileURLWithPath: "/a/test1.jpg"),
            URL(fileURLWithPath: "/b/test1.png"),
            URL(fileURLWithPath: "/c/test2.jpg")
        ]
        #expect(builder.analyzeDuplicateBaseNames(images: mixed) == ["test1"])
    }

    @Test("buildProcessingCommands 正确生成单图和切图命令")
    func testBuildProcessingCommands() async throws {
        let builder = GMCommandBuilder(
            widthThreshold: 2000,
            resizeHeight: 3000,
            quality: 85,
            unsharpRadius: 0,
            unsharpSigma: 0,
            unsharpAmount: 0,
            unsharpThreshold: 0,
            useGrayColorspace: false
        )

        let pathManager = PathCollisionManager()
        let outputDir = URL(fileURLWithPath: "/tmp/out")
        let duplicates: Set<String> = []

        // width < widthThreshold -> Single image
        let singleCmds = await builder.buildProcessingCommands(
            for: URL(fileURLWithPath: "/tmp/in/test1.jpg"),
            dimensions: (1000, 1500),
            outputDir: outputDir,
            pathManager: pathManager,
            duplicateBaseNames: duplicates
        )
        
        #expect(singleCmds.count == 1)
        #expect(!singleCmds[0].contains("-crop"))

        // width >= widthThreshold -> Split image
        let splitCmds = await builder.buildProcessingCommands(
            for: URL(fileURLWithPath: "/tmp/in/test2.jpg"),
            dimensions: (2001, 1500),
            outputDir: outputDir,
            pathManager: pathManager,
            duplicateBaseNames: duplicates
        )
        
        #expect(splitCmds.count == 2)
        
        // Left width = (2001 + 1) / 2 = 1001
        // Right width = 2001 - 1001 = 1000
        // Command 0 is right half: cropParams contain "+1001+0"
        #expect(splitCmds[0].contains("-crop 1000x1500+1001+0"))
        // Command 1 is left half: cropParams contain "+0+0"
        #expect(splitCmds[1].contains("-crop 1001x1500+0+0"))
    }
}
