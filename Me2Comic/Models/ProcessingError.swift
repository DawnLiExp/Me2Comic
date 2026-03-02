//
//  ProcessingError.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Unified error type for all processing operations
enum ProcessingError: Error, Sendable {
    // MARK: - GraphicsMagick Errors
    
    /// GraphicsMagick not found at any known location
    case graphicsMagickNotFound
    /// GraphicsMagick verification failed
    case graphicsMagickVerificationFailed(details: String)
    /// GraphicsMagick is not ready (e.g., not found or verification failed at app start)
    case graphicsMagickNotReady
    /// GraphicsMagick command execution failed
    case graphicsMagickExecutionFailed(exitCode: Int32, stderr: String?)
    
    // MARK: - File System Errors
    
    /// Failed to create directory
    case directoryCreationFailed(path: String, underlyingError: Error)
    /// Failed to read directory contents
    case directoryReadFailed(path: String, underlyingError: Error)
    /// File not found at specified path
    case fileNotFound(path: String)
    /// Failed to access file properties
    case filePropertiesUnavailable(path: String)
    
    // MARK: - Image Processing Errors
    
    /// Failed to read image dimensions
    case imageDimensionsUnavailable(path: String)
    /// Failed to create image source
    case imageSourceCreationFailed(path: String)
    /// Invalid image format or corrupted file
    case invalidImageFormat(path: String)
    
    // MARK: - Process I/O Errors
    
    /// Failed to write command to process pipe
    case pipeWriteFailed(POSIXError: POSIXError)
    /// Process pipe broken (SIGPIPE)
    case pipeBroken
    /// Process I/O timeout
    case processIOTimeout
    /// Failed to encode command to UTF-8
    case commandEncodingFailed
    
    // MARK: - Validation Errors
    
    /// Parameter validation failed
    case invalidParameter(parameter: String, reason: String)
    /// No images found for processing
    case noImagesFound(directory: String)
    /// Processing was cancelled by user
    case processingCancelled
}

// MARK: - LocalizedError Conformance

extension ProcessingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .graphicsMagickNotFound:
            return String(localized: "GMNotFoundViaWhich")
            
        case .graphicsMagickNotReady:
            return String(localized: "GMNotReady")
            
        case .graphicsMagickVerificationFailed(let details):
            return String(format: String(localized: "GMExecutionFailed"), details)
            
        case .graphicsMagickExecutionFailed(let exitCode, let stderr):
            let baseMessage = String(localized: "GMExecutionException")
            if let stderr = stderr, !stderr.isEmpty {
                return "\(baseMessage): \(stderr)"
            }
            return "\(baseMessage) (exit code: \(exitCode))"
            
        case .directoryCreationFailed(let path, let underlyingError):
            return String(localized: "CannotCreateOutputDir", defaultValue: "\(path): \(underlyingError.localizedDescription)")
            
        case .directoryReadFailed(let path, let underlyingError):
            return String(format: String(localized: "ErrorReadingDirectory"), path) + ": " + underlyingError.localizedDescription
            
        case .fileNotFound(let path):
            return String(format: String(localized: "ErrorScanningDirectory"), path, String(localized: "FileNotFound"))
            
        case .filePropertiesUnavailable(let path):
            return String(format: String(localized: "ErrorScanningDirectory"), path, String(localized: "CannotReadFileProperties"))
            
        case .imageDimensionsUnavailable(let path),
             .imageSourceCreationFailed(let path),
             .invalidImageFormat(let path):
            return String(format: String(localized: "ErrorScanningDirectory"), path, String(localized: "InvalidImageFormat"))
            
        case .pipeWriteFailed(let posixError):
            return String(localized: "GMExecutionException") + ": " + posixError.localizedDescription
            
        case .pipeBroken:
            return String(localized: "GMExecutionException") + ": Pipe broken"
            
        case .processIOTimeout:
            return String(localized: "GMExecutionException") + ": Process I/O timeout"
            
        case .commandEncodingFailed:
            return String(localized: "GMExecutionException") + ": Command encoding failed"
            
        case .invalidParameter(let parameter, let reason):
            return "\(parameter): \(reason)"
            
        case .noImagesFound(let directory):
            return String(localized: "NoImagesInDir", defaultValue: "\(directory)")
            
        case .processingCancelled:
            return String(localized: "ProcessingStopped")
        }
    }
}

// MARK: - Error Context Helper

/// Helper to provide additional context for errors
struct ErrorContext: Sendable {
    let file: String
    let function: String
    let line: Int
    
    init(file: String = #file, function: String = #function, line: Int = #line) {
        self.file = (file as NSString).lastPathComponent
        self.function = function
        self.line = line
    }
    
    var description: String {
        "\(file):\(line) in \(function)"
    }
}

// MARK: - Result Extensions

extension Result where Failure == ProcessingError {
    /// Log error if present using the provided logger
    @discardableResult
    func logIfError(
        _ logger: (@Sendable (String, LogLevel, String?) -> Void)?,
        context: ErrorContext? = nil
    ) -> Self {
        if case .failure(let error) = self {
            let message = error.localizedDescription
            let source = context?.description
            logger?(message, .error, source)
        }
        return self
    }
}
