//
//  AppSettingsStore.swift
//  Me2Comic
//
//  应用设置持久化：集中管理处理参数和目录的 UserDefaults 读写
//

import Foundation
import Observation

// MARK: - AppSettingsStore

/// Centralized persistence for all user-configurable parameters and directory selections.
/// Loads from UserDefaults on init; exposes explicit save methods for View-driven persistence.
@Observable
@MainActor
final class AppSettingsStore {
    // MARK: - System Info (Read-Only)

    /// Maximum allowed thread count based on physical CPU cores
    let maxThreadCount: Int

    // MARK: - Basic Parameters

    var widthThreshold: String = "3000"
    var resizeHeight: String = "1648"
    var quality: String = "85"
    var threadCount: Int = 0 // 0 = Auto
    var useGrayColorspace: Bool = true

    // MARK: - Advanced Parameters

    var unsharpRadius: String = "1.5"
    var unsharpSigma: String = "1"
    var unsharpAmount: String = "0.7"
    var unsharpThreshold: String = "0.02"
    var batchSize: String = "40"
    var enableUnsharp: Bool = true

    // MARK: - Directories

    var inputDirectory: URL?
    var outputDirectory: URL?

    // MARK: - Change Detection

    /// Combined hash of all parameters for single `.onChange` observation in the View
    var parametersHash: Int {
        var hasher = Hasher()
        hasher.combine(widthThreshold)
        hasher.combine(resizeHeight)
        hasher.combine(quality)
        hasher.combine(threadCount)
        hasher.combine(useGrayColorspace)
        hasher.combine(unsharpRadius)
        hasher.combine(unsharpSigma)
        hasher.combine(unsharpAmount)
        hasher.combine(unsharpThreshold)
        hasher.combine(batchSize)
        hasher.combine(enableUnsharp)
        return hasher.finalize()
    }

    // MARK: - Directory Key

    enum DirectoryKey {
        case input
        case output
    }

    // MARK: - UserDefaults Keys

    enum Keys {
        static let lastInputDirectory = "Me2Comic.lastInputDirectory"
        static let lastOutputDirectory = "Me2Comic.lastOutputDirectory"
        static let widthThreshold = "Me2Comic.widthThreshold"
        static let resizeHeight = "Me2Comic.resizeHeight"
        static let quality = "Me2Comic.quality"
        static let threadCount = "Me2Comic.threadCount"
        static let useGrayColorspace = "Me2Comic.useGrayColorspace"
        static let unsharpRadius = "Me2Comic.unsharpRadius"
        static let unsharpSigma = "Me2Comic.unsharpSigma"
        static let unsharpAmount = "Me2Comic.unsharpAmount"
        static let unsharpThreshold = "Me2Comic.unsharpThreshold"
        static let batchSize = "Me2Comic.batchSize"
        static let enableUnsharp = "Me2Comic.enableUnsharp"
    }

    // MARK: - Initialization

    init() {
        maxThreadCount = SystemInfoHelper.getMaxThreadCount()
        loadParameters()
        loadDirectories()
    }

    // MARK: - Parameter Persistence

    /// Writes all current parameter values to UserDefaults
    func saveParameters() {
        let d = UserDefaults.standard
        d.set(widthThreshold, forKey: Keys.widthThreshold)
        d.set(resizeHeight, forKey: Keys.resizeHeight)
        d.set(quality, forKey: Keys.quality)
        d.set(threadCount, forKey: Keys.threadCount)
        d.set(useGrayColorspace, forKey: Keys.useGrayColorspace)
        d.set(unsharpRadius, forKey: Keys.unsharpRadius)
        d.set(unsharpSigma, forKey: Keys.unsharpSigma)
        d.set(unsharpAmount, forKey: Keys.unsharpAmount)
        d.set(unsharpThreshold, forKey: Keys.unsharpThreshold)
        d.set(batchSize, forKey: Keys.batchSize)
        d.set(enableUnsharp, forKey: Keys.enableUnsharp)
    }

    // MARK: - Directory Persistence

    /// Persists a directory URL to UserDefaults using a type-safe key
    func saveDirectory(_ url: URL?, forKey key: DirectoryKey) {
        let udKey = key == .input ? Keys.lastInputDirectory : Keys.lastOutputDirectory
        persist(directory: url, forKey: udKey)
    }

    // MARK: - Parameter Building

    /// Validates current state and constructs a `ProcessingParameters` value.
    /// Applies `enableUnsharp` logic: passes "0" as unsharpAmount when sharpening is disabled.
    /// - Throws: `ProcessingParameterError` if any field is invalid
    func buildParameters() throws -> ProcessingParameters {
        try ProcessingParametersValidator.validateAndCreateParameters(
            inputDirectory: inputDirectory,
            outputDirectory: outputDirectory,
            widthThreshold: widthThreshold,
            resizeHeight: resizeHeight,
            quality: quality,
            threadCount: threadCount,
            unsharpRadius: unsharpRadius,
            unsharpSigma: unsharpSigma,
            unsharpAmount: enableUnsharp ? unsharpAmount : "0",
            unsharpThreshold: unsharpThreshold,
            batchSize: batchSize,
            useGrayColorspace: useGrayColorspace
        )
    }

    // MARK: - Private Load

    private func loadParameters() {
        let d = UserDefaults.standard

        widthThreshold = d.string(forKey: Keys.widthThreshold) ?? "3000"
        resizeHeight = d.string(forKey: Keys.resizeHeight) ?? "1648"
        quality = d.string(forKey: Keys.quality) ?? "85"
        useGrayColorspace = d.object(forKey: Keys.useGrayColorspace) as? Bool ?? true
        unsharpRadius = d.string(forKey: Keys.unsharpRadius) ?? "1.5"
        unsharpSigma = d.string(forKey: Keys.unsharpSigma) ?? "1"
        unsharpAmount = d.string(forKey: Keys.unsharpAmount) ?? "0.7"
        unsharpThreshold = d.string(forKey: Keys.unsharpThreshold) ?? "0.02"
        batchSize = d.string(forKey: Keys.batchSize) ?? "40"
        enableUnsharp = d.object(forKey: Keys.enableUnsharp) as? Bool ?? true

        // Clamp thread count: 0 = Auto, [1, maxThreadCount] = valid manual range
        let saved = d.integer(forKey: Keys.threadCount)
        switch saved {
        case 0:
            threadCount = 0
        case 1 ... maxThreadCount:
            threadCount = saved
        default:
            // Clamp out-of-range values (e.g. saved on a machine with more cores)
            threadCount = saved > maxThreadCount ? maxThreadCount : 0
        }
    }

    private func loadDirectories() {
        inputDirectory = loadVerifiedDirectory(forKey: Keys.lastInputDirectory)
        outputDirectory = loadVerifiedDirectory(forKey: Keys.lastOutputDirectory)
    }

    /// Loads a directory URL and verifies it still exists on disk.
    /// Removes stale entries from UserDefaults if the path no longer exists.
    private func loadVerifiedDirectory(forKey key: String) -> URL? {
        guard let url = UserDefaults.standard.url(forKey: key) else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        return url
    }

    private func persist(directory url: URL?, forKey key: String) {
        if let url {
            UserDefaults.standard.set(url, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
