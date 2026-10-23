import AppKit
import Observation
import SwiftUI

@main
struct Me2ComicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() { _ = LanguageSettings.shared }

    var body: some Scene {
        WindowGroup { ImageProcessorView() }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentMinSize)
        Settings { AboutView() }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationManager = NotificationManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let theme = ThemeManager.shared.currentTheme
        NSApp.appearance = NSAppearance(named: theme.isLightTheme ? .aqua : .darkAqua)
        Task { _ = try? await notificationManager.requestNotificationAuthorization() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLifecycle.shared.requestTermination()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Coordinates only explicitly registered processing windows. Settings retain native behavior.
@MainActor
@Observable
final class AppLifecycle: NSObject, NSWindowDelegate {
    static let shared = AppLifecycle()

    private struct Entry {
        weak var window: NSWindow?
        let processor: ImageProcessor
        let settings: AppSettingsStore
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var allowedClosures: Set<ObjectIdentifier> = []
    private var busy = false
    var isBusy: Bool { busy }
    private var terminationApproved = false

    func register(window: NSWindow, processor: ImageProcessor, settings: AppSettingsStore) {
        let key = ObjectIdentifier(window)
        guard entries[key] == nil else { return }
        entries[key] = Entry(window: window, processor: processor, settings: settings)
        window.delegate = self
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.tabbingMode = .disallowed
    }

    func windowShouldClose(_ window: NSWindow) -> Bool {
        let key = ObjectIdentifier(window)
        if allowedClosures.remove(key) != nil { return true }
        guard !busy, let entry = entries[key] else { return false }
        let live = entries.values.filter { $0.window != nil }
        if live.count == 1 {
            NSApp.terminate(nil)
            return false
        }
        busy = true
        Task {
            if await prepare([entry]) {
                allowedClosures.insert(key)
                window.performClose(nil)
            }
            busy = false
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        entries.removeValue(forKey: ObjectIdentifier(window))
    }

    func requestTermination() -> NSApplication.TerminateReply {
        if terminationApproved { return .terminateNow }
        guard !busy else { return .terminateCancel }
        busy = true
        Task {
            let approved = await prepare(Array(entries.values))
            terminationApproved = approved
            busy = false
            NSApp.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }

    private func prepare(_ targets: [Entry]) async -> Bool {
        for entry in targets { entry.processor.isClosing = true }
        if targets.contains(where: { $0.processor.hasActiveWork }) {
            let alert = NSAlert()
            alert.messageText = String(localized: "StopTasksBeforeClosing")
            alert.informativeText = String(localized: "StopTasksBeforeClosingDetail")
            alert.addButton(withTitle: String(localized: "ContinueProcessing"))
            alert.addButton(withTitle: String(localized: "StopTasksAndContinue"))
            let response: NSApplication.ModalResponse
            if let window = targets.compactMap(\.window).first {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            guard response == .alertSecondButtonReturn else {
                for entry in targets { entry.processor.isClosing = false }
                return false
            }
        }
        for entry in targets {
            entry.settings.saveParameters()
            await entry.processor.cancelAndWait()
        }
        return true
    }

    func restart() async {
        guard !busy else { return }
        busy = true
        let targets = Array(entries.values)
        guard await prepare(targets) else { busy = false; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            terminationApproved = true
            busy = false
            NSApp.terminate(nil)
        } catch {
            for entry in targets {
                entry.processor.isClosing = false
                if entry.processor.gmStatus.isChecking { entry.processor.retryGraphicsMagickDetection() }
            }
            busy = false
            let alert = NSAlert()
            alert.messageText = String(localized: "RestartFailed")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

struct ProcessingWindowRegistration: NSViewRepresentable {
    let processor: ImageProcessor
    let settings: AppSettingsStore

    func makeNSView(context: Context) -> RegistrationView { RegistrationView() }
    func updateNSView(_ view: RegistrationView, context: Context) {
        view.attach = { window in
            AppLifecycle.shared.register(window: window, processor: processor, settings: settings)
        }
        if let window = view.window { view.attach?(window) }
    }

    final class RegistrationView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }
}
