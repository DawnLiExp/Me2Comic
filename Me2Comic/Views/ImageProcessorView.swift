//
//  ImageProcessorView.swift
//  Me2Comic
//
//  主界面：视图入口，直接持有状态组件(StateManager/Logger)，协调子视图
//

import AppKit
import SwiftUI

// MARK: - Main View

/// Primary view managing overall layout, state coordination, and user interactions
struct ImageProcessorView: View {
    // MARK: - State Sources (Single Source of Truth)

    @State private var stateManager = ProcessingStateManager()
    @State private var logger = ProcessingLogger()

    // MARK: - Processing Coordinator

    @State private var imageProcessor: ImageProcessor

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

    /// Debounced parameter save task
    @State private var parameterSaveTask: Task<Void, Never>?

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

    // MARK: - Initialization

    init() {
        let sm = ProcessingStateManager()
        let lg = ProcessingLogger()
        _stateManager = State(initialValue: sm)
        _logger = State(initialValue: lg)
        _imageProcessor = State(initialValue: ImageProcessor(stateManager: sm, logger: lg))
    }

    // MARK: - View Layout

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                gmReady: $imageProcessor.gmReady,
                isProcessing: stateManager.isProcessing,
                selectedTab: $selectedTab,
                showLogs: $showLogs,
                logger: logger
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

                if stateManager.isProcessing {
                    ProcessingView(
                        progress: stateManager.processingProgress,
                        processedCount: stateManager.currentProcessedImages,
                        totalCount: stateManager.totalImagesToProcess,
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
                LogPanelMinimal(logger: logger)
                    .frame(width: 350)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(minWidth: showLogs ? 1050 : 684, minHeight: 684)
        .onAppear {
            loadSavedDirectories()
            loadSavedParameters()
        }
        .onDisappear {
            parameterSaveTask?.cancel()
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
            logger.logError(error.localizedDescription, source: "ImageProcessorView")
        }
    }

    // MARK: - Optimized Persistence

    private func handleDirectoryChange(_ directory: URL?, key: String, isInput: Bool) {
        guard !isLoadingDirectories else { return }

        saveDirectoryToUserDefaults(directory, key: key)

        if isUserSelection, let url = directory {
            let msg = String(format: String(localized: isInput ? "SelectedInputDir" : "SelectedOutputDir"), url.path)
            logger.log(msg, level: .success, source: "ImageProcessorView")
        }
    }

    private func handleParametersChange() {
        guard !isLoadingParameters else { return }
        parameterSaveTask?.cancel()
        parameterSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            saveParameters()
        }
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
        logger.logDebug("Parameters saved to UserDefaults", source: "ImageProcessorView")
        #endif
    }

    private func loadSavedParameters() {
        #if DEBUG
        logger.logDebug("Loading saved parameters", source: "ImageProcessorView")
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
        } else if savedThreadCount >= 1, savedThreadCount <= maxThreadCount {
            threadCount = savedThreadCount
        } else if savedThreadCount > maxThreadCount {
            threadCount = maxThreadCount
            #if DEBUG
            logger.logDebug("Thread count clamped from \(savedThreadCount) to \(maxThreadCount)", source: "ImageProcessorView")
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
        logger.logDebug("Parameters loaded from UserDefaults", source: "ImageProcessorView")
        #endif
    }

    // MARK: - Directory Persistence

    private func saveDirectoryToUserDefaults(_ url: URL?, key: String) {
        if let url {
            UserDefaults.standard.set(url, forKey: key)
            #if DEBUG
            logger.logDebug("Successfully saved directory for key: \(key), path: \(url.path)", source: "ImageProcessorView")
            #endif
        } else {
            UserDefaults.standard.removeObject(forKey: key)
            #if DEBUG
            logger.logDebug("Removed directory for key: \(key)", source: "ImageProcessorView")
            #endif
        }
    }

    private func loadDirectoryFromUserDefaults(key: String) -> URL? {
        guard let savedURL = UserDefaults.standard.url(forKey: key) else {
            #if DEBUG
            logger.logDebug("No saved directory found for key: \(key)", source: "ImageProcessorView")
            #endif
            return nil
        }

        // Verify directory still exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: savedURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            #if DEBUG
            logger.logDebug("Saved directory no longer exists: \(savedURL.path)", source: "ImageProcessorView")
            #endif
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        #if DEBUG
        logger.logDebug("Successfully loaded directory for key: \(key), path: \(savedURL.path)", source: "ImageProcessorView")
        #endif

        return savedURL
    }

    private func loadSavedDirectories() {
        #if DEBUG
        logger.logDebug("Starting to load saved directories", source: "ImageProcessorView")
        #endif

        isLoadingDirectories = true

        if let savedInputDir = loadDirectoryFromUserDefaults(key: UserDefaultsKeys.lastInputDirectory) {
            inputDirectory = savedInputDir
            let msg = String(format: String(localized: "LoadedLastInputDir"), savedInputDir.path)
            logger.log(msg, level: .success)

            #if DEBUG
            logger.logDebug("Successfully loaded input directory: \(savedInputDir.path)", source: "ImageProcessorView")
            #endif
        } else {
            #if DEBUG
            logger.logDebug("No saved input directory found", source: "ImageProcessorView")
            #endif
        }

        if let savedOutputDir = loadDirectoryFromUserDefaults(key: UserDefaultsKeys.lastOutputDirectory) {
            outputDirectory = savedOutputDir
            let msg = String(format: String(localized: "LoadedLastOutputDir"), savedOutputDir.path)
            logger.log(msg, level: .success)

            #if DEBUG
            logger.logDebug("Successfully loaded output directory: \(savedOutputDir.path)", source: "ImageProcessorView")
            #endif
        } else {
            #if DEBUG
            logger.logDebug("No saved output directory found", source: "ImageProcessorView")
            #endif
        }

        isLoadingDirectories = false

        #if DEBUG
        logger.logDebug("Finished loading saved directories", source: "ImageProcessorView")
        #endif
    }
}
