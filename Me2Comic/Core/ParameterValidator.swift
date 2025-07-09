//
//  ParameterValidator.swift
//  Me2Comic
//
//  Created by me2 on 2025/7/8.
//

import Foundation

/// A struct to hold validated and converted processing parameters.
/// This struct ensures that all contained parameter values are valid and of the correct type.
struct ValidatedProcessingParameters {
    let widthThreshold: Int
    let resizeHeight: Int
    let quality: Int
    let unsharpRadius: Float
    let unsharpSigma: Float
    let unsharpAmount: Float
    let unsharpThreshold: Float
    let batchSize: Int
}

/// Possible parameter validation errors
enum ParameterValidationError: LocalizedError {
    case invalidWidthThreshold
    case invalidResizeHeight
    case invalidOutputQuality
    case invalidUnsharpParameters
    case invalidBatchSize

    /// Localized error description for each case
    var errorDescription: String? {
        switch self {
        case .invalidWidthThreshold:
            return NSLocalizedString("InvalidWidthThreshold", comment: "")
        case .invalidResizeHeight:
            return NSLocalizedString("InvalidResizeHeight", comment: "")
        case .invalidOutputQuality:
            return NSLocalizedString("InvalidOutputQuality", comment: "")
        case .invalidUnsharpParameters:
            return NSLocalizedString("InvalidUnsharpParameters", comment: "")
        case .invalidBatchSize:
            return NSLocalizedString("InvalidBatchSize", comment: "")
        }
    }
}

/// Utility for validating and converting raw `ProcessingParameters`.
/// This enum provides static methods to ensure input parameters meet the application's requirements.
enum ParameterValidator {
    /// Validates and converts raw parameters to validated types.
    /// - Parameter parameters: Raw `ProcessingParameters` to validate.
    /// - Throws: `ParameterValidationError` on invalid input.
    /// - Returns: Validated parameters with type-safe values.
    static func validate(parameters: ProcessingParameters) throws -> ValidatedProcessingParameters {
        guard let threshold = Int(parameters.widthThreshold), threshold > 0 else {
            throw ParameterValidationError.invalidWidthThreshold
        }

        guard let resize = Int(parameters.resizeHeight), resize > 0 else {
            throw ParameterValidationError.invalidResizeHeight
        }

        guard let qual = Int(parameters.quality), qual >= 1, qual <= 100 else {
            throw ParameterValidationError.invalidOutputQuality
        }

        guard let radius = Float(parameters.unsharpRadius), radius >= 0,
              let sigma = Float(parameters.unsharpSigma), sigma >= 0,
              let amount = Float(parameters.unsharpAmount), amount >= 0,
              let unsharpThreshold = Float(parameters.unsharpThreshold), unsharpThreshold >= 0
        else {
            throw ParameterValidationError.invalidUnsharpParameters
        }

        guard let batchSize = Int(parameters.batchSize), batchSize >= 1, batchSize <= 1000 else {
            throw ParameterValidationError.invalidBatchSize
        }

        return ValidatedProcessingParameters(
            widthThreshold: threshold,
            resizeHeight: resize,
            quality: qual,
            unsharpRadius: radius,
            unsharpSigma: sigma,
            unsharpAmount: amount,
            unsharpThreshold: unsharpThreshold,
            batchSize: batchSize
        )
    }
}
