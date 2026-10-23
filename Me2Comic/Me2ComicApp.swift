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

    @ObservationIgnored private let confirmStop: (NSWindow?) async -> Bool
    @ObservationIgnored private let launchReplacement: () async throws -> Void
    @ObservationIgnored private let requestExit: () -> Void
    @ObservationIgnored private let replyTermination: (Bool) -> Void
    @ObservationIgnored private let reportRestartError: (Error) -> Void
    private var transitionTask: Task<Void, Never>?

    init(
        confirmStop: @escaping (NSWindow?) async -> Bool = { await AppLifecycle.confirmStopping(in: $0) },
        launchReplacement: @escaping () async throws -> Void = {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            configuration.createsNewApplicationInstance = true
            _ = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        },
        requestExit: @escaping () -> Void = { NSApp.terminate(nil) },
        replyTermination: @escaping (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) },
        reportRestartError: @escaping (Error) -> Void = {
            let alert = NSAlert()
            alert.messageText = String(localized: "RestartFailed")
            alert.informativeText = $0.localizedDescription
            alert.runModal()
        }
    ) {
        self.confirmStop = confirmStop
        self.launchReplacement = launchReplacement
        self.requestExit = requestExit
        self.replyTermination = replyTermination
        self.reportRestartError = reportRestartError
        super.init()
    }

    func waitForTransition() async { await transitionTask?.value }

    private static func confirmStopping(in window: NSWindow?) async -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "StopTasksBeforeClosing")
        alert.informativeText = String(localized: "StopTasksBeforeClosingDetail")
        alert.addButton(withTitle: String(localized: "ContinueProcessing"))
        alert.addButton(withTitle: String(localized: "StopTasksAndContinue"))
        let response: NSApplication.ModalResponse
        if let window { response = await alert.beginSheetModal(for: window) }
        else { response = alert.runModal() }
        return response == .alertSecondButtonReturn
    }

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
            requestExit()
            return false
        }
        busy = true
        transitionTask = Task {
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
        transitionTask = Task {
            let approved = await prepare(Array(entries.values))
            terminationApproved = approved
            busy = false
            replyTermination(approved)
        }
        return .terminateLater
    }

    private func prepare(_ targets: [Entry]) async -> Bool {
        for entry in targets { entry.processor.isClosing = true }
        if targets.contains(where: { $0.processor.hasActiveWork }) {
            let approved = await confirmStop(targets.compactMap(\.window).first)
            guard approved else {
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
        do {
            try await launchReplacement()
            terminationApproved = true
            busy = false
            requestExit()
        } catch {
            for entry in targets {
                entry.processor.isClosing = false
                if entry.processor.gmStatus.isChecking { entry.processor.retryGraphicsMagickDetection() }
            }
            busy = false
            reportRestartError(error)
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
