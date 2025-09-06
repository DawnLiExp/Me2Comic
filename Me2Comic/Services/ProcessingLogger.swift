//
//  ProcessingLogger.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/29.
//

import Foundation

// MARK: - Log Level Definition

/// Log levels for different types of messages
enum LogLevel: Int, CaseIterable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3
    
    var prefix: String {
        switch self {
        case .debug: return "[DEBUG]"
        case .info: return "[INFO]"
        case .warning: return "[WARN]"
        case .error: return "[ERROR]"
        }
    }
    
    var isUserVisible: Bool {
        switch self {
        case .debug: return false
        case .info, .warning, .error: return true
        }
    }
}

// MARK: - Log Entry

/// Single log entry with metadata
struct LogEntry: Sendable {
    let message: String
    let level: LogLevel
    let timestamp: Date
    let source: String?
    
    init(message: String, level: LogLevel, source: String? = nil) {
        self.message = message
        self.level = level
        self.timestamp = Date()
        self.source = source
    }
    
    /// Format for display in UI
    var displayMessage: String {
        return message
    }
    
    /// Format for debug output
    var debugMessage: String {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss.SSS"
        let timeString = timeFormatter.string(from: timestamp)
        
        if let source = source {
            return "\(timeString) \(level.prefix) [\(source)] \(message)"
        } else {
            return "\(timeString) \(level.prefix) \(message)"
        }
    }
}

// MARK: - Logging Protocol

/// Protocol for unified logging interface
@preconcurrency
protocol LoggingProtocol: Sendable {
    func log(_ message: String, level: LogLevel, source: String?)
}

// MARK: - Processing Logger

/// Manages asynchronous logging with level-based filtering and unified interface
@MainActor
class ProcessingLogger: ObservableObject, LoggingProtocol {
    // MARK: - Properties
    
    @Published var logMessages: [String] = []
    private var logContinuation: AsyncStream<LogEntry>.Continuation?
    private var debugLogContinuation: AsyncStream<LogEntry>.Continuation?
    
    // MARK: - Constants
    
    private enum Constants {
        static let maxLogMessages = 100
        static let maxDebugMessages = 500
    }
    
    // MARK: - Initialization
    
    init() {
        setupLogStreams()
    }
    
    // MARK: - Public Methods
    
    /// Unified logging interface
    /// Unified logging interface
    nonisolated func log(_ message: String, level: LogLevel = .info, source: String? = nil) {
        let entry = LogEntry(message: message, level: level, source: source)
        
        Task { @MainActor in
            logContinuation?.yield(entry)
            
            #if DEBUG
            debugLogContinuation?.yield(entry)
            #endif
        }
    }
    
    /// Append single log message (legacy compatibility)
    func appendLog(_ message: String) {
        log(message, level: .info)
    }
    
    /// Append multiple log messages synchronously
    func appendLogsBatch(_ messages: [String]) {
        messages.forEach { log($0, level: .info) }
    }
    
    /// Debug logging (only visible in debug builds)
    func logDebug(_ message: String, source: String? = nil) {
        #if DEBUG
        log(message, level: .debug, source: source)
        #endif
    }
    
    /// Warning logging
    func logWarning(_ message: String, source: String? = nil) {
        log(message, level: .warning, source: source)
    }
    
    /// Error logging
    func logError(_ message: String, source: String? = nil) {
        log(message, level: .error, source: source)
    }
    
    /// Log processing start parameters
    func logStartParameters(_ parameters: ProcessingParameters) {
        let grayStatus = NSLocalizedString(
            parameters.useGrayColorspace ? "GrayEnabled" : "GrayDisabled",
            comment: ""
        )
        
        if parameters.unsharpAmount > 0 {
            log(String(
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
            ), level: .info)
        } else {
            log(String(
                format: NSLocalizedString("StartProcessingNoUnsharp", comment: ""),
                parameters.widthThreshold,
                parameters.resizeHeight,
                parameters.quality,
                parameters.threadCount,
                grayStatus
            ), level: .info)
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
    
    /// Configure async log streams for ordered message delivery
    private func setupLogStreams() {
        // UI log stream (user-visible messages only)
        let (uiStream, uiContinuation) = AsyncStream<LogEntry>.makeStream()
        logContinuation = uiContinuation
        
        Task {
            for await entry in uiStream {
                if entry.level.isUserVisible {
                    logMessages.append(entry.displayMessage)
                    if logMessages.count > Constants.maxLogMessages {
                        logMessages.removeFirst(logMessages.count - Constants.maxLogMessages)
                    }
                }
            }
        }
        
        #if DEBUG
        // Debug log stream (all messages with detailed formatting)
        let (debugStream, debugContinuation) = AsyncStream<LogEntry>.makeStream()
        debugLogContinuation = debugContinuation
        
        Task {
            for await entry in debugStream {
                print(entry.debugMessage)
            }
        }
        #endif
    }
}

// MARK: - Logger Factory

/// Factory for creating logger instances with consistent configuration
@MainActor
struct LoggerFactory {
    /// Create logger closure for sendable contexts
    static func createLoggerClosure(from logger: ProcessingLogger) -> @Sendable (String, LogLevel, String?) -> Void {
        return { @Sendable message, level, source in
            Task { @MainActor in
                logger.log(message, level: level, source: source)
            }
        }
    }
    
    /// Create simple log handler for backward compatibility
    static func createSimpleLogHandler(from logger: ProcessingLogger) -> @Sendable (String) -> Void {
        return { @Sendable message in
            Task { @MainActor in
                logger.log(message, level: .info)
            }
        }
    }
}
