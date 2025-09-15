//
//  Me2ComicApp.swift
//  Me2Comic
//
//  Created by Me2 on 2025/4/27.
//

import AppKit
import SwiftUI

@main
struct Me2ComicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ImageProcessorView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)

        Settings {
            AboutView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private let notificationManager = NotificationManager()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply pending changes if exists
        applyPendingChanges()
        
        // Apply theme appearance
        applyThemeAppearance()

        Task {
            do {
                _ = try await notificationManager.requestNotificationAuthorization()
            } catch {
                #if DEBUG
                print("Notification authorization failed: \(error.localizedDescription)")
                #endif
            }
        }

        if let window = NSApp.windows.first {
            mainWindow = window
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.delegate = self
        }

        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.modifierFlags.contains(.command),
               event.charactersIgnoringModifiers == "w"
            {
                NSApp.terminate(nil)
                return nil
            }
            return event
        }
    }
    
    @MainActor
    private func applyPendingChanges() {
        let defaults = UserDefaults.standard
        
        // Apply pending theme if exists
        if let pendingThemeRaw = defaults.string(forKey: "Me2Comic.pendingTheme"),
           let pendingTheme = AppTheme(rawValue: pendingThemeRaw) {
            _ = ThemeManager.shared.setTheme(pendingTheme)
            defaults.set(pendingTheme.rawValue, forKey: "Me2Comic.selectedTheme")
            defaults.removeObject(forKey: "Me2Comic.pendingTheme")
        }
        
        // Apply pending language if exists
        if let pendingLang = defaults.string(forKey: "Me2Comic.pendingLanguage") {
            defaults.set([pendingLang], forKey: "AppleLanguages")
            defaults.set(pendingLang, forKey: "SelectedLanguage")
            defaults.removeObject(forKey: "Me2Comic.pendingLanguage")
        }
    }

    @MainActor
    private func applyThemeAppearance() {
        let theme = ThemeManager.shared.currentTheme
        
        // Set system appearance to match theme type
        // This ensures system controls (pickers, buttons, etc.) match the theme
        NSApplication.shared.appearance = theme.isLightTheme
            ? NSAppearance(named: .aqua)
            : NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            NSApp.terminate(nil)
        }
        return true
    }
}
