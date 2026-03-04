//
//  GraphicsMagickHelperTests.swift
//  Me2ComicTests
//
//  P0 Pure function tests for GraphicsMagickHelper
//

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
