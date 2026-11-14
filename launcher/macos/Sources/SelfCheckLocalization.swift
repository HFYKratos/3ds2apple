//
//  SelfCheckLocalization.swift
//  3ds2apple macOS launcher
//
//  Self-check part 3: the two-language UI (docs/launcher-ui.md). Everything is
//  headless: language resolution from the macOS preferred-language list, the
//  Settings override, both string tables being complete, the iOS-shell
//  terminology and the persisted preference.
//

import Foundation

@MainActor
enum SelfCheckLocalization {
    static func checks() -> [SelfCheck.Check] {
        var checks: [SelfCheck.Check] = []
        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            checks.append(SelfCheck.Check(name: name, passed: condition, detail: condition ? "" : detail))
        }

        // 17. System language resolution (Simplified Chinese wins, otherwise English)
        expect("i18n: zh-Hans-CN resolves to Chinese", LauncherLanguage.resolveSystem(preferred: ["zh-Hans-CN", "en-US"]) == .chinese)
        expect("i18n: zh-CN resolves to Chinese", LauncherLanguage.resolveSystem(preferred: ["zh-CN"]) == .chinese)
        expect("i18n: bare zh resolves to Chinese", LauncherLanguage.resolveSystem(preferred: ["zh"]) == .chinese)
        expect("i18n: zh-Hant falls back to English", LauncherLanguage.resolveSystem(preferred: ["zh-Hant-TW"]) == .english)
        expect("i18n: en-US resolves to English", LauncherLanguage.resolveSystem(preferred: ["en-US"]) == .english)
        expect("i18n: ja-JP falls back to English", LauncherLanguage.resolveSystem(preferred: ["ja-JP"]) == .english)
        expect("i18n: empty preference list falls back to English", LauncherLanguage.resolveSystem(preferred: []) == .english)
        expect("i18n: underscore locale tag resolves", LauncherLanguage.resolveSystem(preferred: ["zh_Hans_CN"]) == .chinese)
        expect("i18n: explicit Chinese override wins", LauncherLanguage.chinese.resolved(preferred: ["en-US"]) == .chinese)
        expect("i18n: explicit English override wins", LauncherLanguage.english.resolved(preferred: ["zh-Hans"]) == .english)
        expect("i18n: system override follows zh-Hans", LauncherLanguage.system.resolved(preferred: ["zh-Hans"]) == .chinese)

        // 18. Both tables are complete and actually translated.
        let english = LauncherStrings(language: .english)
        let chinese = LauncherStrings(language: .chinese)
        let englishFields = english.localizedStringFields()
        let chineseFields = chinese.localizedStringFields()
        expect("i18n: English table has all fields", englishFields.count >= 120, "fields: " + String(englishFields.count))
        expect("i18n: Chinese table has all fields", chineseFields.count >= 120, "fields: " + String(chineseFields.count))
        expect("i18n: both tables have the same fields", englishFields.count == chineseFields.count)
        let emptyEnglish = englishFields.filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { $0.0 }
        let emptyChinese = chineseFields.filter { $0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { $0.0 }
        expect("i18n: no empty English strings", emptyEnglish.isEmpty, emptyEnglish.joined(separator: ","))
        expect("i18n: no empty Chinese strings", emptyChinese.isEmpty, emptyChinese.joined(separator: ","))
        let translated = zip(englishFields, chineseFields).filter { $0.1 != $1.1 }.count
        expect("i18n: Chinese table is translated (not copied)", translated >= 100, "identical fields: " + String(englishFields.count - translated))
        let formatSpecifiers = englishFields.filter { $0.1.contains("%") }.count
        expect("i18n: format strings keep their placeholders", translated >= 0 && formatSpecifiers >= 8)

        // 19. iOS-shell terminology is reused in Chinese.
        expect("i18n: zh uses 游戏库 for Library", chinese.navLibrary == "游戏库")
        expect("i18n: zh uses 导入 for Import", chinese.navImport == "导入")
        expect("i18n: zh uses 设置 for Settings", chinese.settings == "设置")
        expect("i18n: zh push action wording", chinese.primaryPush == "推送游戏数据")
        expect("i18n: zh install wording", chinese.primaryInstall == "安装游戏库")
        expect("i18n: en library terminology", english.navLibrary == "Library" && english.navImport == "Import" && english.settings == "Settings")
        expect("i18n: zh keeps Apple ID", chinese.signingTitle.contains("Apple ID"))

        // 20. Enum labels are localized for every case.
        let phaseOK = GamePhase.allCases.allSatisfy { !english.phase($0).isEmpty && !chinese.phase($0).isEmpty && english.phase($0) != chinese.phase($0) }
        let stateOK = TaskState.allCases.allSatisfy { !english.taskState($0).isEmpty && !chinese.taskState($0).isEmpty }
        let modeOK = BuildMode.allCases.allSatisfy { english.buildModeTitle($0) != chinese.buildModeTitle($0) && !english.buildModeDetail($0).isEmpty }
        let strategyOK = InstallStrategy.allCases.allSatisfy { english.installStrategyTitle($0) != chinese.installStrategyTitle($0) && !chinese.installStrategyDetail($0).isEmpty }
        expect("i18n: game phases localized", phaseOK)
        expect("i18n: task states localized", stateOK)
        expect("i18n: build modes localized", modeOK)
        expect("i18n: install strategies localized", strategyOK)
        let languageRowsOK = LauncherLanguage.allCases.allSatisfy {
            !english.languageTitle($0).isEmpty && !chinese.languageTitle($0).isEmpty && !english.languageDetail($0).isEmpty
        }
        expect("i18n: language picker rows localized", languageRowsOK)

        // 21. Formatting helpers keep numbers/values.
        expect("i18n: games count keeps the number", english.gamesCount(3).contains("3") && chinese.gamesCount(3).contains("3"))
        expect("i18n: checks format keeps both numbers", english.diagnosticsChecks(4, 9).contains("4") && chinese.diagnosticsChecks(4, 9).contains("9"))
        expect("i18n: version format keeps version", english.aboutVersion("0.2.0", "2").contains("0.2.0") && chinese.aboutVersion("0.2.0", "2").contains("0.2.0"))

        // 22. Settings override is persisted (and bad stored values fall back).
        let suiteName = "zl-selfcheck-i18n-" + UUID().uuidString
        if let defaults = UserDefaults(suiteName: suiteName) {
            defaults.removePersistentDomain(forName: suiteName)
            let first = LauncherSettings(persist: true, defaults: defaults)
            expect("i18n: language defaults to system", first.language == .system)
            first.language = .chinese
            first.save()
            let reloaded = LauncherSettings(persist: true, defaults: defaults)
            expect("i18n: language override persists", reloaded.language == .chinese)
            defaults.set("klingon", forKey: "zl.language")
            let corrupted = LauncherSettings(persist: true, defaults: defaults)
            expect("i18n: unknown stored language falls back to system", corrupted.language == .system)
            defaults.removePersistentDomain(forName: suiteName)
        } else {
            expect("i18n: language override persists", false, "no UserDefaults suite")
        }

        return checks
    }
}
