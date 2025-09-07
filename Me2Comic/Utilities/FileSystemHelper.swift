//
//  FileSystemHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Helper for file system operations with comprehensive error handling
enum FileSystemHelper {
    /// Create directory with error handling and logging
    /// - Parameters:
    ///   - url: Directory URL to create
    ///   - logger: Optional logger for operation tracking
    /// - Returns: Result indicating success or failure with detailed error
    static func createDirectory(
        at url: URL,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Void, ProcessingError> {
        do {
            let canonicalURL = url.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: canonicalURL,
                withIntermediateDirectories: true
            )
            
            logger?("Created directory: \(canonicalURL.path)", .debug, "FileSystemHelper")
            
            return .success(())
        } catch {
            let processingError = ProcessingError.directoryCreationFailed(
                path: url.path,
                underlyingError: error
            )
            
            logger?(
                "Directory creation failed for \(url.path): \(error)",
                .error,
                "FileSystemHelper"
            )
            
            return .failure(processingError)
        }
    }
    
    /// Create output directories for scan results with logging
    /// - Parameters:
    ///   - scanResults: Scan results containing directory information
    ///   - outputDir: Base output directory
    ///   - logger: Optional logger for operation tracking
    /// - Returns: Result indicating success or failure
    static func createOutputDirectories(
        scanResults: [DirectoryScanResult],
        outputDir: URL,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Void, ProcessingError> {
        let uniquePaths = Set(scanResults.map { result in
            outputDir
                .appendingPathComponent(result.directoryURL.lastPathComponent)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        })
        
        logger?(
            "Creating \(uniquePaths.count) unique output directories",
            .debug,
            "FileSystemHelper"
        )
        
        for path in uniquePaths {
            let result = createDirectory(at: URL(fileURLWithPath: path), logger: logger)
            if case .failure(let error) = result {
                return .failure(error)
            }
        }
        
        logger?(
            "Successfully created all \(uniquePaths.count) output directories",
            .debug,
            "FileSystemHelper"
        )
        
        return .success(())
    }
    
    /// Check if directory exists and is accessible
    /// - Parameters:
    ///   - url: Directory URL to check
    ///   - logger: Optional logger for operation tracking
    /// - Returns: Result indicating accessibility or failure
    static func checkDirectoryAccess(
        at url: URL,
        logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil
    ) -> Result<Void, ProcessingError> {
        var isDirectory: ObjCBool = false
        
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            let error = ProcessingError.fileNotFound(path: url.path)
            logger?("Directory not found: \(url.path)", .error, "FileSystemHelper")
            return .failure(error)
        }
        
        guard isDirectory.boolValue else {
            let error = ProcessingError.filePropertiesUnavailable(path: url.path)
            logger?("Path exists but is not a directory: \(url.path)", .error, "FileSystemHelper")
            return .failure(error)
        }
        
        logger?("Directory access verified: \(url.path)", .debug, "FileSystemHelper")
        return .success(())
    }
}
