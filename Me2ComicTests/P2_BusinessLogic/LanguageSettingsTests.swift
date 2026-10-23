import Foundation
import Testing
@testable import Me2Comic

@Suite("语言待应用状态")
@MainActor
struct LanguageSettingsTests {
    @Test("暂存与撤销不改变本次运行语言")
    func pendingAndRevert() throws {
        let suite = "Me2Comic.language.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageSettings(defaults: defaults, activeLanguage: "zh-Hans")
        settings.select("ja")
        #expect(settings.activeLanguage == "zh-Hans")
        #expect(settings.selectedLanguage == "ja")
        #expect(defaults.string(forKey: "SelectedLanguage") == "zh-Hans")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja"])
        settings.select("en")
        settings.select("zh-Hans")
        #expect(settings.pendingLanguage == nil)
        #expect(defaults.string(forKey: "Me2Comic.pendingLanguage") == nil)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
    }

    @Test("下次启动确认实际语言并清除已应用目标", arguments: LanguageSettings.supported)
    func nextLaunch(language: String) throws {
        let suite = "Me2Comic.language.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = LanguageSettings(defaults: defaults, activeLanguage: "en")
        settings.select(language)
        let launched = LanguageSettings(defaults: defaults, activeLanguage: language)
        #expect(launched.activeLanguage == language)
        #expect(launched.pendingLanguage == nil)
        #expect(defaults.string(forKey: "SelectedLanguage") == language)
    }

    @Test("历史提前写入的设置不覆盖本进程实际语言")
    func legacyPending() throws {
        let suite = "Me2Comic.language.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ja", forKey: "SelectedLanguage")
        defaults.set("ja", forKey: "Me2Comic.pendingLanguage")
        let settings = LanguageSettings(defaults: defaults, activeLanguage: "zh-Hans")
        #expect(settings.activeLanguage == "zh-Hans")
        #expect(settings.pendingLanguage == "ja")
        settings.select("zh-Hans")
        #expect(defaults.string(forKey: "SelectedLanguage") == "zh-Hans")
    }
}
