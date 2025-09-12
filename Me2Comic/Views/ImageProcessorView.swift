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

    // MARK: - UI State

    @State private var inputDirectory: URL?
    @State private var outputDirectory: URL?
    @State private var selectedTab = "basic"

    @State private var showLogs = true
    /// Prevents directory auto-save during initial load.
    @State private var isLoadingDirectories = false

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
                        useGrayColorspace: $useGrayColorspace,
                        unsharpRadius: $unsharpRadius,
                        unsharpSigma: $unsharpSigma,
                        unsharpAmount: $unsharpAmount,
                        unsharpThreshold: $unsharpThreshold,
                        batchSize: $batchSize,
                        enableUnsharp: $enableUnsharp,
                        onProcess: {
                            startProcessing()
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
        .frame(minWidth: showLogs ? 1050 : 687, minHeight: 676)
        .background(Color.bgPrimary)
        .onAppear {
            loadSavedDirectories()
        }
        .onChange(of: inputDirectory) {
            if !isLoadingDirectories {
                saveDirectoryToUserDefaults(inputDirectory, key: UserDefaultsKeys.lastInputDirectory)
            }
        }
        .onChange(of: outputDirectory) {
            if !isLoadingDirectories {
                saveDirectoryToUserDefaults(outputDirectory, key: UserDefaultsKeys.lastOutputDirectory)
            }
        }
    }

    // MARK: - Processing Logic

    /// Starts the image processing.
    /// Validates parameters and initiates the image processing workflow.
    private func startProcessing() {
        // Validate directory selection
        guard let inputDir = inputDirectory,
              let outputDir = outputDirectory
        else {
            imageProcessor.logger.logError(NSLocalizedString("NoInputOrOutputDir", comment: "Error: Input or output directory not selected"))
            return
        }

        // Validate and convert parameters
        guard let widthThresholdInt = Int(widthThreshold),
              let resizeHeightInt = Int(resizeHeight),
              let qualityInt = Int(quality),
              let unsharpRadiusFloat = Float(unsharpRadius),
              let unsharpSigmaFloat = Float(unsharpSigma),
              let unsharpAmountFloat = Float(unsharpAmount),
              let unsharpThresholdFloat = Float(unsharpThreshold),
              let batchSizeInt = Int(batchSize)
        else {
            imageProcessor.logger.logError(NSLocalizedString("InvalidParameters", comment: "Invalid parameter format"))
            return
        }

        // Build processing parameters
        let parameters = ProcessingParameters(
            widthThreshold: widthThresholdInt,
            resizeHeight: resizeHeightInt,
            quality: qualityInt,
            threadCount: threadCount,
            unsharpRadius: unsharpRadiusFloat,
            unsharpSigma: unsharpSigmaFloat,
            unsharpAmount: enableUnsharp ? unsharpAmountFloat : 0,
            unsharpThreshold: unsharpThresholdFloat,
            batchSize: batchSizeInt,
            useGrayColorspace: useGrayColorspace
        )

        // Start the processing workflow
        withAnimation(.spring()) {
            imageProcessor.processImages(
                inputDir: inputDir,
                outputDir: outputDir,
                parameters: parameters
            )
        }
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
            imageProcessor.logger.log(msg, level: .info)

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
            imageProcessor.logger.log(msg, level: .info)

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
