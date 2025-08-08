//
//  ImageProcessorView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/4/27.
//

import AppKit
import SwiftUI
import UserNotifications

/// UserDefault key for storing the last used output directory.
private let lastUsedOutputDirKey = "lastUsedOutputDirectory"

/// `ImageProcessorView` defines the main user interface for the image processing application.
/// It manages user inputs, displays processing logs, and orchestrates image processing operations.
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

    @ObservedObject private var processor = ImageProcessor()
    @State private var showProgressAfterCompletion: Bool = false
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LeftPanelView() // Left panel of the UI.

            GradientDividerView() // Visual divider between panels.

            VStack(spacing: 20) {
                Spacer().frame(height: 5)

                // Input Directory Selection Button.
                DirectoryButtonView(
                    title: String(format: NSLocalizedString("Input Directory", comment: ""),
                                  inputDirectory?.path ?? NSLocalizedString("Input Directory Placeholder", comment: "")),
                    action: { selectInputDirectory() },
                    isProcessing: processor.isProcessing,
                    openAction: nil,
                    showOpenButton: false,
                    onDropAction: { url in
                        self.inputDirectory = url
                        self.processor.logMessages.append(String(format: NSLocalizedString("SelectedInputDir", comment: ""), url.path))
                    }
                )
                .padding(.top, -11)

                // Output Directory Selection Button.
                DirectoryButtonView(
                    title: String(format: NSLocalizedString("Output Directory", comment: ""),
                                  outputDirectory?.path ?? NSLocalizedString("Output Directory Placeholder", comment: "")),
                    //    outputDirectory?.path ?? ""),
                    action: { selectOutputDirectory() },
                    isProcessing: processor.isProcessing,
                    openAction: { // Action to open the output directory in Finder.
                        if let url = outputDirectory {
                            NSWorkspace.shared.open(url)
                        }
                    },

                    showOpenButton: true,
                    onDropAction: { url in
                        self.outputDirectory = url
                        self.processor.logMessages.append(String(format: NSLocalizedString("SelectedOutputDir", comment: ""), url.path))
                        // Save the newly selected output directory
                        UserDefaults.standard.set(url.path, forKey: lastUsedOutputDirKey)
                    }
                )
                .padding(.bottom, 10)

                // Panel for image processing parameters.
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

                    // Description for the processing parameters.
                    ParameterDescriptionView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.trailing, -3)
                }
                .padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
                .background(.panelBackground)

                // Action button to start or stop processing.
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
                // Log console for displaying messages and progress.
                DecoratedView(content: LogTextView(processor: processor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.bottom, 18)
                    .padding(.trailing, 1)
            }
            .padding(.horizontal, 15)
        }
        .frame(minWidth: 994, minHeight: 735) // Sets minimum window size.
        .background(.panelBackground)
        // 1. Enable delayed hiding when processingProgress reaches 1.0
        .onChange(of: processor.processingProgress) { newValue in
            if newValue >= 1.0 {
                showProgressAfterCompletion = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    showProgressAfterCompletion = false
                }
            }
        }
        // 2. Reset the completion display flag when processing restarts
        .onChange(of: processor.isProcessing) { isProcessing in
            if isProcessing {
                showProgressAfterCompletion = false
            }
        }
        .onAppear {
            // Request notification authorization when the view appears.
            let center = UNUserNotificationCenter.current()
            center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error = error {
                    DispatchQueue.main.async {
                        processor.logMessages.append(String(format: NSLocalizedString("NotificationPermissionFailed", comment: ""), error.localizedDescription))
                    }
                } else if !granted {
                    DispatchQueue.main.async {
                        processor.logMessages.append(NSLocalizedString("NotificationPermissionNotGranted", comment: ""))
                    }
                }
            }

            // Load last used output directory
            if let savedPath = UserDefaults.standard.string(forKey: lastUsedOutputDirKey) {
                outputDirectory = URL(fileURLWithPath: savedPath)
                processor.logMessages.append(String(format: NSLocalizedString("LoadedLastOutputDir", comment: ""), savedPath))
            }
        }
    }

    /// Presents an `NSOpenPanel` to allow the user to select an input directory.
    private func selectInputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            inputDirectory = url
            processor.logMessages.append(String(format: NSLocalizedString("SelectedInputDir", comment: ""), url.path))
        }
    }

    /// Presents an `NSOpenPanel` to allow the user to select an output directory.
    private func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            processor.logMessages.append(String(format: NSLocalizedString("SelectedOutputDir", comment: ""), url.path))
            // Save the newly selected output directory
            UserDefaults.standard.set(url.path, forKey: lastUsedOutputDirKey)
        }
    }

    /// Initiates the image processing operation using the selected directories and parameters.
    private func processImages() {
        guard let inputDir = inputDirectory, let _ = outputDirectory else {
            processor.logMessages.append(NSLocalizedString("InputOutputDirectoryNotSelected", comment: ""))
            return
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        // Check if input directory exists and is readable
        if !fileManager.fileExists(atPath: inputDir.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
            processor.logMessages.append(String(format: NSLocalizedString("InputDirectoryDoesNotExist", comment: ""), inputDir.path))
            return
        }
        if !fileManager.isReadableFile(atPath: inputDir.path) {
            processor.logMessages.append(String(format: NSLocalizedString("InputDirectoryNotReadable", comment: ""), inputDir.path))
            return
        }

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
                unsharpAmount: unsharpAmount,
                unsharpThreshold: unsharpThreshold,
                batchSize: batchSize,
                useGrayColorspace: useGrayColorspace
            )
            processor.processImages(inputDir: inputDirectory!, outputDir: outputDirectory!, parameters: parameters)
        } catch {
            processor.logMessages.append(error.localizedDescription)
        }
    }
}

/// `LogTextView` is an `NSViewRepresentable` wrapper for `NSTextView`,
/// used to display log messages from the `ImageProcessor`.
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
