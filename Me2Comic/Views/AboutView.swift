//
//  AboutView.swift
//  Me2Comic
//
//  关于界面：语言切换、主题设置
//

import AppKit
import Observation
import SwiftUI

/// The active language is captured once per process, independently of the next-launch preference.
@MainActor
@Observable
final class LanguageSettings {
    static let shared = LanguageSettings()
    let activeLanguage: String
    private(set) var pendingLanguage: String?
    @ObservationIgnored private let defaults: UserDefaults
    static let supported = ["en", "zh-Hans", "zh-Hant", "ja"]

    init(defaults: UserDefaults = .standard,
         activeLanguage: String = Bundle.main.preferredLocalizations.first ?? "en") {
        self.defaults = defaults
        let active = Self.supported.contains(activeLanguage) ? activeLanguage : "en"
        self.activeLanguage = active
        let pending = defaults.string(forKey: "Me2Comic.pendingLanguage")
        pendingLanguage = pending.flatMap { Self.supported.contains($0) && $0 != active ? $0 : nil }
        defaults.set(self.activeLanguage, forKey: "SelectedLanguage")
        if pendingLanguage == nil { defaults.removeObject(forKey: "Me2Comic.pendingLanguage") }
    }

    var selectedLanguage: String { pendingLanguage ?? activeLanguage }

    func select(_ language: String) {
        guard Self.supported.contains(language) else { return }
        pendingLanguage = language == activeLanguage ? nil : language
        defaults.set([language], forKey: "AppleLanguages")
        defaults.set(activeLanguage, forKey: "SelectedLanguage")
        if let pendingLanguage {
            defaults.set(pendingLanguage, forKey: "Me2Comic.pendingLanguage")
        } else {
            defaults.removeObject(forKey: "Me2Comic.pendingLanguage")
        }
    }
}

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
            return String(localized: "BuildVersionDefault")
        }
        return buildVersion
    }
    
    // Theme
    @State private var themeManager = ThemeManager.shared
    
    // Applied Settings (currently active)
    @State private var languageSettings = LanguageSettings.shared
    @State private var appliedTheme: AppTheme = ThemeManager.shared.selectedThemeMode
    
    // Selected Settings (UI selection)
    private var selectedLanguage: String { languageSettings.selectedLanguage }
    @State private var selectedTheme: AppTheme = ThemeManager.shared.selectedThemeMode
    
    // Pending Changes
    @State private var pendingChangeType: PendingChangeType = .none
    @State private var showRestartAlert = false
    
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
        .disabled(AppLifecycle.shared.isBusy)
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
                
                Text(String(format: String(localized: "BuildVersionLabel"), displayBuildVersion))
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
                title: String(localized: "LanguageSettings"),
                value: selectedLanguage,
                hasPendingChange: hasPendingLanguageChange
            ) {
                Picker(selection: Binding(get: { selectedLanguage }, set: { handleLanguageChange($0) }), label: Text("LanguageSettings")) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            
            // Theme Setting
            SettingRow(
                title: String(localized: "ThemeSettings"),
                value: selectedTheme,
                hasPendingChange: hasPendingThemeChange
            ) {
                Picker(selection: $selectedTheme, label: EmptyView()) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
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
                    
                    Text(String(localized: "RestartRequired"))
                        .font(.system(size: 11))
                        .foregroundColor(secondaryTextColor)
                }
                .padding(.top, 4)
            }
        }
    }
    
    private var restartAlert: Alert {
        Alert(
            title: Text(String(localized: "RestartRequired")),
            message: Text(restartMessage),
            primaryButton: .default(Text(String(localized: "RestartNow"))) {
                Task { await performRestart() }
            },
            secondaryButton: .cancel(Text(String(localized: "Later")))
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
            return String(localized: "RestartRequiredLanguage")
        case .theme:
            return String(localized: "RestartRequiredTheme")
        case .both:
            return String(localized: "RestartRequiredBoth")
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
        themeManager.currentTheme.isLightTheme ? Color(hex: "#666666") : Color(hex: "#A3A3AA")
    }
    
    private var dividerColor: Color {
        themeManager.currentTheme.isLightTheme ? Color(hex: "#E0E0E0").opacity(0.5) : Color.white.opacity(0.1)
    }
    
    // MARK: - Methods
    
    private func loadSettings() {
        appliedTheme = themeManager.selectedThemeMode
        if let raw = UserDefaults.standard.string(forKey: "Me2Comic.pendingTheme"), let theme = AppTheme(rawValue: raw) {
            selectedTheme = theme
        } else {
            selectedTheme = appliedTheme
        }
        updatePendingState()
    }

    private func handleLanguageChange(_ language: String) {
        languageSettings.select(language)
        updatePendingState()
        if languageSettings.pendingLanguage != nil { showRestartAlert = true }
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
        let hasLanguageChange = languageSettings.pendingLanguage != nil
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
        await AppLifecycle.shared.restart()
    }
}

// MARK: - SettingRow Component

private struct SettingRow<Content: View>: View {
    let title: String
    let value: Any
    let hasPendingChange: Bool
    let content: () -> Content
    
    @State private var themeManager = ThemeManager.shared
    
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
