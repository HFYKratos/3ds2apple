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
        ("library.subtitle", "Import and manage the games you own. Importing only reads the ROM header; Deploy compiles, installs and sends the data to your phone."),
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
        ("library.card.remove", "Remove"),
        ("library.card.titleid", "Title ID: {0}"),
        ("library.card.rom", "ROM: {0}"),
        ("library.card.pack.none", "No GamePack yet"),
        ("library.card.pack.placeholder", "Preview placeholder ({0}) — not installable"),
        ("library.card.pack.built", "GamePack built · {0}"),
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
        ("build.mode.local", "Local build (experimental)"),
        ("build.host", "macOS build host"),
        ("build.hostPlaceholder", "host profile name (e.g. office)"),
        ("build.action", "Build selected game"),
        ("build.previewNote", "Preview builds write labelled placeholders so you can test the whole flow; the phone cannot run them."),
        ("build.noneSelected", "Select a game in the Library first."),
        ("device.title", "Phone"),
        ("device.refresh", "Refresh devices"),
        ("device.none", "No iPhone/iPad found: connect by USB, unlock and tap Trust."),
        ("device.count", "{0} device(s): {1}"),
        ("device.fallback", "devpush is not bundled, so this is a read-only device list."),
        ("device.prereqTitle", "Prerequisites"),
        ("device.prereqUsb", "Windows 10/11 with Apple Devices (or iTunes) for the USB device service."),
        ("device.prereqUsbLinux", "USB + usbmuxd: install/start usbmuxd (libimobiledevice), connect the iPhone/iPad and tap Trust."),
        ("app.impactorNoteLinux", "The official plumesign-linux-x86_64 v2.7.3 is verified by SHA-256 (launcher/linux/vendor/PINS.json). Your Apple ID, password and 2FA code are entered only in its terminal prompt and stored in ~/.config/PlumeImpactor; the launcher never sees them."),
        ("settings.aboutBodyLinux", "3ds2apple launcher {0} · Apache-2.0. Uses the official Impactor v2.7.3 plumesign-linux-x86_64 (MIT; embeds apple-codesign MPL-2.0) and the Linux devpush bridge, all unmodified third-party binaries with pinned SHA-256. Linux local AOT is available: the bundled open-source 3dsrecomp + LLVM 23.1.6 toolchain compiles your own ROMs into GamePacks, and imported .32a packages that already contain a cached GamePack deploy without recompiling. Use only ROMs you own; this tool provides no games, keys or system files."),
        ("settings.languageBodyLinux", "Default follows the Linux desktop locale: Simplified Chinese uses 简体中文, everything else uses English."),
        ("device.prereqTrust", "Enable Developer Mode on the iPhone/iPad and tap Trust on this PC."),
        ("device.prereqUnlock", "Keep the phone unlocked while installing and pushing."),
        ("app.sectionTitle", "App (base shell + game packs)"),
        ("app.sectionBody", "Packs and GameCatalog are injected into the ROM-free shell template IPA, then the whole IPA is signed and installed. Adding or removing a game reinstalls the app; pushed ROM data stays."),
        ("app.bundleId", "Bundle ID: {0}"),
        ("app.install", "Install / update app (signs whole IPA)"),
        ("app.installBare", "No real GamePack built yet; installing the bare shell. Games need a built pack and a reinstall."),
        ("app.openImpactor", "Open Impactor and sign in (Apple ID)"),
        ("app.impactorNote", "The bundled Impactor v2.7.3 and plumesign are the official, unmodified release binaries (SHA-256 pinned). Your Apple ID and password are entered only in Impactor."),
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
        ("settings.appleBodyLinux", "Sign in with the official plumesign-linux-x86_64 CLI. It stores the Apple ID session in ~/.config/PlumeImpactor and prompts for the Apple ID/password/2FA in a terminal; the launcher never sees or logs them. Free Apple IDs expire after 7 days (Apple policy)."),
        ("settings.appleOpen", "Open Impactor"),
        ("settings.appleOpenLinux", "Sign in with plumesign"),
        ("settings.appleAccountRefresh", "Refresh account status"),
        ("settings.appleAccountChecking", "Checking the plumesign account…"),
        ("settings.appleAccountSignedIn", "Signed in — plumesign has a saved Apple ID account."),
        ("settings.appleAccountSignedOut", "Not signed in — press Sign in with plumesign and finish the Apple ID/2FA prompt in the terminal."),
        ("settings.appleAccountMissing", "plumesign was not found — stage the official Linux binary (launcher/linux/vendor/PINS.json)."),
        ("settings.appleAccountFailed", "Could not read the plumesign account state: {0}"),
        ("settings.appleAccountLoginOpened", "A terminal was opened. Finish the Apple ID/2FA prompt there, then press Refresh account status."),
        ("settings.appleAccountLoginManual", "No terminal emulator was found. Run this in a terminal, then press Refresh account status: {0} {1}"),
        ("settings.deviceTitle", "Device & connection"),
        ("settings.buildTitle", "Build mode"),
        ("settings.buildLocal", "Enable the experimental local build (3dsrecomp + LLVM/LLD on this PC)"),
        ("settings.buildRecomp", "3dsrecomp.exe (ROM to generated C)"),
        ("settings.buildLlvm", "LLVM bin folder (clang.exe / llvm-ar.exe / ld64.lld.exe)"),
        ("settings.toolsTitle", "Tool paths"),
        ("settings.toolsBody", "Leave empty to use the extracted package layout (Bin/ and ThirdParty/Impactor) or PATH."),
        ("settings.toolsPack", "3ds2apple-pack.exe (ROM headers / package queue)"),
        ("settings.toolsDevPush", "devpush.exe (device bridge)"),
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
        ("settings.aboutBody", "3ds2apple launcher {0} · Apache-2.0. The bundled official Impactor v2.7.3 (MIT, embeds apple-codesign MPL-2.0) and plumesign are unmodified third-party release binaries with pinned SHA-256. Use only ROMs you own; this tool provides no games, keys or system files. Do not redistribute signed apps or ROM-bundled packages."),
        ("settings.version", "Version {0}"),
        ("settings.distribution", "Distribution: {0}"),
        ("tool.state.ready", "ready"),
        ("tool.state.missing", "missing"),
        ("tool.state.failed", "failed"),
        ("readiness.all", "All bundled tools are ready."),
        ("readiness.blocked", "Not ready: {0}"),
        ("readiness.title", "Tool readiness"),
        ("readiness.unchecked", "Status not checked yet."),
        ("readiness.status.ready", "Ready"),
        ("readiness.status.failed", "Not ready"),
        ("readiness.status.checking", "Checking…"),
        ("readiness.status.retryHint", "Click the status light to run the readiness check again."),
        ("common.browse", "Browse…"),
        ("common.save", "Save"),
        ("common.close", "Close"),
        ("common.auto", "auto"),
        ("common.none", "(none)"),

        // v2 two-section Library -> Deploy flow (task-30).
        ("nav.deploy", "Deploy"),
        ("nav.libraryHint", "Import and manage the games you own."),
        ("nav.deployHint", "Send selected games to your iPhone/iPad."),
        ("library.more", "More"),
        ("library.card.rename", "Name"),
        ("library.import.title", "Import ROM or build package"),
        ("library.import.action", "Import"),
        ("library.card.notBuilt", "Not built yet — Deploy compiles it automatically; Build now can compile it ahead of time. Build it first: Export becomes available once the GamePack exists."),
        ("deploy.title", "Deploy to your iPhone/iPad"),
        ("deploy.subtitle", "Select one or more imported games. One click runs the whole chain in order: compile → compose app IPA → sign/install → push ROM data → verify."),
        ("deploy.subtitleLinux", "Select one or more imported games. On Linux this runs the full chain: local AOT compile (bundled open-source 3dsrecomp + LLVM) → compose app IPA → plumesign sign/install → devpush ROM data → verify. Imported .32a packages with a cached GamePack skip recompiling."),
        ("deploy.selectAll", "Select all"),
        ("deploy.selectNone", "Clear selection"),
        ("deploy.selectedCount", "{0} of {1} selected"),
        ("deploy.action", "Deploy selected"),
        ("deploy.running", "Deploying…"),
        ("deploy.retry", "Retry"),
        ("deploy.refreshSigning", "Refresh signing"),
        ("deploy.refreshSigningHint", "Re-signs the last deployed or exported IPA in place (renews the 7-day free Apple ID signature). It does not add games or update GamePacks — use Deploy for that. Disabled until an IPA exists."),
        ("deploy.refreshSigningRunning", "Re-signing the last IPA…"),
        ("deploy.refreshSigningDone", "Signature renewed and installed — app data kept."),
        ("deploy.refreshSigningNoIpa", "No IPA to re-sign yet. Press Deploy once (or export a ready-to-sign package) first."),
        ("deploy.refreshSigningNoInstaller", "The bundled Impactor/plumesign was not found; reinstall the launcher package."),
        ("deploy.refreshSigningFailed", "Refresh signing failed: {0}"),
        ("deploy.idleTitle", "Ready to deploy"),
        ("deploy.idleBody", "Tick the games to send, then press Deploy selected."),
        ("deploy.doneTitle", "Done — you can play on your phone"),
        ("deploy.doneBody", "The app and the selected ROM data are on the phone. Open 3ds2apple on the device to play."),
        ("deploy.failedTitle", "Deploy failed"),
        ("deploy.failedAt", "Failed step: {0}"),
        ("deploy.failedHelp", "Fix the problem above, then press Retry. Finished work is kept: compiled packs and already-pushed files are reused."),
        ("deploy.step.build", "1 · Compile games"),
        ("deploy.step.compose", "2 · Compose app IPA"),
        ("deploy.step.install", "3 · Sign + install"),
        ("deploy.step.push", "4 · Push ROM data"),
        ("deploy.step.verify", "5 · Verify on phone"),
        ("deploy.step.pending", "Waiting"),
        ("deploy.step.running", "Running"),
        ("deploy.step.succeeded", "Done"),
        ("deploy.step.failed", "Failed"),
        ("deploy.step.skipped", "Skipped"),
        ("deploy.games.title", "Games to deploy"),
        ("deploy.noGames", "No imported game yet. Add a game in the Library first."),
        ("deploy.needSelection", "Select at least one game."),
        ("deploy.needShell", "The ROM-free base shell template is missing from this package. Reinstall the launcher ZIP, then retry."),
        ("deploy.toolchain.title", "Local build components"),
        ("deploy.toolchain.ready", "Ready: local build (3dsrecomp + LLVM), Impactor/plumesign and devpush."),
        ("deploy.toolchain.missing", "Missing: {0}"),
        ("deploy.toolchain.fix", "Place 3dsrecomp.exe and the official LLVM 23.1.6 tools in the launcher's Bin/ (Bin/3dsrecomp.exe, Bin/llvm/bin/…), then press Retry. This is the only build path; there is no Mac fallback."),
        ("deploy.device", "Phone: {0}"),
        ("deploy.deviceNone", "No phone connected. Connect by USB, unlock it and tap Trust, then refresh."),
        ("deploy.installed", "Installed app: {0}"),
        ("deploy.notInstalled", "The app is not installed yet — Deploy installs it first."),
        ("deploy.deviceState.title", "Device state"),
        ("deploy.deviceapp.version", "App v{0} · package {1} · launcher shell {2}"),
        ("deploy.deviceapp.notInstalled", "The app is not installed on this phone yet — the next deploy installs it."),
        ("deploy.deviceapp.unknown", "unknown"),
        ("deploy.deviceapp.unavailable", "App state unavailable — connect the phone by USB (trusted and unlocked), then refresh."),
        ("deploy.devicegames.none", "No game data on the phone yet."),
        ("deploy.devicegames.some", "{0} game(s) on the phone · {1} of {2} selected current"),
        ("deploy.plan.title", "Deploy plan"),
        ("deploy.mode.full", "Install the app and push {0} game(s)."),
        ("deploy.mode.reinstall", "Update the app (keeping {0} game(s)) and push {1} game(s)."),
        ("deploy.mode.push", "The app is current; push {0} game(s) of missing/outdated data."),
        ("deploy.mode.uptodate", "Already up to date — nothing to install or push."),
        ("deploy.orphans.summary", "{0} game(s) exist only on the phone and are not in this library: {1}. Their GameRom and saves stay in Documents, but an app update would remove their app entries."),
        ("deploy.orphans.blockedTitle", "Update paused: phone games missing from this library"),
        ("deploy.orphans.blockedDetail", "This update would remove the app entries of {0} phone-only game(s): {1}. Their GameRom and saves stay in Documents — nothing is deleted."),
        ("deploy.orphans.confirmButton", "Update anyway (data stays, app entries disappear)"),
        ("deploy.orphans.confirmHint", "To keep them playable, import their ROMs into the library and build their GamePacks first."),
        ("deploy.orphans.planSuffix", "({0} phone-only game(s) need confirmation)"),
        ("deploy.state.idle", "Idle"),
        ("deploy.state.running", "Running"),
        ("deploy.state.done", "Done"),
        ("deploy.state.failed", "Failed"),
        ("deploy.log", "Deploy log"),
        ("deploy.logShow", "Show log"),
        ("deploy.logHide", "Hide log"),
        // Deploy prerequisites (task-20): one green/red status light per block.
        ("deploy.prereq.title", "Before deploying"),
        ("deploy.prereq.summary", "{0} of {1} prerequisites ready"),
        ("deploy.prereq.refresh", "Refresh status"),
        ("deploy.prereq.device.label", "iPhone/iPad connected"),
        ("deploy.prereq.device.hint", "Connect the iPhone/iPad with a USB cable, unlock it and tap Trust, then refresh."),
        ("deploy.prereq.signing.label", "Signing tools ready"),
        ("deploy.prereq.signing.note", "First use: sign in to your Apple ID inside Impactor. The launcher never sees the password."),
        ("deploy.prereq.device.hintLinux", "Connect the iPhone/iPad by USB, unlock it and tap Trust; usbmuxd must be running."),
        ("deploy.prereq.signing.labelLinux", "plumesign / Apple ID sign-in"),
        ("deploy.prereq.signing.hintLinux", "Use Sign in with plumesign (Settings), finish the Apple ID/2FA prompt in the terminal, then refresh. The launcher never sees the password."),
        ("deploy.prereq.signing.noteLinux", "Apple ID sessions are handled by the official plumesign CLI (~/.config/PlumeImpactor); the launcher only checks whether an account is saved."),
        ("deploy.prereq.toolchain.labelLinux", "local AOT build (Linux)"),
        ("deploy.prereq.toolchain.hintLinux", "The Linux payload should include 3dsrecomp + the open-source LLVM clang/llvm-ar/ld64.lld subset under Bin/llvm and the Darwin stubs; rebuild the payload with launcher/linux/build-linux.sh --payload --local-aot, then refresh."),
        ("deploy.prereq.bridge.labelLinux", "devpush device bridge (Linux)"),
        ("deploy.prereq.bridge.hintLinux", "Stage the Linux devpush build at Bin/devpush (P3 packaging), start usbmuxd, connect/unlock/trust the iPhone/iPad, then refresh."),
        ("deploy.prereq.shell.hintLinux", "Stage Shell/3ds2apple-shell.ipa + manifest.json in the Linux package (from the macOS build), then refresh."),
        ("deploy.prereq.signing.hint", "The bundled Impactor v2.7.3/plumesign are missing or modified — reinstall the launcher ZIP, then refresh."),
        ("deploy.prereq.toolchain.label", "Local build toolchain ready"),
        ("deploy.prereq.toolchain.hint", "Place 3dsrecomp.exe and the official LLVM 23.1.6 tools in Bin/ (Bin/llvm/bin/…), then refresh."),
        ("deploy.prereq.toolchain.hint.missing", "Missing {0} — place 3dsrecomp.exe and the official LLVM 23.1.6 tools in Bin/ (Bin/llvm/bin/…), then refresh."),
        ("deploy.prereq.bridge.label", "Device bridge (devpush) ready"),
        ("deploy.prereq.bridge.hint", "devpush.exe is missing or cannot list devices — reinstall the launcher ZIP, make sure Apple Devices (or iTunes) is running, then refresh."),
        ("deploy.prereq.shell.label", "Shell template ready"),
        ("deploy.prereq.shell.hint", "The bundled ROM-free shell template is missing or does not match Shell/manifest.json — reinstall the launcher ZIP, then refresh."),
        ("settings.logsExport", "Export log…"),
        ("settings.logsExported", "Log exported to {0}."),
        ("settings.exportFailed", "Could not export the log: {0}"),
        ("settings.bundleId", "Installed bundle id: {0}"),
        ("library.card.publisher", "Publisher: {0}"),
        ("deploy.hardware", "Hardware: {0} logical / {1} physical cores · {2} GB RAM ({3} GB free) · 3dsrecomp auto-parallelizes, no jobs setting"),
        ("settings.workspaceInfo", "Games/state folder: {0} · {1}"),
        ("settings.distributionInfo", "Bundled tools folder: {0} · {1}"),
        ("layout.portable", "portable beside the launcher (writable folder)"),
        ("layout.localAppData", "LocalAppData fallback (the launcher folder is read-only)"),
        ("layout.explicit", "explicit override"),
        ("layout.temp", "temporary fallback folder"),
        // --- task-21: Library "Build now" + build-cache labels (append-only scope; en/zh stay in sync). ---
        ("library.buildNow", "Build now"),
        ("library.buildAll", "Build all"),
        // --- 0.2.2: portable .32a build packages (Library export/import; user data, never uploaded). ---
        ("library.import.noUsableFiles", "Nothing was imported: {0}"),
        ("library.buildPackage.confirmReplace", "Replace existing package"),
        ("library.buildPackage.exported", "Exported: {0}"),
        ("library.buildPackage.exportFailed", "Export failed: {0}"),
        ("library.buildPackage.imported", "Imported {0} into {1}"),
        ("library.buildPackage.cacheRecorded", "Build cache recorded — this package can be deployed without recompiling."),
        ("library.buildPackage.cacheMismatch", "Built with a different build recipe/toolchain — the next deploy will recompile it."),
        ("library.buildPackage.cacheNoRom", "No game data embedded — the build cache cannot be recorded; deploying needs the original ROM."),
        ("library.buildPackage.cacheMissing", "No manifest in this package (older CLI) — the next deploy will recompile it."),
        ("library.buildPackage.importFailed", "Import failed: {0}"),
        ("library.buildPackage.conflict", "A package for this game already exists. {0}"),

        ("status.buildPackageExport", "Exporting the .32a build package…"),
        ("status.buildPackageExportFailed", "Build package export failed."),
        ("status.buildPackageExported", "Build package exported."),
        ("status.buildPackageImport", "Importing the .32a build package…"),
        ("status.buildPackageImportFailed", "Build package import failed."),
        ("status.buildPackageImported", "Build package imported."),
        ("status.buildPackageConflict", "Choose whether to replace the existing package."),
        // --- 0.2.2: unsigned single-game IPA export (Library row "Export IPA"). ---
        ("library.export", "Export"),
        ("library.export.title", "Export {0}"),
        ("library.export.formatBuildPackage", "Finished build package"),
        ("library.export.formatIpa", "Ready-to-sign package"),
        ("library.export.destinationBuildPackage", "Export folder (default: workspace/export/32a)"),
        ("library.export.destinationIpa", "Save IPA as (default: workspace/export/ipa)"),
        ("library.export.warningsBuildPackage", "May contain your own game data. Keep the file local; never upload, share or commit it."),
        ("library.export.warningsIpa", "Contains your own game data and is NOT signed: sign it yourself with Sideloadly or AltStore. Keep it local; never upload or share it."),
        ("library.export.browse", "Choose…"),
        ("library.export.confirm", "Export"),
        ("library.export.cancel", "Cancel"),
        ("library.ipaExported", "Exported: {0}"),
        ("library.ipaExportFailed", "IPA export failed: {0}"),
        ("library.ipaNeedsPack", "Build the GamePack first: only a real AOT pack can be exported."),
        ("library.ipaLibraryUnavailable", "The shell template is missing; reinstall the launcher package so Shell/ contains the ROM-free template."),
        ("library.ipaNeedsRom", "The game's ROM is required: the single-game IPA embeds the game data. Re-import the ROM (or restore its file) and export again."),
        ("status.exportIpa", "Composing the single-game IPA…"),
        ("status.ipaExported", "Single-game IPA exported."),
        ("status.ipaExportFailed", "Single-game IPA export failed."),
        // --- 0.2.2: Deploy -> Advanced build settings (AOT codegen options). ---
        ("settings.advanced.title", "Advanced build settings"),
        ("settings.advanced.body", "Applied to the next build. Defaults keep the current behaviour; changing an option invalidates the build cache for the affected games (they rebuild on the next Build/Deploy)."),
        ("settings.advanced.optLevel", "Optimization level (default O2)"),
        ("settings.advanced.optLevelHint", "O1 / O2 / O3 / Oz. Higher levels build slower; game performance may improve (measure on a device before relying on it)."),
        ("settings.advanced.lto", "Link-time optimization (LTO, default off)"),
        ("settings.advanced.ltoHint", "Enables -flto: the build/link takes longer; performance may improve slightly."),
        ("settings.advanced.fastMath", "Fast-math (default off)"),
        ("settings.advanced.fastMathHint", "Changes guest floating-point results; use for measurement/experiments only. The shipped default build does not enable it."),
        ("settings.advanced.summary", "Current: {0}. The build cache key includes these options."),
        ("settings.advanced.reset", "Reset to defaults"),
        ("library.buildStatus.built", "Built · cache {0}"),
        ("library.buildStatus.noRecord", "Built · no cache marker yet (next build recompiles)"),
        ("library.buildStatus.rebuildCompat", "Rebuild needed · build method changed"),
        ("library.buildStatus.rebuildRom", "Rebuild needed · ROM changed"),
        ("status.buildSummary", "Build finished: {0} built, {1} reused, {2} failed."),
        // --- task-25: Deploy stop / cancellation (append-only scope; en/zh stay in sync). ---
        ("deploy.stop", "Stop"),
        ("deploy.stopping", "Stopping…"),
        ("deploy.state.cancelled", "Cancelled"),
        ("deploy.step.cancelled", "Cancelled"),
        ("deploy.cancelledTitle", "Deploy cancelled"),
        ("deploy.cancelledBody", "Deploy was stopped before it finished. GamePacks that already compiled are kept and reused; press Deploy selected to start again."),
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
        ("library.subtitle", "导入并管理你自有的游戏。导入只读取 ROM 文件头；在“部署”页才会编译、安装并发送数据到手机。"),
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
        ("library.card.remove", "移除"),
        ("library.card.titleid", "标题 ID：{0}"),
        ("library.card.rom", "ROM：{0}"),
        ("library.card.pack.none", "尚未构建 GamePack"),
        ("library.card.pack.placeholder", "预览占位（{0}）— 不可安装"),
        ("library.card.pack.built", "GamePack 已编译 · {0}"),
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
        ("build.mode.local", "本地构建（实验性）"),
        ("build.host", "macOS 构建主机"),
        ("build.hostPlaceholder", "主机配置名（例如 office）"),
        ("build.action", "构建所选游戏"),
        ("build.previewNote", "预览构建会写入带标记的占位文件，便于测试完整流程；手机无法运行它们。"),
        ("build.noneSelected", "请先在游戏库中选择一个游戏。"),
        ("device.title", "手机"),
        ("device.refresh", "刷新设备"),
        ("device.none", "未找到 iPhone/iPad：请用 USB 连接、解锁并点“信任”。"),
        ("device.count", "找到 {0} 台设备：{1}"),
        ("device.fallback", "未随包提供 devpush，这里只显示只读设备列表。"),
        ("device.prereqTitle", "前提条件"),
        ("device.prereqUsb", "Windows 10/11 并安装 Apple Devices（或 iTunes）以提供 USB 设备服务。"),
        ("device.prereqUsbLinux", "USB + usbmuxd：安装并启动 usbmuxd（libimobiledevice），连接 iPhone/iPad 并点按“信任”。"),
        ("app.impactorNoteLinux", "官方 plumesign-linux-x86_64 v2.7.3 已按 SHA-256 固定（launcher/linux/vendor/PINS.json）。Apple ID、密码和 2FA 只在其终端提示中输入，保存在 ~/.config/PlumeImpactor；启动器不会看到这些信息。"),
        ("settings.aboutBodyLinux", "3ds2apple 启动器 {0} · Apache-2.0。使用官方 Impactor v2.7.3 的 plumesign-linux-x86_64（MIT，内嵌 apple-codesign MPL-2.0）与 Linux devpush 设备桥，均为未修改且 SHA-256 固定的第三方二进制。Linux 本地 AOT 已可用：内置开源 3dsrecomp + LLVM 23.1.6 工具链可将自有 ROM 编译为 GamePack；导入已含缓存 GamePack 的 .32a 包可跳过重编译直接部署。只使用你自有的 ROM；本工具不提供游戏、密钥或系统文件。"),
        ("settings.languageBodyLinux", "默认跟随 Linux 桌面语言：简体中文使用简体中文，其他使用 English。"),
        ("device.prereqTrust", "在 iPhone/iPad 上开启开发者模式，并在本机点“信任”。"),
        ("device.prereqUnlock", "安装和推送时请保持手机解锁。"),
        ("app.sectionTitle", "App（基础壳 + 游戏包）"),
        ("app.sectionBody", "游戏包和 GameCatalog 会注入不含 ROM 的壳模板 IPA，然后签名安装整个 IPA。增删游戏会重新安装 App；已推送的 ROM 数据会保留。"),
        ("app.bundleId", "Bundle ID：{0}"),
        ("app.install", "安装 / 更新 App（签名整个 IPA）"),
        ("app.installBare", "尚未构建真实 GamePack；将安装裸壳。游戏需要先构建 pack 并重新安装 App。"),
        ("app.openImpactor", "打开 Impactor 并登录（Apple ID）"),
        ("app.impactorNote", "随包的 Impactor v2.7.3 与 plumesign 是官方未修改的发布二进制（SHA-256 固定）。Apple ID 和密码只在 Impactor 中输入。"),
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
        ("settings.appleBodyLinux", "使用官方 plumesign-linux-x86_64 命令行登录。它会将会话保存在 ~/.config/PlumeImpactor，并在终端中提示输入 Apple ID/密码/2FA；启动器不会看到或记录这些信息。免费 Apple ID 的 7 天限制由 Apple 决定。"),
        ("settings.appleOpen", "打开 Impactor"),
        ("settings.appleOpenLinux", "用 plumesign 登录"),
        ("settings.appleAccountRefresh", "刷新账号状态"),
        ("settings.appleAccountChecking", "正在检查 plumesign 账号…"),
        ("settings.appleAccountSignedIn", "已登录：plumesign 已保存 Apple ID 账号。"),
        ("settings.appleAccountSignedOut", "未登录：请点“用 plumesign 登录”，在终端完成 Apple ID/2FA 提示。"),
        ("settings.appleAccountMissing", "未找到 plumesign：请放入官方 Linux 二进制（见 launcher/linux/vendor/PINS.json）。"),
        ("settings.appleAccountFailed", "无法读取 plumesign 账号状态：{0}"),
        ("settings.appleAccountLoginOpened", "已打开终端；请在那里完成 Apple ID/2FA 提示，然后点“刷新账号状态”。"),
        ("settings.appleAccountLoginManual", "未找到终端模拟器。请在终端运行以下命令，然后点“刷新账号状态”：{0} {1}"),
        ("settings.deviceTitle", "设备与连接"),
        ("settings.buildTitle", "构建方式"),
        ("settings.buildLocal", "启用实验性本地构建（本机 3dsrecomp + LLVM/LLD）"),
        ("settings.buildRecomp", "3dsrecomp.exe（ROM → 生成的 C）"),
        ("settings.buildLlvm", "LLVM bin 目录（clang.exe / llvm-ar.exe / ld64.lld.exe）"),
        ("settings.toolsTitle", "工具路径"),
        ("settings.toolsBody", "留空则使用随包解压目录（Bin/ 与 ThirdParty/Impactor）或 PATH。"),
        ("settings.toolsPack", "3ds2apple-pack.exe（ROM 头 / 包队列）"),
        ("settings.toolsDevPush", "devpush.exe（设备桥）"),
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
        ("settings.aboutBody", "3ds2apple 启动器 {0} · Apache-2.0。随包分发的官方 Impactor v2.7.3（MIT，内嵌 apple-codesign MPL-2.0）与 plumesign 是未修改的第三方发布二进制，SHA-256 已固定。只使用你自有的 ROM；本工具不提供游戏、密钥或系统文件。请不要传播已签名 App 或包含 ROM 的包。"),
        ("settings.version", "版本 {0}"),
        ("settings.distribution", "分发目录：{0}"),
        ("tool.state.ready", "就绪"),
        ("tool.state.missing", "缺失"),
        ("tool.state.failed", "失败"),
        ("readiness.all", "随包工具均已就绪。"),
        ("readiness.blocked", "未就绪：{0}"),
        ("readiness.title", "工具就绪状态"),
        ("readiness.unchecked", "尚未检查状态。"),
        ("readiness.status.ready", "已完成准备"),
        ("readiness.status.failed", "未完成准备"),
        ("readiness.status.checking", "正在检查…"),
        ("readiness.status.retryHint", "点击状态灯可重新检测。"),
        ("common.browse", "浏览…"),
        ("common.save", "保存"),
        ("common.close", "关闭"),
        ("common.auto", "自动"),
        ("common.none", "（无）"),

        // v2 两分区“游戏库 → 部署”流程（task-30）。
        ("nav.deploy", "部署"),
        ("nav.libraryHint", "导入并管理你自有的游戏。"),
        ("nav.deployHint", "把选中的游戏发送到 iPhone/iPad。"),
        ("library.more", "更多"),
        ("library.card.rename", "名称"),
        ("library.import.title", "导入 ROM 或构建包"),
        ("library.import.action", "导入"),
        ("library.card.notBuilt", "尚未构建 —— 部署时会自动编译；也可用“立即构建”提前编译。请先构建：GamePack 生成后才能导出。"),
        ("deploy.title", "部署到 iPhone/iPad"),
        ("deploy.subtitle", "勾选一个或多个已导入的游戏，一键按顺序完成：编译 → 合成 App IPA → 签名安装 → 推送 ROM 数据 → 校验。"),
        ("deploy.subtitleLinux", "勾选一个或多个已导入的游戏。Linux 上执行完整流程：本地 AOT 编译（内置开源 3dsrecomp + LLVM）→ 合成 App IPA → plumesign 签名安装 → devpush 推送 ROM 数据 → 校验。导入的 .32a 若含缓存 GamePack 会跳过重编译。"),
        ("deploy.selectAll", "全选"),
        ("deploy.selectNone", "清除选择"),
        ("deploy.selectedCount", "已选 {0} / {1}"),
        ("deploy.action", "一键部署"),
        ("deploy.running", "正在部署…"),
        ("deploy.retry", "重试"),
        ("deploy.refreshSigning", "续签"),
        ("deploy.refreshSigningHint", "对最近一次部署或导出的 IPA 原地重签并覆盖安装（续上免费 Apple ID 的 7 天签名）。不会新增游戏或更新 GamePack（需要时请点“部署”）。没有可用 IPA 时不可用。"),
        ("deploy.refreshSigningRunning", "正在重签最近的 IPA…"),
        ("deploy.refreshSigningDone", "签名已续期并完成安装，数据保留。"),
        ("deploy.refreshSigningNoIpa", "暂无可续签的 IPA：请先部署一次，或导出“可自签安装包”。"),
        ("deploy.refreshSigningNoInstaller", "未找到内置 Impactor/plumesign：请重新安装启动器包。"),
        ("deploy.refreshSigningFailed", "续签失败：{0}"),
        ("deploy.idleTitle", "可以开始部署"),
        ("deploy.idleBody", "勾选要发送的游戏，然后点击“一键部署”。"),
        ("deploy.doneTitle", "完成 —— 可以在手机上玩了"),
        ("deploy.doneBody", "App 和所选游戏的 ROM 数据已经写入手机。请安全断开连接，然后在设备上打开 3ds2apple。"),
        ("deploy.failedTitle", "部署失败"),
        ("deploy.failedAt", "失败步骤：{0}"),
        ("deploy.failedHelp", "修复上面的问题后点击“重试”。已完成的工作会保留：已编译的 pack 和已推送的文件会复用。"),
        ("deploy.step.build", "1 · 编译游戏"),
        ("deploy.step.compose", "2 · 合成 App IPA"),
        ("deploy.step.install", "3 · 签名安装"),
        ("deploy.step.push", "4 · 推送 ROM 数据"),
        ("deploy.step.verify", "5 · 手机端校验"),
        ("deploy.step.pending", "等待"),
        ("deploy.step.running", "进行中"),
        ("deploy.step.succeeded", "完成"),
        ("deploy.step.failed", "失败"),
        ("deploy.step.skipped", "跳过"),
        ("deploy.games.title", "本次部署的游戏"),
        ("deploy.noGames", "还没有导入游戏，请先在“游戏库”添加。"),
        ("deploy.needSelection", "请至少勾选一个游戏。"),
        ("deploy.needShell", "安装包里缺少不含 ROM 的基础壳模板。请重新安装启动器 ZIP 后重试。"),
        ("deploy.toolchain.title", "本地编译组件"),
        ("deploy.toolchain.ready", "已就绪：本地编译（3dsrecomp + LLVM）、Impactor/plumesign 与 devpush。"),
        ("deploy.toolchain.missing", "缺少：{0}"),
        ("deploy.toolchain.fix", "请把 3dsrecomp.exe 和官方 LLVM 23.1.6 工具放到启动器的 Bin/（Bin/3dsrecomp.exe、Bin/llvm/bin/…），然后点击“重试”。这是唯一的编译路径，不会回退到 Mac。"),
        ("deploy.device", "手机：{0}"),
        ("deploy.deviceNone", "没有检测到手机。请用 USB 连接、解锁并点击“信任”，然后刷新。"),
        ("deploy.installed", "已安装 App：{0}"),
        ("deploy.notInstalled", "App 尚未安装 —— 部署时会先安装。"),
        ("deploy.deviceState.title", "设备状态"),
        ("deploy.deviceapp.version", "App v{0} · 包版本 {1} · 启动器外壳 {2}"),
        ("deploy.deviceapp.notInstalled", "手机尚未安装 App —— 下次部署会先安装。"),
        ("deploy.deviceapp.unknown", "未知"),
        ("deploy.deviceapp.unavailable", "无法读取 App 状态 —— 请用 USB 连接手机（已信任并解锁）后刷新。"),
        ("deploy.devicegames.none", "手机上还没有游戏数据。"),
        ("deploy.devicegames.some", "手机上有 {0} 个游戏 · 所选 {2} 个中 {1} 个已是最新"),
        ("deploy.plan.title", "部署计划"),
        ("deploy.mode.full", "安装 App 并推送 {0} 个游戏。"),
        ("deploy.mode.reinstall", "更新 App（保留 {0} 个游戏）并推送 {1} 个游戏。"),
        ("deploy.mode.push", "App 已是最新；推送 {0} 个缺失/过期游戏数据。"),
        ("deploy.mode.uptodate", "已是最新 —— 无需安装或推送。"),
        ("deploy.orphans.summary", "有 {0} 个游戏只存在于手机上、不在本机库中：{1}。它们的 GameRom 和存档保留在 Documents，但更新 App 会移除这些游戏的入口。"),
        ("deploy.orphans.blockedTitle", "已暂停更新：手机上有本机库没有的游戏"),
        ("deploy.orphans.blockedDetail", "本次更新会移除 {0} 个仅存在于手机上的游戏的入口：{1}。它们的 GameRom 和存档仍保留在 Documents —— 不会删除任何数据。"),
        ("deploy.orphans.confirmButton", "仍然更新（数据保留，游戏入口会消失）"),
        ("deploy.orphans.confirmHint", "如需保留这些游戏可玩，请先把对应 ROM 加入库并构建 GamePack。"),
        ("deploy.orphans.planSuffix", "（{0} 个仅手机上的游戏需要确认）"),
        ("deploy.state.idle", "空闲"),
        ("deploy.state.running", "进行中"),
        ("deploy.state.done", "完成"),
        ("deploy.state.failed", "失败"),
        ("deploy.log", "部署日志"),
        ("deploy.logShow", "显示日志"),
        ("deploy.logHide", "隐藏日志"),
        // Deploy 先决条件（task-20）：逐项状态灯。
        ("deploy.prereq.title", "部署前检查"),
        ("deploy.prereq.summary", "已就绪 {0} / {1} 项"),
        ("deploy.prereq.refresh", "刷新状态"),
        ("deploy.prereq.device.label", "iPhone/iPad 已连接"),
        ("deploy.prereq.device.hint", "用 USB 连接 iPhone/iPad，解锁并点击“信任”，然后刷新。"),
        ("deploy.prereq.signing.label", "签名工具就绪"),
        ("deploy.prereq.signing.note", "首次使用请在 Impactor 里登录你的 Apple ID；启动器不会接触密码。"),
        ("deploy.prereq.device.hintLinux", "用 USB 连接 iPhone/iPad，解锁并点按“信任”；需要 usbmuxd 正在运行。"),
        ("deploy.prereq.signing.labelLinux", "plumesign / Apple ID 登录"),
        ("deploy.prereq.signing.hintLinux", "请在设置中点“用 plumesign 登录”，在终端完成 Apple ID/2FA 提示后刷新。启动器不会看到密码。"),
        ("deploy.prereq.signing.noteLinux", "Apple ID 会话由官方 plumesign CLI 处理（~/.config/PlumeImpactor）；启动器只检查是否已保存账号。"),
        ("deploy.prereq.toolchain.labelLinux", "本地 AOT 编译（Linux）"),
        ("deploy.prereq.toolchain.hintLinux", "Linux 载荷应包含 3dsrecomp 与开源 LLVM 的 clang/llvm-ar/ld64.lld 子集（Bin/llvm）及 Darwin stubs；请用 launcher/linux/build-linux.sh --payload --local-aot 重新打包后刷新。"),
        ("deploy.prereq.bridge.labelLinux", "devpush 设备桥（Linux）"),
        ("deploy.prereq.bridge.hintLinux", "请把 Linux devpush 构建放到 Bin/devpush（P3 打包），启动 usbmuxd，连接并解锁/信任 iPhone/iPad 后刷新。"),
        ("deploy.prereq.shell.hintLinux", "请在 Linux 包中放入 Shell/3ds2apple-shell.ipa 与 manifest.json（来自 macOS 构建），然后刷新。"),
        ("deploy.prereq.signing.hint", "内置的 Impactor v2.7.3/plumesign 缺失或被修改 —— 请重新安装启动器 ZIP 后刷新。"),
        ("deploy.prereq.toolchain.label", "本地编译工具链就绪"),
        ("deploy.prereq.toolchain.hint", "请把 3dsrecomp.exe 和官方 LLVM 23.1.6 工具放到 Bin/（Bin/llvm/bin/…），然后刷新。"),
        ("deploy.prereq.toolchain.hint.missing", "缺少 {0} —— 请把 3dsrecomp.exe 和官方 LLVM 23.1.6 工具放到 Bin/（Bin/llvm/bin/…），然后刷新。"),
        ("deploy.prereq.bridge.label", "设备桥（devpush）就绪"),
        ("deploy.prereq.bridge.hint", "devpush.exe 缺失或无法枚举设备 —— 请重新安装启动器 ZIP，确认 Apple Devices（或 iTunes）正在运行，然后刷新。"),
        ("deploy.prereq.shell.label", "Shell 模板就绪"),
        ("deploy.prereq.shell.hint", "内置的不含 ROM 的 Shell 模板缺失或与 Shell/manifest.json 不一致 —— 请重新安装启动器 ZIP 后刷新。"),
        ("settings.logsExport", "导出日志…"),
        ("settings.logsExported", "日志已导出到 {0}。"),
        ("settings.exportFailed", "导出日志失败：{0}"),
        ("settings.bundleId", "已安装 Bundle ID：{0}"),
        ("library.card.publisher", "发行商：{0}"),
        ("deploy.hardware", "硬件：{0} 逻辑 / {1} 物理核心 · {2} GB 内存（可用 {3} GB）· 3dsrecomp 自动并行编译，无需设置任务数"),
        ("settings.workspaceInfo", "游戏/状态目录：{0} · {1}"),
        ("settings.distributionInfo", "随包工具目录：{0} · {1}"),
        ("layout.portable", "位于启动器旁（目录可写）"),
        ("layout.localAppData", "回退到 LocalAppData（启动器目录不可写）"),
        ("layout.explicit", "手动指定"),
        ("layout.temp", "回退到临时目录"),
        // --- task-21：游戏库“立即构建”+ 构建缓存标签（仅追加；中英 key 保持同步）。---
        ("library.buildNow", "立即构建"),
        ("library.buildAll", "全部构建"),
        // --- 0.2.2：便携 .32a 构建包（游戏库导出/导入；用户数据，绝不上传）。---
        ("library.import.noUsableFiles", "未导入任何内容：{0}"),
        ("library.buildPackage.confirmReplace", "覆盖现有包"),
        ("library.buildPackage.exported", "已导出：{0}"),
        ("library.buildPackage.exportFailed", "导出失败：{0}"),
        ("library.buildPackage.imported", "已导入 {0} 到 {1}"),
        ("library.buildPackage.cacheRecorded", "已记录构建缓存——可直接部署，无需重新编译。"),
        ("library.buildPackage.cacheMismatch", "构建方法或工具链不同——下次部署会重新编译。"),
        ("library.buildPackage.cacheNoRom", "未内嵌游戏数据——无法记录构建缓存；部署需要原始 ROM。"),
        ("library.buildPackage.cacheMissing", "该包没有 manifest（旧版 CLI）——下次部署会重新编译。"),
        ("library.buildPackage.importFailed", "导入失败：{0}"),
        ("library.buildPackage.conflict", "该游戏已存在构建包。{0}"),

        ("status.buildPackageExport", "正在导出 .32a 构建包…"),
        ("status.buildPackageExportFailed", "构建包导出失败。"),
        ("status.buildPackageExported", "构建包已导出。"),
        ("status.buildPackageImport", "正在导入 .32a 构建包…"),
        ("status.buildPackageImportFailed", "构建包导入失败。"),
        ("status.buildPackageImported", "构建包已导入。"),
        ("status.buildPackageConflict", "请选择是否覆盖现有构建包。"),
        // --- 0.2.2：未签名单游戏 IPA 导出（游戏库行“导出 IPA”）。---
        ("library.export", "导出"),
        ("library.export.title", "导出 {0}"),
        ("library.export.formatBuildPackage", "已完成构建包"),
        ("library.export.formatIpa", "可自签安装包"),
        ("library.export.destinationBuildPackage", "导出文件夹（默认 workspace/export/32a）"),
        ("library.export.destinationIpa", "保存 IPA 到（默认 workspace/export/ipa）"),
        ("library.export.warningsBuildPackage", "可能包含你自己的游戏数据；仅保存在本地，切勿上传、外传或提交。"),
        ("library.export.warningsIpa", "包含你自己的游戏数据且未签名：请自行用 Sideloadly 或 AltStore 签名；仅保存在本地，切勿上传或外传。"),
        ("library.export.browse", "选择…"),
        ("library.export.confirm", "导出"),
        ("library.export.cancel", "取消"),
        ("library.ipaExported", "已导出：{0}"),
        ("library.ipaExportFailed", "IPA 导出失败：{0}"),
        ("library.ipaNeedsPack", "请先构建 GamePack：只有真实 AOT 包才能导出。"),
        ("library.ipaLibraryUnavailable", "外壳模板缺失：请重新安装启动器包，使 Shell/ 包含无 ROM 模板。"),
        ("library.ipaNeedsRom", "需要该游戏的 ROM：单游戏 IPA 会内嵌游戏数据。请重新导入 ROM（或恢复原文件）后再导出。"),
        ("status.exportIpa", "正在组合单游戏 IPA…"),
        ("status.ipaExported", "单游戏 IPA 已导出。"),
        ("status.ipaExportFailed", "单游戏 IPA 导出失败。"),
        // --- 0.2.2：部署页 → 高级构建设置（AOT 代码生成选项）。---
        ("settings.advanced.title", "高级构建设置"),
        ("settings.advanced.body", "应用于下一次构建。默认值保持现有行为；改动选项会让受影响游戏的构建缓存失效（下次构建/部署时重新编译）。"),
        ("settings.advanced.optLevel", "优化级别（默认 O2）"),
        ("settings.advanced.optLevelHint", "O1 / O2 / O3 / Oz。级别越高端构建越慢，游戏性能可能更好（依赖前请在真机上测量）。"),
        ("settings.advanced.lto", "链接时优化 LTO（默认关）"),
        ("settings.advanced.ltoHint", "启用 -flto：构建/链接时间更长，性能可能略有提升。"),
        ("settings.advanced.fastMath", "fast-math（默认关）"),
        ("settings.advanced.fastMathHint", "会改变 guest 浮点结果，仅用于测量/实验；默认发布构建不会开启。"),
        ("settings.advanced.summary", "当前：{0}。构建缓存 key 已包含这些选项。"),
        ("settings.advanced.reset", "恢复默认值"),
        ("library.buildStatus.built", "已构建 · 缓存 {0}"),
        ("library.buildStatus.noRecord", "已构建 · 暂无缓存标记（下次将重新编译）"),
        ("library.buildStatus.rebuildCompat", "需重新构建 · 构建方式已变更"),
        ("library.buildStatus.rebuildRom", "需重新构建 · ROM 已变更"),
        ("status.buildSummary", "构建完成：新建 {0} 个，复用 {1} 个，失败 {2} 个。"),
        // --- task-25：Deploy 停止/取消（仅追加；中英 key 保持同步）。---
        ("deploy.stop", "停止"),
        ("deploy.stopping", "正在停止…"),
        ("deploy.state.cancelled", "已取消"),
        ("deploy.step.cancelled", "已取消"),
        ("deploy.cancelledTitle", "部署已取消"),
        ("deploy.cancelledBody", "部署未完成时被停止。已编译好的 GamePack 会保留并在下次复用；点击“一键部署”可重新开始。"),
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