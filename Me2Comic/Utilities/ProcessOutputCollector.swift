//
//  ProcessOutputCollector.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/4.
//

import Foundation

/// Thread-safe collection of external process output
actor ProcessOutputCollector {
    private var stdout = Data()
    private var stderr = Data()
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?
    
    init(logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.logger = logger
    }
    
    /// Append data to stdout buffer
    func appendStdout(_ data: Data) {
        stdout.append(data)
        #if DEBUG
        if !data.isEmpty {
            logger?("Collected \(data.count) bytes of stdout", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    /// Append data to stderr buffer
    func appendStderr(_ data: Data) {
        stderr.append(data)
        #if DEBUG
        if !data.isEmpty {
            logger?("Collected \(data.count) bytes of stderr", .debug, "ProcessOutputCollector")
        }
        #endif
    }
    
    /// Retrieve collected output
    func getOutput() -> (stdout: Data, stderr: Data) {
        return (stdout, stderr)
    }
    
    /// Clear collected buffers
    func reset() {
        stdout.removeAll()
        stderr.removeAll()
    }
}
