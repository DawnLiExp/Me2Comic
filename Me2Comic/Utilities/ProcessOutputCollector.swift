//
//  ProcessOutputCollector.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

struct ProcessOutputSummary: Sendable {
    let stdoutBytesRead: Int
    let stderrBytesRead: Int
    let stderrTail: Data
}

/// Thread-safe collection of external process output
actor ProcessOutputCollector {
    private enum Constants {
        static let stderrTailCapacity = 64 * 1024
    }
    
    private var stdoutBytesRead = 0
    private var stderrBytesRead = 0
    private var stderrTail = Data()
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    /// Count stdout bytes without retaining stdout content.
    func appendStdout(_ data: Data) {
        stdoutBytesRead += data.count
        #if DEBUG
        if !data.isEmpty {
            logger?("Read \(data.count) bytes of stdout; total=\(stdoutBytesRead)", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    /// Keep only the bounded stderr tail needed for failure diagnostics.
    func appendStderr(_ data: Data) {
        stderrBytesRead += data.count
        
        if data.count >= Constants.stderrTailCapacity {
            stderrTail = Data(data.suffix(Constants.stderrTailCapacity))
        } else {
            stderrTail.append(data)
            if stderrTail.count > Constants.stderrTailCapacity {
                stderrTail = Data(stderrTail.suffix(Constants.stderrTailCapacity))
            }
        }
        
        #if DEBUG
        if !data.isEmpty {
            logger?("Read \(data.count) bytes of stderr; total=\(stderrBytesRead), retained=\(stderrTail.count)", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    /// Retrieve bounded output summary.
    func getSummary() -> ProcessOutputSummary {
        ProcessOutputSummary(
            stdoutBytesRead: stdoutBytesRead,
            stderrBytesRead: stderrBytesRead,
            stderrTail: stderrTail
        )
    }
    
    /// Clear collected summary state.
    func reset() {
        stdoutBytesRead = 0
        stderrBytesRead = 0
        stderrTail.removeAll()
    }
}
