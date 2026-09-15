import AppKit

@main @MainActor struct SettingsTests {
    static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
    static func texts(_ window: NSWindow?) -> [String] {
        guard let content = window?.contentView else { return [] }
        return descendants(content).compactMap { view -> String? in
            if let field = view as? NSTextField { return field.stringValue }
            if let button = view as? NSButton { return button.title }
            return nil
        }
    }
    static func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }

    static func main() {
        _ = NSApplication.shared
        // One fixed suite for dot layout and language: nothing touches the user's real preferences.
        let suite = "com.rex.myduobar.tests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        L10n.useDefaultsSuiteForTesting(suite)
        let controller = SettingsController(preferences: DotPreferences(defaults: defaults))
        var languageChanges = 0
        controller.onLanguageChange = { languageChanges += 1 }
        controller.update(SystemStatus())

        let allText = texts(controller.window).joined(separator: "\n")
        check(!allText.contains("nybbamboo") && !allText.contains("小紅書") && !allText.contains("Xiaohongshu"),
              "the developer contact section is gone")

        for (index, language) in [AppLanguage.en, .ja, .zhHant].enumerated() {
            guard let popup = descendants(controller.window!.contentView!).compactMap({ $0 as? NSPopUpButton }).first else {
                check(false, "the settings window has a language menu"); return
            }
            check(popup.numberOfItems == AppLanguage.allCases.count, "the language menu lists every language")
            popup.selectItem(at: AppLanguage.allCases.firstIndex(of: language)!)
            popup.sendAction(popup.action, to: popup.target)
            spin()
            check(L10n.preference == language && L10n.current == language, "choosing \(language) stores the preference")
            check(languageChanges == index + 1, "choosing \(language) notifies the app once")
            check(controller.window?.title == L10n.settingsTitle, "\(language) retitles the window")
            let labels = texts(controller.window)
            check(labels.contains(L10n.launchAtLogin) && labels.contains(L10n.bottomDotsNote), "\(language) rebuilds every label")
            check(labels.filter { $0 == L10n.launchAtLogin }.count == 1, "\(language) rebuild leaves no duplicate controls")
            let content = controller.window!.contentView!
            let lowest = descendants(content).filter { !$0.isHidden && $0.frame.height > 0 }
                .map { $0.convert($0.bounds, to: content).minY }.min() ?? 0
            check(lowest >= 0, "\(language) content fits inside the window")
        }
        print("PASS: settings language switching rebuilds the window in English, Japanese and Traditional Chinese")
    }
}
