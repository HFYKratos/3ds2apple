//
//  Localization.swift
//  3ds2apple macOS launcher
//
//  Two languages, chosen from the macOS system UI language (Simplified Chinese
//  -> zh-Hans, everything else -> English) with a Settings override. All visible
//  UI strings live here so the views never contain user-facing literals and the
//  headless self-check can verify both tables. Pipeline text (logs, stage
//  details, Apple signing errors) is produced by the backends and stays in its
//  raw form by design; it is diagnostic output, not chrome.
//

import Foundation

// MARK: - Languages

enum ResolvedLanguage: String, CaseIterable, Codable {
    case english
    case chinese

    var localeIdentifier: String {
        switch self {
        case .english: return "en"
        case .chinese: return "zh-Hans"
        }
    }

    var isChinese: Bool { self == .chinese }
}

enum LauncherLanguage: String, CaseIterable, Codable, Identifiable {
    /// Follow the macOS UI language.
    case system
    case english
    case chinese

    var id: String { rawValue }

    /// Map the macOS preferred-language list to one of the two UI languages.
    /// Simplified Chinese variants win; every other language falls back to
    /// English, matching launcher/macos/README.md.
    static func resolveSystem(preferred: [String]) -> ResolvedLanguage {
        guard let first = preferred.first(where: { !$0.isEmpty }) else { return .english }
        let normalized = first.replacingOccurrences(of: "_", with: "-").lowercased()
        guard normalized.hasPrefix("zh") else { return .english }
        if normalized.contains("hans") { return .chinese }
        if normalized.contains("hant") { return .english }
        if normalized.contains("-cn") || normalized.contains("-sg") || normalized.contains("-my") {
            return .chinese
        }
        if normalized == "zh" { return .chinese }
        return .english
    }

    func resolved(preferred: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .system: return LauncherLanguage.resolveSystem(preferred: preferred)
        case .english: return .english
        case .chinese: return .chinese
        }
    }
}

// MARK: - Strings

struct LauncherStrings {
    let language: ResolvedLanguage

    // Identity and global chrome
    var appTagline: String
    var navLibrary: String
    var navDeploy: String
    var settings: String
    var close: String
    var done: String
    var cancel: String
    var refresh: String
    var export: String
    var clear: String
    var choose: String
    var versionLabel: String
    var modeLive: String
    var modeMock: String
    var busyWorking: String
    var busyCancelling: String
    var readinessChecking: String
    var readinessReady: String
    var readinessNotReady: String
    var readinessHelpChecking: String
    var readinessHelpReady: String
    var readinessHelpNotReady: String
    var statusReady: String
    var statusNeedsAttention: String
    var statusLabel: String

    // ROM SMDH metadata (read-only, supplied by the pack CLI)
    var publisherFormat: String
    var smdhMetadataBadge: String

    // Compile hardware line + portable data folder (launcher 0.2.4)
    var hardwareLabel: String
    var hardwareLineFormat: String
    var dataRootLabel: String
    var dataRootPortable: String
    var dataRootFallback: String
    var dataRootExplicit: String
    var dataRootTemporary: String
    var dataRootMigrationFormat: String

    // Library
    var librarySubtitle: String
    var libraryCountFormat: String
    var libraryIPALabel: String
    // Portable .32a build packages (Library export/import; user data, never uploaded)
    var buildPackageImport: String
    var buildPackageExport: String
    var buildPackageReplace: String
    var buildPackageNeedsPack: String
    var buildPackageWithRom: String
    var buildPackageWithoutRom: String
    var buildPackageExportedFormat: String
    var buildPackageImportedFormat: String
    var buildPackageExportFailedFormat: String
    var buildPackageImportFailedFormat: String
    var buildPackageConflictFormat: String
    // Unsigned single-game IPA export (Library card "Export IPA")
    var exportIpa: String
    var ipaExportedFormat: String
    var ipaExportFailedFormat: String
    var ipaUnsignedHint: String
    var ipaNeedsRom: String
    var emptyLibraryTitle: String
    var emptyLibraryMessage: String
    var importGame: String
    var importButton: String
    var openLibrary: String
    var addFirstGame: String
    var remove: String
    var removeConfirmTitle: String
    var removeConfirmMessage: String
    var removeConfirmAction: String
    var romSizeLabel: String
    var packSizeLabel: String
    var dataStaged: String
    var noDataStaged: String
    var lastErrorLabel: String
    var phaseQueued: String
    var phaseBuilding: String
    var phaseBuilt: String
    var phaseOnDevice: String
    var phaseFailed: String
    var inLibraryBadge: String
    var notInLibraryBadge: String
    var howToPlayTitle: String
    var howToPlayStep1: String
    var howToPlayStep2: String
    var howToPlayStep3: String
    var howToPlayStep4: String

    // Import sheet
    var importTitle: String
    var importSubtitle: String
    var dropTitle: String
    var dropMessage: String
    var dropHint: String
    var dropChoose: String
    var dropUnsupported: String
    var detectedTitle: String
    var detectedBadge: String
    var fieldTitleID: String
    var fieldProductCode: String
    var fieldContainer: String
    var fieldROMSize: String
    var fieldContentSize: String
    var addGame: String
    var clearSelection: String
    var unrecognisedTitle: String
    var importStepsTitle: String
    var step1Title: String
    var step1Detail: String
    var step2Title: String
    var step2Detail: String
    var step3Title: String
    var step3Detail: String
    var step4Title: String
    var step4Detail: String
    var importLogsTitle: String

    // Deploy
    var deploySubtitle: String
    var deploySelectionTitle: String
    var deploySelectAll: String
    var deployClearSelection: String
    var deploySelectedFormat: String
    var deployButtonFormat: String
    var deployNoSelection: String
    var deployNoGames: String
    // Deploy -> Advanced build settings (AOT codegen options)
    var advancedBuildTitle: String
    var advancedBuildBody: String
    var advancedBuildOptLevel: String
    var advancedBuildLto: String
    var advancedBuildFastMath: String
    var advancedBuildSummaryFormat: String
    var advancedBuildReset: String
    var deployDeviceTitle: String
    var deployDeviceNone: String
    var deployDetectDevice: String
    var deployStepsTitle: String
    var deployStepCheckDevice: String
    var deployStepCompileFormat: String
    var deployStepCompose: String
    var deployStepVerifyIPA: String
    var deployStepInstall: String
    var deployStepPush: String
    var deployStepDone: String
    var deployRunningForFormat: String
    var deployDoneTitle: String
    var deployDoneMessage: String
    var deployFailedTitle: String
    var deployRetry: String
    var deployLogTitle: String
    var deployNoteROMFree: String
    var deployInstalledBundle: String
    var deployNotInstalledBundle: String
    var deployEligible: String
    var deployNeedsBuild: String
    var deployPushedFormat: String
    var deployIPAVerifiedFormat: String
    var deployCompileProgressFormat: String
    var deployInstallProgressFormat: String

    // Settings
    var settingsSubtitle: String
    var languageTitle: String
    var languageHint: String
    var languageSystem: String
    var languageEnglish: String
    var languageChinese: String
    var languageAppliesHint: String
    var languageDetectedFormat: String
    var signingTitle: String
    var signingStatusReady: String
    var signingStatusMissing: String
    var signingXcodeFormat: String
    var signingAssetsFormat: String
    var signingTeamFormat: String
    var signingTeamMissing: String
    var signingOpenXcode: String
    var signingExplanation: String
    var signingRefresh: String
    var deviceTitle: String
    var deviceNone: String
    var deviceRefresh: String
    var deviceBundleID: String
    var deviceBundleIDNone: String
    var logsTitle: String
    var logsNoLines: String
    var logsExport: String
    var logsClear: String
    var logsExportedFormat: String
    var logsRawNote: String
    var aboutTitle: String
    var aboutBodyFormat: String
    var aboutLicense: String
    var aboutIconCaption: String
    var aboutVersionFormat: String
    var diagnosticsChecksFormat: String
    var diagnosticsToolchainTitle: String

    // Task states
    var taskQueued: String
    var taskRunning: String
    var taskSucceeded: String
    var taskFailed: String
    var taskCancelled: String

    init(language: ResolvedLanguage) {
        self.language = language
        let zh = language == .chinese
        func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

        appTagline = t("macOS launcher", "macOS 启动器")
        navLibrary = t("Library", "游戏库")
        navDeploy = t("Deploy", "导入手机")
        settings = t("Settings", "设置")
        close = t("Close", "关闭")
        done = t("Done", "完成")
        cancel = t("Cancel", "取消")
        refresh = t("Refresh", "刷新")
        export = t("Export", "导出")
        clear = t("Clear", "清除")
        choose = t("Choose", "选择")
        versionLabel = t("Version", "版本")
        modeLive = t("LIVE", "实机")
        modeMock = t("MOCK / DRY RUN", "模拟 / 试运行")
        busyWorking = t("Working...", "正在处理...")
        busyCancelling = t("Cancelling...", "正在取消...")
        readinessChecking = t("Checking...", "正在检查...")
        readinessReady = t("Ready", "已完成准备")
        readinessNotReady = t("Not ready", "未完成准备")
        readinessHelpChecking = t("Running the automatic startup readiness check...", "正在运行启动自动检查...")
        readinessHelpReady = t(
            "The local toolchain and Apple ID signing are ready. The check runs automatically on every launch.",
            "本机工具链与 Apple ID 签名均已就绪。每次启动都会自动检查。",
        )
        readinessHelpNotReady = t(
            "Some local tools are missing or Xcode is not signed in. Details are in the tooltip/log; fix them and relaunch.",
            "缺少本机工具，或 Xcode 尚未登录。详情见提示/日志；修复后重新启动即可。",
        )
        statusReady = t("Ready", "就绪")
        statusNeedsAttention = t("Needs attention", "需要处理")
        statusLabel = t("Status", "状态")
        publisherFormat = t("Publisher: %@", "发行商：%@")
        smdhMetadataBadge = t("SMDH", "SMDH")
        hardwareLabel = t("Compile hardware", "编译硬件")
        hardwareLineFormat = t(
            "%d logical cores · %@ GB RAM · 3dsrecomp auto-parallelizes (%d jobs, memory-budgeted)",
            "%d 个逻辑核心 · %@ GB 内存 · 3dsrecomp 自动全核并行（%d 个任务，受内存预算约束）"
        )
        dataRootLabel = t("Data folder", "数据目录")
        dataRootPortable = t("portable, beside the app", "便携模式，位于 App 旁")
        dataRootFallback = t("Application Support fallback", "回退到 Application Support")
        dataRootExplicit = t("custom location", "自定义位置")
        dataRootTemporary = t("temporary fallback", "临时目录回退")
        dataRootMigrationFormat = t("Adopted %d file(s) from the previous location", "已从旧位置迁移 %d 个文件")

        librarySubtitle = t("Your own games, one shell", "你自己的游戏，一个外壳")
        libraryCountFormat = t("%d game(s) in the library", "游戏库中有 %d 个游戏")
        libraryIPALabel = t("Library IPA", "游戏库 IPA")
        buildPackageImport = t("Import .32a", "导入 .32a")
        buildPackageExport = t("Export .32a", "导出 .32a")
        buildPackageReplace = t("Replace existing package", "覆盖现有包")
        buildPackageNeedsPack = t(
            "Build the GamePack first: only a real AOT pack can be exported.",
            "请先构建 GamePack：只有真实 AOT 包才能导出。"
        )
        buildPackageWithRom = t(
            "(includes game data; keep it local, never upload or commit it)",
            "（包含游戏数据——仅保留在本地，切勿上传或提交）"
        )
        buildPackageWithoutRom = t(
            "(no game data; deploying it needs the original ROM)",
            "（不含游戏数据——部署时需要原始 ROM）"
        )
        buildPackageExportedFormat = t("Exported %@  %@", "已导出 %@  %@")
        buildPackageImportedFormat = t("Imported %@ into %@", "已导入 %@ 到 %@")
        buildPackageExportFailedFormat = t("Export failed: %@", "导出失败：%@")
        buildPackageImportFailedFormat = t("Import failed: %@", "导入失败：%@")
        buildPackageConflictFormat = t(
            "A package for this game already exists. %@",
            "该游戏已存在构建包。%@"
        )
        exportIpa = t("Export IPA", "导出 IPA")
        ipaExportedFormat = t("Exported %@ (%@)  %@", "已导出 %@（%@）  %@")
        ipaExportFailedFormat = t("IPA export failed: %@", "IPA 导出失败：%@")
        ipaUnsignedHint = t(
            "Unsigned IPA with your own game data embedded: sign it with Sideloadly or AltStore, keep this file local and never upload or share it.",
            "未签名 IPA（已内嵌你自己的游戏数据）：安装前请用 Sideloadly 或 AltStore 自签名；文件仅保存在本地，切勿上传或外传。"
        )
        ipaNeedsRom = t(
            "The game's ROM is required: the single-game IPA embeds the game data. Re-import the ROM (or restore its file) and export again.",
            "需要该游戏的 ROM：单游戏 IPA 会内嵌游戏数据。请重新导入 ROM（或恢复原文件）后再导出。"
        )
        emptyLibraryTitle = t("Your library is empty", "游戏库还是空的")
        emptyLibraryMessage = t(
            "Import a decrypted .3ds/.cci file that you own. The Deploy tab compiles one native AOT pack per game and installs a single shell on the iPhone/iPad.",
            "导入你自己拥有的解密 .3ds/.cci 文件。在“导入手机”页里，启动器会为每个游戏编译原生 AOT 包，并在 iPhone/iPad 上安装一个统一的外壳。"
        )
        importGame = t("Import game", "导入游戏")
        importButton = t("Import", "导入")
        openLibrary = t("Go to Library", "去游戏库导入")
        addFirstGame = t("Import your first game", "导入第一个游戏")
        remove = t("Remove", "移除")
        removeConfirmTitle = t("Remove this game?", "移除这个游戏？")
        removeConfirmMessage = t(
            "The game is removed from the library. Files in out/ are local build data and can be rebuilt; nothing on the phone is deleted until you deploy again.",
            "游戏会从游戏库中移除。out/ 里的文件是本地构建数据，可以重新生成；手机上的内容要等你再次部署时才会变化。"
        )
        removeConfirmAction = t("Remove", "移除")
        romSizeLabel = t("ROM size", "ROM 大小")
        packSizeLabel = t("AOT pack", "AOT 包")
        dataStaged = t("Game data staged for push", "游戏数据已暂存待推送")
        noDataStaged = t("Game data not staged yet", "游戏数据尚未暂存")
        lastErrorLabel = t("Last error", "上次错误")
        phaseQueued = t("Queued", "已排队")
        phaseBuilding = t("Building", "构建中")
        phaseBuilt = t("AOT ready", "AOT 就绪")
        phaseOnDevice = t("On device", "已上设备")
        phaseFailed = t("Failed", "失败")
        inLibraryBadge = t("IN INSTALLED APP", "已在安装的 App 中")
        notInLibraryBadge = t("NOT INSTALLED", "未安装")
        howToPlayTitle = t("How to play", "如何游玩")
        howToPlayStep1 = t("Select the game here in Deploy and press the one-click deploy button.", "在“导入手机”页勾选游戏，按一键部署。")
        howToPlayStep2 = t("The launcher compiles the AOT packs, composes one ROM-free IPA and installs it with your own Apple ID.", "启动器会编译 AOT 包，组装一个无 ROM 的 IPA，并用你自己的 Apple ID 安装。")
        howToPlayStep3 = t("It then pushes only GameRom.cci + GameInfo.json into the shell's Documents folder.", "随后只把 GameRom.cci + GameInfo.json 推送到外壳的 Documents 目录。")
        howToPlayStep4 = t("Open the 3ds2apple app on the device and pick the game from its library.", "在设备上打开 3ds2apple App，在游戏库中选择该游戏。")

        importTitle = t("Import a game", "导入游戏")
        importSubtitle = t("Add your own decrypted .3ds / .cci files", "添加你自己拥有的解密 .3ds / .cci 文件")
        dropTitle = t("Import a game you own", "导入你拥有的游戏")
        dropMessage = t(
            "The launcher reads only the NCSD/NCCH header (a few KiB) to detect the title, then keeps a gitignored copy of your ROM for the device push. The ROM is never uploaded and never bundled into the signed app.",
            "启动器只读取 NCSD/NCCH 文件头（几 KiB）来识别游戏，然后在本地保留一份被 git 忽略的 ROM 副本用于推送。ROM 不会被上传，也不会被打进签名 App。"
        )
        dropHint = t("Drag a decrypted .3ds / .cci / .ncch / .cxi file here", "将解密的 .3ds / .cci / .ncch / .cxi 文件拖到这里")
        dropChoose = t("Choose ROM...", "选择 ROM...")
        dropUnsupported = t("That file type is not supported. Choose a decrypted 3DS ROM.", "不支持该文件类型，请选择解密的 3DS ROM。")
        detectedTitle = t("Detected game", "检测到的游戏")
        detectedBadge = t("HEADER ONLY", "仅文件头")
        fieldTitleID = t("Title ID", "Title ID")
        fieldProductCode = t("Product code", "产品代码")
        fieldContainer = t("Container", "容器")
        fieldROMSize = t("ROM size", "ROM 大小")
        fieldContentSize = t("Content size", "内容大小")
        addGame = t("Add to library", "添加到游戏库")
        clearSelection = t("Clear", "清除")
        unrecognisedTitle = t("That file was not recognised", "无法识别该文件")
        importStepsTitle = t("What happens next", "接下来会发生什么")
        step1Title = t("Import", "导入")
        step1Detail = t("Header only: title ID, product code, display name; a gitignored local ROM copy is kept for the push.", "只读文件头：Title ID、产品代码、显示名称；同时保留一份被 git 忽略的本地 ROM 副本用于推送。")
        step2Title = t("Deploy", "部署")
        step2Detail = t("Select one or several games on the Deploy tab and press one-click deploy.", "在“导入手机”页勾选一个或多个游戏，按一键部署。")
        step3Title = t("Install the library", "安装游戏库")
        step3Detail = t("A ROM-free IPA with your real GamePacks and a schema-2 GameCatalog is signed with your Apple ID and installed.", "包含真实 GamePack 和 schema-2 GameCatalog 的无 ROM IPA 会用你的 Apple ID 签名并安装。")
        step4Title = t("Push game data", "推送游戏数据")
        step4Detail = t("GameRom.cci + GameInfo.json go to Documents/Games/TITLEID, verified by size/sha.", "GameRom.cci + GameInfo.json 写入 Documents/Games/TITLEID，并校验大小与 sha。")
        importLogsTitle = t("Import log", "导入日志")

        deploySubtitle = t("Pick games, deploy them to the phone in one action", "勾选游戏，一键部署到手机")
        deploySelectionTitle = t("Deploy game selection", "选择要部署的游戏")
        deploySelectAll = t("Select all", "全选")
        deployClearSelection = t("Clear", "清空")
        deploySelectedFormat = t("%d selected", "已选择 %d 个")
        deployButtonFormat = t("Deploy %d game(s) to phone", "一键部署（%d 个游戏）")
        deployNoSelection = t("Select at least one game to deploy.", "请至少勾选一个游戏再部署。")
        deployNoGames = t("Your library is empty. Import a game first.", "游戏库还是空的，请先导入游戏。")
        advancedBuildTitle = t("Advanced build settings", "高级构建设置")
        advancedBuildBody = t(
            "Applied to the next build. The defaults keep the current behaviour; the same options are part of the Windows launcher's build cache key.",
            "应用于下一次构建。默认值保持现有行为；这些选项也是 Windows 启动器构建缓存 key 的一部分。"
        )
        advancedBuildOptLevel = t("Optimization level", "优化级别")
        advancedBuildLto = t("Link-time optimization (LTO)", "链接时优化（LTO）")
        advancedBuildFastMath = t("Fast-math (changes guest float results)", "fast-math（改变 guest 浮点结果）")
        advancedBuildSummaryFormat = t("Current: %@. Applied to the next build.", "当前：%@。应用于下一次构建。")
        advancedBuildReset = t("Reset to defaults", "恢复默认值")
        deployDeviceTitle = t("Target device", "目标设备")
        deployDeviceNone = t("No iPhone/iPad detected. Connect it, unlock it and tap Trust.", "未检测到 iPhone/iPad。请连接、解锁并点按信任。")
        deployDetectDevice = t("Detect device", "检测设备")
        deployStepsTitle = t("Deploy progress", "部署进度")
        deployStepCheckDevice = t("Check device & Apple ID", "检查设备与 Apple ID")
        deployStepCompileFormat = t("Compile GamePacks (%d)", "编译 GamePack（%d 个）")
        deployStepCompose = t("Compose one ROM-free IPA", "组装无 ROM IPA")
        deployStepVerifyIPA = t("Verify IPA (packs + GameCatalog)", "校验 IPA（包 + GameCatalog）")
        deployStepInstall = t("Sign & install", "签名并安装")
        deployStepPush = t("Push game data", "推送游戏数据")
        deployStepDone = t("Done", "完成")
        deployRunningForFormat = t("Deploying %d game(s)...", "正在部署 %d 个游戏...")
        deployDoneTitle = t("Ready to play", "可以开始游玩")
        deployDoneMessage = t("可以打开手机 App 游玩", "可以打开手机 App 游玩")
        deployFailedTitle = t("Deploy failed", "部署失败")
        deployRetry = t("Retry deploy", "重试部署")
        deployLogTitle = t("Deploy log", "部署日志")
        deployNoteROMFree = t(
            "Only AOT code goes into the signed app: the IPA is verified to contain the real GamePacks and a schema-2 GameCatalog, and no ROM/game data.",
            "签名 App 里只有 AOT 代码：IPA 会校验包含真实 GamePack 和 schema-2 GameCatalog，且不包含任何 ROM/游戏数据。"
        )
        deployInstalledBundle = t("Installed app", "已安装 App")
        deployNotInstalledBundle = t("Not installed yet", "尚未安装")
        deployEligible = t("Ready to deploy", "可部署")
        deployNeedsBuild = t("Will be compiled during deploy", "部署时会自动编译")
        deployPushedFormat = t("%d game(s) pushed", "已推送 %d 个游戏")
        deployIPAVerifiedFormat = t("%d pack(s), schema-2 catalogue, no ROM", "%d 个包，schema-2 目录，无 ROM")
        deployCompileProgressFormat = t("Compiling %d/%d", "正在编译 %d/%d")
        deployInstallProgressFormat = t("Installing... %@", "正在安装... %@")

        settingsSubtitle = t("Language, Apple ID signing, device, logs and about", "语言、Apple ID 签名、设备、日志与关于")
        languageTitle = t("Language", "语言")
        languageHint = t(
            "Follows the macOS UI language by default: Simplified Chinese uses the Chinese interface, every other language uses English.",
            "默认跟随 macOS 系统语言：简体中文使用中文界面，其他语言使用英文。"
        )
        languageSystem = t("System", "跟随系统")
        languageEnglish = t("English", "English")
        languageChinese = t("简体中文", "简体中文")
        languageAppliesHint = t("The interface switches immediately.", "界面会立即切换。")
        languageDetectedFormat = t("System language: %@", "系统语言：%@")
        signingTitle = t("Apple ID & Xcode signing", "Apple ID 与 Xcode 签名")
        signingStatusReady = t("Signing ready", "签名已就绪")
        signingStatusMissing = t("Sign in to Xcode", "请登录 Xcode")
        signingXcodeFormat = t("Xcode %@", "Xcode %@")
        signingAssetsFormat = t("%d certificate(s) / %d profile(s)", "%d 个证书 / %d 个描述文件")
        signingTeamFormat = t("Detected Team ID: %@", "检测到的 Team ID：%@")
        signingTeamMissing = t("No Team ID detected yet", "尚未检测到 Team ID")
        signingOpenXcode = t("Open Xcode Accounts...", "打开 Xcode 账户设置...")
        signingExplanation = t(
            "The launcher never asks for your Apple ID or password. Sign in once in Xcode > Settings > Accounts; the launcher detects the Team ID and Xcode manages the certificate and profile.",
            "启动器不会索取你的 Apple ID 或密码。只需在 Xcode > 设置 > 账户中登录一次；启动器会自动检测 Team ID，证书与描述文件由 Xcode 管理。"
        )
        signingRefresh = t("Check again", "重新检查")
        deviceTitle = t("Device", "设备")
        deviceNone = t("No device detected. Connect the iPhone/iPad, unlock it and tap Trust.", "未检测到设备。请连接 iPhone/iPad，解锁并点按信任。")
        deviceRefresh = t("Detect again", "重新检测")
        deviceBundleID = t("Installed app ID", "已安装 App ID")
        deviceBundleIDNone = t("No app installed yet", "尚未安装 App")
        logsTitle = t("Logs", "日志")
        logsNoLines = t("No log lines yet.", "暂无日志。")
        logsExport = t("Export log", "导出日志")
        logsClear = t("Clear log", "清空日志")
        logsExportedFormat = t("Exported to %@", "已导出到 %@")
        logsRawNote = t("Logs are raw engineering output and are not translated.", "日志是原始工程输出，不做翻译。")
        aboutTitle = t("About", "关于")
        aboutBodyFormat = t(
            "3ds2apple macOS launcher %@ - Apache-2.0. The launcher orchestrates the local AOT build, Xcode signing and the device bridge. It never bundles Impactor, ROMs or game data.",
            "3ds2apple macOS 启动器 %@ - Apache-2.0。启动器负责调度本机 AOT 构建、Xcode 签名与设备桥。它不捆绑 Impactor、ROM 或游戏数据。"
        )
        aboutLicense = t("License: Apache-2.0. No ROMs, keys or game data are included.", "许可证：Apache-2.0。不包含 ROM、密钥或游戏数据。")
        aboutIconCaption = t("Same icon as the iPhone/iPad shell app", "与 iPhone/iPad 外壳 App 使用同一图标")
        aboutVersionFormat = t("Version %@ (%@)", "版本 %@ (%@)")
        diagnosticsChecksFormat = t("%d/%d checks passed", "%d/%d 项检查通过")
        diagnosticsToolchainTitle = t("Toolchain", "工具链")

        taskQueued = t("Queued", "排队中")
        taskRunning = t("Running", "进行中")
        taskSucceeded = t("Succeeded", "成功")
        taskFailed = t("Failed", "失败")
        taskCancelled = t("Cancelled", "已取消")
    }

    // MARK: - Formatting helpers

    func gamesCount(_ count: Int) -> String {
        String(format: libraryCountFormat, count)
    }

    func deploySelected(_ count: Int) -> String {
        String(format: deploySelectedFormat, count)
    }

    func deployButton(_ count: Int) -> String {
        String(format: deployButtonFormat, count)
    }

    func deployCompileStep(_ count: Int) -> String {
        String(format: deployStepCompileFormat, count)
    }

    func deployRunningFor(_ count: Int) -> String {
        String(format: deployRunningForFormat, count)
    }

    func deployPushed(_ count: Int) -> String {
        String(format: deployPushedFormat, count)
    }

    func deployIPAVerified(_ packs: Int) -> String {
        String(format: deployIPAVerifiedFormat, packs)
    }

    func deployCompileProgress(_ done: Int, _ total: Int) -> String {
        String(format: deployCompileProgressFormat, done, total)
    }

    func deployInstallProgress(_ line: String) -> String {
        String(format: deployInstallProgressFormat, line)
    }

    func signingAssets(_ certificates: Int, _ profiles: Int) -> String {
        String(format: signingAssetsFormat, certificates, profiles)
    }

    func signingTeam(_ team: String) -> String {
        String(format: signingTeamFormat, team)
    }

    func signingXcode(_ version: String) -> String {
        String(format: signingXcodeFormat, version)
    }

    func languageDetected(_ label: String) -> String {
        String(format: languageDetectedFormat, label)
    }

    func logsExported(_ path: String) -> String {
        String(format: logsExportedFormat, path)
    }

    func aboutBody(_ version: String) -> String {
        String(format: aboutBodyFormat, version)
    }

    func aboutVersion(_ version: String, _ build: String) -> String {
        String(format: aboutVersionFormat, version, build)
    }

    func diagnosticsChecks(_ ok: Int, _ total: Int) -> String {
        String(format: diagnosticsChecksFormat, ok, total)
    }

    /// "Publisher: Nintendo" line on a Library card.
    func publisher(_ value: String) -> String {
        String(format: publisherFormat, value)
    }

    // MARK: - Portable .32a build packages

    func buildPackageExported(_ path: String, _ rom: String) -> String {
        String(format: buildPackageExportedFormat, path, rom)
    }

    func buildPackageImported(_ name: String, _ packageDir: String) -> String {
        String(format: buildPackageImportedFormat, name, packageDir)
    }

    func buildPackageExportFailed(_ message: String) -> String {
        String(format: buildPackageExportFailedFormat, message)
    }

    func buildPackageImportFailed(_ message: String) -> String {
        String(format: buildPackageImportFailedFormat, message)
    }

    func buildPackageConflict(_ message: String) -> String {
        String(format: buildPackageConflictFormat, message)
    }

    func ipaExported(_ path: String, _ size: String, _ hint: String) -> String {
        String(format: ipaExportedFormat, path, size, hint)
    }

    func ipaExportFailed(_ message: String) -> String {
        String(format: ipaExportFailedFormat, message)
    }

    func advancedBuildSummary(_ describe: String) -> String {
        String(format: advancedBuildSummaryFormat, describe)
    }

    /// Compile hardware line: cores + RAM + 3dsrecomp's automatic parallelism.
    func hardwareLine(_ profile: HardwareProfile) -> String {
        String(format: hardwareLineFormat, profile.logicalCores, profile.totalMemoryGBText, profile.compileJobs)
    }

    /// Detail shown on the compile step while the batch build runs.
    func deployCompileHardware(_ profile: HardwareProfile) -> String {
        hardwareLine(profile)
    }

    /// Localized description of the resolved portable data-root kind.
    func dataRootKind(_ kind: DataRootKind) -> String {
        switch kind {
        case .portable: return dataRootPortable
        case .applicationSupport: return dataRootFallback
        case .explicit: return dataRootExplicit
        case .tempFallback: return dataRootTemporary
        }
    }

    func dataRootMigration(_ files: Int) -> String {
        String(format: dataRootMigrationFormat, files)
    }

    // MARK: - Enum labels

    func phase(_ phase: GamePhase) -> String {
        switch phase {
        case .queued: return phaseQueued
        case .building: return phaseBuilding
        case .built: return phaseBuilt
        case .pushed: return phaseOnDevice
        case .failed: return phaseFailed
        }
    }

    func taskState(_ state: TaskState) -> String {
        switch state {
        case .queued: return taskQueued
        case .running: return taskRunning
        case .succeeded: return taskSucceeded
        case .failed: return taskFailed
        case .cancelled: return taskCancelled
        }
    }

    /// Language picker row title.
    func languageTitle(_ language: LauncherLanguage) -> String {
        switch language {
        case .system: return languageSystem
        case .english: return languageEnglish
        case .chinese: return languageChinese
        }
    }

    /// Language picker row detail.
    func languageDetail(_ language: LauncherLanguage) -> String {
        switch language {
        case .system:
            return self.language == .chinese
                ? "使用 macOS 系统语言（当前解析为中文）"
                : "Use the macOS system language (currently English)"
        case .english:
            return self.language == .chinese ? "始终使用英文界面" : "Always use the English interface"
        case .chinese:
            return self.language == .chinese ? "始终使用简体中文界面" : "Always use the Simplified Chinese interface"
        }
    }

    // MARK: - Self-check helper

    /// All localized String fields (used by the headless self-check to prove both
    /// tables are complete). Enum fields such as language are skipped.
    func localizedStringFields() -> [(String, String)] {
        var fields: [(String, String)] = []
        for child in Mirror(reflecting: self).children {
            guard let label = child.label, let value = child.value as? String else { continue }
            fields.append((label, value))
        }
        return fields
    }
}
