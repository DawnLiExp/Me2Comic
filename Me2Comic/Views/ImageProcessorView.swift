//
//  ImageProcessorView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/4/27.
//

import AppKit
import SwiftUI

// MARK: - Main View

/// The main view of the image processor.
/// Manages the overall layout, state coordination, and user interaction.
struct ImageProcessorView: View {
    // MARK: - Dependencies

    /// The image processor instance that manages the backend processing logic.
    @StateObject private var imageProcessor = ImageProcessor()
    /// Theme manager for color scheme
    @StateObject private var themeManager = ThemeManager.shared

    // MARK: - UI State

    @State private var inputDirectory: URL?
    @State private var outputDirectory: URL?
    @State private var selectedTab = "basic"

    @State private var showLogs = true
    /// Prevents directory auto-save during initial load.
    @State private var isLoadingDirectories = false
    /// Prevents parameter auto-save during initial load
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
    /// 0 = auto-detect
    @State private var threadCount = 0
    @State private var useGrayColorspace = true

    // MARK: - Advanced Parameters

    @State private var unsharpRadius = "1.5"
    @State private var unsharpSigma = "1"
    @State private var unsharpAmount = "0.7"
    @State private var unsharpThreshold = "0.02"
    @State private var batchSize = "40"
    @State private var enableUnsharp = true

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
            // Left Sidebar - Navigation and status display
            SidebarView(
                gmReady: $imageProcessor.gmReady,
                isProcessing: imageProcessor.isProcessing,
                selectedTab: $selectedTab,
                showLogs: $showLogs,
                logMessages: $imageProcessor.logMessages
            )
            .frame(width: 270)

            // Main Content Area - Parameter configuration and processing interface
            ZStack {
                // Background Layer
                Color.bgPrimary
                    .ignoresSafeArea()

                // Decorative Element - Gradient glow effect
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

                // Content Switch - Processing view or parameter configuration view
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
                            // Reset flag after a short delay
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
        // .background(Color.bgPrimary)  // Temporary comment for UI testing
        .onAppear {
            loadSavedDirectories()
            loadSavedParameters()
        }
        .onChange(of: inputDirectory) {
            if !isLoadingDirectories {
                saveDirectoryToUserDefaults(inputDirectory, key: UserDefaultsKeys.lastInputDirectory)

                // Only log if this is a user selection (not loading from saved)
                if isUserSelection, let url = inputDirectory {
                    let msg = String(
                        format: NSLocalizedString("SelectedInputDir", comment: ""),
                        url.path
                    )
                    imageProcessor.logger.log(msg, level: .success, source: "ImageProcessorView")
                }
            }
        }
        .onChange(of: outputDirectory) {
            if !isLoadingDirectories {
                saveDirectoryToUserDefaults(outputDirectory, key: UserDefaultsKeys.lastOutputDirectory)

                // Only log if this is a user selection (not loading from saved)
                if isUserSelection, let url = outputDirectory {
                    let msg = String(
                        format: NSLocalizedString("SelectedOutputDir", comment: ""),
                        url.path
                    )
                    imageProcessor.logger.log(msg, level: .success, source: "ImageProcessorView")
                }
            }
        }

        // Parameter persistence
        .onChange(of: widthThreshold) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: resizeHeight) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: quality) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: threadCount) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: useGrayColorspace) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: unsharpRadius) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: unsharpSigma) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: unsharpAmount) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: unsharpThreshold) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: batchSize) { if !isLoadingParameters { saveParameters() } }
        .onChange(of: enableUnsharp) { if !isLoadingParameters { saveParameters() } }
    }

    // MARK: - Processing Logic

    /// Starts the image processing.
    /// Validates parameters and initiates the image processing workflow.
    private func startProcessing() {
        // Use ProcessingParametersValidator for validation
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

            // Start the processing workflow
            withAnimation(.spring()) {
                imageProcessor.processImages(
                    inputDir: inputDirectory!,
                    outputDir: outputDirectory!,
                    parameters: parameters
                )
            }
        } catch {
            // Log validation error
            imageProcessor.logger.logError(error.localizedDescription, source: "ImageProcessorView")
        }
    }

    // MARK: - Parameter Persistence

    /// Save all parameters to UserDefaults
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

    /// Load saved parameters from UserDefaults
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
            threadCount = 0 // Auto mode
        } else if savedThreadCount >= 1 && savedThreadCount <= maxThreadCount {
            threadCount = savedThreadCount // Valid saved value
        } else if savedThreadCount > maxThreadCount {
            threadCount = maxThreadCount // Clamp to current machine's max
            #if DEBUG
            imageProcessor.logger.logDebug("Thread count clamped from \(savedThreadCount) to \(maxThreadCount)", source: "ImageProcessorView")
            #endif
        } else {
            threadCount = 0 // Invalid value, default to auto
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

    /// Saves a directory URL to UserDefaults
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

    /// Loads a directory URL from UserDefaults
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
            // Remove invalid directory
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }

        #if DEBUG
        imageProcessor.logger.logDebug("Successfully loaded directory for key: \(key), path: \(savedURL.path)", source: "ImageProcessorView")
        #endif

        return savedURL
    }

    /// Loads saved directories from UserDefaults on app launch
    private func loadSavedDirectories() {
        #if DEBUG
        imageProcessor.logger.logDebug("Starting to load saved directories", source: "ImageProcessorView")
        #endif

        // Prevent onChange from triggering saves during initial load
        isLoadingDirectories = true

        // Load input directory
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

        // Load output directory
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

        // Re-enable saving for future changes
        isLoadingDirectories = false

        #if DEBUG
        imageProcessor.logger.logDebug("Finished loading saved directories", source: "ImageProcessorView")
        #endif
    }
}
