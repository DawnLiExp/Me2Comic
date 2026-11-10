import Foundation

struct ComicCLISettings: Codable, Sendable {
    let parameters: ProcessingParameters
    let outputDirectory: String?

    @MainActor
    static func load(defaults: UserDefaults) throws -> Self {
        func string(_ key: String, _ fallback: String) -> String {
            defaults.string(forKey: "Me2Comic." + key) ?? fallback
        }
        let savedThreads = defaults.integer(forKey: "Me2Comic.threadCount")
        let threads = max(0, min(savedThreads, SystemInfoHelper.getMaxThreadCount()))
        let parameters = try ProcessingParametersValidator.validateAndCreateParameters(
            inputDirectory: URL(fileURLWithPath: "/"), outputDirectory: URL(fileURLWithPath: "/"),
            widthThreshold: string("widthThreshold", "3000"), resizeHeight: string("resizeHeight", "1648"),
            quality: string("quality", "85"), threadCount: threads,
            unsharpRadius: string("unsharpRadius", "1.5"), unsharpSigma: string("unsharpSigma", "1"),
            unsharpAmount: string("unsharpAmount", "0.7"), unsharpThreshold: string("unsharpThreshold", "0.02"),
            batchSize: string("batchSize", "40"),
            useGrayColorspace: defaults.object(forKey: "Me2Comic.useGrayColorspace") as? Bool ?? true,
            enableUnsharp: defaults.object(forKey: "Me2Comic.enableUnsharp") as? Bool ?? true
        )
        return Self(parameters: parameters, outputDirectory: defaults.url(forKey: "Me2Comic.lastOutputDirectory")?.path)
    }

    @MainActor
    func validatedParameters() throws -> ProcessingParameters {
        let p = parameters
        guard p.threadCount >= 0, p.threadCount <= SystemInfoHelper.getMaxThreadCount() else {
            throw CLIRequestError("threadCount is outside this machine's supported range.")
        }
        return try ProcessingParametersValidator.validateAndCreateParameters(
            inputDirectory: URL(fileURLWithPath: "/"), outputDirectory: URL(fileURLWithPath: "/"),
            widthThreshold: String(p.widthThreshold), resizeHeight: String(p.resizeHeight), quality: String(p.quality),
            threadCount: p.threadCount, unsharpRadius: String(p.unsharpRadius), unsharpSigma: String(p.unsharpSigma),
            unsharpAmount: String(p.unsharpAmount), unsharpThreshold: String(p.unsharpThreshold),
            batchSize: String(p.batchSize), useGrayColorspace: p.useGrayColorspace, enableUnsharp: p.unsharpAmount > 0
        )
    }
}
