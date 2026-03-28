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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: NSWindow?
    private let notificationManager = NotificationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply pending language changes
        applyPendingLanguageChanges()

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

        activatePrimaryWindow()

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

    private func applyPendingLanguageChanges() {
        let defaults = UserDefaults.standard

        // Apply pending language if exists
        if let pendingLang = defaults.string(forKey: "Me2Comic.pendingLanguage") {
            defaults.set([pendingLang], forKey: "AppleLanguages")
            defaults.set(pendingLang, forKey: "SelectedLanguage")
            defaults.removeObject(forKey: "Me2Comic.pendingLanguage")
        }
    }

    private func applyThemeAppearance() {
        let theme = ThemeManager.shared.currentTheme

        // Set system appearance to match theme type
        NSApplication.shared.appearance = theme.isLightTheme
            ? NSAppearance(named: .aqua)
            : NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    private func activatePrimaryWindow(attempt: Int = 0) {
        guard let window = preferredPrimaryWindow() else {
            guard attempt < 12 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.activatePrimaryWindow(attempt: attempt + 1)
            }
            return
        }

        configureWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .disallowed
        window.delegate = self

        if isPrimaryCandidate(window) {
            mainWindow = window
        }
    }

    private func preferredPrimaryWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter(isPrimaryCandidate)
        if let largest = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            return largest
        }
        return NSApp.windows.first
    }

    private func isPrimaryCandidate(_ window: NSWindow) -> Bool {
        let minMainWidth: CGFloat = 600
        return window.frame.width >= minMainWidth
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        configureWindow(window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender == mainWindow {
            NSApp.terminate(nil)
        }
        return true
    }
}
