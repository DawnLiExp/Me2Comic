//
//  MockProcessingLogger.swift
//  Me2ComicTests
//
//  供 @MainActor 业务类测试使用的最小化 LoggingProtocol Mock
//

import Foundation
@testable import Me2Comic

@MainActor
final class MockProcessingLogger: LoggingProtocol {
    
    // 记录所有通过 log(_:level:source:) 写入的条目
    private(set) var entries: [(message: String, level: LogLevel)] = []
    
    // LoggingProtocol 唯一必要实现
    nonisolated func log(_ message: String, level: LogLevel, source: String?) {
        Task { @MainActor in
            self.entries.append((message, level))
        }
    }
    
    // 测试辅助
    var messages: [String] { entries.map(\.message) }
    
    func reset() { entries.removeAll() }
}
