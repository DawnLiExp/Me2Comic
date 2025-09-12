//
//  MainContentView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - MainContentView

/// Main content area for parameter configuration and processing interface.
struct MainContentView: View {
    @Binding var inputDirectory: URL?
    @Binding var outputDirectory: URL?
    let selectedTab: String
    @Binding var widthThreshold: String
    @Binding var resizeHeight: String
    @Binding var quality: String
    @Binding var threadCount: Int
    @Binding var useGrayColorspace: Bool
    @Binding var unsharpRadius: String
    @Binding var unsharpSigma: String
    @Binding var unsharpAmount: String
    @Binding var unsharpThreshold: String
    @Binding var batchSize: String
    @Binding var enableUnsharp: Bool
    let onProcess: () -> Void

    // New state: store measured heights of the two parameter views
    @State private var basicParamsHeight: CGFloat = 0
    @State private var advancedParamsHeight: CGFloat = 0
    @State private var showInputTip = false
    @State private var showOutputTip = false
    // Adjustable extra height (if you want additional fixed space between the two modes)
    // For example: set to 8 or 12 to fine-tune visual spacing
    private let parameterAreaExtraPadding: CGFloat = 0

    // Minimum height fallback value to avoid momentary jumps at initial 0
    private let parameterAreaMinHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 30) {
            // Directory Selection
            VStack(spacing: 16) {
                HStack(spacing: 4) {
                    Text(NSLocalizedString("Input Directory", comment: "输入目录"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                        
                    Button(action: { showInputTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showInputTip) {
                        Text(NSLocalizedString("Input Directory Placeholder", comment: "选择包含子文件夹的图片目录"))
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    
                MinimalDirectorySelector(
                    title: inputDirectory?.lastPathComponent ?? NSLocalizedString("InputNotSelected", comment: "未选择输入目录"),
                    subtitle: inputDirectory?.path ?? "",
                    path: inputDirectory?.path,
                    icon: "folder",
                    accentColor: .accentGreen,
                    onSelect: { inputDirectory = $0 }
                )
                    
                HStack(spacing: 4) {
                    Text(NSLocalizedString("Output Directory", comment: "输出目录"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                        
                    Button(action: { showOutputTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showOutputTip) {
                        Text(NSLocalizedString("Output Directory Placeholder", comment: "处理后的图片保存位置"))
                            .padding()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                    
                MinimalDirectorySelector(
                    title: outputDirectory?.lastPathComponent ?? NSLocalizedString("OutputNotSelected", comment: "未选择输出目录"),
                    subtitle: outputDirectory?.path ?? "",
                    path: outputDirectory?.path,
                    icon: "folder.badge.plus",
                    accentColor: .accentOrange,
                    onSelect: { outputDirectory = $0 }
                )
            }
            .padding(.horizontal, 60)

            // Parameter Area
            let computedHeight = max(max(basicParamsHeight, advancedParamsHeight) + parameterAreaExtraPadding, parameterAreaMinHeight)

            ZStack {
                // Basic Parameter View (always measure height within the layer)
                BasicParametersView(
                    widthThreshold: $widthThreshold,
                    resizeHeight: $resizeHeight,
                    quality: $quality,
                    threadCount: $threadCount,
                    useGrayColorspace: $useGrayColorspace
                )
                .padding(.horizontal, 60)
                // Measure Basic area height
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: BasicParamHeightKey.self, value: geo.size.height)
                    }
                )
                .opacity(selectedTab == "basic" ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: selectedTab)
                .allowsHitTesting(selectedTab == "basic")
                
                // Advanced Parameter View (always measure height within the layer)
                AdvancedParametersView(
                    unsharpRadius: $unsharpRadius,
                    unsharpSigma: $unsharpSigma,
                    unsharpAmount: $unsharpAmount,
                    unsharpThreshold: $unsharpThreshold,
                    batchSize: $batchSize,
                    enableUnsharp: $enableUnsharp
                )

                .padding(.horizontal, 60)
                // Measure Advanced area height
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: AdvancedParamHeightKey.self, value: geo.size.height)
                    }
                )
                .opacity(selectedTab == "advanced" ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: selectedTab)
                .allowsHitTesting(selectedTab == "advanced")
            }
            // Fix parameter area height (using the calculated max height)
            .frame(height: computedHeight)
            // Update measurement results
            .onPreferenceChange(BasicParamHeightKey.self) { value in
                // Protective handling: take non-zero and finite values
                if value.isFinite && value > 0 {
                    basicParamsHeight = value
                }
            }
            .onPreferenceChange(AdvancedParamHeightKey.self) { value in
                if value.isFinite && value > 0 {
                    advancedParamsHeight = value
                }
            }

            // Start Button
            ProcessButton(
                enabled: inputDirectory != nil && outputDirectory != nil,
                action: onProcess
            )
            .padding(.horizontal, 60)
            .padding(.bottom, 18) // Retain bottom spacing
        }
    }
}

// MARK: - BasicParametersView

struct BasicParametersView: View {
    @Binding var widthThreshold: String
    @Binding var resizeHeight: String
    @Binding var quality: String
    @Binding var threadCount: Int
    @Binding var useGrayColorspace: Bool
    
    var body: some View {
        VStack(spacing: 20) {
            // Basic Parameter Group
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 14))
                        .foregroundColor(.accentOrange)
                    Text(NSLocalizedString("BasicParameters", comment: "基础参数选项"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)
                }
                
                MinimalParameterField(
                    label: NSLocalizedString("WidthUnder", comment: "宽度阀值"),
                    value: $widthThreshold,
                    unit: NSLocalizedString("pxUnit", comment: "px"),
                    hint: NSLocalizedString("UnderWidthDesc", comment: "宽度小于此值时直接转换，否则均分裁切为左右两部分")
                )
            
                MinimalParameterField(
                    label: NSLocalizedString("ResizeHeight", comment: "转换高度"),
                    value: $resizeHeight,
                    unit: NSLocalizedString("pxUnit", comment: "px"),
                    hint: NSLocalizedString("ResizeHDesc", comment: "转换后图片高度值")
                )
            
                MinimalParameterField(
                    label: NSLocalizedString("OutputQuality", comment: "输出质量（%）："),
                    value: $quality,
                    unit: "%",
                    hint: NSLocalizedString("QualityDesc", comment: "JPG压缩质量（1-100），值越高质量越好但文件越大")
                )
            
                // Thread Count Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(NSLocalizedString("ThreadCount", comment: "并发线程数："))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.textLight)
                    
                        Spacer()
                    
                        Text(threadCount == 0 ? NSLocalizedString("Auto", comment: "自动") : String(format: NSLocalizedString("ThreadsCount", comment: "%d 线程"), threadCount))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.accentGreen)
                    }
                
                    Slider(value: Binding(
                        get: { Double(threadCount) },
                        set: { threadCount = Int($0) }
                    ), in: 0 ... 8, step: 1)
                        .accentColor(.accentGreen)
                }
            
                // Grayscale Toggle
                HStack {
                    MinimalParameterField(
                        label: NSLocalizedString("GrayColorspace", comment: "灰度色彩空间（黑白）："),
                        value: .constant(""), // Value is not directly used for Toggle, so a constant empty string is fine
                        unit: "",
                        hint: NSLocalizedString("GrayDesc", comment: "on=转换至灰度空间（8-bit），off=保留原始色彩空间")
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                    Toggle("", isOn: $useGrayColorspace)
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
    @State private var showUnsharpTip = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Unsharp Parameters Group
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 14))
                        .foregroundColor(.accentOrange)
                    Text(NSLocalizedString("SharpeningSettings", comment: "锐化设置"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.textLight)

                    Button(action: { showUnsharpTip.toggle() }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundColor(.textMuted.opacity(0.5))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .popover(isPresented: $showUnsharpTip) {
                        Text(NSLocalizedString("UnsharpDesc", comment: "锐化参数说明"))
                            .padding()
                    }

                    Spacer()

                    Toggle("", isOn: $enableUnsharp)
                        .toggleStyle(MinimalToggleStyle())
                }
                
                if enableUnsharp {
                    MinimalParameterField(
                        label: "Radius",
                        value: $unsharpRadius,
                        unit: "",
                        hint: NSLocalizedString("RadiusDesc", comment: "锐化半径，控制影响的区域大小")
                    )
                    
                    MinimalParameterField(
                        label: "Sigma",
                        value: $unsharpSigma,
                        unit: "",
                        hint: NSLocalizedString("SigmaDesc", comment: "锐化模糊半径，越大锐化效果越柔和")
                    )
                    
                    MinimalParameterField(
                        label: "Amount",
                        value: $unsharpAmount,
                        unit: "",
                        hint: NSLocalizedString("AmountDesc", comment: "锐化量，控制锐化效果的强度")
                    )
                    
                    MinimalParameterField(
                        label: "Threshold",
                        value: $unsharpThreshold,
                        unit: "",
                        hint: NSLocalizedString("ThreshDesc", comment: "锐化阈值，只对高于此值的边缘进行锐化")
                    )
                }
            }
            
            Divider()
                .background(Color.textMuted.opacity(0.2))
            
            // Batch Processing Parameters
            MinimalParameterField(
                label: NSLocalizedString("BatchSize", comment: "批处理大小"),
                value: $batchSize,
                unit: NSLocalizedString("ImagesPerBatch", comment: "张"),
                hint: NSLocalizedString("BatchSizeDesc", comment: "每批图像数（张）：")
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
                TextField("", text: $value)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.textLight)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.bgSecondary.opacity(0.5))
                    )
                    .focusable(false) // Prevent automatic focus
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.textMuted)
                        .frame(width: 25, alignment: .leading)
                }
            }
        }
    }
}

// Used to measure Basic parameter area height
private struct BasicParamHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct AdvancedParamHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
