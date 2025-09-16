//
//  ImageProcessorView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/4/27.
//

import AppKit
import Combine
import SwiftUI

// MARK: - Main View

/// Primary view managing overall layout, state coordination, and user interactions
struct ImageProcessorView: View {
    // MARK: - Dependencies

    @StateObject private var imageProcessor = ImageProcessor()

    @StateObject private var themeManager = ThemeManager.shared

    // MARK: - UI State

    @State private var inputDirectory: URL?
    @State private var outputDirectory: URL?
    @State private var selectedTab = "basic"

    @State private var showLogs = true
    /// Prevent auto-save during initial data loading
    @State private var isLoadingDirectories = false

    @State private var isLoadingParameters = false
    /// Tracks if directory selection is from user action (not loading from saved state)
    @State private var isUserSelection = false

    // MARK: - System Info

    /// Maximum thread count based on physical CPU cores
    private let maxThreadCount = SystemInfoHelper.getMaxThreadCount()

    // MARK: - Basic Parameters

    @State private var widthThreshold = "3000"
    @State private var resizeHeight = "1648"
    @State private var quality = "85"
    @State private var threadCount = 0 // 0 = Auto mode
    @State private var useGrayColorspace = true

    // MARK: - Advanced Parameters

    @State private var unsharpRadius = "1.5"
    @State private var unsharpSigma = "1"
    @State private var unsharpAmount = "0.7"
    @State private var unsharpThreshold = "0.02"
    @State private var batchSize = "40"
    @State private var enableUnsharp = true

    // MARK: - Performance Optimization

    /// Debounced parameter save publisher
    private let parameterSavePublisher = PassthroughSubject<Void, Never>()
    @State private var parameterSaveCancellable: AnyCancellable?

    /// Combined parameter state for single onChange
    private var parametersHash: Int {
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

    // MARK: - Constants

    private enum UserDefaultsKeys {
        static let lastInputDirectory = "Me2Comic.lastInputDirectory"
        static let lastOutputDirectory = "Me2Comic.lastOutputDirectory"

        // Parameter keys
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

    // MARK: - View Layout

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                gmReady: $imageProcessor.gmReady,
                isProcessing: imageProcessor.isProcessing,
                selectedTab: $selectedTab,
                showLogs: $showLogs,
                logMessages: $imageProcessor.logMessages
            )
            .frame(width: 255)

            ZStack {
                Color.bgPrimary
                    .ignoresSafeArea()

                // Decorative gradient overlay
                GeometryReader { geo in
                    RadialGradient(
                        colors: [Color.accentGreen.opacity(0.05), Color.clear],
                        center: .center,
                        startRadius: 100,
                        endRadius: 500
                    )
                    .position(x: geo.size.width * 0.7, y: geo.size.height * 0.3)
                    .blur(radius: 50)
                }

                if imageProcessor.isProcessing {
                    ProcessingView(
                        progress: imageProcessor.processingProgress,
                        processedCount: imageProcessor.currentProcessedImages,
                        totalCount: imageProcessor.totalImagesToProcess,
                        onStop: {
                            withAnimation {
                                imageProcessor.stopProcessing()
                            }
                        }
                    )
                } else {
                    MainContentView(
                        inputDirectory: $inputDirectory,
                        outputDirectory: $outputDirectory,
                        selectedTab: selectedTab,
                        widthThreshold: $widthThreshold,
                        resizeHeight: $resizeHeight,
                        quality: $quality,
                        threadCount: $threadCount,
                        maxThreadCount: maxThreadCount,
                        useGrayColorspace: $useGrayColorspace,
                        unsharpRadius: $unsharpRadius,
                        unsharpSigma: $unsharpSigma,
                        unsharpAmount: $unsharpAmount,
                        unsharpThreshold: $unsharpThreshold,
                        batchSize: $batchSize,
                        enableUnsharp: $enableUnsharp,
                        onProcess: {
                            startProcessing()
                        },
                        onDirectorySelect: {
                            isUserSelection = true

                            Task {
                                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                                await MainActor.run {
                                    isUserSelection = false
                                }
                            }
                        }
                    )
                }
            }

            // Right Log Panel - Optional display
            if showLogs {
                LogPanelMinimal(logMessages: $imageProcessor.logMessages)
                    .frame(width: 350)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: showLogs ? 1050 : 684, minHeight: 684)
        .onAppear {
            setupParameterSaveDebounce()
            loadSavedDirectories()
            loadSavedParameters()
        }
        .onChange(of: inputDirectory) { handleDirectoryChange(inputDirectory, key: UserDefaultsKeys.lastInputDirectory, isInput: true) }
        .onChange(of: outputDirectory) { handleDirectoryChange(outputDirectory, key: UserDefaultsKeys.lastOutputDirectory, isInput: false) }
        .onChange(of: parametersHash) { handleParametersChange() }
    }

    // MARK: - Processing Logic

    private func startProcessing() {
        do {
            let parameters = try ProcessingParametersValidator.validateAndCreateParameters(
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

            withAnimation(.spring()) {
                imageProcessor.processImages(
                    inputDir: inputDirectory!,
                    outputDir: outputDirectory!,
                    parameters: parameters
                )
            }
        } catch {
            imageProcessor.logger.logError(error.localizedDescription, source: "ImageProcessorView")
        }
    }

    // MARK: - Optimized Persistence

    private func setupParameterSaveDebounce() {
        parameterSaveCancellable = parameterSavePublisher
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { _ in
                self.saveParameters()
            }
    }

    private func handleDirectoryChange(_ directory: URL?, key: String, isInput: Bool) {
        guard !isLoadingDirectories else { return }

        saveDirectoryToUserDefaults(directory, key: key)

        if isUserSelection, let url = directory {
            let msg = String(
                format: NSLocalizedString(isInput ? "SelectedInputDir" : "SelectedOutputDir", comment: ""),
                url.path
            )
            imageProcessor.logger.log(msg, level: .success, source: "ImageProcessorView")
        }
    }

    private func handleParametersChange() {
        guard !isLoadingParameters else { return }
        parameterSavePublisher.send()
    }

    private func saveParameters() {
        let defaults = UserDefaults.standard

        defaults.set(widthThreshold, forKey: UserDefaultsKeys.widthThreshold)
        defaults.set(resizeHeight, forKey: UserDefaultsKeys.resizeHeight)
        defaults.set(quality, forKey: UserDefaultsKeys.quality)
        defaults.set(threadCount, forKey: UserDefaultsKeys.threadCount)
        defaults.set(useGrayColorspace, forKey: UserDefaultsKeys.useGrayColorspace)
        defaults.set(unsharpRadius, forKey: UserDefaultsKeys.unsharpRadius)
        defaults.set(unsharpSigma, forKey: UserDefaultsKeys.unsharpSigma)
        defaults.set(unsharpAmount, forKey: UserDefaultsKeys.unsharpAmount)
        defaults.set(unsharpThreshold, forKey: UserDefaultsKeys.unsharpThreshold)
        defaults.set(batchSize, forKey: UserDefaultsKeys.batchSize)
        defaults.set(enableUnsharp, forKey: UserDefaultsKeys.enableUnsharp)

        #if DEBUG
        imageProcessor.logger.logDebug("Parameters saved to UserDefaults", source: "ImageProcessorView")
        #endif
    }

    private func loadSavedParameters() {
        #if DEBUG
        imageProcessor.logger.logDebug("Loading saved parameters", source: "ImageProcessorView")
        #endif

        isLoadingParameters = true
        let defaults = UserDefaults.standard

        // Load with defaults if not present
        widthThreshold = defaults.string(forKey: UserDefaultsKeys.widthThreshold) ?? "3000"
        resizeHeight = defaults.string(forKey: UserDefaultsKeys.resizeHeight) ?? "1648"
        quality = defaults.string(forKey: UserDefaultsKeys.quality) ?? "85"

        // Load and validate thread count
        let savedThreadCount = defaults.integer(forKey: UserDefaultsKeys.threadCount)
        if savedThreadCount == 0 {
            threadCount = 0 // 0 = Auto mode
        } else if savedThreadCount >= 1 && savedThreadCount <= maxThreadCount {
            threadCount = savedThreadCount
        } else if savedThreadCount > maxThreadCount {
            threadCount = maxThreadCount
            #if DEBUG
            imageProcessor.logger.logDebug("Thread count clamped from \(savedThreadCount) to \(maxThreadCount)", source: "ImageProcessorView")
            #endif
        } else {
            threadCount = 0
        }

        useGrayColorspace = defaults.object(forKey: UserDefaultsKeys.useGrayColorspace) as? Bool ?? true
        unsharpRadius = defaults.string(forKey: UserDefaultsKeys.unsharpRadius) ?? "1.5"
        unsharpSigma = defaults.string(forKey: UserDefaultsKeys.unsharpSigma) ?? "1"
        unsharpAmount = defaults.string(forKey: UserDefaultsKeys.unsharpAmount) ?? "0.7"
        unsharpThreshold = defaults.string(forKey: UserDefaultsKeys.unsharpThreshold) ?? "0.02"
        batchSize = defaults.string(forKey: UserDefaultsKeys.batchSize) ?? "40"
        enableUnsharp = defaults.object(forKey: UserDefaultsKeys.enableUnsharp) as? Bool ?? true

        isLoadingParameters = false

        #if DEBUG
        imageProcessor.logger.logDebug("Parameters loaded from UserDefaults", source: "ImageProcessorView")
        #endif
    }

    // MARK: - Directory Persistence

    private func saveDirectoryToUserDefaults(_ url: URL?, key: String) {
        if let url = url {
            UserDefaults.standard.set(url, forKey: key)
            #if DEBUG
            imageProcessor.logger.logDebug("Successfully saved directory for key: \(key), path: \(url.path)", source: "ImageProcessorView")
            #endif
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            #if DEBUG
            imageProcessor.logger.logDebug("Removed directory for key: \(key)", source: "ImageProcessorView")
            #endif
        }
    }

    private func loadDirectoryFromUserDefaults(key: String) -> URL? {
        guard let savedURL = UserDefaults.standard.url(forKey: key) else {
            #if DEBUG
            imageProcessor.logger.logDebug("No saved directory found for key: \(key)", source: "ImageProcessorView")
            #endif
            return nil
        }

        // Verify directory still exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            #if DEBUG
            imageProcessor.logger.logDebug("Saved directory no longer exists: \(savedURL.path)", source: "ImageProcessorView")
            #endif
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        #if DEBUG
        imageProcessor.logger.logDebug("Successfully loaded directory for key: \(key), path: \(savedURL.path)", source: "ImageProcessorView")
        #endif

        return savedURL
    }

    private func loadSavedDirectories() {
        #if DEBUG
        imageProcessor.logger.logDebug("Starting to load saved directories", source: "ImageProcessorView")
        #endif

        isLoadingDirectories = true

        if let savedInputDir = loadDirectoryFromUserDefaults(key: UserDefaultsKeys.lastInputDirectory) {
            inputDirectory = savedInputDir
            let msg = String(
                format: NSLocalizedString("LoadedLastInputDir", comment: ""),
                savedInputDir.path
            )
            imageProcessor.logger.log(msg, level: .success)

            #if DEBUG
            imageProcessor.logger.logDebug("Successfully loaded input directory: \(savedInputDir.path)", source: "ImageProcessorView")
            #endif
        } else {
            #if DEBUG
            imageProcessor.logger.logDebug("No saved input directory found", source: "ImageProcessorView")
            #endif
        }

        if let savedOutputDir = loadDirectoryFromUserDefaults(key: UserDefaultsKeys.lastOutputDirectory) {
            outputDirectory = savedOutputDir
            let msg = String(
                format: NSLocalizedString("LoadedLastOutputDir", comment: ""),
                savedOutputDir.path
            )
            imageProcessor.logger.log(msg, level: .success)

            #if DEBUG
            imageProcessor.logger.logDebug("Successfully loaded output directory: \(savedOutputDir.path)", source: "ImageProcessorView")
            #endif
        } else {
            #if DEBUG
            imageProcessor.logger.logDebug("No saved output directory found", source: "ImageProcessorView")
            #endif
        }

        isLoadingDirectories = false

        #if DEBUG
        imageProcessor.logger.logDebug("Finished loading saved directories", source: "ImageProcessorView")
        #endif
    }
}
