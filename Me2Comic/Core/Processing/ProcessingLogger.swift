//
//  ProcessingLogger.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

/// Manages asynchronous logging with ordered message delivery
@MainActor
class ProcessingLogger: ObservableObject {
    // MARK: - Properties
    
    @Published var logMessages: [String] = []
    private var logContinuation: AsyncStream<String>.Continuation?
    
    // MARK: - Constants
    
    private enum Constants {
        static let maxLogMessages = 100
    }
    
    // MARK: - Initialization
    
    init() {
        setupLogStream()
    }
    
    // MARK: - Public Methods
    
    /// Append single log message via async stream
    func appendLog(_ message: String) {
        logContinuation?.yield(message)
    }
    
    /// Append multiple log messages synchronously
    func appendLogsBatch(_ messages: [String]) {
        messages.forEach { logContinuation?.yield($0) }
    }
    
    /// Log processing start parameters
    func logStartParameters(_ parameters: ProcessingParameters) {
        let grayStatus = NSLocalizedString(
            parameters.useGrayColorspace ? "GrayEnabled" : "GrayDisabled",
            comment: ""
        )
        
        if parameters.unsharpAmount > 0 {
            appendLog(String(
                format: NSLocalizedString("StartProcessingWithUnsharp", comment: ""),
                parameters.widthThreshold,
                parameters.resizeHeight,
                parameters.quality,
                parameters.threadCount,
                parameters.unsharpRadius,
                parameters.unsharpSigma,
                parameters.unsharpAmount,
                parameters.unsharpThreshold,
                grayStatus
            ))
        } else {
            appendLog(String(
                format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                parameters.widthThreshold,
                parameters.resizeHeight,
                parameters.quality,
                parameters.threadCount,
                grayStatus
            ))
        }
    }
    
    /// Format processing time for display
    func formatProcessingTime(_ seconds: Int) -> String {
        if seconds < 60 {
            return String(
                format: NSLocalizedString("ProcessingTimeSeconds", comment: ""),
                seconds
            )
        } else {
            return String(
                format: NSLocalizedString("ProcessingTimeMinutesSeconds", comment: ""),
                seconds / 60,
                seconds % 60
            )
        }
    }
    
    // MARK: - Private Methods
    
    /// Configure async log stream for ordered message delivery
    private func setupLogStream() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        logContinuation = continuation
        
        Task {
            for await message in stream {
                logMessages.append(message)
                if logMessages.count > Constants.maxLogMessages {
                    logMessages.removeFirst(logMessages.count - Constants.maxLogMessages)
                }
            }
        }
    }
}
