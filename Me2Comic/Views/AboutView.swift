//
//  AboutView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import AppKit
import SwiftUI

/// View displaying app info, language selection, and theme selection
struct AboutView: View {
    @StateObject private var themeManager = ThemeManager.shared
    @State private var showRestartAlert = false
    @State private var showLanguageRestartAlert = false
    
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? NSLocalizedString("BuildVersionDefault", comment: "")
    
    // Language selection state
    @State private var selectedLanguage: String = {
        if let savedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") {
            return savedLanguage
        }

        let systemLanguage = Locale.preferredLanguages.first ?? "en"
        if systemLanguage.contains("zh-Hans") { return "zh-Hans" }
        if systemLanguage.contains("zh-Hant") { return "zh-Hant" }
        if systemLanguage.contains("ja") { return "ja" }
        return "en"
    }()

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSImage(named: NSImage.Name("AppIcon")) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .padding(.top, 20)

            Text("Me2Comic")
                .font(.title)
                .foregroundColor(Color.textMuted)

            Text("Version \(appVersion) (Build \(buildVersion))")
                .foregroundColor(Color.textMuted)

            Text("© 2025 Me2")
                .foregroundColor(Color.textMuted)

            Spacer().frame(height: 20)

            // Language Selection
            HStack(spacing: 5) {
                Text(NSLocalizedString("Select Language", comment: ""))
                    .foregroundColor(Color.textMuted)
                Picker("", selection: Binding(
                    get: { selectedLanguage },
                    set: { newValue in
                        if newValue != selectedLanguage {
                            selectedLanguage = newValue
                            UserDefaults.standard.set(newValue, forKey: "SelectedLanguage")
                            UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                            showLanguageRestartAlert = true
                        }
                    }
                )) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .offset(x: -5)
            }
            
            // Theme Selection
            HStack(spacing: 5) {
                Text(NSLocalizedString("Select Theme", comment: ""))
                    .foregroundColor(Color.textMuted)
                Picker("", selection: Binding(
                    get: { themeManager.currentThemeType },
                    set: { newValue in
                        if newValue != themeManager.currentThemeType {
                            themeManager.currentThemeType = newValue
                            showRestartAlert = true
                        }
                    }
                )) {
                    ForEach(ThemeManager.ThemeType.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .offset(x: -5)
            }

            Spacer()
        }
        .padding()
        .frame(width: 290, height: 380)
        .background(Color.bgTertiary)
        .alert(NSLocalizedString("RestartRequired", comment: ""), isPresented: $showRestartAlert) {
            Button(NSLocalizedString("RestartNow", comment: ""), role: .destructive) {
                restartApp()
            }
            Button(NSLocalizedString("RestartLater", comment: ""), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("RestartThemeMessage", comment: ""))
        }
        .alert(NSLocalizedString("RestartRequired", comment: ""), isPresented: $showLanguageRestartAlert) {
            Button(NSLocalizedString("RestartNow", comment: ""), role: .destructive) {
                restartApp()
            }
            Button(NSLocalizedString("RestartLater", comment: ""), role: .cancel) { }
        } message: {
            Text(NSLocalizedString("RestartLanguageMessage", comment: ""))
        }
    }
    
    private func restartApp() {
        // Save any pending data
        UserDefaults.standard.synchronize()
        
        // Restart the app
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        exit(0)
    }
}
