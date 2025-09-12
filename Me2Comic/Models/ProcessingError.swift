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
            return NSLocalizedString("GMNotFoundViaWhich", comment: "")
            
        case .graphicsMagickNotReady:
            return NSLocalizedString("GMNotReady", comment: "")
            
        case .graphicsMagickVerificationFailed(let details):
            return String(format: NSLocalizedString("GMExecutionFailed", comment: ""), details)
            
        case .graphicsMagickExecutionFailed(let exitCode, let stderr):
            let baseMessage = NSLocalizedString("GMExecutionException", comment: "")
            if let stderr = stderr, !stderr.isEmpty {
                return "\(baseMessage): \(stderr)"
            }
            return "\(baseMessage) (exit code: \(exitCode))"
            
        case .directoryCreationFailed(let path, let underlyingError):
            return String(
                format: NSLocalizedString("CannotCreateOutputDir", comment: ""),
                "\(path): \(underlyingError.localizedDescription)"
            )
            
        case .directoryReadFailed(let path, let underlyingError):
            return String(
                format: NSLocalizedString("ErrorReadingDirectory", comment: ""),
                path
            ) + ": " + underlyingError.localizedDescription
            
        case .fileNotFound(let path):
            return String(
                format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                path,
                "File not found"
            )
            
        case .filePropertiesUnavailable(let path):
            return String(
                format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                path,
                "Cannot read file properties"
            )
            
        case .imageDimensionsUnavailable(let path),
             .imageSourceCreationFailed(let path),
             .invalidImageFormat(let path):
            return String(
                format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                path,
                "Invalid image"
            )
            
        case .pipeWriteFailed(let posixError):
            return NSLocalizedString("GMExecutionException", comment: "") + ": " + posixError.localizedDescription
            
        case .pipeBroken:
            return NSLocalizedString("GMExecutionException", comment: "") + ": Pipe broken"
            
        case .processIOTimeout:
            return NSLocalizedString("GMExecutionException", comment: "") + ": Process I/O timeout"
            
        case .commandEncodingFailed:
            return NSLocalizedString("GMExecutionException", comment: "") + ": Command encoding failed"
            
        case .invalidParameter(let parameter, let reason):
            return "\(parameter): \(reason)"
            
        case .noImagesFound(let directory):
            return String(format: NSLocalizedString("NoImagesInDir", comment: ""), directory)
            
        case .processingCancelled:
            return NSLocalizedString("ProcessingStopped", comment: "")
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
