import AppKit
import Testing
@testable import Me2Comic

@MainActor
private final class LifecycleProcessor: ImageProcessor {
    var working = true
    var cleanupCount = 0
    override var hasActiveWork: Bool { working }
    override func cancelAndWait() async { cleanupCount += 1; working = false }
}

@Suite("窗口与应用退出协调", .serialized)
@MainActor
struct AppLifecycleTests {
    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    private func processor() -> LifecycleProcessor {
        LifecycleProcessor(stateManager: ProcessingStateManager(), logger: ProcessingLogger(), detector: { .success("/fixture/gm") })
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "Me2Comic.lifecycle.tests.\(UUID())")!
    }

    @Test("拒绝退出保留运行任务，重复退出不重复确认")
    func rejectQuit() async {
        var confirmations = 0
        var replies: [Bool] = []
        let lifecycle = AppLifecycle(confirmStop: { _ in confirmations += 1; return false }, replyTermination: { replies.append($0) })
        let window = window(), processor = processor()
        lifecycle.register(window: window, processor: processor, settings: AppSettingsStore(defaults: defaults()))
        #expect(lifecycle.requestTermination() == .terminateLater)
        #expect(lifecycle.requestTermination() == .terminateCancel)
        await lifecycle.waitForTransition()
        #expect(confirmations == 1)
        #expect(replies == [false])
        #expect(processor.cleanupCount == 0)
        #expect(!processor.isClosing)
    }

    @Test("确认退出会清理全部窗口并保存最新输入")
    func approveQuit() async {
        var replies: [Bool] = []
        let lifecycle = AppLifecycle(confirmStop: { _ in true }, replyTermination: { replies.append($0) })
        let first = window(), second = window()
        let p1 = processor(), p2 = processor()
        let store = defaults(), settings = AppSettingsStore(defaults: defaults())
        let firstSettings = AppSettingsStore(defaults: store)
        firstSettings.quality = "91"
        lifecycle.register(window: first, processor: p1, settings: firstSettings)
        lifecycle.register(window: second, processor: p2, settings: settings)
        #expect(lifecycle.requestTermination() == .terminateLater)
        await lifecycle.waitForTransition()
        #expect(replies == [true])
        #expect(p1.cleanupCount == 1 && p2.cleanupCount == 1)
        #expect(store.string(forKey: AppSettingsStore.Keys.quality) == "91")
        #expect(lifecycle.requestTermination() == .terminateNow)
    }

    @Test("关闭最后主窗口请求退出，设置窗口不被登记")
    func lastWindow() {
        var exits = 0
        let lifecycle = AppLifecycle(requestExit: { exits += 1 })
        let main = window(), settingsWindow = window()
        let p = processor()
        lifecycle.register(window: main, processor: p, settings: AppSettingsStore(defaults: defaults()))
        #expect(!lifecycle.windowShouldClose(main))
        #expect(exits == 1)
        #expect(settingsWindow.delegate == nil)
    }

    @Test("关闭非最后窗口只取消该窗口任务")
    func individualWindow() async {
        var exits = 0
        let lifecycle = AppLifecycle(confirmStop: { _ in true }, requestExit: { exits += 1 })
        let first = window(), second = window()
        let p1 = processor(), p2 = processor()
        lifecycle.register(window: first, processor: p1, settings: AppSettingsStore(defaults: defaults()))
        lifecycle.register(window: second, processor: p2, settings: AppSettingsStore(defaults: defaults()))
        #expect(!lifecycle.windowShouldClose(first))
        await lifecycle.waitForTransition()
        #expect(exits == 0)
        #expect(p1.cleanupCount == 1 && p2.cleanupCount == 0)
    }

    @Test("重启失败保留应用并解除操作锁")
    func restartFailure() async {
        var exits = 0, errors = 0
        let lifecycle = AppLifecycle(confirmStop: { _ in true }, launchReplacement: { throw CocoaError(.fileNoSuchFile) }, requestExit: { exits += 1 }, reportRestartError: { _ in errors += 1 })
        let window = window(), p = processor()
        lifecycle.register(window: window, processor: p, settings: AppSettingsStore(defaults: defaults()))
        await lifecycle.restart()
        #expect(p.cleanupCount == 1)
        #expect(exits == 0 && errors == 1)
        #expect(!p.isClosing && !lifecycle.isBusy)
    }
}
