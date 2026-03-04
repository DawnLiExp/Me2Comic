//
//  ParametersValidatorTests.swift
//  Me2ComicTests
//
//  P0 Pure function tests for ProcessingParametersValidator
//

import Testing
import Foundation
@testable import Me2Comic

@Suite("参数校验器单元测试")
struct ParametersValidatorTests {

    // Helper URLs
    let validInDir = URL(fileURLWithPath: "/tmp/in")
    let validOutDir = URL(fileURLWithPath: "/tmp/out")

    @Test("校验缺失的输入或输出目录")
    func testMissingDirectories() throws {
        #expect(throws: ProcessingParameterError.noInputOrOutputDirectory) {
            _ = try ProcessingParametersValidator.validateAndCreateParameters(
                inputDirectory: nil,
                outputDirectory: validOutDir,
                widthThreshold: "100",
                resizeHeight: "100",
                quality: "80",
                threadCount: 2,
                unsharpRadius: "1",
                unsharpSigma: "1",
                unsharpAmount: "1",
                unsharpThreshold: "0.05",
                batchSize: "10",
                useGrayColorspace: false
            )
        }

        #expect(throws: ProcessingParameterError.noInputOrOutputDirectory) {
            _ = try ProcessingParametersValidator.validateAndCreateParameters(
                inputDirectory: validInDir,
                outputDirectory: nil,
                widthThreshold: "100",
                resizeHeight: "100",
                quality: "80",
                threadCount: 2,
                unsharpRadius: "1",
                unsharpSigma: "1",
                unsharpAmount: "1",
                unsharpThreshold: "0.05",
                batchSize: "10",
                useGrayColorspace: false
            )
        }

        #expect(throws: Never.self) {
            _ = try ProcessingParametersValidator.validateAndCreateParameters(
                inputDirectory: validInDir,
                outputDirectory: validOutDir,
                widthThreshold: "100",
                resizeHeight: "100",
                quality: "80",
                threadCount: 2,
                unsharpRadius: "1",
                unsharpSigma: "1",
                unsharpAmount: "1",
                unsharpThreshold: "0.05",
                batchSize: "10",
                useGrayColorspace: false
            )
        }
    }

    @Test("校验 widthThreshold 参数", arguments: [
        ("0", true),
        ("-1", true),
        ("abc", true),
        ("1", false),
        ("2000", false)
    ])
    func testWidthThreshold(value: String, expectsError: Bool) throws {
        if expectsError {
            #expect(throws: ProcessingParameterError.invalidWidthThreshold) {
                _ = try callValidator(widthThreshold: value)
            }
        } else {
            let params = try callValidator(widthThreshold: value)
            #expect(params.widthThreshold == Int(value)!)
        }
    }

    @Test("校验 resizeHeight 参数", arguments: [
        ("0", true),
        ("-1", true),
        ("abc", true),
        ("1", false),
        ("2000", false)
    ])
    func testResizeHeight(value: String, expectsError: Bool) throws {
        if expectsError {
            #expect(throws: ProcessingParameterError.invalidResizeHeight) {
                _ = try callValidator(resizeHeight: value)
            }
        } else {
            let params = try callValidator(resizeHeight: value)
            #expect(params.resizeHeight == Int(value)!)
        }
    }

    @Test("校验 quality 参数", arguments: [
        ("0", true),
        ("101", true),
        ("abc", true),
        ("1", false),
        ("100", false)
    ])
    func testQuality(value: String, expectsError: Bool) throws {
        if expectsError {
            #expect(throws: ProcessingParameterError.invalidQuality) {
                _ = try callValidator(quality: value)
            }
        } else {
            let params = try callValidator(quality: value)
            #expect(params.quality == Int(value)!)
        }
    }

    @Test("校验 batchSize 参数", arguments: [
        ("0", true),
        ("1001", true),
        ("abc", true),
        ("1", false),
        ("1000", false)
    ])
    func testBatchSize(value: String, expectsError: Bool) throws {
        if expectsError {
            #expect(throws: ProcessingParameterError.invalidBatchSize) {
                _ = try callValidator(batchSize: value)
            }
        } else {
            let params = try callValidator(batchSize: value)
            #expect(params.batchSize == Int(value)!)
        }
    }

    @Test("校验锐化参数", arguments: [
        ("-1", "1", "1", "0.05", true),
        ("1", "-1", "1", "0.05", true),
        ("1", "1", "-1", "0.05", true),
        ("1", "1", "1", "-0.05", true),
        ("0", "0", "0", "0", false),
        ("abc", "1", "1", "0.05", true)
    ])
    func testUnsharpParameters(r: String, s: String, a: String, t: String, expectsError: Bool) throws {
        if expectsError {
            #expect(throws: ProcessingParameterError.invalidUnsharpParameters) {
                _ = try callValidator(unsharpRadius: r, unsharpSigma: s, unsharpAmount: a, unsharpThreshold: t)
            }
        } else {
            let params = try callValidator(unsharpRadius: r, unsharpSigma: s, unsharpAmount: a, unsharpThreshold: t)
            #expect(params.unsharpRadius == Float(r)!)
            #expect(params.unsharpSigma == Float(s)!)
            #expect(params.unsharpAmount == Float(a)!)
            #expect(params.unsharpThreshold == Float(t)!)
        }
    }

    @Test("完整成功路径校验")
    func testComprehensiveSuccess() throws {
        let params = try ProcessingParametersValidator.validateAndCreateParameters(
            inputDirectory: validInDir,
            outputDirectory: validOutDir,
            widthThreshold: "2000",
            resizeHeight: "3000",
            quality: "85",
            threadCount: 4,
            unsharpRadius: "0.5",
            unsharpSigma: "1.0",
            unsharpAmount: "1.5",
            unsharpThreshold: "0.05",
            batchSize: "50",
            useGrayColorspace: true
        )

        #expect(params.widthThreshold == 2000)
        #expect(params.resizeHeight == 3000)
        #expect(params.quality == 85)
        #expect(params.threadCount == 4)
        #expect(params.unsharpRadius == 0.5)
        #expect(params.unsharpSigma == 1.0)
        #expect(params.unsharpAmount == 1.5)
        #expect(params.unsharpThreshold == 0.05)
        #expect(params.batchSize == 50)
        #expect(params.useGrayColorspace == true)
    }

    // Helper function to provide default valid values
    private func callValidator(
        widthThreshold: String = "2000",
        resizeHeight: String = "3000",
        quality: String = "85",
        unsharpRadius: String = "0.5",
        unsharpSigma: String = "1.0",
        unsharpAmount: String = "1.5",
        unsharpThreshold: String = "0.05",
        batchSize: String = "50"
    ) throws -> ProcessingParameters {
        try ProcessingParametersValidator.validateAndCreateParameters(
            inputDirectory: validInDir,
            outputDirectory: validOutDir,
            widthThreshold: widthThreshold,
            resizeHeight: resizeHeight,
            quality: quality,
            threadCount: 4,
            unsharpRadius: unsharpRadius,
            unsharpSigma: unsharpSigma,
            unsharpAmount: unsharpAmount,
            unsharpThreshold: unsharpThreshold,
            batchSize: batchSize,
            useGrayColorspace: false
        )
    }
}
