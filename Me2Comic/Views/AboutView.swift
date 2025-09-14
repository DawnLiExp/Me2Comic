//
//  AboutView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import AppKit
import SwiftUI

enum ChangeType {
    case none, language, theme, both
}

struct AboutView: View {
    // Layout
    private let horizontalPadding: CGFloat = 50
    private let labelMinWidth: CGFloat = 80
    private let pickerWidth: CGFloat = 105

    // App info
    private let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    private let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""

    // State
    @State private var appliedLanguage: String = {
        if let saved = UserDefaults.standard.string(forKey: "SelectedLanguage") { return saved }
        let system = Locale.preferredLanguages.first ?? "en"
        if system.contains("zh-Hans") { return "zh-Hans" }
        if system.contains("zh-Hant") { return "zh-Hant" }
        if system.contains("ja") { return "ja" }
        return "en"
    }()

    @State private var selectedLanguage: String = ""
    @StateObject private var themeManager = ThemeManager.shared
    @State private var selectedTheme: AppTheme = ThemeManager.shared.currentTheme
    @State private var pendingTheme: AppTheme?

    @State private var showRestartAlert = false
    @State private var pendingChangeType: ChangeType = .none

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSImage(named: NSImage.Name("AppIcon")) ?? NSImage())
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .padding(.top, 20)

            Text("Me2Comic")
                .font(.title)
                .foregroundColor(Color.adaptiveTextPrimary)

            Text("Version \(appVersion) (Build \(buildVersion))")
                .font(.caption)
                .foregroundColor(Color.adaptiveTextSecondary)

            Text("© 2025 Me2")
                .font(.caption)
                .foregroundColor(Color.adaptiveTextSecondary)

            VStack(spacing: 16) {
                HStack(spacing: 5) {
                    Text(NSLocalizedString("LanguageSettings", comment: ""))
                        .font(.headline)
                        .foregroundColor(Color.adaptiveTextPrimary)
                        .frame(minWidth: labelMinWidth, alignment: .leading)

                    Picker("", selection: $selectedLanguage) {
                        Text("简体中文").tag("zh-Hans")
                        Text("繁體中文").tag("zh-Hant")
                        Text("English").tag("en")
                        Text("日本語").tag("ja")
                    }
                    .pickerStyle(.menu)
                    .frame(width: pickerWidth)
                    .fixedSize()
                    .onChange(of: selectedLanguage) { _, newValue in
                        // If user reverts to applied language, clear pending and restore consistency
                        if newValue == appliedLanguage {
                            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingLanguage")
                            // Restore AppleLanguages to appliedLanguage instead of removing it
                            UserDefaults.standard.set([appliedLanguage], forKey: "AppleLanguages")
                            switch pendingChangeType {
                            case .language: pendingChangeType = .none
                            case .both: pendingChangeType = .theme
                            default: break
                            }
                            return
                        }

                        // Save pending language
                        UserDefaults.standard.set(newValue, forKey: "Me2Comic.pendingLanguage")
                        UserDefaults.standard.set(newValue, forKey: "SelectedLanguage")
                        // Update AppleLanguages immediately so it persists across relaunch
                        UserDefaults.standard.set([newValue], forKey: "AppleLanguages")

                        pendingChangeType = (pendingChangeType == .theme) ? .both : .language
                        showRestartAlert = true
                    }
                }
                .padding(.horizontal, horizontalPadding)

                HStack(spacing: 5) {
                    Text(NSLocalizedString("ThemeSettings", comment: ""))
                        .font(.headline)
                        .foregroundColor(Color.adaptiveTextPrimary)
                        .frame(minWidth: labelMinWidth, alignment: .leading)

                    Picker("", selection: $selectedTheme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: pickerWidth)
                    .fixedSize()
                    .onChange(of: selectedTheme) { _, newTheme in
                        if newTheme == themeManager.currentTheme {
                            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingTheme")
                            switch pendingChangeType {
                            case .theme: pendingChangeType = .none
                            case .both: pendingChangeType = .language
                            default: break
                            }
                            return
                        }

                        pendingTheme = newTheme
                        UserDefaults.standard.set(newTheme.rawValue, forKey: "Me2Comic.pendingTheme")
                        pendingChangeType = (pendingChangeType == .language) ? .both : .theme
                        showRestartAlert = true
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
            .padding(.top, 40)

            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 320, height: 420)
        .background(Color.bgTertiary)
        .alert(isPresented: $showRestartAlert) {
            Alert(
                title: Text(NSLocalizedString("RestartRequired", comment: "")),
                message: Text(restartMessage),
                primaryButton: .default(Text(NSLocalizedString("RestartNow", comment: ""))) {
                    Task { await restartApplication() }
                },
                secondaryButton: .cancel(Text(NSLocalizedString("Later", comment: ""))) {
                    // keep pending selections; user may revert which clears pending
                }
            )
        }
        .onAppear {
            // Load language selection
            if let pending = UserDefaults.standard.string(forKey: "Me2Comic.pendingLanguage") {
                selectedLanguage = pending
            } else {
                selectedLanguage = appliedLanguage
            }

            // Load theme selection
            if let pendingRaw = UserDefaults.standard.string(forKey: "Me2Comic.pendingTheme"),
               let pending = AppTheme(rawValue: pendingRaw)
            {
                pendingTheme = pending
                selectedTheme = pending
            } else {
                selectedTheme = themeManager.currentTheme
            }
        }
    }

    private var restartMessage: String {
        switch pendingChangeType {
        case .language: return NSLocalizedString("RestartRequiredLanguage", comment: "")
        case .theme: return NSLocalizedString("RestartRequiredTheme", comment: "")
        case .both: return NSLocalizedString("RestartRequiredBoth", comment: "")
        case .none: return ""
        }
    }

    private func restartApplication() async {
        if let pending = pendingTheme {
            _ = themeManager.setTheme(pending)
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingTheme")
        }

        if let pendingLang = UserDefaults.standard.string(forKey: "Me2Comic.pendingLanguage") {
            // AppleLanguages is already set in onChange, but ensure it's set here too
            UserDefaults.standard.set([pendingLang], forKey: "AppleLanguages")
            UserDefaults.standard.set(pendingLang, forKey: "SelectedLanguage")
            UserDefaults.standard.removeObject(forKey: "Me2Comic.pendingLanguage")
        }

        let bundleURL = Bundle.main.bundleURL

        // 1) Primary: launch app binary directly (most reliable to create a new process)
        let execURL = Bundle.main.executableURL
            ?? bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent(Bundle.main.infoDictionary?["CFBundleExecutable"] as? String ?? "")

        if FileManager.default.fileExists(atPath: execURL.path) {
            let proc = Process()
            proc.executableURL = execURL
            proc.arguments = []
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            proc.environment = ProcessInfo.processInfo.environment
            do {
                try proc.run()

                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return
            } catch {
                NSLog("Direct executable launch failed: \(error.localizedDescription). Falling back to NSWorkspace.")
            }
        } else {
            NSLog("Executable not found at \(execURL.path). Falling back to NSWorkspace.")
        }

        // 2) Fallback: NSWorkspace.openApplication
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, openError in
                if let openError = openError {
                    NSLog("NSWorkspace open failed: \(openError.localizedDescription). Falling back to `open -n`.")
                    // 3) Final fallback: open -n
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    task.arguments = ["-n", bundleURL.path]
                    task.standardOutput = FileHandle.nullDevice
                    task.standardError = FileHandle.nullDevice
                    do {
                        try task.run()
                        DispatchQueue.main.async {
                            NSApplication.shared.terminate(nil)
                        }
                        return
                    } catch {
                        NSLog("Primary open -n failed: \(error.localizedDescription). Falling back to NSWorkspace.")
                    }
                }
                continuation.resume()
            }
        }

        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
        }
    }
}
