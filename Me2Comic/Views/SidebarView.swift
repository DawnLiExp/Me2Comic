//
//  SidebarView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/9/11.
//

import AppKit
import SwiftUI

// MARK: - Sidebar View

/// Left navigation bar component
/// Contains app logo, status indicator, navigation menu, and log control.
struct SidebarView: View {
    // MARK: - Properties

    /// GraphicsMagick ready status.
    let gmReady: Bool
    /// Whether processing is in progress.
    let isProcessing: Bool
    /// Currently selected tab.
    @Binding var selectedTab: String
    /// Whether to show logs.
    @Binding var showLogs: Bool
    /// List of log messages.
    @Binding var logMessages: [LogEntry]
    
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? NSLocalizedString("BuildVersionDefault", comment: "")
    
    var body: some View {
        VStack(spacing: 0) {
            // Logo Area
            VStack(spacing: 16) {
                Image(nsImage: NSImage(named: NSImage.Name("AppIcon")) ?? NSImage())
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)

                VStack(spacing: 4) {
                    Text("Me2Comic")
                        .font(.system(size: 22, weight: .light, design: .rounded))
                        .foregroundColor(.textLight)
                    
                    Text("Version \(appVersion) (Build \(buildVersion))")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.textMuted)
                        .tracking(1)
                }
            }
            .padding(.vertical, 30)
            
            // Status Indicator
            StatusIndicator(gmReady: gmReady)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            
            Divider()
                .background(Color.textMuted.opacity(0.2))
            
            // Navigation Menu
            VStack(spacing: 4) {
                NavigationItem(
                    icon: "square.grid.2x2",
                    title: NSLocalizedString("BasicSettings", comment: "基础设置"),
                    isSelected: selectedTab == "basic",
                    action: { selectedTab = "basic" }
                )
                
                NavigationItem(
                    icon: "slider.horizontal.3",
                    title: NSLocalizedString("AdvancedParameters", comment: "高级参数"),
                    isSelected: selectedTab == "advanced",
                    action: { selectedTab = "advanced" }
                )
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 12)
            
            Spacer()
            
            Divider()
                .background(Color.textMuted.opacity(0.2))
            
            // Bottom Controls
            VStack(spacing: 12) {
                // Log Toggle
                HStack {
                    Image(systemName: showLogs ? "doc.text" : "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.textMuted)
                    
                    Text(NSLocalizedString("ShowLogs", comment: "显示日志"))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.textMuted)
                    
                    Spacer()
                    
                    Toggle("", isOn: $showLogs)
                        .toggleStyle(MinimalToggleStyle())
                }
                .padding(.horizontal, 20)
                
                // Clear Logs Button
                if !logMessages.isEmpty {
                    Button(action: {
                        withAnimation {
                            logMessages.removeAll()
                        }
                    }) {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                            Text(String(format: NSLocalizedString("ClearLogsCount", comment: "清理日志 (%d)"), logMessages.count))
                                .font(.system(size: 12, weight: .regular))
                        }
                        .foregroundColor(.textMuted)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color.bgTertiary.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 20)
        }
        .background(Color.bgSecondary)
    }
}

// MARK: - Status Indicator

struct StatusIndicator: View {
    let gmReady: Bool
    @State private var pulse = false
    
    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(gmReady ? Color.successGreen : Color.warningOrange)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(gmReady ? Color.successGreen : Color.warningOrange, lineWidth: 8)
                        .opacity(pulse ? 0 : 0.5)
                        .scaleEffect(pulse ? 2 : 1)
                        .animation(
                            .easeOut(duration: 1).repeatForever(autoreverses: false),
                            value: pulse
                        )
                )
                .onAppear { pulse = true }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("GraphicsMagick")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.textLight)
                Text(gmReady ? NSLocalizedString("Ready", comment: "准备就绪") : NSLocalizedString("Detecting", comment: "检测中..."))
                    .font(.system(size: 10))
                    .foregroundColor(.textMuted)
            }
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgTertiary.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            gmReady ? Color.successGreen.opacity(0.2) : Color.warningOrange.opacity(0.2),
                            lineWidth: 1
                        )
                )
        )
    }
}

// MARK: - Navigation Item

struct NavigationItem: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .accentGreen : .textMuted)
                    .frame(width: 24)
                
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .medium : .regular))
                    .foregroundColor(isSelected ? .textLight : .textMuted)
                
                Spacer()
                
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentGreen)
                        .frame(width: 3, height: 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentGreen.opacity(0.1) : (isHovered ? Color.bgTertiary.opacity(0.3) : Color.clear))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
