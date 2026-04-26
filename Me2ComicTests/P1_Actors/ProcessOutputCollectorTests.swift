//
//  ProcessOutputCollectorTests.swift
//  Me2ComicTests
//
//  P1 Actor tests for bounded process output collection
//

import Foundation
import Testing
@testable import Me2Comic

@Suite("ProcessOutputCollector bounded output tests")
struct ProcessOutputCollectorTests {
    
    @Test("stdout is counted without retaining content")
    func stdoutIsCountedOnly() async {
        let collector = ProcessOutputCollector()
        let stdout = Data(repeating: UInt8(ascii: "x"), count: 128 * 1024)
        
        await collector.appendStdout(stdout)
        let summary = await collector.getSummary()
        
        #expect(summary.stdoutBytesRead == stdout.count)
        #expect(summary.stderrBytesRead == 0)
        #expect(summary.stderrTail.isEmpty)
    }
    
    @Test("stderr smaller than capacity is fully retained")
    func stderrKeepsSmallOutput() async {
        let collector = ProcessOutputCollector()
        let stderr = Data("small stderr output".utf8)
        
        await collector.appendStderr(stderr)
        let summary = await collector.getSummary()
        
        #expect(summary.stdoutBytesRead == 0)
        #expect(summary.stderrBytesRead == stderr.count)
        #expect(summary.stderrTail == stderr)
    }
    
    @Test("stderr larger than capacity keeps tail bytes")
    func stderrKeepsTailBytesOnly() async {
        let collector = ProcessOutputCollector()
        let capacity = 64 * 1024
        let stderr = Data((0..<(capacity + 4096)).map { UInt8($0 % 251) })
        let expectedTail = Data(stderr.suffix(capacity))
        
        await collector.appendStderr(stderr)
        let summary = await collector.getSummary()
        
        #expect(summary.stderrBytesRead == stderr.count)
        #expect(summary.stderrTail.count == capacity)
        #expect(summary.stderrTail == expectedTail)
    }
    
    @Test("repeated stderr appends remain bounded")
    func repeatedStderrAppendsRemainBounded() async {
        let collector = ProcessOutputCollector()
        let capacity = 64 * 1024
        var completeInput = Data()
        
        for index in 0..<20 {
            let chunk = Data(repeating: UInt8(index), count: 4096)
            completeInput.append(chunk)
            await collector.appendStderr(chunk)
        }
        
        let summary = await collector.getSummary()
        let expectedTail = Data(completeInput.suffix(capacity))
        
        #expect(summary.stderrBytesRead == completeInput.count)
        #expect(summary.stderrTail.count == capacity)
        #expect(summary.stderrTail == expectedTail)
    }
    
    @Test("reset clears counters and retained tail")
    func resetClearsSummary() async {
        let collector = ProcessOutputCollector()
        
        await collector.appendStdout(Data(repeating: UInt8(ascii: "o"), count: 128))
        await collector.appendStderr(Data(repeating: UInt8(ascii: "e"), count: 256))
        await collector.reset()
        let summary = await collector.getSummary()
        
        #expect(summary.stdoutBytesRead == 0)
        #expect(summary.stderrBytesRead == 0)
        #expect(summary.stderrTail.isEmpty)
    }
}
