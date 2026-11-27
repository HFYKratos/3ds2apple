using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Localization;

namespace ThreeDsTwoApple.Launcher.App.ViewModels;

/// <summary>
/// Strongly typed view of the localized UI strings for the v2 two-section launcher.
/// The view model replaces the instance when the language changes so every XAML
/// binding re-evaluates.
/// </summary>
public sealed class LocalizedText
{
    // Identity / navigation
    public string AppTitle => Loc.T("app.title");
    public string NavLibrary => Loc.T("nav.library");
    public string NavDeploy => Loc.T("nav.deploy");
    public string NavSettings => Loc.T("nav.settings");
    public string NavLibraryHint => Loc.T("nav.libraryHint");
    public string NavDeployHint => Loc.T("nav.deployHint");

    // Library
    public string LibraryTitle => Loc.T("library.title");
    public string LibrarySubtitle => Loc.T("library.subtitle");
    public string LibraryEmptyTitle => Loc.T("library.empty.title");
    public string LibraryEmptyBody => Loc.T("library.empty.body");
    public string LibraryEmptyAction => Loc.T("library.empty.action");
    public string LibraryImportTitle => Loc.T("library.import.title");
    public string LibraryImportAction => Loc.T("library.import.action");
    public string LibraryCardRemove => Loc.T("library.card.remove");
    public string LibraryCardRename => Loc.T("library.card.rename");
    public string LibraryCardNotBuilt => Loc.T("library.card.notBuilt");
    public string LibraryRefresh => Loc.T("library.refresh");
    public string LibraryMore => Loc.T("library.more");

    // Library "Build now" / build-cache labels (task-21).
    public string LibraryBuildNow => Loc.T("library.buildNow");
    public string LibraryBuildAll => Loc.T("library.buildAll");

    // Library portable build packages (.32a export/import).
    public string LibraryExport => Loc.T("library.export");
    public string LibraryConfirmImportReplace => Loc.T("library.buildPackage.confirmReplace");

    // Library -> single Export dialog (format + destination + warnings).
    public string ExportFormatBuildPackage => Loc.T("library.export.formatBuildPackage");
    public string ExportFormatIpa => Loc.T("library.export.formatIpa");
    public string ExportBrowse => Loc.T("library.export.browse");
    public string ExportConfirm => Loc.T("library.export.confirm");
    public string ExportCancel => Loc.T("library.export.cancel");

    // Deploy
    public string DeployTitle => Loc.T("deploy.title");
    public string DeploySubtitle => Loc.T("deploy.subtitle");
    public string DeploySelectAll => Loc.T("deploy.selectAll");
    public string DeploySelectNone => Loc.T("deploy.selectNone");
    public string DeployAction => Loc.T("deploy.action");
    public string DeployRunning => Loc.T("deploy.running");
    public string DeployRetry => Loc.T("deploy.retry");
    public string DeployRefreshSigning => Loc.T("deploy.refreshSigning");
    public string DeployRefreshSigningHint => Loc.T("deploy.refreshSigningHint");
    public string DeployIdleTitle => Loc.T("deploy.idleTitle");
    public string DeployIdleBody => Loc.T("deploy.idleBody");
    public string DeployDoneTitle => Loc.T("deploy.doneTitle");
    public string DeployDoneBody => Loc.T("deploy.doneBody");
    public string DeployFailedTitle => Loc.T("deploy.failedTitle");
    public string DeployFailedHelp => Loc.T("deploy.failedHelp");
    public string DeployStepBuild => Loc.T("deploy.step.build");
    public string DeployStepCompose => Loc.T("deploy.step.compose");
    public string DeployStepInstall => Loc.T("deploy.step.install");
    public string DeployStepPush => Loc.T("deploy.step.push");
    public string DeployStepVerify => Loc.T("deploy.step.verify");
    public string DeployGamesTitle => Loc.T("deploy.games.title");
    public string DeployNoGames => Loc.T("deploy.noGames");
    public string DeployNeedShell => Loc.T("deploy.needShell");
    public string DeployToolchainTitle => Loc.T("deploy.toolchain.title");
    public string DeployToolchainReady => Loc.T("deploy.toolchain.ready");
    public string DeployToolchainFix => Loc.T("deploy.toolchain.fix");
    public string DeployDeviceNone => Loc.T("deploy.deviceNone");
    public string DeployNotInstalled => Loc.T("deploy.notInstalled");
    public string DeployDeviceStateTitle => Loc.T("deploy.deviceState.title");
    public string DeployDeviceAppNotInstalled => Loc.T("deploy.deviceapp.notInstalled");
    public string DeployDeviceGamesNone => Loc.T("deploy.devicegames.none");
    public string DeployPlanTitle => Loc.T("deploy.plan.title");
    public string DeployOrphansBlockedTitle => Loc.T("deploy.orphans.blockedTitle");
    public string DeployOrphansConfirmHint => Loc.T("deploy.orphans.confirmHint");
    public string DeployOrphansConfirmButton => Loc.T("deploy.orphans.confirmButton");
    public string DeployLog => Loc.T("deploy.log");
    public string DeployLogShow => Loc.T("deploy.logShow");
    public string DeployLogHide => Loc.T("deploy.logHide");

    // Deploy stop / cancellation (task-25).
    public string DeployStop => Loc.T("deploy.stop");
    public string DeployStopping => Loc.T("deploy.stopping");
    public string DeployCancelledTitle => Loc.T("deploy.cancelledTitle");
    public string DeployCancelledBody => Loc.T("deploy.cancelledBody");

    // Deploy prerequisites (task-20): one green/red status light per row.
    public string DeployPrereqTitle => Loc.T("deploy.prereq.title");
    public string DeployPrereqRefresh => Loc.T("deploy.prereq.refresh");
    public string DeployPrereqSigningNote => Loc.T("deploy.prereq.signing.note");

    public string DeployPrereqSummary(int ready, int total) => Loc.T("deploy.prereq.summary", ready, total);

    public string DeployPrereqLabel(DeployPrerequisiteKind kind) => kind switch
    {
        DeployPrerequisiteKind.DeviceConnected => Loc.T("deploy.prereq.device.label"),
        DeployPrerequisiteKind.SigningTools => Loc.T("deploy.prereq.signing.label"),
        DeployPrerequisiteKind.LocalToolchain => Loc.T("deploy.prereq.toolchain.label"),
        DeployPrerequisiteKind.DeviceBridge => Loc.T("deploy.prereq.bridge.label"),
        DeployPrerequisiteKind.ShellTemplate => Loc.T("deploy.prereq.shell.label"),
        _ => kind.ToString(),
    };

    /// <summary>One short action for a red row; <paramref name="detail"/> is the missing tool list for the toolchain.</summary>
    public string DeployPrereqHint(DeployPrerequisiteKind kind, string detail) => kind switch
    {
        DeployPrerequisiteKind.DeviceConnected => Loc.T("deploy.prereq.device.hint"),
        DeployPrerequisiteKind.SigningTools => Loc.T("deploy.prereq.signing.hint"),
        DeployPrerequisiteKind.LocalToolchain => string.IsNullOrWhiteSpace(detail)
            ? Loc.T("deploy.prereq.toolchain.hint")
            : Loc.T("deploy.prereq.toolchain.hint.missing", detail),
        DeployPrerequisiteKind.DeviceBridge => Loc.T("deploy.prereq.bridge.hint"),
        DeployPrerequisiteKind.ShellTemplate => Loc.T("deploy.prereq.shell.hint"),
        _ => string.Empty,
    };

    // Settings -> Advanced build settings (AOT codegen options).
    public string SettingsAdvancedTitle => Loc.T("settings.advanced.title");
    public string SettingsAdvancedBody => Loc.T("settings.advanced.body");
    public string SettingsAdvancedOptLevel => Loc.T("settings.advanced.optLevel");
    public string SettingsAdvancedOptLevelHint => Loc.T("settings.advanced.optLevelHint");
    public string SettingsAdvancedLto => Loc.T("settings.advanced.lto");
    public string SettingsAdvancedLtoHint => Loc.T("settings.advanced.ltoHint");
    public string SettingsAdvancedFastMath => Loc.T("settings.advanced.fastMath");
    public string SettingsAdvancedFastMathHint => Loc.T("settings.advanced.fastMathHint");
    public string SettingsAdvancedReset => Loc.T("settings.advanced.reset");

    // Settings
    public string SettingsTitle => Loc.T("settings.title");
    public string SettingsClose => Loc.T("settings.close");
    public string SettingsAppleTitle => Loc.T("settings.appleTitle");
    public string SettingsAppleBody => Loc.T("settings.appleBody");
    public string SettingsAppleOpen => Loc.T("settings.appleOpen");
    public string AppImpactorNote => Loc.T("app.impactorNote");
    public string SettingsDeviceTitle => Loc.T("settings.deviceTitle");
    public string DeviceRefresh => Loc.T("device.refresh");
    public string DevicePrereqUsb => Loc.T("device.prereqUsb");
    public string DevicePrereqTrust => Loc.T("device.prereqTrust");
    public string DevicePrereqUnlock => Loc.T("device.prereqUnlock");
    public string SettingsLanguageTitle => Loc.T("settings.languageTitle");
    public string SettingsLanguageBody => Loc.T("settings.languageBody");
    public string SettingsLogsTitle => Loc.T("settings.logsTitle");
    public string SettingsLogsShow => Loc.T("settings.logsShow");
    public string SettingsLogsHide => Loc.T("settings.logsHide");
    public string SettingsLogsSelfTest => Loc.T("settings.logsSelfTest");
    public string SettingsLogsWorkspace => Loc.T("settings.logsWorkspace");
    public string SettingsLogsExport => Loc.T("settings.logsExport");
    public string SettingsAboutTitle => Loc.T("settings.aboutTitle");
    public string SettingsAboutBody => Loc.T("settings.aboutBody", LauncherInfo.Version);
    public string SettingsVersion => Loc.T("settings.version", LauncherInfo.Version);
    public string ReadinessTitle => Loc.T("readiness.title");
    public string ReadinessStatusReady => Loc.T("readiness.status.ready");
    public string ReadinessStatusFailed => Loc.T("readiness.status.failed");
    public string ReadinessStatusChecking => Loc.T("readiness.status.checking");
    public string ReadinessRetryHint => Loc.T("readiness.status.retryHint");

    // Common
    public string CommonBrowse => Loc.T("common.browse");
    public string CommonClose => Loc.T("common.close");
    public string CommonNone => Loc.T("common.none");
}
