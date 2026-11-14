using System.Collections.ObjectModel;
using System.Globalization;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Localization;

namespace ThreeDsTwoApple.Launcher.App.ViewModels;

/// <summary>One row of the launcher game library (card in the Library section).</summary>
public sealed class GameRow : ObservableObject
{
    private readonly MainViewModel _owner;
    private string _state = "imported";

    public GameRow(MainViewModel owner, LibraryEntry entry)
    {
        _owner = owner;
        Entry = entry;
        BuildCommand = new AsyncRelayCommand(() => _owner.RunBuildForAsync(this), () => !_owner.IsBusy);
        PushCommand = new AsyncRelayCommand(() => _owner.RunPushForAsync(this), () => !_owner.IsBusy);
        VerifyCommand = new AsyncRelayCommand(() => _owner.RunVerifyForAsync(this), () => !_owner.IsBusy);
        InstallCommand = new AsyncRelayCommand(() => _owner.RunInstallForAsync(this), () => !_owner.IsBusy);
        RemoveCommand = new AsyncRelayCommand(() => _owner.RunRemoveForAsync(this), () => !_owner.IsBusy);
        PrimaryCommand = new AsyncRelayCommand(() => _owner.RunPrimaryAsync(this), () => !_owner.IsBusy);
    }

    public LibraryEntry Entry { get; }

    public string TitleID => Entry.TitleID;
    public string DisplayName => string.IsNullOrWhiteSpace(Entry.DisplayNameOverride) ? Entry.DisplayName : Entry.DisplayNameOverride;
    public string RomPath => Entry.RomPath;
    public string? ProductCode => Entry.ProductCode;

    public string State
    {
        get => _state;
        private set => SetProperty(ref _state, value);
    }

    /// <summary>Localized state label for the card badge.</summary>
    public string StateLabel => State switch
    {
        "imported" => Loc.T("library.card.state.imported"),
        "queued" => Loc.T("library.card.state.queued"),
        "built" => Loc.T("library.card.state.built"),
        "preview" => Loc.T("library.card.state.preview"),
        "build_failed" => Loc.T("library.card.state.build_failed"),
        "pushed" => Loc.T("library.card.state.pushed"),
        _ => State,
    };

    public string TitleIdLine => Loc.T("library.card.titleid", TitleID);

    public string RomLine => Loc.T("library.card.rom", RomPath);

    public bool HasRealPack => Entry.Pack is { IsPlaceholder: false };

    public bool IsPushed => Entry.PushedAt is not null;

    /// <summary>One status line under the game name.</summary>
    public string PackLine => Entry.Pack is null
        ? Loc.T("library.card.pack.none")
        : Entry.Pack.IsPlaceholder
            ? Loc.T("library.card.pack.placeholder", FormatBytes(Entry.Pack.Bytes))
            : Loc.T("library.card.pack.built", FormatBytes(Entry.Pack.Bytes), Entry.Pack.Sha256[..12]);

    /// <summary>The single primary action for this card (build / install / push / verify).</summary>
    public string PrimaryLabel => _owner.PrimaryAction(this) switch
    {
        CardAction.Build => Loc.T("library.card.primary.build"),
        CardAction.Install => Loc.T("library.card.primary.install"),
        CardAction.Push => Loc.T("library.card.primary.push"),
        _ => Loc.T("library.card.primary.verify"),
    };

    public string MoreLabel => Loc.T("library.card.more");
    public string BuildLabel => Loc.T("library.card.primary.build");
    public string PushLabel => Loc.T("library.card.push");
    public string VerifyLabel => Loc.T("library.card.verify");
    public string InstallLabel => Loc.T("library.card.install");
    public string RemoveLabel => Loc.T("library.card.remove");

    public AsyncRelayCommand PrimaryCommand { get; }
    public AsyncRelayCommand BuildCommand { get; }
    public AsyncRelayCommand PushCommand { get; }
    public AsyncRelayCommand VerifyCommand { get; }
    public AsyncRelayCommand InstallCommand { get; }
    public AsyncRelayCommand RemoveCommand { get; }

    public void Refresh()
    {
        State = Entry.Pack is null
            ? Entry.State
            : Entry.Pack.IsPlaceholder ? "preview" : "built";
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(PackLine));
        OnPropertyChanged(nameof(PrimaryLabel));
        OnPropertyChanged(nameof(DisplayName));
        OnPropertyChanged(nameof(HasRealPack));
        OnPropertyChanged(nameof(IsPushed));
        OnPropertyChanged(nameof(MoreLabel));
        OnPropertyChanged(nameof(BuildLabel));
        OnPropertyChanged(nameof(PushLabel));
        OnPropertyChanged(nameof(VerifyLabel));
        OnPropertyChanged(nameof(InstallLabel));
        OnPropertyChanged(nameof(RemoveLabel));
    }

    public void RaiseCommandStates()
    {
        PrimaryCommand.RaiseCanExecuteChanged();
        BuildCommand.RaiseCanExecuteChanged();
        PushCommand.RaiseCanExecuteChanged();
        VerifyCommand.RaiseCanExecuteChanged();
        InstallCommand.RaiseCanExecuteChanged();
        RemoveCommand.RaiseCanExecuteChanged();
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.00} GiB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.0} MiB",
        _ => $"{bytes} B",
    };
}

/// <summary>One row of the tools/readiness panel.</summary>
public sealed record ToolRow(string Name, string State, string Message)
{
    public bool Ready => State == "ready";

    public string StateLabel => State switch
    {
        "ready" => Loc.T("tool.state.ready"),
        "missing" => Loc.T("tool.state.missing"),
        "failed" => Loc.T("tool.state.failed"),
        _ => State,
    };
}

/// <summary>A selectable build mode with its localized label.</summary>
public sealed record BuildModeOption(PackBuildMode Mode, string Label);

/// <summary>A selectable UI language with its localized label.</summary>
public sealed record LanguageChoice(UiLanguagePreference Preference, string Label);

/// <summary>The one primary action shown on a library card.</summary>
public enum CardAction
{
    Build,
    Install,
    Push,
    Verify,
}

/// <summary>Main window view model: implements the S2Arm-style flow
/// library -> build -> install base shell -> push game files.</summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly LauncherServices _services;
    private GameRow? _selectedGame;
    private DeviceInfo? _selectedDevice;
    private ShellManifest? _shell;
    private bool _isBusy;
    private LocalizedText _localized = new();
    private LanguageChoice? _selectedLanguage;
    private BuildModeOption? _selectedBuildMode;
    private UiLanguagePreference _languagePreference = UiLanguagePreference.System;
    private string _section = "library";
    private bool _showSettings;
    private bool _showDiagnostics;
    private bool _importRunning;
    private string _statusText = string.Empty;
    private string _header = string.Empty;
    private double _progressValue;
    private string _deviceStatus = string.Empty;
    private string _shellStatus = string.Empty;
    private string _pushStatus = string.Empty;
    private string _importPath = string.Empty;
    private string _displayNameOverride = string.Empty;
    private string _buildHost = string.Empty;
    private string _packPathSetting = string.Empty;
    private string _devPushPathSetting = string.Empty;
    private string _builderPathSetting = string.Empty;
    private string _bundleIdOverride = string.Empty;
    private string _mockDirectory = string.Empty;
    private bool _localBuildEnabled;
    private string _recompPathSetting = string.Empty;
    private string _llvmDirSetting = string.Empty;

    public MainViewModel() : this(LauncherServices.Create())
    {
    }

    public MainViewModel(LauncherServices services)
    {
        _services = services;
        _languagePreference = LanguageCatalog.ParsePreference(_services.Workspace.State.Language);
        Loc.ApplyPreference(_languagePreference, CultureInfo.CurrentUICulture.Name);
        Header = $"3ds2apple Launcher (Windows) · {LauncherInfo.Version}";
        StatusText = Loc.T("status.ready");
        DeviceStatus = Loc.T("device.none");
        ShellStatus = Loc.T("shell.missing");
        PushStatus = Loc.T("push.noPack");
        ImportCommand = new AsyncRelayCommand(() => ImportFromBoxAsync(), () => !IsBusy);
        BrowseRomCommand = new RelayCommand(RequestBrowseRom);
        RemoveGameCommand = new AsyncRelayCommand(() => RemoveSelectedAsync(), () => SelectedGame is not null && !IsBusy);
        BuildSelectedCommand = new AsyncRelayCommand(() => BuildSelectedAsync(), () => SelectedGame is not null && !IsBusy);
        RefreshStatusCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        RefreshDevicesCommand = new AsyncRelayCommand(() => RefreshDevicesAsync(), () => !IsBusy);
        InstallShellCommand = new AsyncRelayCommand(() => InstallShellAsync(), () => !IsBusy);
        OpenImpactorCommand = new RelayCommand(() => OpenImpactor(), () => !IsBusy);
        PushSelectedCommand = new AsyncRelayCommand(() => PushSelectedAsync(), () => SelectedGame is not null && !IsBusy);
        VerifyPushCommand = new AsyncRelayCommand(() => VerifyPushAsync(), () => SelectedGame is not null && !IsBusy);
        SaveSettingsCommand = new AsyncRelayCommand(() => SaveSettingsAsync(), () => !IsBusy);
        RunSelfTestCommand = new RelayCommand(() => RunSelfTest(), () => !IsBusy);
        OpenWorkspaceCommand = new RelayCommand(OpenWorkspace);
        ShowLibraryCommand = new RelayCommand(ShowLibrary);
        ShowImportCommand = new RelayCommand(ShowImport);
        ShowSettingsCommand = new RelayCommand(OpenSettings);
        CloseSettingsCommand = new RelayCommand(CloseSettings);
        ToggleDiagnosticsCommand = new RelayCommand(ToggleDiagnostics);
        BuildHost = _services.Workspace.State.BuildHost ?? string.Empty;
        BundleIdOverride = _services.Workspace.State.ShellBundleIdOverride ?? string.Empty;
        MockDirectory = _services.Workspace.State.DevPushMockDirectory ?? string.Empty;
        LocalBuildEnabled = _services.Workspace.State.LocalBuildEnabled;
        RecompPathSetting = _services.Locator.OverrideFor(ToolLocator.RecompTool) ?? string.Empty;
        LlvmDirSetting = _services.Locator.OverrideFor(ToolLocator.LlvmTool) ?? string.Empty;
        PackPathSetting = _services.Locator.OverrideFor(ToolLocator.PackCliTool) ?? string.Empty;
        DevPushPathSetting = _services.Locator.OverrideFor(ToolLocator.DevPushTool) ?? string.Empty;
        BuilderPathSetting = _services.Locator.OverrideFor(ToolLocator.BuilderTool) ?? string.Empty;
        ResetBuildModes();
        RebuildLanguageOptions();
        Log($"workspace: {_services.Workspace.Root}");
        Log($"distribution: {_services.Locator.DistributionRoot}");
        Log("3ds2apple launcher started. Import your own decrypted .3ds/.cci ROM to begin.");
    }

    public ObservableCollection<GameRow> Games { get; } = new();

    /// <summary>Choices shown in the Build tab; the experimental local build is feature-flagged.</summary>
    /// <summary>Localized build-mode choices; the experimental local build stays behind the feature flag.</summary>
    public ObservableCollection<BuildModeOption> BuildModes { get; } = new();

    /// <summary>Localized language choices (System / English / 简体中文).</summary>
    public ObservableCollection<LanguageChoice> LanguageOptions { get; } = new();

    private void ResetBuildModes()
    {
        var wanted = new List<BuildModeOption>
        {
            new(PackBuildMode.Preview, L.BuildModePreview),
            new(PackBuildMode.MacAgentIpa, L.BuildModeMacAgent),
        };
        if (LocalBuildEnabled)
        {
            wanted.Add(new(PackBuildMode.LocalWinbuild, L.BuildModeLocal));
        }
        var current = _selectedBuildMode?.Mode ?? _services.Workspace.State.Mode;
        if (BuildModes.Count != wanted.Count || BuildModes.Where((option, index) => option != wanted[index]).Any())
        {
            BuildModes.Clear();
            foreach (var option in wanted)
            {
                BuildModes.Add(option);
            }
        }
        var match = BuildModes.FirstOrDefault(option => option.Mode == current) ?? BuildModes.FirstOrDefault();
        if (match is not null)
        {
            _selectedBuildMode = match;
            OnPropertyChanged(nameof(SelectedBuildMode));
            OnPropertyChanged(nameof(CurrentBuildModeLabel));
        }
    }

    private void RebuildLanguageOptions()
    {
        LanguageOptions.Clear();
        foreach (var preference in LanguageCatalog.AllPreferences)
        {
            LanguageOptions.Add(new LanguageChoice(preference, LanguageCatalog.DisplayName(preference, Loc.CurrentTag)));
        }
        _selectedLanguage = LanguageOptions.FirstOrDefault(option => option.Preference == _languagePreference) ?? LanguageOptions.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedLanguage));
    }
    public ObservableCollection<ToolRow> Tools { get; } = new();
    public ObservableCollection<DeviceInfo> Devices { get; } = new();
    public ObservableCollection<string> LogLines { get; } = new();

    public event Action? BrowseRomRequested;

    public AsyncRelayCommand ImportCommand { get; }
    public RelayCommand BrowseRomCommand { get; }
    public AsyncRelayCommand RemoveGameCommand { get; }
    public AsyncRelayCommand BuildSelectedCommand { get; }
    public AsyncRelayCommand RefreshStatusCommand { get; }
    public AsyncRelayCommand RefreshDevicesCommand { get; }
    public AsyncRelayCommand InstallShellCommand { get; }
    public RelayCommand OpenImpactorCommand { get; }
    public AsyncRelayCommand PushSelectedCommand { get; }
    public AsyncRelayCommand VerifyPushCommand { get; }
    public AsyncRelayCommand SaveSettingsCommand { get; }
    public RelayCommand RunSelfTestCommand { get; }
    public RelayCommand OpenWorkspaceCommand { get; }
    public RelayCommand ShowLibraryCommand { get; }
    public RelayCommand ShowImportCommand { get; }
    public RelayCommand ShowSettingsCommand { get; }
    public RelayCommand CloseSettingsCommand { get; }
    public RelayCommand ToggleDiagnosticsCommand { get; }

    /// <summary>Localized UI strings; replaced whenever the language changes.</summary>
    public LocalizedText L { get => _localized; private set => SetProperty(ref _localized, value); }

    public string WindowTitle => L.AppTitle + " · " + LauncherInfo.Version;

    public string Header { get => _header; private set => SetProperty(ref _header, value); }

    public bool IsLibrarySection => !_showSettings && _section == "library";

    public bool IsImportSection => !_showSettings && _section == "import";

    public bool ShowSettings => _showSettings;

    public bool ShowDiagnostics => _showDiagnostics;

    public string DiagnosticsToggleLabel => _showDiagnostics ? L.SettingsLogsHide : L.SettingsLogsShow;

    public bool HasGames => Games.Count > 0;

    public bool IsLibraryEmpty => Games.Count == 0;

    public string GameCountText => Loc.T("library.count", Games.Count);

    public bool IsImportRunning { get => _importRunning; private set => SetProperty(ref _importRunning, value); }

    public bool HasRealPacks => Games.Any(row => row.HasRealPack);

    public string DistributionRoot => _services.Locator.DistributionRoot;

    public string ShellBundleIdLine => Loc.T("app.bundleId", ShellBundleId);

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetProperty(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(IsNotBusy));
                RaiseCommandStates();
            }
        }
    }

    public bool IsNotBusy => !IsBusy;

    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    public double ProgressValue { get => _progressValue; private set => SetProperty(ref _progressValue, value); }

    public string ReadinessText => Tools.Count == 0
        ? Loc.T("readiness.unchecked")
        : Tools.All(tool => tool.Ready)
            ? Loc.T("readiness.all")
            : Loc.T("readiness.blocked", string.Join(", ", Tools.Where(tool => !tool.Ready).Select(tool => tool.Name)));

    public string ReadinessSummary => ReadinessText;

    public string ShellStatus { get => _shellStatus; private set => SetProperty(ref _shellStatus, value); }

    public string DeviceStatus { get => _deviceStatus; private set => SetProperty(ref _deviceStatus, value); }

    public string PushStatus { get => _pushStatus; private set => SetProperty(ref _pushStatus, value); }

    public string ImportPath { get => _importPath; set => SetProperty(ref _importPath, value); }

    public string DisplayNameOverride { get => _displayNameOverride; set => SetProperty(ref _displayNameOverride, value); }

    public string DeviceUdid
    {
        get => _services.Workspace.State.LastDeviceUdid ?? string.Empty;
        private set
        {
            _services.Workspace.State.LastDeviceUdid = string.IsNullOrWhiteSpace(value) ? null : value;
            OnPropertyChanged();
        }
    }

    public string BuildHost { get => _buildHost; set => SetProperty(ref _buildHost, value); }

    public BuildModeOption? SelectedBuildMode
    {
        get => _selectedBuildMode;
        set
        {
            if (SetProperty(ref _selectedBuildMode, value))
            {
                OnPropertyChanged(nameof(CurrentBuildModeLabel));
            }
        }
    }

    public string CurrentBuildModeLabel => _selectedBuildMode?.Label ?? L.BuildModePreview;

    /// <summary>Feature flag: enable the experimental local build (3dsrecomp + LLVM/LLD on this PC).</summary>
    public bool LocalBuildEnabled
    {
        get => _localBuildEnabled;
        set
        {
            if (SetProperty(ref _localBuildEnabled, value))
            {
                ResetBuildModes();
            }
        }
    }

    public string RecompPathSetting { get => _recompPathSetting; set => SetProperty(ref _recompPathSetting, value); }

    public string LlvmDirSetting { get => _llvmDirSetting; set => SetProperty(ref _llvmDirSetting, value); }

    public string PackPathSetting { get => _packPathSetting; set => SetProperty(ref _packPathSetting, value); }

    public string DevPushPathSetting { get => _devPushPathSetting; set => SetProperty(ref _devPushPathSetting, value); }

    public string BuilderPathSetting { get => _builderPathSetting; set => SetProperty(ref _builderPathSetting, value); }

    public string BundleIdOverride { get => _bundleIdOverride; set => SetProperty(ref _bundleIdOverride, value); }

    public string MockDirectory { get => _mockDirectory; set => SetProperty(ref _mockDirectory, value); }

    public string WorkspaceRoot => _services.Workspace.Root;

    public string ShellBundleId => _shell?.BundleId ?? (string.IsNullOrWhiteSpace(BundleIdOverride) ? Loc.T("common.none") : BundleIdOverride);

    public GameRow? SelectedGame
    {
        get => _selectedGame;
        set
        {
            if (SetProperty(ref _selectedGame, value))
            {
                OnPropertyChanged(nameof(SelectedSummary));
                RaiseCommandStates();
            }
        }
    }

    public string SelectedSummary => _selectedGame is null
        ? Loc.T("library.selectedNone")
        : Loc.T("library.selectedSummary", _selectedGame.DisplayName, _selectedGame.TitleID) + " · " + Loc.T("library.card.rom", _selectedGame.RomPath) + " · " + _selectedGame.PackLine;

    public DeviceInfo? SelectedDevice
    {
        get => _selectedDevice;
        set
        {
            if (SetProperty(ref _selectedDevice, value))
            {
                DeviceUdid = value?.Udid ?? string.Empty;
                RaiseCommandStates();
            }
        }
    }

    public bool CanBuild => _services.Pack is not null || _services.Builder is not null;

    public async Task InitializeAsync()
    {
        try
        {
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            _shell = await _services.LoadShellAsync().ConfigureAwait(true);
            UpdateShellStatus();
            Log(_shell is null
                ? "Shell template manifest not found in Shell/. Install/push stays disabled until the launcher package includes the ROM-free template IPA."
                : $"Shell template: v{_shell.Version} {_shell.BundleId} ({_shell.FileName}); packs are injected into the app IPA at install time.");
        }
        catch (Exception exception)
        {
            Log("initialize failed: " + exception.Message);
        }
    }

    // --- navigation / language --------------------------------------------

    public void ShowLibrary()
    {
        _section = "library";
        _showSettings = false;
        RaiseViewState();
    }

    public void ShowImport()
    {
        _section = "import";
        _showSettings = false;
        RaiseViewState();
    }

    public void OpenSettings()
    {
        _showSettings = true;
        RaiseViewState();
    }

    public void CloseSettings()
    {
        _showSettings = false;
        RaiseViewState();
    }

    public void ToggleDiagnostics()
    {
        _showDiagnostics = !_showDiagnostics;
        OnPropertyChanged(nameof(ShowDiagnostics));
        OnPropertyChanged(nameof(DiagnosticsToggleLabel));
    }

    private void RaiseViewState()
    {
        OnPropertyChanged(nameof(IsLibrarySection));
        OnPropertyChanged(nameof(IsImportSection));
        OnPropertyChanged(nameof(ShowSettings));
    }

    public LanguageChoice? SelectedLanguage
    {
        get => _selectedLanguage;
        set
        {
            if (value is null || value.Preference == _languagePreference)
            {
                return;
            }
            ApplyLanguagePreference(value.Preference, persist: true);
        }
    }

    /// <summary>Apply a language preference immediately, localize everything and persist it.</summary>
    public void ApplyLanguagePreference(UiLanguagePreference preference, bool persist)
    {
        _languagePreference = preference;
        Loc.ApplyPreference(preference, CultureInfo.CurrentUICulture.Name);
        if (persist)
        {
            _services.Workspace.State.Language = LanguageCatalog.PreferenceKey(preference);
            _services.Workspace.SaveState();
        }
        L = new LocalizedText();
        RebuildLanguageOptions();
        ResetBuildModes();
        OnPropertyChanged(nameof(WindowTitle));
        OnPropertyChanged(nameof(GameCountText));
        OnPropertyChanged(nameof(ReadinessText));
        OnPropertyChanged(nameof(ReadinessSummary));
        OnPropertyChanged(nameof(SelectedSummary));
        OnPropertyChanged(nameof(ShellBundleIdLine));
        OnPropertyChanged(nameof(DiagnosticsToggleLabel));
        foreach (var row in Games)
        {
            row.Refresh();
        }
        UpdateShellStatus();
        StatusText = Loc.T("status.languageChanged");
        _ = RefreshStatusAsync();
    }

    // --- library card actions ---------------------------------------------

    /// <summary>Which primary action a library card offers right now.</summary>
    public CardAction PrimaryAction(GameRow row)
    {
        if (!row.HasRealPack)
        {
            return CardAction.Build;
        }
        var installedAt = _services.Workspace.State.InstalledAt;
        if (installedAt is null || (row.Entry.BuiltAt is not null && row.Entry.BuiltAt > installedAt))
        {
            return CardAction.Install;
        }
        return row.IsPushed ? CardAction.Verify : CardAction.Push;
    }

    public async Task RunPrimaryAsync(GameRow row)
    {
        SelectedGame = row;
        switch (PrimaryAction(row))
        {
            case CardAction.Build:
                await BuildSelectedAsync().ConfigureAwait(true);
                break;
            case CardAction.Install:
                await InstallShellAsync().ConfigureAwait(true);
                await RefreshLibraryAsync().ConfigureAwait(true);
                break;
            case CardAction.Push:
                await PushSelectedAsync().ConfigureAwait(true);
                await RefreshLibraryAsync().ConfigureAwait(true);
                break;
            default:
                await VerifyPushAsync().ConfigureAwait(true);
                await RefreshLibraryAsync().ConfigureAwait(true);
                break;
        }
    }

    public async Task RunBuildForAsync(GameRow row)
    {
        SelectedGame = row;
        await BuildSelectedAsync().ConfigureAwait(true);
    }

    public async Task RunPushForAsync(GameRow row)
    {
        SelectedGame = row;
        await PushSelectedAsync().ConfigureAwait(true);
        await RefreshLibraryAsync().ConfigureAwait(true);
    }

    public async Task RunVerifyForAsync(GameRow row)
    {
        SelectedGame = row;
        await VerifyPushAsync().ConfigureAwait(true);
    }

    public async Task RunInstallForAsync(GameRow row)
    {
        SelectedGame = row;
        await InstallShellAsync().ConfigureAwait(true);
        await RefreshLibraryAsync().ConfigureAwait(true);
    }

    public async Task RunRemoveForAsync(GameRow row)
    {
        SelectedGame = row;
        await RemoveSelectedAsync().ConfigureAwait(true);
    }

    // --- library / import --------------------------------------------------

    public void RequestBrowseRom() => BrowseRomRequested?.Invoke();

    public async Task ImportFromBoxAsync()
    {
        if (string.IsNullOrWhiteSpace(ImportPath))
        {
            Log("Choose a decrypted .3ds/.cci file first (or drag it onto the import area).");
            return;
        }
        await ImportAsync(new[] { ImportPath.Trim().Trim('"') }).ConfigureAwait(true);
    }

    public async Task ImportAsync(IReadOnlyList<string> paths)
    {
        var pack = _services.Pack;
        if (pack is null)
        {
            Log("3ds2apple-pack was not found. Put 3ds2apple-pack.exe into Bin/ or set its path in Settings.");
            return;
        }
        if (paths.Count == 0)
        {
            return;
        }
        IsImportRunning = true;
        SetBusy(true, Loc.T("status.importing"));
        try
        {
            foreach (var path in paths)
            {
                var inspect = await pack.InspectAsync(path).ConfigureAwait(true);
                if (inspect.Roms.Count == 0)
                {
                    var error = inspect.Errors.Count > 0 ? string.Join("; ", inspect.Errors) : "not a decrypted 3DS ROM";
                    Log($"import failed: {path}: {error}");
                    continue;
                }
                var rom = inspect.Roms[0];
                var overrideName = paths.Count == 1 && !string.IsNullOrWhiteSpace(DisplayNameOverride) ? DisplayNameOverride.Trim() : null;
                var added = await pack.AddAsync(new[] { path }, overrideName).ConfigureAwait(true);
                if (!added.Ok || added.Packages.Count == 0)
                {
                    Log($"import failed: {path}: " + (added.Errors.Count > 0 ? string.Join("; ", added.Errors) : PackCli.FirstMeaningfulLine(added.Process)));
                    continue;
                }
                var imported = added.Packages[0];
                var entry = _services.Workspace.Find(imported.TitleID) ?? new LibraryEntry
                {
                    TitleID = imported.TitleID,
                    RomPath = path,
                    ImportedAt = DateTimeOffset.UtcNow,
                };
                entry.DisplayName = imported.DisplayName;
                entry.ProductCode = imported.ProductCode;
                entry.RomPath = path;
                entry.PackageDir = imported.PackageDir;
                entry.State = "queued";
                entry.LastError = null;
                _services.Workspace.Upsert(entry);
                _services.Workspace.SaveState();
                Log($"imported {imported.TitleID}  {imported.DisplayName}  {imported.ProductCode}  (headers only, phone gets a separate push)");
            }
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            StatusText = Loc.T("status.importFinished");
            if (Games.Count > 0)
            {
                ShowLibrary();
            }
        }
        catch (Exception exception)
        {
            Log("import failed: " + exception.Message);
            StatusText = Loc.T("status.importFailed");
        }
        finally
        {
            IsImportRunning = false;
            SetBusy(false, Loc.T("status.ready"));
        }
    }

    public async Task RefreshLibraryAsync()
    {
        if (_services.Pack is { } pack)
        {
            var list = await pack.ListAsync().ConfigureAwait(true);
            foreach (var info in list.Packages)
            {
                var entry = _services.Workspace.Find(info.TitleID);
                if (entry is null)
                {
                    continue;
                }
                entry.DisplayName = info.DisplayName;
                entry.ProductCode = info.ProductCode;
                entry.State = info.State;
                entry.Pack = info.Pack;
                if (info.Pack is not null)
                {
                    entry.PackPath = Path.Combine(_services.Workspace.OutRoot, "packages", info.TitleID, GameInfoWriter.GamePackFileName);
                }
            }
        }
        Games.Clear();
        foreach (var entry in _services.Workspace.State.Games.OrderBy(game => game.TitleID, StringComparer.Ordinal))
        {
            Games.Add(new GameRow(this, entry));
        }
        _services.Workspace.SaveState();
        SelectedGame = Games.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedSummary));
        OnPropertyChanged(nameof(HasGames));
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(GameCountText));
        OnPropertyChanged(nameof(HasRealPacks));
    }

    private async Task RemoveSelectedAsync()
    {
        if (SelectedGame is null)
        {
            return;
        }
        var title = SelectedGame.TitleID;
        if (_services.Pack is { } pack)
        {
            var process = await _services.Runner.RunAsync(new ProcessRequest(pack.ExecutablePath, new[] { "--out", _services.Workspace.OutRoot, "--json", "packages", "remove", title })).ConfigureAwait(true);
            if (!process.Ok)
            {
                Log("packages remove failed: " + PackCli.FirstMeaningfulLine(process));
            }
        }
        _services.Workspace.Remove(title);
        _services.Workspace.SaveState();
        await RefreshLibraryAsync().ConfigureAwait(true);
        Log($"removed {title} from the launcher library (the ROM file itself was not touched).");
    }

    // --- build -------------------------------------------------------------

    private async Task BuildSelectedAsync()
    {
        if (SelectedGame is null)
        {
            return;
        }
        var mode = ModeFromUi();
        var provider = _services.CreateBuildProvider(mode);
        if (provider is null)
        {
            Log(mode switch
            {
                PackBuildMode.MacAgentIpa => "macOS build needs builder-windows.exe (Bin/) and 3ds2apple-pack.exe.",
                PackBuildMode.LocalWinbuild => "Local build needs 3ds2apple-pack.exe (Bin/), 3dsrecomp.exe and the LLVM bin folder (clang.exe, llvm-ar.exe, ld64.lld.exe); set them in Settings and enable the experimental local build.",
                _ => "Preview build needs 3ds2apple-pack.exe (Bin/).",
            });
            return;
        }
        if (mode == PackBuildMode.MacAgentIpa && string.IsNullOrWhiteSpace(BuildHost))
        {
            Log("Set the macOS build host name in Settings first (same host profile builder-windows/zkb uses).");
            return;
        }
        SetBusy(true, Loc.T("status.building"));
        try
        {
            var entry = SelectedGame.Entry;
            var request = new PackBuildRequest(
                entry.TitleID,
                SelectedGame.DisplayName,
                entry.ProductCode,
                entry.RomPath,
                string.IsNullOrWhiteSpace(BuildHost) ? null : BuildHost.Trim(),
                _services.Workspace.WorkDirectory);
            var progress = new Progress<BuildProgress>(item =>
            {
                if (item.Percent is { } percent && percent > 0)
                {
                    ProgressValue = percent;
                }
                StatusText = $"{item.Stage}: {item.Message}";
            });
            var outcome = await provider.BuildAsync(request, progress, line => Log("[build] " + line)).ConfigureAwait(true);
            if (!outcome.Success)
            {
                entry.LastError = outcome.ErrorMessage;
                entry.State = "build_failed";
                _services.Workspace.SaveState();
                Log($"build failed ({outcome.ErrorCode}): {outcome.ErrorMessage}");
                StatusText = Loc.T("status.buildFailed");
                return;
            }
            entry.Pack = outcome.Pack;
            entry.PackPath = outcome.PackPath ?? Path.Combine(_services.Workspace.OutRoot, "packages", entry.TitleID, GameInfoWriter.GamePackFileName);
            entry.State = outcome.Installable ? "built" : "preview";
            entry.BuiltAt = DateTimeOffset.UtcNow;
            entry.LastBuildName = outcome.BuildName;
            entry.LastError = null;
            _services.Workspace.SaveState();
            await RefreshLibraryAsync().ConfigureAwait(true);
            Log(outcome.Installable
                ? $"build ok: real GamePack for {entry.TitleID} ({outcome.Pack?.Sha256[..16]}…)."
                : "preview build ok: placeholder pack written. It is NOT installable; use the macOS Build Agent for a real GamePack.");
            StatusText = Loc.T("status.buildFinished");
        }
        catch (Exception exception)
        {
            Log("build failed: " + exception.Message);
            StatusText = Loc.T("status.buildFailed");
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private PackBuildMode ModeFromUi() => _selectedBuildMode?.Mode ?? PackBuildMode.Preview;

    // --- device / shell ----------------------------------------------------

    private async Task RefreshDevicesAsync()
    {
        SetBusy(true, Loc.T("status.devices"));
        try
        {
            Devices.Clear();
            if (_services.DevPush is { } devPush)
            {
                var devices = await devPush.DevicesAsync().ConfigureAwait(true);
                foreach (var device in devices)
                {
                    Devices.Add(device);
                }
                DeviceStatus = devices.Count == 0
                    ? Loc.T("device.none")
                    : Loc.T("device.count", devices.Count, string.Join(", ", devices.Select(d => Privacy.RedactUdid(d.Udid))));
            }
            else
            {
                var muxDevices = await _services.Mux.ListDevicesAsync().ConfigureAwait(true);
                foreach (var mux in muxDevices)
                {
                    Devices.Add(new DeviceInfo(mux.Udid, null, null, null, mux.ConnectionType, Paired: true));
                }
                DeviceStatus = devPushFallbackNote(muxDevices.Count);
            }
            SelectedDevice = Devices.FirstOrDefault();
            if (SelectedDevice is not null)
            {
                Log($"device: {Privacy.RedactUdid(SelectedDevice.Udid)} ({SelectedDevice.Connection})");
            }
        }
        catch (LauncherToolException error)
        {
            DeviceStatus = Loc.T("status.deviceRefreshFailed", $"{error.Code}: {error.Message}" + (error.Hint is null ? string.Empty : " — " + error.Hint));
            Log(DeviceStatus);
        }
        catch (Exception exception)
        {
            DeviceStatus = Loc.T("status.deviceRefreshFailed", exception.Message);
            Log(DeviceStatus);
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private string devPushFallbackNote(int count) => count == 0
        ? Loc.T("device.none") + " (" + Loc.T("device.fallback") + ")"
        : Loc.T("device.count", count, Loc.T("device.fallback"));

    private async Task InstallShellAsync()
    {
        _shell ??= await _services.LoadShellAsync().ConfigureAwait(true);
        if (_shell is null)
        {
            Log("No base shell manifest (Shell/manifest.json). The launcher package must include a ROM-free base shell IPA; see docs/windows-launcher.md.");
            return;
        }
        var installer = _services.CreateShellInstallService();
        if (installer is null)
        {
            Log("plumesign was not found in the bundled Impactor directory. Run tools/fetch-impactor.ps1 or reinstall the launcher package.");
            return;
        }
        var templateIpa = Path.Combine(_services.ShellDirectory, _shell.FileName);
        var realPacks = Games
            .Where(row => row.Entry.Pack is { IsPlaceholder: false }
                          && !string.IsNullOrWhiteSpace(row.Entry.PackPath)
                          && File.Exists(row.Entry.PackPath))
            .Select(row => new ComposedPack(row.Entry.TitleID, row.DisplayName, row.Entry.ProductCode, 1, row.Entry.PackPath!))
            .ToList();
        var composer = _services.CreateComposer();
        string installIpa;
        var gameCount = 0;
        SetBusy(true, Loc.T("status.composing"));
        try
        {
            if (composer is not null && realPacks.Count > 0)
            {
                Log($"Composing ROM-free app IPA: shell template + {realPacks.Count} pack(s) + GameCatalog…");
                var composed = await composer.ComposeAsync(templateIpa, realPacks, Path.Combine(_services.Workspace.WorkDirectory, "app-ipa")).ConfigureAwait(true);
                installIpa = composed.IpaPath;
                gameCount = composed.GameCount;
                Log($"composed {composed.IpaPath} ({FormatBytes(composed.Bytes)}, sha256 {composed.Sha256[..16]}…, games: {string.Join(", ", composed.TitleIDs)})");
            }
            else
            {
                Log("No real GamePacks are built yet; installing the bare shell template. Games will not launch until packs are built and the app is reinstalled.");
                installIpa = templateIpa;
            }
            SetBusy(true, Loc.T("status.signing"));
            var outcome = await installer.InstallAsync(
                _shell,
                _services.ShellDirectory,
                installIpa,
                string.IsNullOrWhiteSpace(BundleIdOverride) ? null : BundleIdOverride.Trim(),
                SelectedDevice?.Udid,
                line => Log("[install] " + line)).ConfigureAwait(true);
            if (outcome.Installed)
            {
                _services.Workspace.State.InstalledBundleId = outcome.BundleId;
                _services.Workspace.State.InstalledAt = DateTimeOffset.UtcNow;
                _services.Workspace.State.InstalledGameCount = gameCount;
                _services.Workspace.SaveState();
                ShellStatus = Loc.T("shell.installedCount", outcome.BundleId, gameCount);
                Log($"app installed: {outcome.BundleId}" + (outcome.SignedIpaPath is null ? string.Empty : $" (signed IPA: {outcome.SignedIpaPath})")
                    + (gameCount == 0 ? " — no game packs yet; build packs and reinstall to add games." : string.Empty));
                PushStatus = gameCount == 0 ? Loc.T("shell.installedNoPacks") : Loc.T("shell.installedReady");
                StatusText = Loc.T("status.appInstalled");
            }
            else
            {
                var error = outcome.Error;
                ShellStatus = error is null ? Loc.T("shell.installFailed") : Loc.T("shell.installError", error.Title, error.Fix);
                Log("base shell install failed: " + (error?.Title ?? "unknown") + (error?.Detail is null ? string.Empty : " — " + error.Detail));
                if (error is not null)
                {
                    Log("fix: " + error.Fix);
                }
            }
        }
        catch (LauncherToolException error)
        {
            ShellStatus = Loc.T("shell.installError", error.Code, error.Message);
            Log(ShellStatus + (error.Hint is null ? string.Empty : " — " + error.Hint));
        }
        catch (Exception exception)
        {
            ShellStatus = Loc.T("shell.installError", Loc.T("shell.installFailed"), exception.Message);
            Log(ShellStatus);
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private void OpenImpactor()
    {
        if (_services.PlumeSign is null)
        {
            Log("The bundled Impactor/plumesign was not found (ThirdParty/Impactor). See docs/windows-build.md for the fetch step.");
            return;
        }
        try
        {
            _services.Impactor.StartImpactor();
            Log("Impactor started. Sign in with your own Apple ID there; the launcher never sees the password. Come back and install the base shell.");
            ShellStatus = Loc.T("shell.waiting");
        }
        catch (Exception exception)
        {
            Log("could not start Impactor: " + exception.Message);
        }
    }

    private void UpdateShellStatus()
    {
        if (_shell is null)
        {
            ShellStatus = Loc.T("shell.missing");
            return;
        }
        var verification = _shell.Verify(_services.ShellDirectory);
        if (!verification.Ok)
        {
            ShellStatus = Loc.T("shell.invalid", verification.Error ?? string.Empty);
            return;
        }
        var compatibility = ShellTemplateRules.ValidateManifest(_shell);
        if (!compatibility.Ok)
        {
            ShellStatus = Loc.T("shell.rejected", compatibility.Error ?? string.Empty, compatibility.Fix ?? string.Empty);
            return;
        }
        var installed = _services.Workspace.State.InstalledAt;
        ShellStatus = installed is null
            ? Loc.T("shell.pending", _shell.Version, _shell.BundleId)
            : Loc.T("shell.installed", _services.Workspace.State.InstalledBundleId, installed.Value.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture), _services.Workspace.State.InstalledGameCount);
    }

    // --- push --------------------------------------------------------------

    private async Task PushSelectedAsync()
    {
        if (SelectedGame is null)
        {
            return;
        }
        var entry = SelectedGame.Entry;
        if (entry.Pack is null || entry.Pack.IsPlaceholder)
        {
            Log("This game has no real GamePack yet. Build it with the macOS Build Agent before pushing (preview placeholders cannot run on the phone).");
            PushStatus = Loc.T("push.noPack");
            return;
        }
        var pushService = _services.CreatePushService();
        if (pushService is null)
        {
            Log("devpush was not found (Bin/devpush.exe). The device bridge is required to push files.");
            PushStatus = Loc.T("push.devpushMissing");
            return;
        }
        var shell = _shell ?? await _services.LoadShellAsync().ConfigureAwait(true);
        var bundleId = string.IsNullOrWhiteSpace(BundleIdOverride) ? shell?.BundleId : BundleIdOverride.Trim();
        if (string.IsNullOrWhiteSpace(bundleId))
        {
            Log("No bundle id: bundle the base shell manifest or set the shell bundle id in Settings.");
            PushStatus = Loc.T("push.noBundle");
            return;
        }
        if (!File.Exists(entry.RomPath))
        {
            Log("The imported ROM is gone from " + entry.RomPath + ". Re-import it first.");
            PushStatus = Loc.T("push.romMissing", entry.RomPath);
            return;
        }
        SetBusy(true, Loc.T("status.pushPreparing"));
        try
        {
            var plan = await GamePushPlan.CreateAsync(
                _services.Workspace.StagingDirectory,
                entry.TitleID,
                SelectedGame.DisplayName,
                entry.ProductCode,
                1,
                entry.PackPath,
                entry.RomPath,
                Log).ConfigureAwait(true);
            PushStatus = Loc.T("push.preparing", FormatBytes(plan.TotalBytes), plan.RemoteDirectory);
            var progress = new Progress<PushProgress>(item =>
            {
                ProgressValue = item.OverallPercent;
                StatusText = $"{item.FileName}: {item.Message}";
            });
            var outcome = await pushService.PushAsync(plan, bundleId, SelectedDevice?.Udid, resume: true, progress, Log).ConfigureAwait(true);
            if (outcome.Success)
            {
                entry.PushedAt = DateTimeOffset.UtcNow;
                entry.PushedFiles = plan.Files.Select(file => file.RemoteName).ToList();
                entry.LastError = null;
                _services.Workspace.SaveState();
                PushStatus = Loc.T("push.done", outcome.RemoteDirectory, SelectedDevice is null ? Loc.T("common.auto") : Privacy.RedactUdid(SelectedDevice.Udid));
                Log(PushStatus);
                StatusText = Loc.T("status.pushFinished");
            }
            else
            {
                PushStatus = Loc.T("push.failed", outcome.ErrorCode, outcome.ErrorMessage);
                Log(PushStatus);
                StatusText = Loc.T("status.pushFailed");
            }
        }
        catch (LauncherToolException error)
        {
            PushStatus = Loc.T("push.failed", error.Code, error.Message);
            Log(PushStatus + (error.Hint is null ? string.Empty : " — " + error.Hint));
        }
        catch (Exception exception)
        {
            PushStatus = Loc.T("push.failed", "exception", exception.Message);
            Log(PushStatus);
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private async Task VerifyPushAsync()
    {
        if (SelectedGame is null || _services.CreatePushService() is not { } pushService)
        {
            return;
        }
        var entry = SelectedGame.Entry;
        var shell = _shell ?? await _services.LoadShellAsync().ConfigureAwait(true);
        var bundleId = string.IsNullOrWhiteSpace(BundleIdOverride) ? shell?.BundleId : BundleIdOverride.Trim();
        if (string.IsNullOrWhiteSpace(bundleId))
        {
            Log("No bundle id to verify against.");
            return;
        }
        try
        {
            var plan = await GamePushPlan.CreateAsync(
                _services.Workspace.StagingDirectory,
                entry.TitleID,
                SelectedGame.DisplayName,
                entry.ProductCode,
                1,
                entry.PackPath,
                entry.RomPath,
                Log).ConfigureAwait(true);
            var problems = await pushService.VerifyAsync(plan, bundleId, SelectedDevice?.Udid).ConfigureAwait(true);
            PushStatus = problems.Count == 0 ? Loc.T("push.verifyOk") : string.Join("; ", problems);
            Log(PushStatus);
        }
        catch (Exception exception)
        {
            Log("verify failed: " + exception.Message);
            PushStatus = Loc.T("status.verifyFailed", exception.Message);
        }
    }

    // --- status / settings / misc -----------------------------------------

    private async Task RefreshStatusAsync()
    {
        try
        {
            var readiness = await _services.CheckAsync().ConfigureAwait(true);
            Tools.Clear();
            foreach (var tool in readiness.Tools)
            {
                Tools.Add(new ToolRow(tool.Name, tool.State, tool.Message));
            }
            OnPropertyChanged(nameof(ReadinessText));
            OnPropertyChanged(nameof(ReadinessSummary));
            Log("status: " + readiness.Summary);
        }
        catch (Exception exception)
        {
            Log("status check failed: " + exception.Message);
        }
    }

    private async Task SaveSettingsAsync()
    {
        try
        {
            _services.SetToolOverride(ToolLocator.PackCliTool, PackPathSetting);
            _services.SetToolOverride(ToolLocator.DevPushTool, DevPushPathSetting);
            _services.SetToolOverride(ToolLocator.BuilderTool, BuilderPathSetting);
            _services.SetToolOverride(ToolLocator.RecompTool, RecompPathSetting);
            _services.SetToolOverride(ToolLocator.LlvmTool, LlvmDirSetting);
            _services.Workspace.State.LocalBuildEnabled = LocalBuildEnabled;
            _services.Workspace.State.BuildHost = string.IsNullOrWhiteSpace(BuildHost) ? null : BuildHost.Trim();
            _services.Workspace.State.BuildMode = ModeFromUi().ToString();
            _services.Workspace.State.ShellBundleIdOverride = string.IsNullOrWhiteSpace(BundleIdOverride) ? null : BundleIdOverride.Trim();
            _services.Workspace.State.DevPushMockDirectory = string.IsNullOrWhiteSpace(MockDirectory) ? null : MockDirectory.Trim();
            _services.Workspace.State.Language = LanguageCatalog.PreferenceKey(_languagePreference);
            _services.Workspace.SaveState();
            _services.Reload();
            ResetBuildModes();
            _shell = await _services.LoadShellAsync().ConfigureAwait(true);
            UpdateShellStatus();
            await RefreshStatusAsync().ConfigureAwait(true);
            Log("settings saved and tools reloaded.");
            StatusText = Loc.T("status.settingsSaved");
        }
        catch (Exception exception)
        {
            Log("saving settings failed: " + exception.Message);
            StatusText = Loc.T("status.settingsSaveFailed", exception.Message);
        }
    }

    private void RunSelfTest()
    {
        var writer = new StringWriter();
        var code = SelfTest.Run(writer, writer);
        foreach (var line in writer.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            Log(line);
        }
        Log(code == 0 ? "self-test passed (see lines above)." : "self-test FAILED — copy the launcher log when reporting.");
        StatusText = code == 0 ? Loc.T("status.selftestPassed") : Loc.T("status.selftestFailed");
    }

    private void OpenWorkspace()
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = _services.Workspace.Root,
                UseShellExecute = true,
            });
        }
        catch (Exception exception)
        {
            Log("could not open the workspace folder: " + exception.Message);
        }
    }

    private void Log(string message)
    {
        var line = $"{DateTimeOffset.Now:HH:mm:ss} {message}";
        LogLines.Add(line);
        if (LogLines.Count > 4000)
        {
            LogLines.RemoveAt(0);
        }
        try
        {
            _services.Workspace.AppendLog(message);
        }
        catch (IOException)
        {
            // logging must never break the launcher
        }
    }

    private void SetBusy(bool busy, string? status)
    {
        IsBusy = busy;
        StatusText = busy && !string.IsNullOrWhiteSpace(status) ? status! : Loc.T("status.ready");
        if (!busy)
        {
            ProgressValue = 0;
        }
    }

    private void RaiseCommandStates()
    {
        foreach (var row in Games)
        {
            row.RaiseCommandStates();
        }
        foreach (var command in new System.Windows.Input.ICommand[]
                 {
                     ImportCommand, RemoveGameCommand, BuildSelectedCommand, RefreshStatusCommand, RefreshDevicesCommand,
                     InstallShellCommand, OpenImpactorCommand, PushSelectedCommand, VerifyPushCommand, SaveSettingsCommand, RunSelfTestCommand,
                 })
        {
            switch (command)
            {
                case AsyncRelayCommand asyncCommand:
                    asyncCommand.RaiseCanExecuteChanged();
                    break;
                case RelayCommand relay:
                    relay.RaiseCanExecuteChanged();
                    break;
            }
        }
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.00} GiB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.0} MiB",
        >= 1L << 10 => $"{bytes / (double)(1L << 10):0.0} KiB",
        _ => $"{bytes} B",
    };
}
