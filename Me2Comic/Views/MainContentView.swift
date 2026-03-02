//
//  MainContentView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - MainContentView

struct MainContentView: View {
    @Binding var inputDirectory: URL?
    @Binding var outputDirectory: URL?
    let selectedTab: String
    @Binding var widthThreshold: String
    @Binding var resizeHeight: String
    @Binding var quality: String
    @Binding var threadCount: Int
    let maxThreadCount: Int
    @Binding var useGrayColorspace: Bool
    @Binding var unsharpRadius: String
    @Binding var unsharpSigma: String
    @Binding var unsharpAmount: String
    @Binding var unsharpThreshold: String
    @Binding var batchSize: String
    @Binding var enableUnsharp: Bool
    let onProcess: () -> Void
    let onDirectorySelect: () -> Void

    // MARK: - UI State
    
    @State private var showInputTip = false
    @State private var showOutputTip = false
    @State private var isShowInFinderHovered = false
    
    // MARK: - Layout Constants
    
    /// Prevents layout shift during tab transitions
    private let parameterAreaHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 9) {
            // Directory Selection
            VStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text(String(localized: "Input Directory"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                        
                    Button(action: { showInputTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showInputTip) {
                        Text(String(localized: "Input Directory Placeholder"))
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    
                MinimalDirectorySelector(
                    title: inputDirectory?.lastPathComponent ?? String(localized: "InputNotSelected"),
                    subtitle: inputDirectory?.path ?? "",
                    path: inputDirectory?.path,
                    icon: "folder",
                    accentColor: .accentGreen,
                    onSelect: {
                        onDirectorySelect()
                        inputDirectory = $0
                    }
                )
                    
                HStack(spacing: 4) {
                    Text(String(localized: "Output Directory"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                        
                    Button(action: { showOutputTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showOutputTip) {
                        Text(String(localized: "Output Directory Placeholder"))
                            .padding()
                    }
                    
                    Spacer()
                    
                    if outputDirectory != nil {
                        Button(action: showOutputInFinder) {
                            Image(systemName: "magnifyingglass.circle")
                                .font(.system(size: 16))
                                .foregroundColor(isShowInFinderHovered ? .accentOrange : .textMuted)
                                .padding(.leading, 4)
                                .padding(.trailing, 12)
                                .padding(.vertical, 4)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isShowInFinderHovered = hovering
                            }
                        }
                        .transition(.opacity.combined(with: .scale))
                        .animation(.spring(response: 0.3), value: outputDirectory != nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    
                MinimalDirectorySelector(
                    title: outputDirectory?.lastPathComponent ?? String(localized: "OutputNotSelected"),
                    subtitle: outputDirectory?.path ?? "",
                    path: outputDirectory?.path,
                    icon: "folder.badge.plus",
                    accentColor: .accentOrange,
                    onSelect: {
                        onDirectorySelect()
                        outputDirectory = $0
                    }
                )
            }
            .padding(.horizontal, 60)

            // Parameter Configuration Area
            ZStack {
                if selectedTab == "basic" {
                    BasicParametersView(
                        widthThreshold: $widthThreshold,
                        resizeHeight: $resizeHeight,
                        quality: $quality,
                        threadCount: $threadCount,
                        maxThreadCount: maxThreadCount,
                        useGrayColorspace: $useGrayColorspace
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.15)),
                        removal: .identity
                    ))
                } else {
                    AdvancedParametersView(
                        unsharpRadius: $unsharpRadius,
                        unsharpSigma: $unsharpSigma,
                        unsharpAmount: $unsharpAmount,
                        unsharpThreshold: $unsharpThreshold,
                        batchSize: $batchSize,
                        enableUnsharp: $enableUnsharp,
                        threadCount: threadCount
                    )
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.15)),
                        removal: .identity
                    ))
                }
            }
            .padding(.horizontal, 60)
            .frame(height: parameterAreaHeight)
            .animation(.easeInOut(duration: 0.18), value: selectedTab)

            ProcessButton(
                enabled: inputDirectory != nil && outputDirectory != nil,
                action: onProcess
            )
            .padding(.horizontal, 60)
            .padding(.bottom, 18)
        }
    }
    
    // MARK: - Private Methods
    
    private func showOutputInFinder() {
        guard let url = outputDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

// MARK: - BasicParametersView

struct BasicParametersView: View {
    @Binding var widthThreshold: String
    @Binding var resizeHeight: String
    @Binding var quality: String
    @Binding var threadCount: Int
    let maxThreadCount: Int
    @Binding var useGrayColorspace: Bool
    @State private var showGrayTip = false
    @State private var showThreadTip = false
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 14))
                        .foregroundColor(.accentOrange)
                    Text(String(localized: "BasicParameters"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                }
                
                MinimalParameterField(
                    label: String(localized: "WidthUnder"),
                    value: $widthThreshold,
                    unit: String(localized: "pxUnit"),
                    hint: String(localized: "UnderWidthDesc")
                )
            
                MinimalParameterField(
                    label: String(localized: "ResizeHeight"),
                    value: $resizeHeight,
                    unit: String(localized: "pxUnit"),
                    hint: String(localized: "ResizeHDesc")
                )
            
                MinimalParameterField(
                    label: String(localized: "OutputQuality"),
                    value: $quality,
                    unit: "%",
                    hint: String(localized: "QualityDesc")
                )
            
                // Thread Count Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        HStack(spacing: 6) {
                            Text(String(localized: "ThreadCount"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.textLight)
                            
                            Button(action: { showThreadTip.toggle() }) {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(.textMuted.opacity(0.5))
                            }
                            .buttonStyle(PlainButtonStyle())
                            .popover(isPresented: $showThreadTip) {
                                Text(String(localized: "ThreadsDesc"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.textLight)
                                    .padding(10)
                                    .background(Color.bgTertiary)
                            }
                        }
                    
                        Spacer()
                    
                        Text(threadCount == 0 ? String(localized: "Auto") : String(format: String(localized: "ThreadsCount"), threadCount))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.accentGreen)
                    }
                    
                    Slider(value: Binding(
                        get: { Double(threadCount) },
                        set: { threadCount = Int($0) }
                    ), in: 0 ... Double(maxThreadCount), step: 1)
                        .accentColor(.accentGreen)
                }
            
                // Grayscale Toggle
                HStack {
                    HStack(spacing: 6) {
                        Text(String(localized: "GrayColorspace"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.textLight)
                        
                        Button(action: { showGrayTip.toggle() }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.textMuted.opacity(0.5))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .popover(isPresented: $showGrayTip) {
                            Text(String(localized: "GrayDesc"))
                                .font(.system(size: 11))
                                .foregroundColor(.textLight)
                                .padding(10)
                                .background(Color.bgTertiary)
                        }
                    }
                    
                    Spacer()

                    Toggle(isOn: $useGrayColorspace) {
                        EmptyView()
                    }
                        .labelsHidden()
                        .toggleStyle(MinimalToggleStyle())
                }
                .padding(.vertical, 8)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.bgTertiary.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.textMuted.opacity(0.1), lineWidth: 1)
                    )
            )
        }
    }
}

// MARK: - AdvancedParametersView

struct AdvancedParametersView: View {
    @Binding var unsharpRadius: String
    @Binding var unsharpSigma: String
    @Binding var unsharpAmount: String
    @Binding var unsharpThreshold: String
    @Binding var batchSize: String
    @Binding var enableUnsharp: Bool
    let threadCount: Int
    @State private var showUnsharpTip = false
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 14))
                        .foregroundColor(.accentOrange)
                    Text(String(localized: "SharpeningSettings"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)

                    Button(action: { showUnsharpTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showUnsharpTip) {
                        Text(String(localized: "UnsharpDesc"))
                            .padding()
                    }

                    Spacer()

                    Toggle(isOn: $enableUnsharp) {
                        EmptyView()
                    }
                        .labelsHidden()
                        .toggleStyle(MinimalToggleStyle())
                }
                
                if enableUnsharp {
                    MinimalParameterField(
                        label: "Radius",
                        value: $unsharpRadius,
                        unit: "",
                        hint: String(localized: "RadiusDesc")
                    )
                    
                    MinimalParameterField(
                        label: "Sigma",
                        value: $unsharpSigma,
                        unit: "",
                        hint: String(localized: "SigmaDesc")
                    )
                    
                    MinimalParameterField(
                        label: "Amount",
                        value: $unsharpAmount,
                        unit: "",
                        hint: String(localized: "AmountDesc")
                    )
                    
                    MinimalParameterField(
                        label: "Threshold",
                        value: $unsharpThreshold,
                        unit: "",
                        hint: String(localized: "ThreshDesc")
                    )
                }
            }
            
            Divider()
                .background(Color.textMuted.opacity(0.2))
            
            // Batch Processing Parameters
            MinimalParameterField(
                label: String(localized: "BatchSize"),
                value: $batchSize,
                unit: String(localized: "ImagesPerBatch"),
                hint: String(localized: "BatchSizeDesc"),
                isInputDisabled: threadCount == 0
            )
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.bgTertiary.opacity(0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.textMuted.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - MinimalParameterField

struct MinimalParameterField: View {
    let label: String
    @Binding var value: String
    let unit: String
    let hint: String
    var isInputDisabled: Bool = false
    
    @State private var showHint = false
    
    var body: some View {
        HStack {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textLight)
                
                Button(action: { showHint.toggle() }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.textMuted.opacity(0.5))
                }
                .buttonStyle(PlainButtonStyle())
                .popover(isPresented: $showHint) {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundColor(.textLight)
                        .padding(10)
                        .background(Color.bgTertiary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                TextField(text: $value) {
                    EmptyView()
                }
                    .labelsHidden()
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(isInputDisabled ? .textMuted : .textLight)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.bgSecondary.opacity(isInputDisabled ? 0.3 : 0.5))
                    )
                    .focusable(false)
                    .disabled(isInputDisabled)
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isInputDisabled ? .textMuted.opacity(0.5) : .textMuted)
                        .frame(width: 25, alignment: .leading)
                }
            }
        }
    }
}
