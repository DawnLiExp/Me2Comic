//
//  ImageProcessorView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/4/27.
//

import AppKit
import SwiftUI
import UserNotifications

/// UserDefault key for storing the last used output directory
private let lastUsedOutputDirKey = "lastUsedOutputDirectory"

/// UserDefault keys for storing processing parameters
private let widthThresholdKey = "widthThreshold"
private let resizeHeightKey = "resizeHeight"
private let qualityKey = "quality"
private let threadCountKey = "threadCount"
private let unsharpRadiusKey = "unsharpRadius"
private let unsharpSigmaKey = "unsharpSigma"
private let unsharpAmountKey = "unsharpAmount"
private let unsharpThresholdKey = "unsharpThreshold"
private let batchSizeKey = "batchSize"
private let useGrayColorspaceKey = "useGrayColorspace"

/// Main user interface for the image processing application
struct ImageProcessorView: View {
    @State private var inputDirectory: URL?
    @State private var outputDirectory: URL?
    @State private var widthThreshold: String = "3000"
    @State private var resizeHeight: String = "1648"
    @State private var quality: String = "85"
    @State private var threadCount: Int = 0
    @State private var unsharpRadius: String = "1.5"
    @State private var useGrayColorspace: Bool = true
    @State private var unsharpSigma: String = "1"
    @State private var unsharpAmount: String = "0.7"
    @State private var unsharpThreshold: String = "0.02"
    @State private var batchSize: String = "40"
    
    @StateObject private var processor = ImageProcessor()
    @State private var showProgressAfterCompletion: Bool = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LeftPanelView() // Left panel of the UI
            
            GradientDividerView() // Visual divider between panels
            
            VStack(spacing: 20) {
                Spacer().frame(height: 5)
                
                // Input Directory Selection Button
                DirectoryButtonView(
                    title: String(format: NSLocalizedString("Input Directory", comment: ""),
                                  inputDirectory?.path ?? NSLocalizedString("Input Directory Placeholder", comment: "")),
                    action: { selectInputDirectory() },
                    isProcessing: processor.isProcessing,
                    openAction: nil,
                    showOpenButton: false,
                    onDropAction: { url in
                        self.inputDirectory = url
                        self.processor.appendLog(String(format: NSLocalizedString("SelectedInputDir", comment: ""), url.path))
                    }
                )
                .padding(.top, -11)
                
                // Output Directory Selection Button
                DirectoryButtonView(
                    title: String(format: NSLocalizedString("Output Directory", comment: ""),
                                  outputDirectory?.path ?? NSLocalizedString("Output Directory Placeholder", comment: "")),
                    action: { selectOutputDirectory() },
                    isProcessing: processor.isProcessing,
                    openAction: {
                        if let url = outputDirectory {
                            NSWorkspace.shared.open(url)
                        }
                    },
                    showOpenButton: true,
                    onDropAction: { url in
                        self.outputDirectory = url
                        self.processor.appendLog(String(format: NSLocalizedString("SelectedOutputDir", comment: ""), url.path))
                        // Save the newly selected output directory
                        UserDefaults.standard.set(url.path, forKey: lastUsedOutputDirKey)
                    }
                )
                .padding(.bottom, 10)
                
                // Panel for image processing parameters
                HStack(alignment: .top, spacing: 18) {
                    SettingsPanelView(
                        widthThreshold: $widthThreshold,
                        resizeHeight: $resizeHeight,
                        quality: $quality,
                        threadCount: $threadCount,
                        unsharpRadius: $unsharpRadius,
                        unsharpSigma: $unsharpSigma,
                        unsharpAmount: $unsharpAmount,
                        unsharpThreshold: $unsharpThreshold,
                        batchSize: $batchSize,
                        useGrayColorspace: $useGrayColorspace,
                        isProcessing: processor.isProcessing
                    )
                    
                    // Description for the processing parameters
                    ParameterDescriptionView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, -3)
                }
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(.panelBackground)
                
                // Action button to start or stop processing
                ActionButtonView(isProcessing: processor.isProcessing) {
                    if processor.isProcessing {
                        processor.stopProcessing()
                    } else {
                        processImages()
                    }
                }
                .disabled(!processor.isProcessing && (inputDirectory == nil || outputDirectory == nil))
                
                // Progress display when processing
                if (processor.isProcessing || showProgressAfterCompletion) && processor.totalImagesToProcess > 0 {
                    ProgressDisplayView(processor: processor)
                        .padding(.horizontal, 4)
                        .padding(.top, -10)
                        .padding(.bottom, -10)
                }
                
                // Log console for displaying messages and progress
                DecoratedView(content: LogTextView(processor: processor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 18)
                    .padding(.trailing, 1)
            }
            .padding(.horizontal, 15)
        }
        .frame(minWidth: 994, minHeight: 735)
        .background(.panelBackground)
        .onChange(of: processor.didFinishAllTasks) { finished in
            if finished {
                showProgressAfterCompletion = true
            } else {
                showProgressAfterCompletion = false
            }
        }
        .onChange(of: processor.isProcessing) { isProcessing in
            if isProcessing {
                showProgressAfterCompletion = false
            }
        }
        .onAppear {
            setupNotifications()
            loadSavedSettings()
        }
    }
    
    /// Sets up notification permissions
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                Task { @MainActor in
                    processor.appendLog(String(format: NSLocalizedString("NotificationPermissionFailed", comment: ""), error.localizedDescription))
                }
            } else if !granted {
                Task { @MainActor in
                    processor.appendLog(NSLocalizedString("NotificationPermissionNotGranted", comment: ""))
                }
            }
        }
    }
    
    /// Loads saved settings from UserDefaults
    private func loadSavedSettings() {
        // Load last used output directory
        if let savedPath = UserDefaults.standard.string(forKey: lastUsedOutputDirKey) {
            outputDirectory = URL(fileURLWithPath: savedPath)
            processor.appendLog(String(format: NSLocalizedString("LoadedLastOutputDir", comment: ""), savedPath))
        }
        
        // Load saved parameters
        widthThreshold = UserDefaults.standard.string(forKey: widthThresholdKey) ?? widthThreshold
        resizeHeight = UserDefaults.standard.string(forKey: resizeHeightKey) ?? resizeHeight
        quality = UserDefaults.standard.string(forKey: qualityKey) ?? quality
        threadCount = UserDefaults.standard.integer(forKey: threadCountKey)
        unsharpRadius = UserDefaults.standard.string(forKey: unsharpRadiusKey) ?? unsharpRadius
        unsharpSigma = UserDefaults.standard.string(forKey: unsharpSigmaKey) ?? unsharpSigma
        unsharpAmount = UserDefaults.standard.string(forKey: unsharpAmountKey) ?? unsharpAmount
        unsharpThreshold = UserDefaults.standard.string(forKey: unsharpThresholdKey) ?? unsharpThreshold
        batchSize = UserDefaults.standard.string(forKey: batchSizeKey) ?? batchSize
        useGrayColorspace = UserDefaults.standard.bool(forKey: useGrayColorspaceKey)
    }
    
    /// Presents an NSOpenPanel to select an input directory
    private func selectInputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            inputDirectory = url
            processor.appendLog(String(format: NSLocalizedString("SelectedInputDir", comment: ""), url.path))
        }
    }
    
    /// Presents an NSOpenPanel to select an output directory
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            processor.appendLog(String(format: NSLocalizedString("SelectedOutputDir", comment: ""), url.path))
            // Save the newly selected output directory
            UserDefaults.standard.set(url.path, forKey: lastUsedOutputDirKey)
        }
    }
    
    /// Initiates the image processing operation
    private func processImages() {
        // Save current parameters before processing
        saveCurrentParameters()
        
        do {
            // Validate and create parameters
            let parameters = try ProcessingParametersValidator.validateAndCreateParameters(
                inputDirectory: inputDirectory,
                outputDirectory: outputDirectory,
                widthThreshold: widthThreshold,
                resizeHeight: resizeHeight,
                quality: quality,
                threadCount: threadCount,
                unsharpRadius: unsharpRadius,
                unsharpSigma: unsharpSigma,
                unsharpAmount: unsharpAmount,
                unsharpThreshold: unsharpThreshold,
                batchSize: batchSize,
                useGrayColorspace: useGrayColorspace
            )
            
            // Start processing (now using async internally)
            processor.processImages(
                inputDir: inputDirectory!,
                outputDir: outputDirectory!,
                parameters: parameters
            )
        } catch {
            processor.appendLog(error.localizedDescription)
        }
    }
    
    /// Saves current parameters to UserDefaults
    private func saveCurrentParameters() {
        UserDefaults.standard.set(widthThreshold, forKey: widthThresholdKey)
        UserDefaults.standard.set(resizeHeight, forKey: resizeHeightKey)
        UserDefaults.standard.set(quality, forKey: qualityKey)
        UserDefaults.standard.set(threadCount, forKey: threadCountKey)
        UserDefaults.standard.set(unsharpRadius, forKey: unsharpRadiusKey)
        UserDefaults.standard.set(unsharpSigma, forKey: unsharpSigmaKey)
        UserDefaults.standard.set(unsharpAmount, forKey: unsharpAmountKey)
        UserDefaults.standard.set(unsharpThreshold, forKey: unsharpThresholdKey)
        UserDefaults.standard.set(batchSize, forKey: batchSizeKey)
        UserDefaults.standard.set(useGrayColorspace, forKey: useGrayColorspaceKey)
    }
    
    /// NSViewRepresentable wrapper for NSTextView to display log messages
    struct LogTextView: NSViewRepresentable {
        @ObservedObject var processor: ImageProcessor
        
        func makeNSView(context: Context) -> NSScrollView {
            let scrollView = NSTextView.scrollableTextView()
            let textView = scrollView.documentView as! NSTextView
            textView.isEditable = false
            textView.isSelectable = true
            textView.backgroundColor = .clear
            textView.textColor = NSColor(.textSecondary)
            textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 0, height: 0)
            scrollView.borderType = .noBorder
            textView.string = processor.logMessages.joined(separator: "\n")
            textView.scrollToEndOfDocument(nil)
            return scrollView
        }
        
        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let textView = nsView.documentView as? NSTextView else { return }
            let newText = processor.logMessages.joined(separator: "\n")
            if textView.string != newText {
                textView.string = newText
                textView.scrollToEndOfDocument(nil)
            }
        }
    }
    
    struct ImageProcessorView_Previews: PreviewProvider {
        static var previews: some View {
            ImageProcessorView()
        }
    }
}
