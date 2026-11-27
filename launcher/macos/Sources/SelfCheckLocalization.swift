//
//  SelfCheckLocalization.swift
//  3ds2apple macOS launcher
//
//  Self-check part 3: the two-language UI (launcher/macos/README.md +
//  launcher/macos/README.md). Everything is headless: language resolution from
//  the macOS preferred-language list, the Settings override, both string tables
//  being complete, the two-section v2 terminology and the persisted preference.
//

import Foundation

@MainActor
enum SelfCheckLocalization {
    static func checks() -> [SelfCheck.Check] {
        var checks: [SelfCheck.Check] = []
        func expect(_ name: String, _ condition: Bool, _ detail: String = "") {
            checks.append(SelfCheck.Check(name: name, passed: condition, detail: condition ? "" : detail))
        }

        // 18. System language resolution (Simplified Chinese wins, otherwise English)
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

        // 19. Both tables are complete and actually translated.
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
        expect("i18n: format strings keep their placeholders", formatSpecifiers >= 8, String(formatSpecifiers))
        expect("i18n: publisher line keeps the publisher",
               english.publisher("Nintendo").contains("Nintendo") && chinese.publisher("Nintendo").contains("Nintendo"))
        let mockedHardware = HardwareProfile(logicalCores: 8, physicalCores: 8, totalMemoryBytes: 12 * 1_073_741_824)
        expect("i18n: hardware line keeps cores, RAM and jobs",
               english.hardwareLine(mockedHardware).contains("8")
               && english.hardwareLine(mockedHardware).contains("12")
               && chinese.hardwareLine(mockedHardware).contains("8"))
        expect("i18n: compile hardware wording is localized",
               english.deployCompileHardware(mockedHardware) != chinese.deployCompileHardware(mockedHardware))
        let dataKinds: [DataRootKind] = [.portable, .applicationSupport, .explicit, .tempFallback]
        expect("i18n: every data-root kind is localized",
               dataKinds.allSatisfy {
                   !english.dataRootKind($0).isEmpty && !chinese.dataRootKind($0).isEmpty
                       && english.dataRootKind($0) != chinese.dataRootKind($0)
               })
        expect("i18n: migration summary keeps the file count",
               english.dataRootMigration(3).contains("3") && chinese.dataRootMigration(3).contains("3"))

        // 20. The v2 two-section terminology is reused.
        expect("i18n: zh uses 游戏库 for Library", chinese.navLibrary == "游戏库")
        expect("i18n: zh uses 导入手机 for Deploy", chinese.navDeploy == "导入手机")
        expect("i18n: zh uses 设置 for Settings", chinese.settings == "设置")
        expect("i18n: en library/deploy terminology", english.navLibrary == "Library" && english.navDeploy == "Deploy" && english.settings == "Settings")
        expect("i18n: zh one-click deploy wording", chinese.deployButton(2).contains("一键部署") && chinese.deployButton(2).contains("2"))
        expect("i18n: zh Done wording", chinese.deployDoneMessage == "可以打开手机 App 游玩")
        expect("i18n: zh keeps Apple ID", chinese.signingTitle.contains("Apple ID"))
        expect("i18n: zh import wording", chinese.importTitle.contains("导入") && chinese.addGame.contains("添加"))
        expect("i18n: zh deploy steps are localized", chinese.deployStepCheckDevice != english.deployStepCheckDevice
            && chinese.deployStepCompose != english.deployStepCompose
            && chinese.deployStepVerifyIPA != english.deployStepVerifyIPA
            && chinese.deployCompileStep(2) != english.deployCompileStep(2))
        expect("i18n: zh notes the ROM-free rule", chinese.deployNoteROMFree.contains("ROM") && english.deployNoteROMFree.contains("ROM"))
        expect("i18n: zh status words differ", chinese.statusReady != chinese.statusNeedsAttention && english.statusReady != english.statusNeedsAttention)

        // 21. Enum labels are localized for every case.
        let phaseOK = GamePhase.allCases.allSatisfy { !english.phase($0).isEmpty && !chinese.phase($0).isEmpty && english.phase($0) != chinese.phase($0) }
        let stateOK = TaskState.allCases.allSatisfy { !english.taskState($0).isEmpty && !chinese.taskState($0).isEmpty }
        expect("i18n: game phases localized", phaseOK)
        expect("i18n: task states localized", stateOK)
        let languageRowsOK = LauncherLanguage.allCases.allSatisfy {
            !english.languageTitle($0).isEmpty && !chinese.languageTitle($0).isEmpty && !english.languageDetail($0).isEmpty
        }
        expect("i18n: language picker rows localized", languageRowsOK)
        expect("i18n: deploy step labels differ per language", english.deployStepPush != chinese.deployStepPush && english.deployStepDone != chinese.deployStepDone)

        // 22. Formatting helpers keep numbers/values.
        expect("i18n: games count keeps the number", english.gamesCount(3).contains("3") && chinese.gamesCount(3).contains("3"))
        expect("i18n: deploy button keeps the count", english.deployButton(2).contains("2") && chinese.deployButton(2).contains("2"))
        expect("i18n: about version keeps version", english.aboutVersion("0.3.0", "3").contains("0.3.0") && chinese.aboutVersion("0.3.0", "3").contains("0.3.0"))
        expect("i18n: signing assets format keeps counts", english.signingAssets(2, 3).contains("2") && chinese.signingAssets(2, 3).contains("3"))

        // 23. Settings override is persisted (and bad stored values fall back).
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
