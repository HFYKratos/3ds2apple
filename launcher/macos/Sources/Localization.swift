//
//  Localization.swift
//  3ds2apple macOS launcher
//
//  Two languages, chosen from the macOS system UI language (Simplified Chinese
//  -> zh-Hans, everything else -> English) with a Settings override.
//
//  All visible UI strings live here so the views never contain user-facing
//  literals and the headless self-check can verify both tables. Pipeline text
//  (logs, stage details, Apple signing errors) is produced by the backends and
//  stays in its raw form by design; it is diagnostic output, not chrome.
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
    /// Force English.
    case english
    /// Force Simplified Chinese.
    case chinese

    var id: String { rawValue }

    /// Map the macOS preferred-language list to one of the two UI languages.
    /// Simplified Chinese variants win; every other language falls back to
    /// English, matching docs/launcher-ui.md.
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
    var navImport: String
    var settings: String
    var close: String
    var done: String
    var cancel: String
    var refresh: String
    var export: String
    var clear: String
    var choose: String
    var detect: String
    var versionLabel: String
    var modeLive: String
    var modeMock: String
    var busyWorking: String
    var busyCancelling: String

    // Library
    var librarySubtitle: String
    var gamesCountFormat: String
    var emptyLibraryTitle: String
    var emptyLibraryMessage: String
    var importFirstGame: String
    var buildInstallLibrary: String
    var rebuildInstallLibrary: String
    var refreshPackages: String
    var verifyPackages: String
    var noDevice: String
    var deviceSelectedFormat: String
    var libraryStatusTitle: String
    var installedGamesFormat: String
    var libraryIPALabel: String
    var libraryNotInstalled: String
    var libraryUpToDate: String
    var libraryNeedsRebuild: String
    var libraryNoGamesBuilt: String
    var romDataNote: String
    var primaryBuild: String
    var primaryInstall: String
    var primaryPush: String
    var primaryHowToPlay: String
    var primaryBuilding: String
    var secondaryDetails: String
    var secondaryVerify: String
    var secondaryBuildAgain: String
    var secondaryPushAgain: String
    var secondaryRefreshPackages: String
    var secondarySettings: String
    var phaseQueued: String
    var phaseBuilding: String
    var phaseBuilt: String
    var phaseOnDevice: String
    var phaseFailed: String
    var inLibraryBadge: String
    var notInLibraryBadge: String
    var stagedDataLine: String
    var lastError: String
    var howToPlayTitle: String
    var howToPlayStep1: String
    var howToPlayStep2: String
    var howToPlayStep3: String
    var howToPlayStep4: String

    // Import
    var importSubtitle: String
    var dropTitle: String
    var dropMessage: String
    var dropHint: String
    var dropChoose: String
    var dropUnsupported: String
    var detectedTitle: String
    var detectedBadge: String
    var fieldTitleID: String
    var fieldDisplayName: String
    var fieldProductCode: String
    var fieldContainer: String
    var fieldROMSize: String
    var fieldContentSize: String
    var queueGame: String
    var clearSelection: String
    var noSelection: String
    var stepsTitle: String
    var step1Title: String
    var step1Detail: String
    var step2Title: String
    var step2Detail: String
    var step3Title: String
    var step3Detail: String
    var step4Title: String
    var step4Detail: String
    var unrecognisedTitle: String
    var importLogsTitle: String

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
    var signingTeamID: String
    var signingTeamIDPlaceholder: String
    var signingExplanation: String
    var deviceTitle: String
    var deviceNone: String
    var deviceRefresh: String
    var deviceBundleID: String
    var deviceRemoteRoot: String
    var deviceRemoteRootValue: String
    var buildModeTitle: String
    var modeDryTitle: String
    var modeDryDetail: String
    var modeFakeTitle: String
    var modeFakeDetail: String
    var modeRealTitle: String
    var modeRealDetail: String
    var installStrategyTitle: String
    var strategyXcodeTitle: String
    var strategyXcodeDetail: String
    var strategyDeviceTitle: String
    var strategyDeviceDetail: String
    var strategyImpactorTitle: String
    var strategyImpactorDetail: String
    var strategyMockTitle: String
    var strategyMockDetail: String
    var toolsTitle: String
    var toolsRepoRoot: String
    var toolsOutDir: String
    var toolsPackCLI: String
    var toolsDevpush: String
    var toolsDeviceCLI: String
    var toolsAutoDetected: String
    var toolsMockBackend: String
    var toolsNotBuilt: String
    var toolsNotSet: String
    var toolsNotStaged: String
    var toolsBundleID: String
    var toolsLibraryIPA: String
    var toolsInstalledTitles: String
    var diagnosticsTitle: String
    var diagnosticsChecksFormat: String
    var diagnosticsXcode: String
    var diagnosticsSigningAssetsFormat: String
    var diagnosticsDevpush: String
    var diagnosticsRefresh: String
    var diagnosticsToolchainTitle: String
    var diagnosticsNotesTitle: String
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

    // Game detail dialog
    var gameDetailTitle: String
    var gamePackageTitle: String
    var fieldStatus: String
    var fieldROM: String
    var fieldSaveNamespace: String
    var fieldBuildName: String
    var fieldPackPath: String
    var fieldPackSize: String
    var fieldPackSha: String
    var fieldInLibrary: String
    var fieldPackInLibraryYes: String
    var fieldPackInLibraryNo: String
    var fieldGameDataSource: String
    var fieldPushedAt: String
    var pushPlanTitle: String
    var pushPlanSubtitle: String
    var pushPlanNoPlan: String
    var pushPlanFilesFormat: String
    var pushPrepare: String
    var pushToDevice: String
    var pushVerify: String
    var pushVerified: String
    var activityTitle: String
    var noActivity: String

    // MARK: - Initializer

    init(language: ResolvedLanguage) {
        self.language = language
        let zh = language == .chinese
        func t(_ en: String, _ cn: String) -> String { zh ? cn : en }

        appTagline = t("macOS launcher", "macOS 启动器")
        navLibrary = t("Library", "游戏库")
        navImport = t("Import", "导入")
        settings = t("Settings", "设置")
        close = t("Close", "关闭")
        done = t("Done", "完成")
        cancel = t("Cancel", "取消")
        refresh = t("Refresh", "刷新")
        export = t("Export", "导出")
        clear = t("Clear", "清除")
        choose = t("Choose", "选择")
        detect = t("Detect", "检测")
        versionLabel = t("Version", "版本")
        modeLive = t("LIVE", "实机")
        modeMock = t("MOCK / DRY RUN", "模拟 / 试运行")
        busyWorking = t("Working...", "正在处理...")
        busyCancelling = t("Cancelling...", "正在取消...")

        librarySubtitle = t("One shell, many per-game AOT packs", "一个外壳，承载多个游戏的 AOT 包")
        gamesCountFormat = t("%d game(s) in the library", "游戏库中有 %d 个游戏")
        emptyLibraryTitle = t("Your library is empty", "游戏库还是空的")
        emptyLibraryMessage = t(
            "Import a decrypted .3ds/.cci file that you own. The launcher builds one native AOT pack per game and installs a single shell on the iPhone/iPad.",
            "导入你自己拥有的解密 .3ds/.cci 文件。启动器会为每个游戏编译原生 AOT 包，并在 iPhone/iPad 上安装一个统一的外壳。"
        )
        importFirstGame = t("Import a game", "导入游戏")
        buildInstallLibrary = t("Build & install library", "构建并安装游戏库")
        rebuildInstallLibrary = t("Rebuild & install library", "重新构建并安装游戏库")
        refreshPackages = t("Refresh", "刷新")
        verifyPackages = t("Verify", "校验")
        noDevice = t("No device connected", "未连接设备")
        deviceSelectedFormat = t("%@ connected", "%@ 已连接")
        libraryStatusTitle = t("On-device library", "设备上的游戏库")
        installedGamesFormat = t("%d game(s) in the signed app", "已签名 App 中包含 %d 个游戏")
        libraryIPALabel = t("Library IPA", "游戏库 IPA")
        libraryNotInstalled = t("No library installed yet", "尚未安装游戏库")
        libraryUpToDate = t("The installed library matches your built games.", "已安装的游戏库与已构建的游戏一致。")
        libraryNeedsRebuild = t(
            "The installed library does not match the built games. Rebuild and reinstall it; ROM data already pushed to Documents is kept.",
            "已安装的游戏库与已构建的游戏不一致。请重新构建并安装；已推送到 Documents 的游戏数据会保留。"
        )
        libraryNoGamesBuilt = t(
            "Build at least one AOT pack before installing the library.",
            "请先构建至少一个 AOT 包，然后再安装游戏库。"
        )
        romDataNote = t(
            "Game data stays in Documents/Games and survives reinstalls.",
            "游戏数据保存在 Documents/Games，重装 App 后仍然保留。"
        )
        primaryBuild = t("Build AOT", "构建 AOT")
        primaryInstall = t("Install library", "安装游戏库")
        primaryPush = t("Push game data", "推送游戏数据")
        primaryHowToPlay = t("How to play", "如何游玩")
        primaryBuilding = t("Building...", "正在构建...")
        secondaryDetails = t("Package details", "包详情")
        secondaryVerify = t("Verify on device", "在设备上校验")
        secondaryBuildAgain = t("Build again", "重新构建")
        secondaryPushAgain = t("Push again", "重新推送")
        secondaryRefreshPackages = t("Refresh packages", "刷新包列表")
        secondarySettings = t("Open settings", "打开设置")
        phaseQueued = t("Queued", "已排队")
        phaseBuilding = t("Building", "构建中")
        phaseBuilt = t("AOT ready", "AOT 就绪")
        phaseOnDevice = t("On device", "已上设备")
        phaseFailed = t("Failed", "失败")
        inLibraryBadge = t("IN LIBRARY", "已在库中")
        notInLibraryBadge = t("NOT IN LIBRARY", "不在库中")
        stagedDataLine = t("Game data staged", "游戏数据已暂存")
        lastError = t("Last error", "上次错误")
        howToPlayTitle = t("How to play", "如何游玩")
        howToPlayStep1 = t("The signed shell app with your AOT packs is installed on the device.", "已签名外壳 App（含你的 AOT 包）已安装到设备。")
        howToPlayStep2 = t("Game data (ROM + GameInfo.json) has been pushed into the app Documents folder.", "游戏数据（ROM + GameInfo.json）已推送到 App 的 Documents 目录。")
        howToPlayStep3 = t("Open the 3ds2apple app on the device and pick this game from its library.", "在设备上打开 3ds2apple App，在游戏库中选择该游戏。")
        howToPlayStep4 = t("No ROM or game data is stored inside the launcher or the public IPA.", "启动器和公开 IPA 内不包含任何 ROM 或游戏数据。")

        importSubtitle = t("Add your own decrypted .3ds / .cci files", "添加你自己拥有的解密 .3ds / .cci 文件")
        dropTitle = t("Import a game you own", "导入你拥有的游戏")
        dropMessage = t(
            "The launcher reads only the NCSD/NCCH header (a few KiB) to detect the title, then queues one AOT package. Your ROM is never uploaded, and it is not bundled into the shell IPA.",
            "启动器只读取 NCSD/NCCH 文件头（几 KiB）来识别游戏，然后排队一个 AOT 包。ROM 不会被上传，也不会被打包进外壳 IPA。"
        )
        dropHint = t("Drag a decrypted .3ds / .cci / .ncch / .cxi file here", "将解密的 .3ds / .cci / .ncch / .cxi 文件拖到这里")
        dropChoose = t("Choose ROM...", "选择 ROM...")
        dropUnsupported = t("That file type is not supported. Choose a decrypted 3DS ROM.", "不支持该文件类型，请选择解密的 3DS ROM。")
        detectedTitle = t("Detected game", "检测到的游戏")
        detectedBadge = t("HEADER ONLY", "仅文件头")
        fieldTitleID = t("Title ID", "Title ID")
        fieldDisplayName = t("Display name", "显示名称")
        fieldProductCode = t("Product code", "产品代码")
        fieldContainer = t("Container", "容器")
        fieldROMSize = t("ROM size", "ROM 大小")
        fieldContentSize = t("Content size", "内容大小")
        queueGame = t("Queue this game", "添加这个游戏")
        clearSelection = t("Clear", "清除")
        noSelection = t("No game selected yet", "尚未选择游戏")
        stepsTitle = t("What happens next", "接下来会发生什么")
        step1Title = t("Detect", "识别")
        step1Detail = t("Header only: title ID, product code, display name.", "只读文件头：Title ID、产品代码、显示名称。")
        step2Title = t("Build", "构建")
        step2Detail = t("3dsrecomp translates the game; clang builds one GamePack.dylib for arm64.", "3dsrecomp 翻译游戏代码，clang 为 arm64 构建一个 GamePack.dylib。")
        step3Title = t("Install the library", "安装游戏库")
        step3Detail = t("A ROM-free IPA with your GamePacks inside is signed with your own Apple ID and installed with devicectl.", "包含 GamePack 的无 ROM IPA 会用你自己的 Apple ID 签名，并通过 devicectl 安装。")
        step4Title = t("Push game data", "推送游戏数据")
        step4Detail = t("GameRom.cci + GameInfo.json go to Documents/Games/TITLEID; the AOT code is already in the signed app.", "GameRom.cci + GameInfo.json 会写入 Documents/Games/TITLEID；AOT 代码已在签名 App 内。")
        unrecognisedTitle = t("That file was not recognised", "无法识别该文件")
        importLogsTitle = t("Import log", "导入日志")

        settingsSubtitle = t("Language, signing, device, tools and logs", "语言、签名、设备、工具与日志")
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
        signingTitle = t("Apple ID & Team ID", "Apple ID 与 Team ID")
        signingTeamID = t("Team ID", "Team ID")
        signingTeamIDPlaceholder = t("ABCDE12345", "ABCDE12345")
        signingExplanation = t(
            "The launcher never asks for your Apple ID or password. Sign in once in Xcode > Settings > Accounts; Xcode manages the certificate and profile for your team.",
            "启动器不会索取你的 Apple ID 或密码。只需在 Xcode > 设置 > 账户中登录一次，Xcode 会为你的团队管理证书与描述文件。"
        )
        deviceTitle = t("Device", "设备")
        deviceNone = t("No device detected. Connect the iPhone/iPad, unlock it and tap Trust.", "未检测到设备。请连接 iPhone/iPad，解锁并点按信任。")
        deviceRefresh = t("Detect again", "重新检测")
        deviceBundleID = t("Bundle ID", "Bundle ID")
        deviceRemoteRoot = t("Remote folder", "远程目录")
        deviceRemoteRootValue = t("Documents/Games/<TITLEID>/", "Documents/Games/<TITLEID>/")
        buildModeTitle = t("Build mode", "构建模式")
        modeDryTitle = t("Dry run", "试运行")
        modeDryDetail = t("Prints the exact commands; compiles and writes nothing.", "只打印实际命令，不编译、不写入。")
        modeFakeTitle = t("Fake preview pack", "模拟预览包")
        modeFakeDetail = t("Writes labelled placeholder packs for UI and layout tests; not installable.", "写入带标记的占位包，用于界面与布局测试，不可安装。")
        modeRealTitle = t("Real AOT build", "真实 AOT 构建")
        modeRealDetail = t("Runs 3dsrecomp and the Xcode pack link on this Mac (slow).", "在本机运行 3dsrecomp 与 Xcode 打包链接（较慢）。")
        installStrategyTitle = t("Sign & install", "签名与安装")
        strategyXcodeTitle = t("Xcode build + devicectl", "Xcode 构建 + devicectl")
        strategyXcodeDetail = t("Signs the ROM-free shell with your Apple ID in Xcode and installs it with devicectl.", "在 Xcode 中用你的 Apple ID 签名无 ROM 外壳，并用 devicectl 安装。")
        strategyDeviceTitle = t("device_cli wrapper", "device_cli 封装")
        strategyDeviceDetail = t("Uses builder/device/device_cli.py when the device-bridge task publishes it.", "在设备桥任务发布后使用 builder/device/device_cli.py。")
        strategyImpactorTitle = t("Official Impactor (manual)", "官方 Impactor（手动）")
        strategyImpactorDetail = t("Builds the unsigned IPA and opens it in the official Impactor; sign in and install there.", "构建未签名 IPA 并在官方 Impactor 中打开，登录后手动安装。")
        strategyMockTitle = t("Mock (dry run)", "模拟（试运行）")
        strategyMockDetail = t("Simulates readiness, build and install without touching a device.", "模拟就绪检查、构建和安装，不接触真机。")
        toolsTitle = t("Tools & paths", "工具与路径")
        toolsRepoRoot = t("Checkout", "代码目录")
        toolsOutDir = t("Output", "输出目录")
        toolsPackCLI = t("Pack CLI", "打包 CLI")
        toolsDevpush = t("devpush", "devpush")
        toolsDeviceCLI = t("device_cli", "device_cli")
        toolsAutoDetected = t("auto-detected", "自动检测")
        toolsMockBackend = t("mock backend", "模拟后端")
        toolsNotBuilt = t("not built", "未构建")
        toolsNotSet = t("not set", "未设置")
        toolsNotStaged = t("not staged", "未暂存")
        toolsBundleID = t("Bundle ID", "Bundle ID")
        toolsLibraryIPA = t("Library IPA", "游戏库 IPA")
        toolsInstalledTitles = t("Installed games", "已安装游戏")
        diagnosticsTitle = t("Diagnostics", "诊断")
        diagnosticsChecksFormat = t("%d/%d checks passed", "%d/%d 项检查通过")
        diagnosticsXcode = t("Xcode", "Xcode")
        diagnosticsSigningAssetsFormat = t("%d certificate(s) / %d profile(s)", "%d 个证书 / %d 个描述文件")
        diagnosticsDevpush = t("Device bridge", "设备桥")
        diagnosticsRefresh = t("Re-check environment", "重新检查环境")
        diagnosticsToolchainTitle = t("Toolchain", "工具链")
        diagnosticsNotesTitle = t("Notes", "说明")
        logsTitle = t("Logs", "日志")
        logsNoLines = t("No log lines yet.", "暂无日志。")
        logsExport = t("Export log", "导出日志")
        logsClear = t("Clear log", "清空日志")
        logsExportedFormat = t("Exported to %@", "已导出到 %@")
        logsRawNote = t("Logs are raw engineering output and are not translated.", "日志是原始工程输出，不做翻译。")
        aboutTitle = t("About", "关于")
        aboutBodyFormat = t(
            "3ds2apple macOS launcher %@ - Apache-2.0. The launcher orchestrates the desktop AOT build, Xcode signing and the device bridge. It never bundles Impactor, ROMs or game data.",
            "3ds2apple macOS 启动器 %@ - Apache-2.0。启动器负责调度桌面端 AOT 构建、Xcode 签名与设备桥。它不捆绑 Impactor、ROM 或游戏数据。"
        )
        aboutLicense = t("License: Apache-2.0. No ROMs, keys or game data are included.", "许可证：Apache-2.0。不包含 ROM、密钥或游戏数据。")
        aboutIconCaption = t("Same icon as the iPhone/iPad shell app", "与 iPhone/iPad 外壳 App 使用同一图标")
        aboutVersionFormat = t("Version %@ (%@)", "版本 %@ (%@)")

        gameDetailTitle = t("Game package", "游戏包")
        gamePackageTitle = t("Package details", "包详情")
        fieldStatus = t("Status", "状态")
        fieldROM = t("ROM file", "ROM 文件")
        fieldSaveNamespace = t("Save namespace", "存档命名空间")
        fieldBuildName = t("Build name", "构建名称")
        fieldPackPath = t("GamePack", "GamePack")
        fieldPackSize = t("GamePack size", "GamePack 大小")
        fieldPackSha = t("GamePack SHA-256", "GamePack SHA-256")
        fieldInLibrary = t("In installed library", "已在安装的游戏库中")
        fieldPackInLibraryYes = t("yes (signed IPA)", "是（已签名 IPA）")
        fieldPackInLibraryNo = t("no - build & install the library", "否 - 请构建并安装游戏库")
        fieldGameDataSource = t("Game data (push source)", "游戏数据（推送源）")
        fieldPushedAt = t("Pushed", "推送时间")
        pushPlanTitle = t("Documents push plan", "Documents 推送计划")
        pushPlanSubtitle = t("GamePacks stay in the signed IPA; only game data is pushed", "GamePack 保留在签名 IPA 中，只推送游戏数据")
        pushPlanNoPlan = t("Prepare the push plan to see the files.", "准备推送计划后可查看文件列表。")
        pushPlanFilesFormat = t("%d file(s) - %@", "%d 个文件 - %@")
        pushPrepare = t("Prepare", "准备")
        pushToDevice = t("Push to device", "推送到设备")
        pushVerify = t("Verify", "校验")
        pushVerified = t("Verified on device", "已在设备上校验")
        activityTitle = t("Current activity", "当前活动")
        noActivity = t("No task is running.", "当前没有运行中的任务。")

        // No further initializer work.
    }

    // MARK: - Formatting helpers

    func gamesCount(_ count: Int) -> String {
        String(format: gamesCountFormat, count)
    }

    func installedGames(_ count: Int) -> String {
        String(format: installedGamesFormat, count)
    }

    func diagnosticsChecks(_ ok: Int, _ total: Int) -> String {
        String(format: diagnosticsChecksFormat, ok, total)
    }

    func signingAssets(_ certificates: Int, _ profiles: Int) -> String {
        String(format: diagnosticsSigningAssetsFormat, certificates, profiles)
    }

    func pushPlanFiles(_ count: Int, _ bytes: String) -> String {
        String(format: pushPlanFilesFormat, count, bytes)
    }

    func deviceSelected(_ name: String) -> String {
        String(format: deviceSelectedFormat, name)
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
        case .queued: return phaseQueued
        case .running: return primaryBuilding
        case .succeeded: return language == .chinese ? "成功" : "Succeeded"
        case .failed: return phaseFailed
        case .cancelled: return language == .chinese ? "已取消" : "Cancelled"
        }
    }

    func buildModeTitle(_ mode: BuildMode) -> String {
        switch mode {
        case .dryRun: return modeDryTitle
        case .fake: return modeFakeTitle
        case .real: return modeRealTitle
        }
    }

    func buildModeDetail(_ mode: BuildMode) -> String {
        switch mode {
        case .dryRun: return modeDryDetail
        case .fake: return modeFakeDetail
        case .real: return modeRealDetail
        }
    }

    func installStrategyTitle(_ strategy: InstallStrategy) -> String {
        switch strategy {
        case .xcodebuild: return strategyXcodeTitle
        case .deviceCLI: return strategyDeviceTitle
        case .impactor: return strategyImpactorTitle
        case .mock: return strategyMockTitle
        }
    }

    func installStrategyDetail(_ strategy: InstallStrategy) -> String {
        switch strategy {
        case .xcodebuild: return strategyXcodeDetail
        case .deviceCLI: return strategyDeviceDetail
        case .impactor: return strategyImpactorDetail
        case .mock: return strategyMockDetail
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
