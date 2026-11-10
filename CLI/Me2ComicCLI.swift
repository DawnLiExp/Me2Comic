import Foundation

private struct ImageRequest: Decodable, Sendable {
    let settings: ComicCLISettings
    let jobs: [ImageJob]
}

private struct ImageJob: Decodable, Sendable {
    let id: String
    let input: String
    /// Parent of the generated directory, matching the GUI's output-directory setting.
    let output: String
}

private struct ImageResult: Encodable, Sendable {
    let id: String
    let status: String
    let outputs: [String]
    let error: String?
}

private struct Message: Encodable {
    let event: String
    var id: String?
    var stage: String?
    var result: ImageResult?
    var results: [ImageResult]?
}

private final class ConsoleLogger: LoggingProtocol {
    func log(_ message: String, level: LogLevel, source: String?) {
        if level.isUserVisible { CLIOutput.diagnostic(message) }
    }
}

@main
struct Me2ComicCLI {
    static func main() async {
        await CLIOutput.run { await execute() }
    }

    @MainActor
    private static func execute() async -> Int32 {
        let request: ImageRequest
        let parameters: ProcessingParameters
        do {
            switch CommandLine.arguments.dropFirst().first {
            case "--help", "-h", nil:
                print("me2comic-cli settings | process --request request.json | --version\nSee docs/CLI.md for the JSON contract.")
                return 0
            case "--version":
                CLIOutput.version(tool: "me2comic-cli")
                return 0
            case "settings":
                CLIOutput.emit(try ComicCLISettings.load(defaults: CLIOutput.appDefaults("me2.comic.me2comic")))
                return 0
            default: break
            }
            let path = try CLIOutput.requestPath(command: "process")
            request = try JSONDecoder().decode(ImageRequest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            parameters = try request.settings.validatedParameters()
            let destinations = request.jobs.map {
                URL(fileURLWithPath: $0.output).appendingPathComponent(URL(fileURLWithPath: $0.input).lastPathComponent).standardizedFileURL.path
            }
            guard !request.jobs.isEmpty, Set(request.jobs.map(\.id)).count == request.jobs.count,
                  Set(destinations).count == request.jobs.count else {
                throw CLIRequestError("Provide nonempty jobs with unique ids and destination directories.")
            }
        } catch {
            CLIOutput.emit(["event": "error", "error": error.localizedDescription])
            return 2
        }
        let gm: String
        do {
            gm = try await GraphicsMagickHelper.verifyGraphicsMagickAsync(logger: nil).get()
        } catch {
            CLIOutput.emit(["event": "error", "error": error.localizedDescription])
            return 1
        }
        let logger = ConsoleLogger()
        var results: [ImageResult] = []
        // Keep all books sharing an output root in the same image worker pool.
        var roots: [String] = []
        for job in request.jobs where !roots.contains(job.output) { roots.append(job.output) }
        for root in roots {
            if Task.isCancelled { break }
            let jobs = request.jobs.filter { $0.output == root }
            var before: [String: Set<String>] = [:]
            for job in jobs {
                let destination = URL(fileURLWithPath: root).appendingPathComponent(URL(fileURLWithPath: job.input).lastPathComponent)
                before[job.id] = Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
                CLIOutput.emit(Message(event: "job_started", id: job.id, stage: "processing"))
            }
            var failure: String?
            do {
                _ = try await ImageProcessingRunner(gmPath: gm, logger: logger).run(
                    inputs: jobs.map { URL(fileURLWithPath: $0.input) }, output: URL(fileURLWithPath: root),
                    parameters: parameters, cancellationToken: ProcessingCancellationToken(),
                    eventSink: { _ in }
                )
            } catch {
                failure = error.localizedDescription
            }
            for job in jobs {
                let input = URL(fileURLWithPath: job.input)
                let destination = URL(fileURLWithPath: root).appendingPathComponent(input.lastPathComponent)
                let files = (try? FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)) ?? []
                let sources = files.filter { ["jpg", "jpeg", "png", "webp", "bmp"].contains($0.pathExtension.lowercased()) }
                var expected = 0
                var unreadable = false
                for source in sources {
                    switch ImageIOHelper.getImageDimensions(imagePath: source.path) {
                    case .success(let size): expected += size.width >= parameters.widthThreshold ? 2 : 1
                    case .failure: unreadable = true
                    }
                }
                let outputs = ((try? FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension.lowercased() == "jpg" && !(before[job.id] ?? []).contains($0.lastPathComponent) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                let readable = outputs.allSatisfy { if case .success = ImageIOHelper.getImageDimensions(imagePath: $0.path) { true } else { false } }
                let valid = !sources.isEmpty && !unreadable && expected == outputs.count && readable
                let result = ImageResult(
                    id: job.id, status: valid ? "succeeded" : Task.isCancelled ? "cancelled" : "failed",
                    outputs: outputs.map(\.path),
                    error: valid ? nil : failure ?? "Expected \(expected) readable images, generated \(outputs.count); unreadable input: \(unreadable)."
                )
                results.append(result)
                CLIOutput.emit(Message(event: "job_result", id: job.id, result: result))
            }
        }
        for job in request.jobs where !results.contains(where: { $0.id == job.id }) {
            results.append(ImageResult(id: job.id, status: "cancelled", outputs: [], error: "Cancelled before starting"))
        }
        let ordered = request.jobs.compactMap { job in results.first { $0.id == job.id } }
        CLIOutput.emit(Message(event: "summary", results: ordered))
        return Task.isCancelled ? 130 : results.allSatisfy { $0.status == "succeeded" } ? 0 : 1
    }
}
