//
//  AboutView.swift
//  Me2Comic
//
//  Created by Me2 on 2025/8/6.
//

import AppKit
import SwiftUI

/// View displaying app info and language selection
struct AboutView: View {
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
                .foregroundColor(.textPrimary)

            Text("Version \(appVersion) (Build \(buildVersion))")
                .foregroundColor(.textSecondary)

            Text("© 2025 Me2")
                .foregroundColor(.textSecondary)

            Spacer().frame(height: 20)

            HStack(spacing: 5) {
                Text(NSLocalizedString("Select Language", comment: ""))
                    .foregroundColor(.textPrimary)
                Picker("", selection: $selectedLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("繁體中文").tag("zh-Hant")
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
                .pickerStyle(.menu)
                .frame(width: 100)
                .offset(x: -5)
                .onChange(of: selectedLanguage) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "SelectedLanguage")
                    UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
                }
            }

            Spacer()
        }
        .padding()
        .frame(width: 290, height: 340)
        .background(.backgroundPrimary)
    }
}
