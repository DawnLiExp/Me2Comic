import Foundation
import Dispatch

nonisolated struct CLIRequestError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Serializes complete JSON lines even when several jobs emit events concurrently.
nonisolated enum CLIOutput {
    private static let lock = NSLock()

    static func emit<T: Encodable>(_ value: T) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(value)
            data.append(10)
            lock.lock()
            defer { lock.unlock() }
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            diagnostic("Cannot write CLI result: \(error.localizedDescription)")
        }
    }

    static func diagnostic(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    static func version(tool: String) {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info = Bundle(url: app)?.infoDictionary ?? [:]
        emit(["tool": tool, "version": info["CFBundleShortVersionString"] as? String ?? "development",
              "build": info["CFBundleVersion"] as? String ?? (tool == "me2comic-cli" ? "Mucha" : "development"), "protocolVersion": "1"])
    }

    static func appDefaults(_ identifier: String) throws -> UserDefaults {
        // Embedded tools inherit the containing app's bundle identity.
        if Bundle.main.bundleIdentifier == identifier { return .standard }
        guard let defaults = UserDefaults(suiteName: identifier) else {
            throw CLIRequestError("Cannot read preferences for \(identifier).")
        }
        return defaults
    }

    static func run(_ operation: @escaping @Sendable () async -> Int32) async -> Never {
        let task = Task { await operation() }
        let sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { task.cancel() }
            source.resume()
            return source
        }
        let code = await task.value
        for source in sources { source.cancel() }
        exit(code)
    }

    static func requestPath(command: String) throws -> String {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3, arguments[0] == command, arguments[1] == "--request" else {
            throw CLIRequestError("Usage: \(CommandLine.arguments[0]) \(command) --request request.json")
        }
        return arguments[2]
    }
}
