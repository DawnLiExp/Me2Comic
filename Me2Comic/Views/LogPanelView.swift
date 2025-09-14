//
//  LogPanelView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import SwiftUI

// MARK: - LogPanelMinimal

/// Minimalistic log panel.
struct LogPanelMinimal: View {
    @Binding var logMessages: [LogEntry]
    @State private var autoScroll = true
    
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
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logMessages.enumerated()), id: \.offset) { index, message in
                            LogRow(entry: message, index: index)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .background(Color.bgSecondary)
                .onChange(of: logMessages.count) { _, _ in
                    if autoScroll && !logMessages.isEmpty {
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(logMessages.count - 1, anchor: .bottom)
                        }
                    }
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
                
                // Copy All button
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
    
    // Copy all logs to clipboard
    private func copyAllLogs() {
        let logText = logMessages
            .map { $0.displayMessage }
            .joined(separator: "\n")
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }
}

// MARK: - LogRow

/// A single row in the log panel.
struct LogRow: View {
    let entry: LogEntry
    let index: Int
    @State private var isHovered = false
    
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
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: { copyToClipboard(entry.displayMessage) }) {
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
        case .success:return Color.successGreen.opacity(0.85)
        case .warning: return Color.warningOrange.opacity(0.85)
        case .error:  return Color.errorRed.opacity(0.85)
        case .debug: return .textMuted
        }
    }
    
    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
