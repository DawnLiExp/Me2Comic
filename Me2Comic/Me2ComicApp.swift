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
        // Main window configuration
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

/// Handles application lifecycle and window management
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private let notificationManager = NotificationManager()

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply theme-appropriate appearance
        applyThemeAppearance()

        // Request notification authorization asynchronously
        Task {
            do {
                _ = try await notificationManager.requestNotificationAuthorization()
            } catch {
                // Log the error if authorization fails, but do not block app launch
                #if DEBUG
                print("Notification authorization failed: \(error.localizedDescription)")
                #endif
            }
        }

        // Main window setup
        if let window = NSApp.windows.first {
            mainWindow = window
            window.isMovableByWindowBackground = true
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.delegate = self
        }

        // Ensure app window comes to foreground after relaunch
        NSApp.activate(ignoringOtherApps: true)

        // Register global keyboard shortcut (Cmd+W to quit)
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

    /// Apply the appropriate system appearance based on current theme
    @MainActor
    private func applyThemeAppearance() {
        let theme = ThemeManager.shared.currentTheme

        switch theme {
        case .greenDark:
            // Dark purple theme - use dark appearance
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case .macOSDark:
            // Light sage theme - use light appearance
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        }
    }

    // Quit app when last window closed
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// Window delegate implementation
extension AppDelegate: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            NSApp.terminate(nil)
        }
        return true
    }
}
