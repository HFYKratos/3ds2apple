using System.Globalization;

namespace ThreeDsTwoApple.Launcher.Core.Localization;

/// <summary>UI language preference persisted in the launcher state.</summary>
public enum UiLanguagePreference
{
    /// <summary>Follow the Windows UI language (zh-Hans for Simplified Chinese, English otherwise).</summary>
    System = 0,
    English = 1,
    SimplifiedChinese = 2,
}

/// <summary>English and Simplified Chinese UI strings for the launcher.</summary>
public static class LanguageCatalog
{
    public const string EnglishTag = "en";
    public const string ChineseSimplifiedTag = "zh-Hans";
    public const string SystemKey = "system";
    public const string EnglishKey = "en";
    public const string ChineseSimplifiedKey = "zh-Hans";

    public static IReadOnlyList<UiLanguagePreference> AllPreferences { get; } = new[]
    {
        UiLanguagePreference.System,
        UiLanguagePreference.English,
        UiLanguagePreference.SimplifiedChinese,
    };

    /// <summary>Key used in the persisted state file; never a display name.</summary>
    public static string PreferenceKey(UiLanguagePreference preference) => preference switch
    {
        UiLanguagePreference.English => EnglishKey,
        UiLanguagePreference.SimplifiedChinese => ChineseSimplifiedKey,
        _ => SystemKey,
    };

    /// <summary>Parse a persisted preference; unknown values fall back to System.</summary>
    public static UiLanguagePreference ParsePreference(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return UiLanguagePreference.System;
        }
        var normalized = value.Trim().ToLowerInvariant().Replace("_", "-");
        return normalized switch
        {
            "en" or "english" or "en-us" or "en-gb" => UiLanguagePreference.English,
            "zh" or "zh-hans" or "zh-cn" or "zh-sg" or "chinese" or "simplifiedchinese" or "简体中文" or "中文" => UiLanguagePreference.SimplifiedChinese,
            _ => UiLanguagePreference.System,
        };
    }

    /// <summary>English or zh-Hans tag for a culture name (null/blank -> English).</summary>
    public static string Detect(string? cultureName)
    {
        if (string.IsNullOrWhiteSpace(cultureName))
        {
            return EnglishTag;
        }
        var normalized = cultureName.Trim().ToLowerInvariant().Replace("_", "-");
        if (!normalized.StartsWith("zh", StringComparison.Ordinal))
        {
            return EnglishTag;
        }
        if (normalized.Contains("hant", StringComparison.Ordinal)
            || normalized.Contains("-tw", StringComparison.Ordinal)
            || normalized.Contains("-hk", StringComparison.Ordinal)
            || normalized.Contains("-mo", StringComparison.Ordinal))
        {
            // Traditional Chinese is not translated; the documented fallback is English.
            return EnglishTag;
        }
        return ChineseSimplifiedTag;
    }

    /// <summary>Resolve the active language tag from the preference and the OS UI culture name.</summary>
    public static string Resolve(UiLanguagePreference preference, string? osCultureName) => preference switch
    {
        UiLanguagePreference.English => EnglishTag,
        UiLanguagePreference.SimplifiedChinese => ChineseSimplifiedTag,
        _ => Detect(osCultureName),
    };

    /// <summary>Display name of a language in its own language.</summary>
    public static string NativeName(UiLanguagePreference preference) => preference switch
    {
        UiLanguagePreference.English => "English",
        UiLanguagePreference.SimplifiedChinese => "简体中文",
        _ => "System",
    };

    /// <summary>Localized display name of a language choice.</summary>
    public static string DisplayName(UiLanguagePreference preference, string tag) => preference == UiLanguagePreference.System
        ? NativeName(preference) + " (" + (string.Equals(tag, ChineseSimplifiedTag, StringComparison.Ordinal) ? "简体中文" : "English") + ")"
        : NativeName(preference);

    /// <summary>Text lookup with English fallback and the key itself as the last resort.</summary>
    public static string Text(string? tag, string key)
    {
        var dictionary = string.Equals(tag, ChineseSimplifiedTag, StringComparison.Ordinal) ? ChineseSimplified : English;
        if (dictionary.TryGetValue(key, out var value))
        {
            return value;
        }
        return English.TryGetValue(key, out var fallback) ? fallback : key;
    }

    /// <summary>Formatted lookup; a malformed template returns the raw template instead of throwing.</summary>
    public static string Format(string? tag, string key, params object?[] arguments)
    {
        var template = Text(tag, key);
        if (arguments.Length == 0)
        {
            return template;
        }
        try
        {
            return string.Format(CultureInfo.InvariantCulture, template, arguments);
        }
        catch (FormatException)
        {
            return template;
        }
    }

    /// <summary>All keys, ordered; both dictionaries must define exactly these keys.</summary>
    public static IReadOnlyList<string> Keys => English.Keys.Concat(ChineseSimplified.Keys).Distinct(StringComparer.Ordinal).OrderBy(key => key, StringComparer.Ordinal).ToList();

    /// <summary>Placeholder tokens ({0}, {1}...) contained in a template, for parity tests.</summary>
    public static IReadOnlyList<string> Placeholders(string template)
    {
        var tokens = new List<string>();
        for (var index = 0; index < template.Length - 1; index++)
        {
            if (template[index] == '{' && char.IsDigit(template[index + 1]))
            {
                var end = template.IndexOf('}', index + 2);
                if (end > index)
                {
                    tokens.Add(template.Substring(index, end - index + 1));
                    index = end;
                }
            }
        }
        return tokens;
    }

    public static IReadOnlyDictionary<string, string> English { get; } = Build(new (string Key, string Text)[]
    {
        ("app.title", "3ds2apple Launcher"),
        ("app.subtitle", "Bring your own decrypted 3DS ROMs. The launcher builds AOT packs and installs the ROM-free base shell signed with your own Apple ID."),
        ("nav.library", "Library"),
        ("nav.import", "Import"),
        ("nav.settings", "Settings"),
        ("nav.back", "Back to library"),
        ("status.ready", "Ready."),
        ("status.importing", "Reading ROM headers…"),
        ("status.importFinished", "Import finished."),
        ("status.importFailed", "Import failed."),
        ("status.building", "Building GamePack…"),
        ("status.buildFinished", "Build finished."),
        ("status.buildFailed", "Build failed."),
        ("status.composing", "Composing the app IPA (template + game packs)…"),
        ("status.signing", "Signing and installing the whole app IPA…"),
        ("status.appInstalled", "App installed."),
        ("status.pushPreparing", "Preparing the push plan…"),
        ("status.pushFinished", "Push finished."),
        ("status.pushFailed", "Push failed."),
        ("status.devices", "Refreshing devices…"),
        ("status.settingsSaved", "Settings saved."),
        ("status.languageChanged", "Language updated."),
        ("status.selftestPassed", "Self-test passed (see the raw diagnostics)."),
        ("status.selftestFailed", "Self-test FAILED — copy the launcher log when reporting."),
        ("status.deviceRefreshFailed", "Device refresh failed: {0}"),
        ("status.buildFailedDetail", "Build failed: {0}"),
        ("status.verifyFailed", "Verify failed: {0}"),
        ("status.settingsSaveFailed", "Could not save settings: {0}"),
        ("status.impactorMissing", "Bundled Impactor/plumesign not found."),
        ("library.title", "Library"),
        ("library.subtitle", "Import a decrypted .3ds/.cci you own; the launcher builds its AOT GamePack and pushes the ROM data to your iPhone/iPad."),
        ("library.empty.title", "No games yet"),
        ("library.empty.body", "Import your own decrypted ROM to get started. Only file headers are read; the ROM never leaves this PC."),
        ("library.empty.action", "Import a game"),
        ("library.count", "{0} game(s)"),
        ("library.refresh", "Refresh status"),
        ("library.install", "Install / update app"),
        ("library.installHint", "Signs the whole IPA with the official Impactor."),
        ("library.card.primary.build", "Build"),
        ("library.card.primary.install", "Install app"),
        ("library.card.primary.push", "Push ROM"),
        ("library.card.primary.verify", "Verify"),
        ("library.card.more", "More"),
        ("library.card.push", "Push ROM data"),
        ("library.card.verify", "Verify phone data"),
        ("library.card.install", "Install / update app"),
        ("library.card.remove", "Remove from library"),
        ("library.card.titleid", "Title ID: {0}"),
        ("library.card.rom", "ROM: {0}"),
        ("library.card.pack.none", "No GamePack yet"),
        ("library.card.pack.placeholder", "Preview placeholder ({0}) — not installable"),
        ("library.card.pack.built", "{0} · SHA-256 {1}…"),
        ("library.card.state.imported", "Imported"),
        ("library.card.state.queued", "Queued"),
        ("library.card.state.built", "Built"),
        ("library.card.state.preview", "Preview"),
        ("library.card.state.build_failed", "Build failed"),
        ("library.card.state.pushed", "Pushed"),
        ("library.selectedNone", "No game selected."),
        ("library.selectedSummary", "{0} ({1})"),
        ("import.title", "Import a decrypted ROM"),
        ("import.body", "Supports .3ds / .cci (also .ncch / .cxi). Only headers are read; the ROM is not copied into the launcher workspace."),
        ("import.path", "ROM file"),
        ("import.pathPlaceholder", "D:/ROM/Pokemon Y.cci"),
        ("import.browse", "Browse…"),
        ("import.name", "Display name override (optional, single ROM)"),
        ("import.namePlaceholder", "Pokemon Y"),
        ("import.action", "Import ROM"),
        ("import.steps.title", "What happens next"),
        ("import.step.build", "2. Build the GamePack on a macOS host you control (real AOT), or use the experimental local build."),
        ("import.step.install", "3. Install / update the app: packs + GameCatalog are injected into the ROM-free shell IPA and the whole IPA is signed with the official Impactor."),
        ("import.step.push", "4. Push this game's ROM + GameInfo into the phone's Documents folder."),
        ("import.job", "Working: {0}"),
        ("import.successHint", "Imported games appear in the Library section."),
        ("build.title", "Build the GamePack"),
        ("build.mode", "Build mode"),
        ("build.mode.preview", "Preview (placeholder, not installable)"),
        ("build.mode.macagent", "macOS Build Agent (real AOT)"),
        ("build.mode.local", "Local build (experimental)"),
        ("build.host", "macOS build host"),
        ("build.hostPlaceholder", "host profile name (e.g. office)"),
        ("build.action", "Build selected game"),
        ("build.note", "The supported AOT path compiles on a Mac you control through builder-windows. The experimental local build uses 3dsrecomp + open-source LLVM/LLD on this PC (feature flag in Settings). The GamePack.dylib always stays inside the signed app IPA."),
        ("build.previewNote", "Preview builds write labelled placeholders so you can test the whole flow; the phone cannot run them."),
        ("build.noneSelected", "Select a game in the Library first."),
        ("device.title", "Phone"),
        ("device.refresh", "Refresh devices"),
        ("device.none", "No iPhone/iPad found: connect by USB, unlock and tap Trust."),
        ("device.count", "{0} device(s): {1}"),
        ("device.fallback", "devpush is not bundled, so this is a read-only device list."),
        ("device.prereqTitle", "Prerequisites"),
        ("device.prereqUsb", "Windows 10/11 with Apple Devices (or iTunes) for the USB device service."),
        ("device.prereqTrust", "Enable Developer Mode on the iPhone/iPad and tap Trust on this PC."),
        ("device.prereqUnlock", "Keep the phone unlocked while installing and pushing."),
        ("app.sectionTitle", "App (base shell + game packs)"),
        ("app.sectionBody", "Packs and GameCatalog are injected into the ROM-free shell template IPA, then the whole IPA is signed and installed. Adding or removing a game reinstalls the app; pushed ROM data stays."),
        ("app.bundleId", "Bundle ID: {0}"),
        ("app.install", "Install / update app (signs whole IPA)"),
        ("app.installBare", "No real GamePack built yet; installing the bare shell. Games need a built pack and a reinstall."),
        ("app.openImpactor", "Open Impactor and sign in (Apple ID)"),
        ("app.impactorNote", "The bundled Impactor v2.7.2 and plumesign are the official, unmodified release binaries (SHA-256 pinned). Your Apple ID and password are entered only in Impactor."),
        ("push.title", "Push ROM data"),
        ("push.body", "Only GameRom.cci and GameInfo.json go to Documents/Games/<TITLEID>/ (GameInfo last), with read-back verification. The GamePack stays inside the signed app."),
        ("push.action", "Push selected game ROM"),
        ("push.verify", "Verify phone data"),
        ("push.resumeNote", "Re-running a push skips files whose size already matches on the phone; a 90-second stall aborts with a retry hint from the device bridge."),
        ("push.noPack", "This game has no real GamePack yet. Build it first; preview placeholders cannot run on the phone."),
        ("push.devpushMissing", "devpush is not available; the device bridge is required to push files."),
        ("push.noBundle", "No bundle id: bundle the base shell manifest or set the shell bundle id in Settings."),
        ("push.romMissing", "The imported ROM is gone from {0}. Re-import it first."),
        ("push.preparing", "Pushing ROM data ({0}) to {1}…"),
        ("push.done", "Pushed and verified to {0} (device {1})."),
        ("push.failed", "Push failed ({0}): {1}"),
        ("push.verifyOk", "Remote files match the local pack/ROM/GameInfo."),
        ("shell.missing", "Shell template not bundled (Shell/manifest.json missing)."),
        ("shell.invalid", "Shell template invalid: {0}"),
        ("shell.rejected", "Template rejected: {0} {1}"),
        ("shell.pending", "Shell template v{0} ready ({1}); app not installed yet."),
        ("shell.installed", "App {0} installed {1} with {2} pack(s)."),
        ("shell.waiting", "Waiting for Apple ID sign-in in Impactor…"),
        ("shell.installFailed", "Base shell install failed."),
        ("shell.installError", "{0} — {1}"),
        ("shell.installedCount", "App installed: {0} ({1} game pack(s))"),
        ("shell.installedNoPacks", "App installed without game packs. Build packs, reinstall the app, then push ROM data."),
        ("shell.installedReady", "App installed. Push the selected game's ROM data to Documents next."),
        ("settings.title", "Settings"),
        ("settings.close", "Close settings"),
        ("settings.appleTitle", "Apple ID & signing"),
        ("settings.appleBody", "The launcher never sees or stores your Apple ID or password. Sign in only inside the official Impactor; plumesign reuses that session to sign the IPA. Team IDs are handled by Impactor. Free Apple IDs expire after 7 days (Apple policy)."),
        ("settings.appleOpen", "Open Impactor"),
        ("settings.deviceTitle", "Device & connection"),
        ("settings.buildTitle", "Build mode"),
        ("settings.buildLocal", "Enable the experimental local build (3dsrecomp + LLVM/LLD on this PC)"),
        ("settings.buildRecomp", "3dsrecomp.exe (ROM to generated C)"),
        ("settings.buildLlvm", "LLVM bin folder (clang.exe / llvm-ar.exe / ld64.lld.exe)"),
        ("settings.toolsTitle", "Tool paths"),
        ("settings.toolsBody", "Leave empty to use the extracted package layout (Bin/ and ThirdParty/Impactor) or PATH."),
        ("settings.toolsPack", "3ds2apple-pack.exe (ROM headers / package queue)"),
        ("settings.toolsDevPush", "devpush.exe (device bridge)"),
        ("settings.toolsBuilder", "builder-windows.exe (macOS Build Agent CLI)"),
        ("settings.toolsMock", "devpush mock directory (optional; test without a phone)"),
        ("settings.toolsBundle", "Shell bundle id override (use when Apple answers 9401)"),
        ("settings.languageTitle", "Language"),
        ("settings.languageBody", "Default follows the Windows UI language: Simplified Chinese uses 简体中文, everything else uses English."),
        ("settings.language.system", "Follow system"),
        ("settings.logsTitle", "Logs & diagnostics"),
        ("settings.logsPath", "Daily log: {0}"),
        ("settings.logsShow", "Show raw diagnostics"),
        ("settings.logsHide", "Hide raw diagnostics"),
        ("settings.logsSelfTest", "Run self-test"),
        ("settings.logsWorkspace", "Open workspace folder"),
        ("settings.save", "Save settings"),
        ("settings.readiness", "Readiness"),
        ("settings.aboutTitle", "About & licences"),
        ("settings.aboutBody", "3ds2apple launcher {0} · Apache-2.0. The bundled official Impactor v2.7.2 (MIT, embeds apple-codesign MPL-2.0) and plumesign are unmodified third-party release binaries with pinned SHA-256. Use only ROMs you own; this tool provides no games, keys or system files. Do not redistribute signed apps or ROM-bundled packages."),
        ("settings.version", "Version {0}"),
        ("settings.distribution", "Distribution: {0}"),
        ("tool.state.ready", "ready"),
        ("tool.state.missing", "missing"),
        ("tool.state.failed", "failed"),
        ("readiness.all", "All bundled tools are ready."),
        ("readiness.blocked", "Not ready: {0}"),
        ("readiness.title", "Tool readiness"),
        ("readiness.unchecked", "Status not checked yet."),
        ("common.browse", "Browse…"),
        ("common.save", "Save"),
        ("common.close", "Close"),
        ("common.auto", "auto"),
        ("common.none", "(none)"),
    });

    public static IReadOnlyDictionary<string, string> ChineseSimplified { get; } = Build(new (string Key, string Text)[]
    {
        ("app.title", "3ds2apple 启动器"),
        ("app.subtitle", "使用你自己持有的解密 3DS ROM。启动器构建 AOT 包，并用你自己的 Apple ID 签名安装不含 ROM 的基础壳。"),
        ("nav.library", "游戏库"),
        ("nav.import", "导入"),
        ("nav.settings", "设置"),
        ("nav.back", "返回游戏库"),
        ("status.ready", "就绪。"),
        ("status.importing", "正在读取 ROM 信息…"),
        ("status.importFinished", "导入完成。"),
        ("status.importFailed", "导入失败。"),
        ("status.building", "正在构建 GamePack…"),
        ("status.buildFinished", "构建完成。"),
        ("status.buildFailed", "构建失败。"),
        ("status.composing", "正在组合 App IPA（模板 + 游戏包）…"),
        ("status.signing", "正在签名并安装整个 App IPA…"),
        ("status.appInstalled", "App 已安装。"),
        ("status.pushPreparing", "正在准备推送计划…"),
        ("status.pushFinished", "推送完成。"),
        ("status.pushFailed", "推送失败。"),
        ("status.devices", "正在刷新设备…"),
        ("status.settingsSaved", "设置已保存。"),
        ("status.languageChanged", "语言已切换。"),
        ("status.selftestPassed", "自检通过（见原始诊断日志）。"),
        ("status.selftestFailed", "自检失败——请附上启动器日志。"),
        ("status.deviceRefreshFailed", "设备刷新失败：{0}"),
        ("status.buildFailedDetail", "构建失败：{0}"),
        ("status.verifyFailed", "校验失败：{0}"),
        ("status.settingsSaveFailed", "保存设置失败：{0}"),
        ("status.impactorMissing", "未找到随包的 Impactor/plumesign。"),
        ("library.title", "游戏库"),
        ("library.subtitle", "导入你自有的解密 .3ds/.cci；启动器构建对应的 AOT GamePack，并把 ROM 数据推送到 iPhone/iPad。"),
        ("library.empty.title", "还没有游戏"),
        ("library.empty.body", "导入你自己解密的 ROM 开始使用。启动器只读取文件头，ROM 不会离开本机。"),
        ("library.empty.action", "导入游戏"),
        ("library.count", "{0} 个游戏"),
        ("library.refresh", "刷新状态"),
        ("library.install", "安装 / 更新 App"),
        ("library.installHint", "用官方 Impactor 签名整个 IPA。"),
        ("library.card.primary.build", "构建"),
        ("library.card.primary.install", "安装 App"),
        ("library.card.primary.push", "推送 ROM"),
        ("library.card.primary.verify", "校验"),
        ("library.card.more", "更多"),
        ("library.card.push", "推送 ROM 数据"),
        ("library.card.verify", "校验手机端数据"),
        ("library.card.install", "安装 / 更新 App"),
        ("library.card.remove", "从游戏库移除"),
        ("library.card.titleid", "标题 ID：{0}"),
        ("library.card.rom", "ROM：{0}"),
        ("library.card.pack.none", "尚未构建 GamePack"),
        ("library.card.pack.placeholder", "预览占位（{0}）— 不可安装"),
        ("library.card.pack.built", "{0} · SHA-256 {1}…"),
        ("library.card.state.imported", "已导入"),
        ("library.card.state.queued", "待构建"),
        ("library.card.state.built", "已构建"),
        ("library.card.state.preview", "预览占位"),
        ("library.card.state.build_failed", "构建失败"),
        ("library.card.state.pushed", "已推送"),
        ("library.selectedNone", "未选择游戏。"),
        ("library.selectedSummary", "{0}（{1}）"),
        ("import.title", "导入解密的 ROM"),
        ("import.body", "支持 .3ds / .cci（也支持 .ncch / .cxi）。只读取文件头，ROM 不会被复制到启动器工作目录。"),
        ("import.path", "ROM 文件"),
        ("import.pathPlaceholder", "D:/ROM/Pokemon Y.cci"),
        ("import.browse", "浏览…"),
        ("import.name", "显示名称覆盖（可选，单文件）"),
        ("import.namePlaceholder", "Pokemon Y"),
        ("import.action", "导入 ROM"),
        ("import.steps.title", "接下来会做什么"),
        ("import.step.build", "2. 在你控制的 macOS 主机上构建 GamePack（真实 AOT），或使用实验性本地构建。"),
        ("import.step.install", "3. 安装 / 更新 App：把游戏包和 GameCatalog 注入不含 ROM 的壳 IPA，再用官方 Impactor 签名整个 IPA。"),
        ("import.step.push", "4. 把该游戏的 ROM + GameInfo 推送到手机的 Documents 目录。"),
        ("import.job", "正在处理：{0}"),
        ("import.successHint", "导入完成后会出现在“游戏库”中。"),
        ("build.title", "构建 GamePack"),
        ("build.mode", "构建方式"),
        ("build.mode.preview", "预览（占位，不可安装）"),
        ("build.mode.macagent", "macOS Build Agent（真实 AOT）"),
        ("build.mode.local", "本地构建（实验性）"),
        ("build.host", "macOS 构建主机"),
        ("build.hostPlaceholder", "主机配置名（例如 office）"),
        ("build.action", "构建所选游戏"),
        ("build.note", "受支持的 AOT 路径通过 builder-windows 在你控制的 Mac 上编译。实验性本地构建在本机使用 3dsrecomp + 开源 LLVM/LLD（在设置中开启功能开关）。GamePack.dylib 始终位于签名后的 App IPA 内。"),
        ("build.previewNote", "预览构建会写入带标记的占位文件，便于测试完整流程；手机无法运行它们。"),
        ("build.noneSelected", "请先在游戏库中选择一个游戏。"),
        ("device.title", "手机"),
        ("device.refresh", "刷新设备"),
        ("device.none", "未找到 iPhone/iPad：请用 USB 连接、解锁并点“信任”。"),
        ("device.count", "找到 {0} 台设备：{1}"),
        ("device.fallback", "未随包提供 devpush，这里只显示只读设备列表。"),
        ("device.prereqTitle", "前提条件"),
        ("device.prereqUsb", "Windows 10/11 并安装 Apple Devices（或 iTunes）以提供 USB 设备服务。"),
        ("device.prereqTrust", "在 iPhone/iPad 上开启开发者模式，并在本机点“信任”。"),
        ("device.prereqUnlock", "安装和推送时请保持手机解锁。"),
        ("app.sectionTitle", "App（基础壳 + 游戏包）"),
        ("app.sectionBody", "游戏包和 GameCatalog 会注入不含 ROM 的壳模板 IPA，然后签名安装整个 IPA。增删游戏会重新安装 App；已推送的 ROM 数据会保留。"),
        ("app.bundleId", "Bundle ID：{0}"),
        ("app.install", "安装 / 更新 App（签名整个 IPA）"),
        ("app.installBare", "尚未构建真实 GamePack；将安装裸壳。游戏需要先构建 pack 并重新安装 App。"),
        ("app.openImpactor", "打开 Impactor 并登录（Apple ID）"),
        ("app.impactorNote", "随包的 Impactor v2.7.2 与 plumesign 是官方未修改的发布二进制（SHA-256 固定）。Apple ID 和密码只在 Impactor 中输入。"),
        ("push.title", "推送 ROM 数据"),
        ("push.body", "只把 GameRom.cci 和 GameInfo.json 推送到 Documents/Games/<TITLEID>/（GameInfo 最后写入），并在手机上校验。GamePack 保留在签名后的 App 内。"),
        ("push.action", "推送所选游戏 ROM"),
        ("push.verify", "校验手机端数据"),
        ("push.resumeNote", "重新推送会跳过手机端大小已匹配的文件；设备桥 90 秒无进展会中断并提示重试。"),
        ("push.noPack", "该游戏尚未构建真实 GamePack。请先构建；预览占位无法在手机上运行。"),
        ("push.devpushMissing", "devpush 不可用；推送文件需要设备桥。"),
        ("push.noBundle", "没有 Bundle ID：请随包提供壳 manifest，或在设置中填写壳 Bundle ID。"),
        ("push.romMissing", "导入的 ROM 已不在 {0}。请重新导入。"),
        ("push.preparing", "正在推送 ROM 数据（{0}）到 {1}…"),
        ("push.done", "已推送并校验到 {0}（设备 {1}）。"),
        ("push.failed", "推送失败（{0}）：{1}"),
        ("push.verifyOk", "手机端文件与本地 pack/ROM/GameInfo 一致。"),
        ("shell.missing", "未随包提供壳模板（缺少 Shell/manifest.json）。"),
        ("shell.invalid", "壳模板无效：{0}"),
        ("shell.rejected", "模板被拒绝：{0} {1}"),
        ("shell.pending", "壳模板 v{0} 已就绪（{1}）；App 尚未安装。"),
        ("shell.installed", "App {0} 已于 {1} 安装，包含 {2} 个游戏包。"),
        ("shell.waiting", "等待在 Impactor 中登录 Apple ID…"),
        ("shell.installFailed", "基础壳安装失败。"),
        ("shell.installError", "{0} — {1}"),
        ("shell.installedCount", "App 已安装：{0}（{1} 个游戏包）"),
        ("shell.installedNoPacks", "App 已安装，但没有游戏包。请构建 pack、重新安装 App，然后推送 ROM 数据。"),
        ("shell.installedReady", "App 已安装。接下来把所选游戏的 ROM 数据推送到 Documents。"),
        ("settings.title", "设置"),
        ("settings.close", "关闭设置"),
        ("settings.appleTitle", "Apple ID 与签名"),
        ("settings.appleBody", "启动器不会接触或保存你的 Apple ID / 密码。请在官方 Impactor 中登录；plumesign 复用该登录来签名 IPA。Team ID 由 Impactor 处理。免费 Apple ID 的 7 天限制由 Apple 决定。"),
        ("settings.appleOpen", "打开 Impactor"),
        ("settings.deviceTitle", "设备与连接"),
        ("settings.buildTitle", "构建方式"),
        ("settings.buildLocal", "启用实验性本地构建（本机 3dsrecomp + LLVM/LLD）"),
        ("settings.buildRecomp", "3dsrecomp.exe（ROM → 生成的 C）"),
        ("settings.buildLlvm", "LLVM bin 目录（clang.exe / llvm-ar.exe / ld64.lld.exe）"),
        ("settings.toolsTitle", "工具路径"),
        ("settings.toolsBody", "留空则使用随包解压目录（Bin/ 与 ThirdParty/Impactor）或 PATH。"),
        ("settings.toolsPack", "3ds2apple-pack.exe（ROM 头 / 包队列）"),
        ("settings.toolsDevPush", "devpush.exe（设备桥）"),
        ("settings.toolsBuilder", "builder-windows.exe（macOS Build Agent CLI）"),
        ("settings.toolsMock", "devpush 模拟目录（可选；无手机也能测试）"),
        ("settings.toolsBundle", "基础壳 Bundle ID 覆盖（Apple 返回 9401 时使用）"),
        ("settings.languageTitle", "语言"),
        ("settings.languageBody", "默认跟随 Windows 系统语言：简体中文使用简体中文，其他使用 English。"),
        ("settings.language.system", "跟随系统"),
        ("settings.logsTitle", "日志与诊断"),
        ("settings.logsPath", "每日日志：{0}"),
        ("settings.logsShow", "显示原始诊断日志"),
        ("settings.logsHide", "隐藏原始诊断日志"),
        ("settings.logsSelfTest", "运行自检"),
        ("settings.logsWorkspace", "打开工作目录"),
        ("settings.save", "保存设置"),
        ("settings.readiness", "就绪状态"),
        ("settings.aboutTitle", "关于与许可"),
        ("settings.aboutBody", "3ds2apple 启动器 {0} · Apache-2.0。随包分发的官方 Impactor v2.7.2（MIT，内嵌 apple-codesign MPL-2.0）与 plumesign 是未修改的第三方发布二进制，SHA-256 已固定。只使用你自有的 ROM；本工具不提供游戏、密钥或系统文件。请不要传播已签名 App 或包含 ROM 的包。"),
        ("settings.version", "版本 {0}"),
        ("settings.distribution", "分发目录：{0}"),
        ("tool.state.ready", "就绪"),
        ("tool.state.missing", "缺失"),
        ("tool.state.failed", "失败"),
        ("readiness.all", "随包工具均已就绪。"),
        ("readiness.blocked", "未就绪：{0}"),
        ("readiness.title", "工具就绪状态"),
        ("readiness.unchecked", "尚未检查状态。"),
        ("common.browse", "浏览…"),
        ("common.save", "保存"),
        ("common.close", "关闭"),
        ("common.auto", "自动"),
        ("common.none", "（无）"),
    });

    private static IReadOnlyDictionary<string, string> Build((string Key, string Text)[] entries)
    {
        var dictionary = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            dictionary[entry.Key] = entry.Text;
        }
        return dictionary;
    }
}

/// <summary>Ambient UI language used by the launcher process.</summary>
public static class Loc
{
    private static readonly object Gate = new();
    private static string _currentTag = LanguageCatalog.EnglishTag;
    private static UiLanguagePreference _preference = UiLanguagePreference.System;

    public static string CurrentTag
    {
        get
        {
            lock (Gate)
            {
                return _currentTag;
            }
        }
    }

    public static UiLanguagePreference Preference
    {
        get
        {
            lock (Gate)
            {
                return _preference;
            }
        }
    }

    public static event Action? LanguageChanged;

    /// <summary>Apply a stored preference; the OS culture name is only used for System.</summary>
    public static void ApplyPreference(UiLanguagePreference preference, string? osCultureName = null)
    {
        var tag = LanguageCatalog.Resolve(preference, osCultureName);
        lock (Gate)
        {
            _preference = preference;
            _currentTag = tag;
        }
        LanguageChanged?.Invoke();
    }

    public static string T(string key) => LanguageCatalog.Text(CurrentTag, key);

    public static string T(string key, params object?[] arguments) => LanguageCatalog.Format(CurrentTag, key, arguments);

    /// <summary>Test hook: restore the English/System default.</summary>
    public static void ResetForTests() => ApplyPreference(UiLanguagePreference.System, "en-US");
}