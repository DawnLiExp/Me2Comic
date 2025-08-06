//
//  ProcessingParametersValidator.swift
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
            return NSLocalizedString("InvalidWidthThreshold", comment: "")
        case .invalidResizeHeight:
            return NSLocalizedString("InvalidResizeHeight", comment: "")
        case .invalidQuality:
            return NSLocalizedString("InvalidOutputQuality", comment: "")
        case .invalidUnsharpParameters:
            return NSLocalizedString("InvalidUnsharpParameters", comment: "")
        case .invalidBatchSize:
            return NSLocalizedString("InvalidBatchSize", comment: "")
        case .noInputOrOutputDirectory:
            return NSLocalizedString("NoInputOrOutputDir", comment: "")
        }
    }
}

/// Validates processing parameters from string inputs.
enum ProcessingParametersValidator {
    /// Validates and converts string parameters to their correct types.
    /// - Parameters:
    ///   - inputDirectory: URL of the input directory.
    ///   - outputDirectory: URL of the output directory.
    ///   - widthThreshold: String value for width threshold.
    ///   - resizeHeight: String value for resize height.
    ///   - quality: String value for quality.
    ///   - threadCount: Integer value for thread count.
    ///   - unsharpRadius: String value for unsharp radius.
    ///   - unsharpSigma: String value for unsharp sigma.
    ///   - unsharpAmount: String value for unsharp amount.
    ///   - unsharpThreshold: String value for unsharp threshold.
    ///   - batchSize: String value for batch size.
    ///   - useGrayColorspace: Boolean value for grayscale conversion.
    /// - Returns: A `ProcessingParameters` struct if all validations pass, otherwise throws a `ProcessingParameterError`.
    static func validateAndCreateParameters(
        inputDirectory: URL?,
        outputDirectory: URL?,
        widthThreshold: String,
        resizeHeight: String,
        quality: String,
        threadCount: Int,
        unsharpRadius: String,
        unsharpSigma: String,
        unsharpAmount: String,
        unsharpThreshold: String,
        batchSize: String,
        useGrayColorspace: Bool
    ) throws -> ProcessingParameters {
        guard inputDirectory != nil, outputDirectory != nil else {
            throw ProcessingParameterError.noInputOrOutputDirectory
        }

        guard let widthThresholdValue = Int(widthThreshold), widthThresholdValue > 0 else {
            throw ProcessingParameterError.invalidWidthThreshold
        }

        guard let resizeHeightValue = Int(resizeHeight), resizeHeightValue > 0 else {
            throw ProcessingParameterError.invalidResizeHeight
        }

        guard let qualityValue = Int(quality), qualityValue >= 1, qualityValue <= 100 else {
            throw ProcessingParameterError.invalidQuality
        }

        guard let unsharpRadiusValue = Float(unsharpRadius), unsharpRadiusValue >= 0,
              let unsharpSigmaValue = Float(unsharpSigma), unsharpSigmaValue >= 0,
              let unsharpAmountValue = Float(unsharpAmount), unsharpAmountValue >= 0,
              let unsharpThresholdValue = Float(unsharpThreshold), unsharpThresholdValue >= 0
        else {
            throw ProcessingParameterError.invalidUnsharpParameters
        }

        guard let batchSizeValue = Int(batchSize), batchSizeValue >= 1, batchSizeValue <= 1000 else {
            throw ProcessingParameterError.invalidBatchSize
        }

        return ProcessingParameters(
            widthThreshold: widthThresholdValue,
            resizeHeight: resizeHeightValue,
            quality: qualityValue,
            threadCount: threadCount,
            unsharpRadius: unsharpRadiusValue,
            unsharpSigma: unsharpSigmaValue,
            unsharpAmount: unsharpAmountValue,
            unsharpThreshold: unsharpThresholdValue,
            batchSize: batchSizeValue,
            useGrayColorspace: useGrayColorspace
        )
    }
}
