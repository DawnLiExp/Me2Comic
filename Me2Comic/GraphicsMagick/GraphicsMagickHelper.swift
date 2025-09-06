//
//  GraphicsMagickHelper.swift
//  Me2Comic
//
//  Created by Me2 on 2025/6/8.
//

import Foundation

/// `GraphicsMagickHelper` provides utility functions for interacting with the GraphicsMagick command-line tool.
class GraphicsMagickHelper {
    /// Verify GraphicsMagick installation and return executable path
    /// - Parameter logger: Logger closure for status messages
    /// - Returns: Result with GM path on success or error on failure
    static func verifyGraphicsMagickAsync(
        logger: (@Sendable (String, LogLevel, String?) -> Void)?
    ) async -> Result<String, ProcessingError> {
        #if DEBUG
        logger?("Verifying GraphicsMagick installation", .debug, "GraphicsMagickHelper")
        #endif

        let path = await Task.detached {
            detectGMPathSafely { message in
                Task {
                    logger?(message, .info, "GraphicsMagickHelper")
                }
            }
        }.value

        guard let path = path else {
            #if DEBUG
            logger?("GraphicsMagick path detection failed", .debug, "GraphicsMagickHelper")
            #endif
            return .failure(.graphicsMagickNotFound)
        }

        #if DEBUG
        logger?("GraphicsMagick path detected: \(path)", .debug, "GraphicsMagickHelper")
        #endif

        let verifyResult = await Task.detached {
            Self.verifyGraphicsMagick(
                gmPath: path,
                logHandler: { message in
                    Task {
                        logger?(message, .info, "GraphicsMagickHelper")
                    }
                }
            )
        }.value

        switch verifyResult {
        case .success:
            #if DEBUG
            logger?("GraphicsMagick verification succeeded", .debug, "GraphicsMagickHelper")
            #endif
            return .success(path)
        case .failure(let error):
            #if DEBUG
            logger?("GraphicsMagick verification failed: \(error)", .debug, "GraphicsMagickHelper")
            #endif
            return .failure(error)
        }
    }

    /// Attempts to detect the GraphicsMagick executable path by checking common installation locations.
    /// If not found in known paths, it falls back to using the `which` command.
    /// - Parameter logHandler: A closure to handle log messages during the detection process.
    /// - Returns: The detected path to the GraphicsMagick executable, or `nil` if not found.
    static func detectGMPathSafely(logHandler: (String) -> Void) -> String? {
        let knownPaths = ["/opt/homebrew/bin/gm", "/usr/local/bin/gm", "/usr/bin/gm"]

        for path in knownPaths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        return detectGMPathViaWhich(logHandler: logHandler)
    }

    /// Detects the GraphicsMagick executable path using the `which` command.
    /// - Parameter logHandler: A closure to handle log messages.
    /// - Returns: The detected path to the GraphicsMagick executable, or `nil` if not found.
    private static func detectGMPathViaWhich(logHandler: (String) -> Void) -> String? {
        let whichTask = Process()
        whichTask.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichTask.arguments = ["gm"]

        var env = ProcessInfo.processInfo.environment
        let homebrewPaths = ["/opt/homebrew/bin", "/usr/local/bin"]
        let originalPath = env["PATH"] ?? ""
        env["PATH"] = homebrewPaths.joined(separator: ":") + ":" + originalPath
        whichTask.environment = env

        let pipe = Pipe()
        whichTask.standardOutput = pipe
        whichTask.standardError = pipe

        do {
            try whichTask.run()
            whichTask.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard whichTask.terminationStatus == 0,
                  let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty
            else {
                logHandler(NSLocalizedString("GMNotFoundViaWhich", comment: "Cannot find gm via `which`"))
                return nil
            }
            return output
        } catch {
            logHandler(NSLocalizedString("GMWhichCommandFailed", comment: "`which gm` command failed"))
            return nil
        }
    }

    /// Verifies the GraphicsMagick installation by running `gm --version`.
    /// - Parameters:
    ///   - gmPath: The path to the GraphicsMagick executable.
    ///   - logHandler: A closure to handle log messages.
    /// - Returns: Result indicating success or failure with error details.
    static func verifyGraphicsMagick(gmPath: String, logHandler: (String) -> Void) -> Result<Void, ProcessingError> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gmPath)
        task.arguments = ["--version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            let outputMessage = String(data: outputData, encoding: .utf8) ?? NSLocalizedString("CannotReadOutput", comment: "")

            if task.terminationStatus != 0 {
                logHandler(NSLocalizedString("GMExecutionFailed", comment: "gm command failed to run properly"))
                return .failure(.graphicsMagickVerificationFailed(details: outputMessage))
            } else {
                logHandler(String(format: NSLocalizedString("GraphicsMagickVersion", comment: ""), outputMessage))
                return .success(())
            }
        } catch {
            logHandler(NSLocalizedString("GMExecutionException", comment: "Exception thrown when trying to run gm"))
            return .failure(.graphicsMagickVerificationFailed(details: error.localizedDescription))
        }
    }

    /// Escapes a given file path for safe use within shell commands.
    /// This implementation uses single quotes for robust shell escaping.
    /// - Parameter path: The file path to escape.
    /// - Returns: The escaped file path, enclosed in single quotes.
    static func escapePathForShell(_ path: String) -> String {
        // Use single-quote wrapping and escape single quotes inside the path safely:
        // 'a'b'c' -> 'a'\''b'\''c'
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Constructs a GraphicsMagick `convert` command string based on the provided parameters.
    ///   - cropParams: Optional cropping parameters (e.g., "100x100+0+0").
    ///   - resizeHeight: The target height for resizing.
    /// - Returns: A complete GraphicsMagick command string ready for execution.
    static func buildConvertCommand(
        inputPath: String,
        outputPath: String,
        cropParams: String?,
        resizeHeight: Int,
        quality: Int,
        unsharpRadius: Float,
        unsharpSigma: Float,
        unsharpAmount: Float,
        unsharpThreshold: Float,
        useGrayColorspace: Bool
    ) -> String {
        let escapedInputPath = escapePathForShell(inputPath)
        let escapedOutputPath = escapePathForShell(outputPath)

        var command = "convert \(escapedInputPath)"

        if let crop = cropParams {
            command += " -crop \(crop)"
        }

        command += " -resize x\(resizeHeight)"

        if useGrayColorspace {
            command += " -colorspace GRAY"
        }

        if unsharpAmount > 0 {
            command += " -unsharp \(unsharpRadius)x\(unsharpSigma)+\(unsharpAmount)+\(unsharpThreshold)"
        }

        command += " -quality \(quality) \(escapedOutputPath)"

        return command
    }
}
