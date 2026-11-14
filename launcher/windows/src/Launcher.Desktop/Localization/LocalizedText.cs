using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.Localization;

namespace ThreeDsTwoApple.Launcher.App.ViewModels;

/// <summary>
/// Strongly typed view of the localized UI strings. The view model replaces the instance
/// when the language changes so every XAML binding re-evaluates.
/// </summary>
public sealed class LocalizedText
{
    public string AppTitle => Loc.T("app.title");
    public string AppSubtitle => Loc.T("app.subtitle");
    public string NavLibrary => Loc.T("nav.library");
    public string NavImport => Loc.T("nav.import");
    public string NavSettings => Loc.T("nav.settings");
    public string NavBack => Loc.T("nav.back");

    public string LibraryTitle => Loc.T("library.title");
    public string LibrarySubtitle => Loc.T("library.subtitle");
    public string LibraryEmptyTitle => Loc.T("library.empty.title");
    public string LibraryEmptyBody => Loc.T("library.empty.body");
    public string LibraryEmptyAction => Loc.T("library.empty.action");
    public string LibraryRefresh => Loc.T("library.refresh");
    public string LibraryInstall => Loc.T("library.install");
    public string LibraryInstallHint => Loc.T("library.installHint");
    public string LibraryCardMore => Loc.T("library.card.more");
    public string LibraryCardPush => Loc.T("library.card.push");
    public string LibraryCardVerify => Loc.T("library.card.verify");
    public string LibraryCardInstall => Loc.T("library.card.install");
    public string LibraryCardRemove => Loc.T("library.card.remove");

    public string ImportTitle => Loc.T("import.title");
    public string ImportBody => Loc.T("import.body");
    public string ImportPath => Loc.T("import.path");
    public string ImportPathPlaceholder => Loc.T("import.pathPlaceholder");
    public string ImportBrowse => Loc.T("import.browse");
    public string ImportName => Loc.T("import.name");
    public string ImportNamePlaceholder => Loc.T("import.namePlaceholder");
    public string ImportAction => Loc.T("import.action");
    public string ImportStepsTitle => Loc.T("import.steps.title");
    public string ImportStepBuild => Loc.T("import.step.build");
    public string ImportStepInstall => Loc.T("import.step.install");
    public string ImportStepPush => Loc.T("import.step.push");
    public string ImportSuccessHint => Loc.T("import.successHint");

    public string BuildTitle => Loc.T("build.title");
    public string BuildModePreview => Loc.T("build.mode.preview");
    public string BuildModeMacAgent => Loc.T("build.mode.macagent");
    public string BuildModeLocal => Loc.T("build.mode.local");
    public string BuildMode => Loc.T("build.mode");
    public string BuildHost => Loc.T("build.host");
    public string BuildHostPlaceholder => Loc.T("build.hostPlaceholder");
    public string BuildAction => Loc.T("build.action");
    public string BuildNote => Loc.T("build.note");
    public string BuildPreviewNote => Loc.T("build.previewNote");
    public string BuildNoneSelected => Loc.T("build.noneSelected");

    public string DeviceTitle => Loc.T("device.title");
    public string DeviceRefresh => Loc.T("device.refresh");
    public string DevicePrereqTitle => Loc.T("device.prereqTitle");
    public string DevicePrereqUsb => Loc.T("device.prereqUsb");
    public string DevicePrereqTrust => Loc.T("device.prereqTrust");
    public string DevicePrereqUnlock => Loc.T("device.prereqUnlock");

    public string AppSectionTitle => Loc.T("app.sectionTitle");
    public string AppSectionBody => Loc.T("app.sectionBody");
    public string AppInstall => Loc.T("app.install");
    public string AppOpenImpactor => Loc.T("app.openImpactor");
    public string AppImpactorNote => Loc.T("app.impactorNote");

    public string PushTitle => Loc.T("push.title");
    public string PushBody => Loc.T("push.body");
    public string PushAction => Loc.T("push.action");
    public string PushVerify => Loc.T("push.verify");
    public string PushResumeNote => Loc.T("push.resumeNote");

    public string SettingsTitle => Loc.T("settings.title");
    public string SettingsClose => Loc.T("settings.close");
    public string SettingsAppleTitle => Loc.T("settings.appleTitle");
    public string SettingsAppleBody => Loc.T("settings.appleBody");
    public string SettingsAppleOpen => Loc.T("settings.appleOpen");
    public string SettingsDeviceTitle => Loc.T("settings.deviceTitle");
    public string SettingsBuildTitle => Loc.T("settings.buildTitle");
    public string SettingsBuildLocal => Loc.T("settings.buildLocal");
    public string SettingsBuildRecomp => Loc.T("settings.buildRecomp");
    public string SettingsBuildLlvm => Loc.T("settings.buildLlvm");
    public string SettingsToolsTitle => Loc.T("settings.toolsTitle");
    public string SettingsToolsBody => Loc.T("settings.toolsBody");
    public string SettingsToolsPack => Loc.T("settings.toolsPack");
    public string SettingsToolsDevPush => Loc.T("settings.toolsDevPush");
    public string SettingsToolsBuilder => Loc.T("settings.toolsBuilder");
    public string SettingsToolsMock => Loc.T("settings.toolsMock");
    public string SettingsToolsBundle => Loc.T("settings.toolsBundle");
    public string SettingsLanguageTitle => Loc.T("settings.languageTitle");
    public string SettingsLanguageBody => Loc.T("settings.languageBody");
    public string SettingsLogsTitle => Loc.T("settings.logsTitle");
    public string SettingsLogsShow => Loc.T("settings.logsShow");
    public string SettingsLogsHide => Loc.T("settings.logsHide");
    public string SettingsLogsSelfTest => Loc.T("settings.logsSelfTest");
    public string SettingsLogsWorkspace => Loc.T("settings.logsWorkspace");
    public string SettingsSave => Loc.T("settings.save");
    public string SettingsReadiness => Loc.T("settings.readiness");
    public string SettingsAboutTitle => Loc.T("settings.aboutTitle");
    public string ReadinessTitle => Loc.T("readiness.title");
    public string ReadinessUnchecked => Loc.T("readiness.unchecked");
    public string CommonBrowse => Loc.T("common.browse");
    public string CommonSave => Loc.T("common.save");
    public string CommonClose => Loc.T("common.close");

    public string SettingsAboutBody => Loc.T("settings.aboutBody", LauncherInfo.Version);
    public string SettingsVersion => Loc.T("settings.version", LauncherInfo.Version);
    public string SettingsDistribution => Loc.T("settings.distribution", DistributionLayout.Resolve());
    public string SettingsLogsPath => Loc.T("settings.logsPath", System.IO.Path.Combine(DistributionLayout.LauncherDataRoot(), "launcher", "logs"));
}