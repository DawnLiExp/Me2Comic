import Darwin
import Foundation

/// Owns one child until its termination callback has run.
/// The lock protects launch/cancellation/exit state and all continuation ownership.
final class ManagedChildProcess: @unchecked Sendable {
    let process: Process
    private let lock = NSLock()
    private let gracePeriod: Duration
    private var launched = false
    private var cancelled = false
    private var exitStatus: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var escalation: Task<Void, Never>?

    init(process: Process, gracePeriod: Duration = .seconds(3)) {
        self.process = process
        self.gracePeriod = gracePeriod
    }

    func start() throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            process.terminationHandler = { [weak self] process in
                self?.didExit(process.terminationStatus)
            }
            do {
                try process.run()
                launched = true
            } catch {
                process.terminationHandler = nil
                throw error
            }
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            guard launched, exitStatus == nil, escalation == nil, process.isRunning else { return }
            process.terminate()
            escalation = Task.detached { [weak self, gracePeriod] in
                do { try await Task.sleep(for: gracePeriod) } catch { return }
                self?.forceTermination()
            }
        }
    }

    private func forceTermination() {
        lock.withLock {
            guard launched, exitStatus == nil, process.isRunning else { return }
            // Only this still-owned child is eligible for escalation.
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let status = lock.withLock { () -> Int32? in
                if let exitStatus { return exitStatus }
                waiters.append(continuation)
                return nil
            }
            if let status { continuation.resume(returning: status) }
        }
    }

    private func didExit(_ status: Int32) {
        let pending = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard exitStatus == nil else { return [] }
            exitStatus = status
            escalation?.cancel()
            escalation = nil
            process.terminationHandler = nil
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in pending { waiter.resume(returning: status) }
    }
}

struct GMProcessExecutor {
    private let gmPath: String
    private let logger: (@Sendable (String, LogLevel, String?) -> Void)?

    init(gmPath: String, logger: (@Sendable (String, LogLevel, String?) -> Void)? = nil) {
        self.gmPath = gmPath
        self.logger = logger
    }

    func executeBatch(
        commandGenerator: @escaping (FileHandle) async -> Result<Void, ProcessingError>
    ) async -> Result<Void, ProcessingError> {
        let collector = ProcessOutputCollector(logger: logger)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gmPath)
        process.arguments = ["batch", "-stop-on-error", "off"]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await collector.appendStdout(data) } }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { Task { await collector.appendStderr(data) } }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
        }
        let child = ManagedChildProcess(process: process)
        return await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try child.start()
            } catch {
                if Task.isCancelled || error is CancellationError { return .failure(.processingCancelled) }
                return .failure(.graphicsMagickExecutionFailed(exitCode: -1, stderr: error.localizedDescription))
            }
            let result = await commandGenerator(input.fileHandleForWriting)
            try? input.fileHandleForWriting.close()
            if case .failure = result { child.cancel() }
            if Task.isCancelled { child.cancel() }
            let status = await child.waitForExit()
            if Task.isCancelled { return .failure(.processingCancelled) }
            if case .failure = result { return result }
            if status != 0 {
                let summary = await collector.getSummary()
                let failure = ProcessingError.graphicsMagickExecutionFailed(
                    exitCode: status,
                    stderr: summary.stderrTail.isEmpty ? nil : String(decoding: summary.stderrTail, as: UTF8.self)
                )
                logger?(failure.localizedDescription, .error, "GMProcessExecutor")
                return .failure(failure)
            }
            return .success(())
        } onCancel: {
            child.cancel()
        }
    }

    func writeCommand(_ command: String, to fileHandle: FileHandle) async -> Result<Void, ProcessingError> {
        guard !Task.isCancelled else { return .failure(.processingCancelled) }
        guard let data = (command + "\n").data(using: .utf8) else { return .failure(.commandEncodingFailed) }
        do {
            // Blocking pipe writes must not occupy the UI executor.
            try await Task.detached { try fileHandle.write(contentsOf: data) }.value
            return Task.isCancelled ? .failure(.processingCancelled) : .success(())
        } catch {
            return Task.isCancelled ? .failure(.processingCancelled) : .failure(.pipeBroken)
        }
    }
}
