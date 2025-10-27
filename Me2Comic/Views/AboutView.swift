//
//  AboutView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import AppKit
import SwiftUI

// MARK: - Types

enum PendingChangeType {
    case none
    case language
    case theme
    case both
}

// MARK: - AboutView

struct AboutView: View {
    // MARK: - Properties
    
    // App Info
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    
    private var displayBuildVersion: String {
        if buildVersion.isEmpty {
            return NSLocalizedString("BuildVersionDefault", comment: "")
        }
        return buildVersion
    }
    
    // Theme
    @StateObject private var themeManager = ThemeManager.shared
    
    // Applied Settings (currently active)
    @State private var appliedLanguage: String = ""
    @State private var appliedTheme: AppTheme = ThemeManager.shared.selectedThemeMode
    
    // Selected Settings (UI selection)
    @State private var selectedLanguage: String = ""
    @State private var selectedTheme: AppTheme = ThemeManager.shared.selectedThemeMode
    
    // Pending Changes
    @State private var pendingChangeType: PendingChangeType = .none
    @State private var showRestartAlert = false
    
    // MARK: - Initialization
    
    init() {
        // Initialize applied language
        let saved = UserDefaults.standard.string(forKey: "SelectedLanguage")
        let systemLang = Locale.preferredLanguages.first ?? "en"
        let initialLang = saved ?? Self.detectSystemLanguage(systemLang)
        
        _appliedLanguage = State(initialValue: initialLang)
        _selectedLanguage = State(initialValue: initialLang)
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // App Info Section
            appInfoSection
                .padding(.top, 32)
                .padding(.bottom, 40)
            
            Divider()
                .background(dividerColor)
                .padding(.horizontal, 24)
            
            // Settings Section
            settingsSection
                .padding(.top, 32)
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            
            Spacer()
        }
        .frame(width: 360, height: 505)
        .background(backgroundColor)
        .onAppear(perform: loadSettings)
        .alert(isPresented: $showRestartAlert) {
            restartAlert
        }
    }
    
    // MARK: - View Components
    
    private var appInfoSection: some View {
        VStack(spacing: 16) {
            // App Icon
            Image(nsImage: NSImage(named: "AppIcon") ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
            
            // App Name
            Text("Me2Comic")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(primaryTextColor)
            
            // Version Info
            VStack(spacing: 4) {
                Text("Version \(appVersion)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(secondaryTextColor)
                
                Text(String(format: NSLocalizedString("BuildVersionLabel", comment: ""), displayBuildVersion))
                    .font(.system(size: 11))
                    .foregroundColor(tertiaryTextColor)
            }
            
            // Copyright
            Text("© 2025 Me2")
                .font(.system(size: 11))
                .foregroundColor(tertiaryTextColor)
                .padding(.top, 4)
        }
    }
    
    private var settingsSection: some View {
        VStack(spacing: 24) {
            // Language Setting
            SettingRow(
                title: NSLocalizedString("LanguageSettings", comment: ""),
                value: selectedLanguage,
                hasPendingChange: hasPendingLanguageChange
            ) {
                Picker("", selection: $selectedLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                .onChange(of: selectedLanguage) { _, newValue in
                    handleLanguageChange(newValue)
                }
            }
            
            // Theme Setting
            SettingRow(
                title: NSLocalizedString("ThemeSettings", comment: ""),
                value: selectedTheme,
                hasPendingChange: hasPendingThemeChange
            ) {
                Picker("", selection: $selectedTheme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 120)
                .onChange(of: selectedTheme) { _, newTheme in
                    handleThemeChange(newTheme)
                }
            }
            
            // Pending Changes Indicator
            if pendingChangeType != .none {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                    
                    Text(NSLocalizedString("RestartRequired", comment: ""))
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var restartAlert: Alert {
        Alert(
            title: Text(NSLocalizedString("RestartRequired", comment: "")),
            message: Text(restartMessage),
            primaryButton: .default(Text(NSLocalizedString("RestartNow", comment: ""))) {
                Task { await performRestart() }
            },
            secondaryButton: .cancel(Text(NSLocalizedString("Later", comment: "")))
        )
    }
    
    // MARK: - Computed Properties
    
    private var hasPendingLanguageChange: Bool {
        pendingChangeType == .language || pendingChangeType == .both
    }
    
    private var hasPendingThemeChange: Bool {
        pendingChangeType == .theme || pendingChangeType == .both
    }
    
    private var restartMessage: String {
        switch pendingChangeType {
        case .language:
            return NSLocalizedString("RestartRequiredLanguage", comment: "")
        case .theme:
            return NSLocalizedString("RestartRequiredTheme", comment: "")
        case .both:
            return NSLocalizedString("RestartRequiredBoth", comment: "")
        case .none:
            return ""
        }
    }
    
    // MARK: - Colors (Theme-aware)
    
    private var backgroundColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#FAFAFA") : Color.bgTertiary
    }
    
    private var primaryTextColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#1A1A1A") : Color(hex: "#F0F0F0")
    }
    
    private var secondaryTextColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#4A4A4A") : Color(hex: "#B0B0B0")
    }
    
    private var tertiaryTextColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#7A7A7A") : Color(hex: "#808080")
    }
    
    private var dividerColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#E0E0E0").opacity(0.5) : Color.white.opacity(0.1)
    }
    
    // MARK: - Methods
    
    private static func detectSystemLanguage(_ systemLang: String) -> String {
        if systemLang.contains("zh-Hans") { return "zh-Hans" }
        if systemLang.contains("zh-Hant") { return "zh-Hant" }
        if systemLang.contains("ja") { return "ja" }
        return "en"
    }
    
    private func loadSettings() {
        // Load applied settings (user's selection mode)
        appliedTheme = themeManager.selectedThemeMode
        
        if let saved = UserDefaults.standard.string(forKey: "SelectedLanguage") {
            appliedLanguage = saved
        } else {
            let systemLang = Locale.preferredLanguages.first ?? "en"
            appliedLanguage = Self.detectSystemLanguage(systemLang)
        }
        
        // Load pending settings or use applied
        if let pendingLang = UserDefaults.standard.string(forKey: "Me2Comic.pendingLanguage") {
            selectedLanguage = pendingLang
        } else {
            selectedLanguage = appliedLanguage
        }
        
        if let pendingThemeRaw = UserDefaults.standard.string(forKey: "Me2Comic.pendingTheme"),
           let pendingTheme = AppTheme(rawValue: pendingThemeRaw)
        {
            selectedTheme = pendingTheme
        } else {
            selectedTheme = appliedTheme
        }
        
        // Update pending state
        updatePendingState()
    }
    
    private func handleLanguageChange(_ newLanguage: String) {
        if newLanguage == appliedLanguage {
            // Reverting to applied - clear pending
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingLanguage")
            updatePendingState()
        } else {
            // New pending change
            UserDefaults.standard.set(newLanguage, forKey: "Me2Comic.pendingLanguage")
            UserDefaults.standard.set(newLanguage, forKey: "SelectedLanguage")
            UserDefaults.standard.set([newLanguage], forKey: "AppleLanguages")
            updatePendingState()
            showRestartAlert = true
        }
    }
    
    private func handleThemeChange(_ newTheme: AppTheme) {
        if newTheme == appliedTheme {
            // Reverting to applied - clear pending
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingTheme")
            updatePendingState()
        } else {
            // New pending change
            UserDefaults.standard.set(newTheme.rawValue, forKey: "Me2Comic.pendingTheme")
            updatePendingState()
            showRestartAlert = true
        }
    }
    
    private func updatePendingState() {
        let hasLanguageChange = selectedLanguage != appliedLanguage
        let hasThemeChange = selectedTheme != appliedTheme
        
        if hasLanguageChange, hasThemeChange {
            pendingChangeType = .both
        } else if hasLanguageChange {
            pendingChangeType = .language
        } else if hasThemeChange {
            pendingChangeType = .theme
        } else {
            pendingChangeType = .none
        }
    }
    
    @MainActor
    private func performRestart() async {
        // Apply pending theme
        if let pendingThemeRaw = UserDefaults.standard.string(forKey: "Me2Comic.pendingTheme"),
           let pendingTheme = AppTheme(rawValue: pendingThemeRaw)
        {
            _ = themeManager.setTheme(pendingTheme)
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingTheme")
        }
        
        // Apply pending language
        if let pendingLang = UserDefaults.standard.string(forKey: "Me2Comic.pendingLanguage") {
            UserDefaults.standard.set([pendingLang], forKey: "AppleLanguages")
            UserDefaults.standard.set(pendingLang, forKey: "SelectedLanguage")
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingLanguage")
        }
        
        // Restart application
        let bundleURL = Bundle.main.bundleURL
        
        // Try direct executable launch
        let execURL = Bundle.main.executableURL
            ?? bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "")
        
        if FileManager.default.fileExists(atPath: execURL.path) {
            let process = Process()
            process.executableURL = execURL
            process.arguments = []
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.environment = ProcessInfo.processInfo.environment
            
            do {
                try process.run()
                NSApplication.shared.terminate(nil)
                return
            } catch {
                NSLog("Direct launch failed: \(error)")
            }
        }
        
        // Fallback: NSWorkspace
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration
            )
            NSApplication.shared.terminate(nil)
        } catch {
            NSLog("NSWorkspace launch failed: \(error)")
            
            // Final fallback: open command
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            
            try? task.run()
            NSApplication.shared.terminate(nil)
        }
    }
}

// MARK: - SettingRow Component

private struct SettingRow<Content: View>: View {
    let title: String
    let value: Any
    let hasPendingChange: Bool
    let content: () -> Content
    
    @StateObject private var themeManager = ThemeManager.shared
    
    var body: some View {
        HStack(spacing: 16) {
            // Title with pending indicator
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(titleColor)
                    .frame(minWidth: 80, alignment: .leading)
                
                if hasPendingChange {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            
            Spacer()
            
            // Control
            content()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(rowBackground)
        .cornerRadius(8)
    }
    
    private var titleColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#2A2A2A") : Color(hex: "#E0E0E0")
    }
    
    private var rowBackground: Color {
        if themeManager.currentTheme.isLightTheme {
            return Color.white.opacity(0.8)
        } else {
            return Color.white.opacity(0.05)
        }
    }
}
