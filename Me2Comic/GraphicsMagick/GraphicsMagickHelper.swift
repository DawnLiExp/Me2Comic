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
        do {
            try Task.checkCancellation()
            let knownPaths = ["/opt/homebrew/bin/gm", "/usr/local/bin/gm", "/usr/bin/gm"]
            let path: String
            if let known = knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                path = known
            } else {
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "")
                let result = try await runProbe(executable: "/usr/bin/which", arguments: ["gm"], environment: environment)
                let found = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.status == 0, !found.isEmpty else { return .failure(.graphicsMagickNotFound) }
                path = found
            }
            let result = try await runProbe(executable: path, arguments: ["--version"])
            guard result.status == 0 else {
                return .failure(.graphicsMagickVerificationFailed(details: result.output))
            }
            logger?(result.output, .info, "GraphicsMagickHelper")
            return .success(path)
        } catch is CancellationError {
            return .failure(.processingCancelled)
        } catch {
            return .failure(.graphicsMagickVerificationFailed(details: error.localizedDescription))
        }
    }

    /// Detection children use the same cancellation and reap contract as conversion children.
    static func runProbe(executable: String, arguments: [String], environment: [String: String]? = nil) async throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let child = ManagedChildProcess(process: process)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try child.start()
            // Drain concurrently so even an unexpectedly verbose executable cannot fill the pipe.
            let output = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
            let status = await child.waitForExit()
            let data = await output.value
            try? pipe.fileHandleForReading.close()
            try Task.checkCancellation()
            return (status, String(decoding: data, as: UTF8.self))
        } onCancel: {
            child.cancel()
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
                logHandler(String(localized: "GMNotFoundViaWhich"))
                return nil
            }
            return output
        } catch {
            logHandler(String(localized: "GMWhichCommandFailed"))
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
            let outputMessage = String(data: outputData, encoding: .utf8) ?? String(localized: "CannotReadOutput")

            if task.terminationStatus != 0 {
                logHandler(String(localized: "GMExecutionFailed"))
                return .failure(.graphicsMagickVerificationFailed(details: outputMessage))
            } else {
                logHandler(String(localized: "GraphicsMagickVersion", defaultValue: "\(outputMessage)"))
                return .success(())
            }
        } catch {
            logHandler(String(localized: "GMExecutionException"))
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
