//
//  ParametersValidator.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/7.
//

import Foundation

/// Defines validation errors for processing parameters.
enum ProcessingParameterError: LocalizedError {
    case invalidWidthThreshold
    case invalidResizeHeight
    case invalidQuality
    case invalidUnsharpParameters
    case invalidBatchSize
    case noInputOrOutputDirectory

    var errorDescription: String? {
        switch self {
        case .invalidWidthThreshold:
            return String(localized: "InvalidWidthThreshold")
        case .invalidResizeHeight:
            return String(localized: "InvalidResizeHeight")
        case .invalidQuality:
            return String(localized: "InvalidOutputQuality")
        case .invalidUnsharpParameters:
            return String(localized: "InvalidUnsharpParameters")
        case .invalidBatchSize:
            return String(localized: "InvalidBatchSize")
        case .noInputOrOutputDirectory:
            return String(localized: "NoInputOrOutputDir")
        }
    }
}

enum ParameterField: String, CaseIterable, Identifiable {
    case inputDirectory, outputDirectory, widthThreshold, resizeHeight, quality
    case unsharpRadius, unsharpSigma, unsharpAmount, unsharpThreshold, batchSize
    var id: String { rawValue }
    var tab: String {
        switch self {
        case .unsharpRadius, .unsharpSigma, .unsharpAmount, .unsharpThreshold, .batchSize: "advanced"
        default: "basic"
        }
    }
}

struct ParameterIssue: Identifiable {
    let field: ParameterField
    let error: ProcessingParameterError
    var id: ParameterField { field }
    var message: String { error.localizedDescription }
}

struct ParameterValidationReport {
    let parameters: ProcessingParameters?
    let issues: [ParameterIssue]
}

struct ParameterFocusRequest: Equatable {
    let field: ParameterField
    let id = UUID()
}

enum ProcessingParametersValidator {
    static func evaluate(
        inputDirectory: URL?, outputDirectory: URL?,
        widthThreshold: String, resizeHeight: String, quality: String, threadCount: Int,
        unsharpRadius: String, unsharpSigma: String, unsharpAmount: String, unsharpThreshold: String,
        batchSize: String, useGrayColorspace: Bool, enableUnsharp: Bool = true
    ) -> ParameterValidationReport {
        var issues: [ParameterIssue] = []
        if inputDirectory == nil { issues.append(.init(field: .inputDirectory, error: .noInputOrOutputDirectory)) }
        if outputDirectory == nil { issues.append(.init(field: .outputDirectory, error: .noInputOrOutputDirectory)) }
        func integer(_ text: String, field: ParameterField, range: ClosedRange<Int>, error: ProcessingParameterError) -> Int {
            guard let value = Int(text), range.contains(value) else {
                issues.append(.init(field: field, error: error))
                return 0
            }
            return value
        }
        func decimal(_ text: String, field: ParameterField) -> Float {
            guard let value = Float(text), value.isFinite, value >= 0 else {
                issues.append(.init(field: field, error: .invalidUnsharpParameters))
                return 0
            }
            return value
        }
        let width = integer(widthThreshold, field: .widthThreshold, range: 1...Int.max, error: .invalidWidthThreshold)
        let height = integer(resizeHeight, field: .resizeHeight, range: 1...Int.max, error: .invalidResizeHeight)
        let outputQuality = integer(quality, field: .quality, range: 1...100, error: .invalidQuality)
        let radius: Float = enableUnsharp ? decimal(unsharpRadius, field: .unsharpRadius) : 0
        let sigma: Float = enableUnsharp ? decimal(unsharpSigma, field: .unsharpSigma) : 0
        let amount: Float = enableUnsharp ? decimal(unsharpAmount, field: .unsharpAmount) : 0
        let threshold: Float = enableUnsharp ? decimal(unsharpThreshold, field: .unsharpThreshold) : 0
        let batch = threadCount == 0 ? 40 : integer(batchSize, field: .batchSize, range: 1...1000, error: .invalidBatchSize)
        guard issues.isEmpty else { return .init(parameters: nil, issues: issues) }
        return .init(parameters: ProcessingParameters(
            widthThreshold: width, resizeHeight: height, quality: outputQuality, threadCount: threadCount,
            unsharpRadius: radius, unsharpSigma: sigma, unsharpAmount: amount, unsharpThreshold: threshold,
            batchSize: batch, useGrayColorspace: useGrayColorspace
        ), issues: [])
    }

    static func validateAndCreateParameters(
        inputDirectory: URL?, outputDirectory: URL?,
        widthThreshold: String, resizeHeight: String, quality: String, threadCount: Int,
        unsharpRadius: String, unsharpSigma: String, unsharpAmount: String, unsharpThreshold: String,
        batchSize: String, useGrayColorspace: Bool, enableUnsharp: Bool = true
    ) throws -> ProcessingParameters {
        let report = evaluate(
            inputDirectory: inputDirectory, outputDirectory: outputDirectory,
            widthThreshold: widthThreshold, resizeHeight: resizeHeight, quality: quality, threadCount: threadCount,
            unsharpRadius: unsharpRadius, unsharpSigma: unsharpSigma, unsharpAmount: unsharpAmount,
            unsharpThreshold: unsharpThreshold, batchSize: batchSize, useGrayColorspace: useGrayColorspace,
            enableUnsharp: enableUnsharp
        )
        if let error = report.issues.first?.error { throw error }
        // A successful report always contains the converted parameters.
        return report.parameters!
    }
}
