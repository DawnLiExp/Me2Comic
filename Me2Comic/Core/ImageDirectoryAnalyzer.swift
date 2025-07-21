//
//  v2.1-ImageDirectoryAnalyzer.swift
//  Me2Comic
//
//  Created by me2 on 2025/7/9.
//

import Foundation

/// Represents the result of a directory scan.
struct DirectoryScanResult {
    let directoryURL: URL
    let imageFiles: [URL]
}

class ImageDirectoryAnalyzer {
    private let logHandler: (String) -> Void
    private let isProcessingCheck: () -> Bool

    init(logHandler: @escaping (String) -> Void, isProcessingCheck: @escaping () -> Bool) {
        self.logHandler = logHandler
        self.isProcessingCheck = isProcessingCheck
    }

    /// Scans a directory for supported image files.
    private func getImageFiles(_ directory: URL) -> [URL] {
        #if DEBUG
        let startTime = Date()
        #endif
        guard let enumerator = FileManager.default.enumerator(at: directory,
                                                              includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else {
            DispatchQueue.main.async { [self] in
                logHandler(String(format: NSLocalizedString("ErrorReadingDirectory", comment: ""), directory.lastPathComponent)
                    + ": "
                    + NSLocalizedString("FailedToCreateEnumerator", comment: ""))
            }
            return []
        }

        let imageExtensions = Set(["jpg", "jpeg", "png"])
        let files: [URL] = enumerator.compactMap { element in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile ?? false,
                  imageExtensions.contains(url.pathExtension.lowercased()) else { return nil }
            return url
        }
        #if DEBUG
        let elapsedTime = Date().timeIntervalSince(startTime)
        print("ImageDirectoryAnalyzer: getImageFiles for \(directory.lastPathComponent) took \(String(format: "%.4f", elapsedTime)) seconds. Found \(files.count) images.")
        #endif
        return files
    }

    /// Scans the input directory for subdirectories and collects image files within them.
    /// - Parameter inputDir: The input directory URL.
    /// - Returns: An array of `DirectoryScanResult` containing directories and their image files.
    func analyze(inputDir: URL) -> [DirectoryScanResult] {
        #if DEBUG
        let overallAnalyzeStartTime = Date()
        print("ImageDirectoryAnalyzer: Starting analyze for inputDir: \(inputDir.lastPathComponent)")
        #endif

        let fileManager = FileManager.default
        var allScanResults: [DirectoryScanResult] = []

        do {
            let subdirs = try fileManager.contentsOfDirectory(at: inputDir, includingPropertiesForKeys: [.isDirectoryKey])
                .filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                }

            guard !subdirs.isEmpty else {
                DispatchQueue.main.async { [self] in
                    logHandler(NSLocalizedString("NoSubdirectories", comment: ""))
                }
                return []
            }

            for subdir in subdirs {
                // Check for cancellation before processing each subdirectory
                guard isProcessingCheck() else { return [] }

                #if DEBUG
                let subdirProcessingStartTime = Date()
                print("ImageDirectoryAnalyzer: Processing subdirectory: \(subdir.lastPathComponent)")
                #endif

                let imageFiles = getImageFiles(subdir)
                guard !imageFiles.isEmpty else {
                    DispatchQueue.main.async { [self] in
                        logHandler(String(format: NSLocalizedString("NoImagesInDir", comment: ""), subdir.lastPathComponent))
                    }
                    continue
                }

                allScanResults.append(DirectoryScanResult(directoryURL: subdir, imageFiles: imageFiles))

                #if DEBUG
                let subdirProcessingElapsedTime = Date().timeIntervalSince(subdirProcessingStartTime)
                print("ImageDirectoryAnalyzer: Finished processing subdirectory \(subdir.lastPathComponent) in \(String(format: "%.4f", subdirProcessingElapsedTime)) seconds.")
                #endif
            }
        } catch {
            DispatchQueue.main.async { [self] in
                logHandler(String(format: NSLocalizedString("ErrorScanningDirectory", comment: ""),
                                  inputDir.lastPathComponent,
                                  error.localizedDescription))
            }
            return []
        }

        #if DEBUG
        let overallAnalyzeElapsedTime = Date().timeIntervalSince(overallAnalyzeStartTime)
        print("ImageDirectoryAnalyzer: Overall analyze process completed in \(String(format: "%.4f", overallAnalyzeElapsedTime)) seconds. Found \(allScanResults.count) subdirectories.")
        #endif
        return allScanResults
    }
}
