//
//  MainContentView.swift
//  Me2Comic
//
//  主内容区：参数配置（基础/高级）
//

import SwiftUI

// MARK: - MainContentView

struct MainContentView: View {
    @Bindable var settings: AppSettingsStore
    let selectedTab: String
    var issues: [ParameterIssue] = []
    var focusRequest: ParameterFocusRequest?
    var toolReady = true
    let onProcess: () -> Void
    let onDirectorySelect: () -> Void

    // MARK: - UI State

    @State private var isShowInFinderHovered = false

    // MARK: - Layout Constants

    /// Prevents layout shift during tab transitions
    private let parameterAreaHeight: CGFloat = 360

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 9) {
                        // Directory Selection
                        VStack(spacing: 16) {
                            HStack(spacing: 4) {
                                Text(String(localized: "Input Directory"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.textLight)

                                ParameterHelpButton(label: String(localized: "Input Directory"), hint: String(localized: "Input Directory Placeholder"))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            MinimalDirectorySelector(
                                title: settings.inputDirectory?.lastPathComponent ?? String(localized: "InputNotSelected"),
                                subtitle: settings.inputDirectory?.path ?? "",
                                path: settings.inputDirectory?.path,
                                icon: "folder",
                                accentColor: .accentGreen,
                                onSelect: {
                                    onDirectorySelect()
                                    settings.inputDirectory = $0
                                }
                            )

                            HStack(spacing: 4) {
                                Text(String(localized: "Output Directory"))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.textLight)

                                ParameterHelpButton(label: String(localized: "Output Directory"), hint: String(localized: "Output Directory Placeholder"))

                                Spacer()

                                if settings.outputDirectory != nil {
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
                                        withAnimation(.easeOut(duration: 0.12)) {
                                            isShowInFinderHovered = hovering
                                        }
                                    }
                                    .transition(.opacity)
                                    .animation(.easeOut(duration: 0.12), value: settings.outputDirectory != nil)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            MinimalDirectorySelector(
                                title: settings.outputDirectory?.lastPathComponent ?? String(localized: "OutputNotSelected"),
                                subtitle: settings.outputDirectory?.path ?? "",
                                path: settings.outputDirectory?.path,
                                icon: "folder.badge.plus",
                                accentColor: .accentOrange,
                                onSelect: {
                                    onDirectorySelect()
                                    settings.outputDirectory = $0
                                }
                            )
                        }
                        .padding(.horizontal, 60)

                        // Parameter cards can grow to accommodate validation messages.
                        Group {
                            if selectedTab == "basic" {
                                BasicParametersView(settings: settings)
                            } else {
                                AdvancedParametersView(settings: settings)
                            }
                        }
                        .padding(.horizontal, 60)
                        .frame(minHeight: parameterAreaHeight)
                    }
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                    .environment(\.parameterIssues, issues)
                    .environment(\.parameterFocusRequest, focusRequest)
                }
                .task(id: focusRequest) {
                    guard let focusRequest else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(focusRequest.field, anchor: .center)
                }
            }
            if !issues.isEmpty {
                Label("FixParametersBeforeStarting", systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Color.errorRed)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ProcessButton(
                enabled: toolReady && settings.inputDirectory != nil && settings.outputDirectory != nil,
                action: onProcess
            )
            .padding(.horizontal, 60)
            .padding(.bottom, 18)
        }
    }

    // MARK: - Private Methods

    private func showOutputInFinder() {
        guard let url = settings.outputDirectory else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}

// MARK: - BasicParametersView

struct BasicParametersView: View {
    @Bindable var settings: AppSettingsStore

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
                    value: $settings.widthThreshold,
                    field: .widthThreshold,
                    unit: String(localized: "pxUnit"),
                    hint: String(localized: "UnderWidthDesc")
                )

                MinimalParameterField(
                    label: String(localized: "ResizeHeight"),
                    value: $settings.resizeHeight,
                    field: .resizeHeight,
                    unit: String(localized: "pxUnit"),
                    hint: String(localized: "ResizeHDesc")
                )

                MinimalParameterField(
                    label: String(localized: "OutputQuality"),
                    value: $settings.quality,
                    field: .quality,
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

                            ParameterHelpButton(label: String(localized: "ThreadCount"), hint: String(localized: "ThreadsDesc"))
                        }

                        Spacer()

                        Text(settings.threadCount == 0
                            ? String(localized: "Auto")
                            : String(format: String(localized: "ThreadsCount"), settings.threadCount))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.accentGreen)
                    }

                    Slider(
                        value: Binding(
                            get: { Double(settings.threadCount) },
                            set: { settings.threadCount = Int($0) }
                        ),
                        in: 0 ... Double(settings.maxThreadCount),
                        step: 1
                    )
                    .accentColor(.accentGreen)
                }

                // Grayscale Toggle
                HStack {
                    HStack(spacing: 6) {
                        Text(String(localized: "GrayColorspace"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.textLight)

                        ParameterHelpButton(label: String(localized: "GrayColorspace"), hint: String(localized: "GrayDesc"))
                    }

                    Spacer()

                    Toggle(isOn: $settings.useGrayColorspace) {
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
    @Bindable var settings: AppSettingsStore

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

                    ParameterHelpButton(label: String(localized: "SharpeningSettings"), hint: String(localized: "UnsharpDesc"))

                    Spacer()

                    Toggle(isOn: $settings.enableUnsharp) {
                        EmptyView()
                    }
                    .labelsHidden()
                    .toggleStyle(MinimalToggleStyle())
                }

                if settings.enableUnsharp {
                    MinimalParameterField(
                        label: String(localized: "Radius"),
                        value: $settings.unsharpRadius,
                    field: .unsharpRadius,
                        unit: "",
                        hint: String(localized: "RadiusDesc")
                    )

                    MinimalParameterField(
                        label: String(localized: "Sigma"),
                        value: $settings.unsharpSigma,
                    field: .unsharpSigma,
                        unit: "",
                        hint: String(localized: "SigmaDesc")
                    )

                    MinimalParameterField(
                        label: String(localized: "Amount"),
                        value: $settings.unsharpAmount,
                    field: .unsharpAmount,
                        unit: "",
                        hint: String(localized: "AmountDesc")
                    )

                    MinimalParameterField(
                        label: String(localized: "Thresh"),
                        value: $settings.unsharpThreshold,
                    field: .unsharpThreshold,
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
                value: $settings.batchSize,
                    field: .batchSize,
                unit: String(localized: "ImagesPerBatch"),
                hint: String(localized: "BatchSizeDesc"),
                isInputDisabled: settings.threadCount == 0
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
    let field: ParameterField
    let unit: String
    let hint: String
    var isInputDisabled: Bool = false

    @FocusState private var isFocused: Bool
    @Environment(\.parameterIssues) private var issues
    @Environment(\.parameterFocusRequest) private var focusRequest

    private var errorMessage: String? { issues.first { $0.field == field }?.message }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textLight)

                    ParameterHelpButton(label: label, hint: hint)
                }

                Spacer()

                HStack(spacing: 4) {
                    TextField(label, text: $value)
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
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(
                        errorMessage != nil ? Color.errorRed : (isFocused ? Color.accentGreen : .clear), lineWidth: 1
                    ))
                    .focused($isFocused)
                    .disabled(isInputDisabled)

                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.textMuted)
                            .frame(width: 25, alignment: .leading)
                    }
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(Color.errorRed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .id(field)
        .task(id: focusRequest) {
            guard focusRequest?.field == field, !isInputDisabled else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            isFocused = true
        }
    }
}

private struct ParameterIssuesKey: EnvironmentKey {
    static let defaultValue: [ParameterIssue] = []
}
private struct ParameterFocusKey: EnvironmentKey {
    static let defaultValue: ParameterFocusRequest? = nil
}
private extension EnvironmentValues {
    var parameterIssues: [ParameterIssue] {
        get { self[ParameterIssuesKey.self] }
        set { self[ParameterIssuesKey.self] = newValue }
    }
    var parameterFocusRequest: ParameterFocusRequest? {
        get { self[ParameterFocusKey.self] }
        set { self[ParameterFocusKey.self] = newValue }
    }
}

private struct ParameterHelpButton: View {
    let label: String
    let hint: String
    @State private var isPresented = false

    private var helpLabel: String { String(format: String(localized: "ParameterHelpLabel"), label) }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(helpLabel)
        .help(helpLabel)
        .popover(isPresented: $isPresented) {
            Text(hint).font(.system(size: 12)).foregroundStyle(Color.textLight)
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.bgTertiary)
                .fixedSize()
        }
    }
}
