//
//  FileSystemHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Helper for file system operations with comprehensive error handling
enum FileSystemHelper {
    /// Create directory with error handling
    /// - Parameter url: Directory URL to create
    /// - Returns: Result indicating success or failure with detailed error
    static func createDirectory(at url: URL) -> Result<Void, ProcessingError> {
        do {
            let canonicalURL = url.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: canonicalURL,
                withIntermediateDirectories: true
            )
            
            #if DEBUG
            print("Created directory: \(canonicalURL.path)")
            #endif
            
            return .success(())
        } catch {
            #if DEBUG
            print("Directory creation failed for \(url.path): \(error)")
            #endif
            
            return .failure(.directoryCreationFailed(path: url.path, underlyingError: error))
        }
    }
    
    /// Create output directories for scan results
    /// - Parameters:
    ///   - scanResults: Scan results containing directory information
    ///   - outputDir: Base output directory
    /// - Returns: Result indicating success or failure
    static func createOutputDirectories(
        scanResults: [DirectoryScanResult],
        outputDir: URL
    ) -> Result<Void, ProcessingError> {
        let uniquePaths = Set(scanResults.map { result in
            outputDir
                .appendingPathComponent(result.directoryURL.lastPathComponent)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
        })
        
        #if DEBUG
        print("Creating \(uniquePaths.count) unique output directories")
        #endif
        
        for path in uniquePaths {
            let result = createDirectory(at: URL(fileURLWithPath: path))
            if case .failure(let error) = result {
                return .failure(error)
            }
        }
        
        return .success(())
    }
}
