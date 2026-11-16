using ThreeDsTwoApple.Launcher.Core;
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

    // Deploy
    public string DeployTitle => Loc.T("deploy.title");
    public string DeploySubtitle => Loc.T("deploy.subtitle");
    public string DeploySelectAll => Loc.T("deploy.selectAll");
    public string DeploySelectNone => Loc.T("deploy.selectNone");
    public string DeployAction => Loc.T("deploy.action");
    public string DeployRunning => Loc.T("deploy.running");
    public string DeployRetry => Loc.T("deploy.retry");
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
    public string DeployLog => Loc.T("deploy.log");
    public string DeployLogShow => Loc.T("deploy.logShow");
    public string DeployLogHide => Loc.T("deploy.logHide");

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
