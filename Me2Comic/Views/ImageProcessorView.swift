//
//  ImageProcessorView.swift
//  Me2Comic
//
//  主界面：视图入口，协调所有子视图
//

import AppKit
import SwiftUI

// MARK: - Main View

/// Primary view managing overall layout, state coordination, and user interactions
struct ImageProcessorView: View {
    // MARK: - State Sources (Single Source of Truth)

    @State private var stateManager: ProcessingStateManager
    @State private var logger: ProcessingLogger

    // MARK: - Processing Coordinator

    @State private var imageProcessor: ImageProcessor

    // MARK: - Settings Store

    @State private var settings = AppSettingsStore()

    // MARK: - UI State

    @State private var selectedTab = "basic"
    @State private var showLogs = true

    /// Distinguishes user-initiated directory selections from programmatic loads (for logging)
    @State private var isUserSelection = false

    /// Debounce task for parameter auto-save
    @State private var parameterSaveTask: Task<Void, Never>?

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
                            withAnimation { imageProcessor.stopProcessing() }
                        }
                    )
                } else {
                    MainContentView(
                        settings: settings,
                        selectedTab: selectedTab,
                        onProcess: { startProcessing() },
                        onDirectorySelect: { handleDirectorySelectStart() }
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
        .onAppear { logLoadedDirectories() }
        .onDisappear { parameterSaveTask?.cancel() }
        .onChange(of: settings.inputDirectory) { handleInputDirectoryChange() }
        .onChange(of: settings.outputDirectory) { handleOutputDirectoryChange() }
        .onChange(of: settings.parametersHash) { handleParametersChange() }
    }

    // MARK: - Processing

    private func startProcessing() {
        do {
            let parameters = try settings.buildParameters()
            withAnimation(.spring()) {
                imageProcessor.processImages(
                    inputDir: settings.inputDirectory!,
                    outputDir: settings.outputDirectory!,
                    parameters: parameters
                )
            }
        } catch {
            logger.logError(error.localizedDescription, source: "ImageProcessorView")
        }
    }

    // MARK: - Directory Handling

    /// Logs directories that were restored from UserDefaults on app launch
    private func logLoadedDirectories() {
        if let url = settings.inputDirectory {
            logger.log(
                String(format: String(localized: "LoadedLastInputDir"), url.path),
                level: .success
            )
        }
        if let url = settings.outputDirectory {
            logger.log(
                String(format: String(localized: "LoadedLastOutputDir"), url.path),
                level: .success
            )
        }
    }

    /// Marks the next directory change as user-initiated (for logging purposes)
    private func handleDirectorySelectStart() {
        isUserSelection = true
        Task {
            try? await Task.sleep(for: .milliseconds(100))
            isUserSelection = false
        }
    }

    private func handleInputDirectoryChange() {
        settings.saveDirectory(settings.inputDirectory, forKey: .input)
        if isUserSelection, let url = settings.inputDirectory {
            logger.log(
                String(format: String(localized: "SelectedInputDir"), url.path),
                level: .success,
                source: "ImageProcessorView"
            )
        }
    }

    private func handleOutputDirectoryChange() {
        settings.saveDirectory(settings.outputDirectory, forKey: .output)
        if isUserSelection, let url = settings.outputDirectory {
            logger.log(
                String(format: String(localized: "SelectedOutputDir"), url.path),
                level: .success,
                source: "ImageProcessorView"
            )
        }
    }

    // MARK: - Parameter Persistence

    /// Debounced save: waits 500ms after last change before writing to UserDefaults
    private func handleParametersChange() {
        parameterSaveTask?.cancel()
        parameterSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            settings.saveParameters()
            #if DEBUG
            logger.logDebug("Parameters saved to UserDefaults", source: "ImageProcessorView")
            #endif
        }
    }
}
