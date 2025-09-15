//
//  LogPanelView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - LogPanelMinimal

struct LogPanelMinimal: View {
    @Binding var logMessages: [LogEntry]
    @State private var autoScroll = true
    @State private var hoveredIndex: Int? = nil
    @State private var selectedIndex: Int? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Title Bar
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "text.badge.checkmark")
                        .font(.system(size: 14))
                        .foregroundColor(.accentOrange)
                    
                    Text(NSLocalizedString("ProcessingLogs", comment: "处理日志"))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.textLight)
                }
                Spacer()
                
                Text(String(format: NSLocalizedString("LogsCount", comment: "%d 条"), logMessages.count))
                    .font(.system(size: 11))
                    .foregroundColor(.textMuted)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.bgTertiary.opacity(0.3))
            
            // Log Content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logMessages.indices, id: \.self) { index in
                            LogRow(
                                entry: logMessages[index],
                                index: index,
                                isHovered: hoveredIndex == index,
                                onHover: { isHovering in
                                    hoveredIndex = isHovering ? index : nil
                                },
                                onCopy: {
                                    copyToClipboard(logMessages[index].displayMessage)
                                }
                            )
                            .id(index)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color.bgSecondary)
                .onChange(of: logMessages.count) { oldCount, newCount in
                    guard autoScroll && newCount > oldCount else { return }
                    proxy.scrollTo(newCount - 1, anchor: .bottom)
                }
            }
            
            // Bottom Controls
            HStack {
                Button(action: { autoScroll.toggle() }) {
                    HStack(spacing: 6) {
                        Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .font(.system(size: 12))
                        Text(NSLocalizedString("AutoScroll", comment: "自动滚动"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(autoScroll ? .accentGreen : .textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
                
                Button(action: copyAllLogs) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                        Text(NSLocalizedString("CopyAll", comment: "复制全部"))
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.textMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(logMessages.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.bgTertiary.opacity(0.3))
        }
        .background(Color.bgSecondary)
    }
    
    private func copyAllLogs() {
        let logText = logMessages
            .map { $0.displayMessage }
            .joined(separator: "\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - LogRow

struct LogRow: View {
    let entry: LogEntry
    let index: Int
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onCopy: () -> Void
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(String(format: "%03d", index + 1))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.textMuted.opacity(0.5))
                .frame(width: 30, alignment: .trailing)
            
            Image(systemName: iconName(for: entry.level))
                .font(.system(size: 10))
                .foregroundColor(color(for: entry.level))
            
            Text(entry.displayMessage)
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(color(for: entry.level))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
        .background(isHovered ? Color.bgTertiary.opacity(0.6) : Color.clear)
        .onHover(perform: onHover)
        .contextMenu {
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
    
    private func iconName(for level: LogLevel) -> String {
        switch level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        case .debug: return "ant.fill"
        }
    }
    
    private func color(for level: LogLevel) -> Color {
        switch level {
        case .info: return .textMuted
        case .success: return Color.successGreen.opacity(0.85)
        case .warning: return Color.warningOrange.opacity(0.85)
        case .error: return Color.errorRed.opacity(0.85)
        case .debug: return .textMuted
        }
    }
}
