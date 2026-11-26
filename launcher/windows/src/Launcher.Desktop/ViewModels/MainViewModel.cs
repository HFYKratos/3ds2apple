using System.Collections.ObjectModel;
using System.Globalization;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.Hardware;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Portable;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Localization;

namespace ThreeDsTwoApple.Launcher.App.ViewModels;

/// <summary>One card in the Library: ROM icon / name / state / publisher, build-cache state,
/// "Build now" (pre-build ahead of Deploy) and remove. Install/push stay on the Deploy page.</summary>
public sealed class GameRow : ObservableObject
{
    private readonly MainViewModel _owner;
    private string _state = "imported";
    private string _buildStatusText = string.Empty;
    private bool _isBuildCurrent;
    private Avalonia.Media.Imaging.Bitmap? _cover;
    private string? _coverSourcePath;

    public GameRow(MainViewModel owner, LibraryEntry entry)
    {
        _owner = owner;
        Entry = entry;
        RemoveCommand = new AsyncRelayCommand(() => _owner.RemoveGameAsync(this), () => !_owner.IsBusy);
        BuildCommand = new AsyncRelayCommand(() => _owner.BuildGameAsync(this), () => !_owner.IsBusy);
        ExportBuildPackageCommand = new AsyncRelayCommand(() => _owner.ExportBuildPackageAsync(this), () => !_owner.IsBusy && HasRealPack);
        ExportIpaCommand = new AsyncRelayCommand(() => _owner.ExportIpaAsync(this), () => !_owner.IsBusy && HasRealPack);
        Refresh();
    }

    public LibraryEntry Entry { get; }

    public string TitleID => Entry.TitleID;

    /// <summary>Name for the current UI language from the ROM's SMDH titles (no user input).</summary>
    public string DisplayName => GameNames.Resolve(Entry.DisplayNames, Entry.DisplayName, Loc.CurrentTag);

    public string DisplayNameText => DisplayName;

    /// <summary>ROM icon extracted by 3ds2apple-pack (cover.png); null falls back to the placeholder.</summary>
    public Avalonia.Media.Imaging.Bitmap? CoverImage => _cover;

    public bool HasCover => _cover is not null;

    public bool HasPublisher => !string.IsNullOrWhiteSpace(Publisher);

    public string Publisher => GameNames.ResolvePublisher(Entry.Publisher);

    public string PublisherLine => Loc.T("library.card.publisher", Publisher);

    public string RomPath => Entry.RomPath;

    public string? ProductCode => Entry.ProductCode;

    public string State
    {
        get => _state;
        private set => SetProperty(ref _state, value);
    }

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

    public bool HasRealPack => Entry.Pack is { IsPlaceholder: false }
                               && !string.IsNullOrWhiteSpace(Entry.PackPath)
                               && File.Exists(Entry.PackPath);

    public bool IsPushed => Entry.PushedAt is not null;

    public string PackLine => Entry.Pack is null
        ? string.Empty
        : Entry.Pack.IsPlaceholder
            ? Loc.T("library.card.pack.placeholder", FormatBytes(Entry.Pack.Bytes))
            : Loc.T("library.card.pack.built", FormatBytes(Entry.Pack.Bytes));

    public string RemoveLabel => Loc.T("library.card.remove");

    public AsyncRelayCommand RemoveCommand { get; }

    /// <summary>"Build now": compile this game's GamePack ahead of a deploy (or reuse the cache).</summary>
    public AsyncRelayCommand BuildCommand { get; }

    /// <summary>"Export .32a": write this game's portable build package into workspace/builds.</summary>
    public AsyncRelayCommand ExportBuildPackageCommand { get; }

    /// <summary>"Export IPA": compose an unsigned single-game IPA into workspace/exports.</summary>
    public AsyncRelayCommand ExportIpaCommand { get; }

    public string BuildNowLabel => Loc.T("library.buildNow");

    public string ExportBuildPackageLabel => Loc.T("library.buildPackage.export");

    public string ExportIpaLabel => Loc.T("library.exportIpa");

    /// <summary>Built/cache label or the exact rebuild reason (recorded buildCompatVersion + ROM fingerprint).</summary>
    public string BuildStatusText
    {
        get => _buildStatusText;
        private set => SetProperty(ref _buildStatusText, value);
    }

    /// <summary>true when the GamePack matches the current build recipe and the recorded ROM fingerprint.</summary>
    public bool IsBuildCurrent
    {
        get => _isBuildCurrent;
        private set => SetProperty(ref _isBuildCurrent, value);
    }

    public void Refresh()
    {
        State = Entry.Pack is null
            ? Entry.State
            : Entry.Pack.IsPlaceholder ? "preview" : "built";
        RefreshCover();
        RefreshBuildStatus();
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(PackLine));
        OnPropertyChanged(nameof(DisplayName));
        OnPropertyChanged(nameof(DisplayNameText));
        OnPropertyChanged(nameof(CoverImage));
        OnPropertyChanged(nameof(HasCover));
        OnPropertyChanged(nameof(Publisher));
        OnPropertyChanged(nameof(PublisherLine));
        OnPropertyChanged(nameof(HasPublisher));
        OnPropertyChanged(nameof(HasRealPack));
        OnPropertyChanged(nameof(IsPushed));
        OnPropertyChanged(nameof(TitleIdLine));
        OnPropertyChanged(nameof(RomLine));
        OnPropertyChanged(nameof(RemoveLabel));
        OnPropertyChanged(nameof(BuildNowLabel));
        OnPropertyChanged(nameof(ExportBuildPackageLabel));
        OnPropertyChanged(nameof(ExportIpaLabel));
    }

    public void RaiseCommandStates()
    {
        RemoveCommand.RaiseCanExecuteChanged();
        BuildCommand.RaiseCanExecuteChanged();
        ExportBuildPackageCommand.RaiseCanExecuteChanged();
        ExportIpaCommand.RaiseCanExecuteChanged();
    }

    /// <summary>Recompute the cache label; cheap (size/mtime only, never reads the ROM).</summary>
    private void RefreshBuildStatus()
    {
        var status = _owner.DescribeBuild(Entry);
        BuildStatusText = status.Text;
        IsBuildCurrent = status.Current;
    }

    /// <summary>Load the ROM icon once per package path; a broken/missing PNG keeps the placeholder.</summary>
    private void RefreshCover()
    {
        var path = GameNames.ResolveCoverPath(Entry.PackageDir, Entry.CoverPath);
        if (string.Equals(path, _coverSourcePath, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }
        _coverSourcePath = path;
        _cover?.Dispose();
        _cover = null;
        if (path is null)
        {
            return;
        }
        try
        {
            _cover = new Avalonia.Media.Imaging.Bitmap(path);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            _cover = null;
        }
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.00} GiB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.0} MiB",
        _ => $"{bytes} B",
    };
}

/// <summary>One checkbox row on the Deploy page (select one or many games).</summary>
public sealed class DeployRow : ObservableObject
{
    private readonly MainViewModel _owner;
    private bool _isSelected;

    public DeployRow(MainViewModel owner, LibraryEntry entry, bool selected)
    {
        _owner = owner;
        Entry = entry;
        _isSelected = selected;
    }

    public LibraryEntry Entry { get; }

    public string TitleID => Entry.TitleID;

    public string DisplayName => GameNames.Resolve(Entry.DisplayNames, Entry.DisplayName, Loc.CurrentTag);

    public bool HasRealPack => Entry.Pack is { IsPlaceholder: false }
                               && !string.IsNullOrWhiteSpace(Entry.PackPath)
                               && File.Exists(Entry.PackPath);

    public string StateLabel => Entry.PushedAt is not null
        ? Loc.T("library.card.state.pushed")
        : HasRealPack ? Loc.T("library.card.state.built") : Loc.T("library.card.state.imported");

    public string DetailLine => HasRealPack
        ? Loc.T("library.card.pack.built", FormatBytes(Entry.Pack?.Bytes ?? 0))
        : Loc.T("library.card.notBuilt");

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (SetProperty(ref _isSelected, value))
            {
                _owner.OnDeploySelectionChanged();
            }
        }
    }

    public void Refresh()
    {
        OnPropertyChanged(nameof(DisplayName));
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(DetailLine));
        OnPropertyChanged(nameof(HasRealPack));
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 30 => $"{bytes / (double)(1L << 30):0.00} GiB",
        >= 1L << 20 => $"{bytes / (double)(1L << 20):0.0} MiB",
        _ => $"{bytes} B",
    };
}

/// <summary>One visible Deploy step with its status and last detail line.</summary>
public sealed class DeployStepRow : ObservableObject
{
    private string _label;
    private string _detail = string.Empty;
    private DeployStepStatus _status = DeployStepStatus.Pending;

    public DeployStepRow(DeployStepKind kind, string label)
    {
        Kind = kind;
        _label = label;
    }

    public DeployStepKind Kind { get; }

    public string Label { get => _label; set => SetProperty(ref _label, value); }

    public DeployStepStatus Status => _status;

    public string Detail => _detail;

    public string StatusLabel => _status switch
    {
        DeployStepStatus.Running => Loc.T("deploy.step.running"),
        DeployStepStatus.Succeeded => Loc.T("deploy.step.succeeded"),
        DeployStepStatus.Failed => Loc.T("deploy.step.failed"),
        DeployStepStatus.Cancelled => Loc.T("deploy.step.cancelled"),
        DeployStepStatus.Skipped => Loc.T("deploy.step.skipped"),
        _ => Loc.T("deploy.step.pending"),
    };

    public bool IsFailed => _status == DeployStepStatus.Failed;

    public bool IsSucceeded => _status == DeployStepStatus.Succeeded;

    public bool IsRunning => _status == DeployStepStatus.Running;

    public void Update(DeployStepStatus status, string? detail)
    {
        _status = status;
        if (!string.IsNullOrWhiteSpace(detail))
        {
            _detail = detail!;
        }
        OnPropertyChanged(nameof(Status));
        OnPropertyChanged(nameof(StatusLabel));
        OnPropertyChanged(nameof(Detail));
        OnPropertyChanged(nameof(IsFailed));
        OnPropertyChanged(nameof(IsSucceeded));
        OnPropertyChanged(nameof(IsRunning));
    }

    public void RefreshLabels() => OnPropertyChanged(nameof(StatusLabel));
}

/// <summary>
/// One row of the Deploy prerequisites panel: a status light (green = ready, red = not
/// yet), a short label, the probe detail and — when red — one actionable hint.
/// </summary>
public sealed class DeployPrerequisiteRow : ObservableObject
{
    private DeployPrerequisite _prerequisite;
    private string _line = string.Empty;
    private string _hint = string.Empty;
    private string _note = string.Empty;

    public DeployPrerequisiteRow(DeployPrerequisite prerequisite, LocalizedText text)
    {
        _prerequisite = prerequisite;
        Kind = prerequisite.Kind;
        Apply(text);
    }

    public DeployPrerequisiteKind Kind { get; }

    public bool IsReady => _prerequisite.Ready;

    /// <summary>Label + probe detail on one line (detail is omitted while the row is red).</summary>
    public string Line => _line;

    /// <summary>One short action shown below a red row.</summary>
    public string Hint => _hint;

    public bool ShowRedHint => !IsReady;

    /// <summary>Apple-ID note under the green signing row (the login cannot be probed).</summary>
    public string Note => _note;

    public bool ShowNote => IsReady && Kind == DeployPrerequisiteKind.SigningTools;

    public void RefreshLabels(LocalizedText text) => Apply(text);

    private void Apply(LocalizedText text)
    {
        var label = text.DeployPrereqLabel(Kind);
        _line = IsReady && !string.IsNullOrWhiteSpace(_prerequisite.Detail)
            ? label + " · " + _prerequisite.Detail
            : label;
        _hint = text.DeployPrereqHint(Kind, IsReady ? string.Empty : _prerequisite.Detail);
        _note = Kind == DeployPrerequisiteKind.SigningTools ? text.DeployPrereqSigningNote : string.Empty;
        OnPropertyChanged(nameof(IsReady));
        OnPropertyChanged(nameof(Line));
        OnPropertyChanged(nameof(Hint));
        OnPropertyChanged(nameof(ShowRedHint));
        OnPropertyChanged(nameof(Note));
        OnPropertyChanged(nameof(ShowNote));
    }
}

/// <summary>One row of the readiness panel (auto self-check result).</summary>
public sealed class ToolRow : ObservableObject
{
    public ToolRow(string name, string state, string message)
    {
        Name = name;
        State = state;
        Message = message;
    }

    public string Name { get; }

    public string State { get; }

    public string Message { get; }

    public bool Ready => State == "ready";

    public string StateLabel => State switch
    {
        "ready" => Loc.T("tool.state.ready"),
        "missing" => Loc.T("tool.state.missing"),
        "failed" => Loc.T("tool.state.failed"),
        _ => State,
    };

    public void RefreshLabels() => OnPropertyChanged(nameof(StateLabel));
}

/// <summary>
/// v2 view model: exactly two top-level sections (Library, Deploy) plus a minimal
/// Settings overlay. Library imports/lists/removes games and can pre-build a GamePack
/// ("Build now"/"Build all") ahead of a deploy, reusing the cache when the recorded
/// buildCompatVersion + ROM SHA-256 still match; Deploy selects one or many and runs one
/// chained action (compile -> compose -> sign/install -> push -> verify).
/// Build mode / tool paths / bundle id / UDID controls are gone: tools are auto-detected.
/// </summary>
public sealed class MainViewModel : ObservableObject
{
    private readonly LauncherServices _services;
    private DeviceInfo? _device;
    private ShellManifest? _shell;
    private bool _isBusy;
    private bool _importRunning;
    private bool _showSettings;
    private bool _showDiagnostics;
    private bool _showDeployLog;
    private string _section = "library";
    private string _statusText = string.Empty;
    private string _deviceStatus = string.Empty;
    private string _shellStatus = string.Empty;
    private string _installedStatus = string.Empty;
    private Task? _prerequisiteRefresh;
    private string _readinessState = "checking";
    private string _readinessDetail = string.Empty;
    private string _deployState = "idle";
    private string _deployMessage = string.Empty;
    private string _deployStepName = string.Empty;
    private string _deployErrorTitle = string.Empty;
    private string _deployErrorDetail = string.Empty;
    private string _deployErrorFix = string.Empty;
    private CancellationTokenSource? _deployCancellation;
    private TaskCompletionSource? _deployCompletion;
    private double _progressValue;
    private LocalizedText _localized = new();
    private LanguageChoice? _selectedLanguage;
    private UiLanguagePreference _languagePreference = UiLanguagePreference.System;
    private readonly HardwareProfile _hardware = HardwareProbe.Current;
    private BuildCompatibility? _buildCompatibility;
    private bool _libraryBuildRunning;
    private string _deviceAppStatus = string.Empty;
    private string _deviceGamesStatus = string.Empty;
    private string _deployPlanStatus = string.Empty;
    private string _deviceOrphanStatus = string.Empty;
    private bool _hasOrphanedGamesBlock;
    private string _buildPackageStatus = string.Empty;
    private bool _hasBuildPackageStatus;
    private bool _isBuildPackageWarning;
    private string? _pendingImportReplacePath;
    private string _orphanedGamesWarning = string.Empty;

    public MainViewModel() : this(LauncherServices.Create())
    {
    }

    public MainViewModel(LauncherServices services)
    {
        _services = services;
        _languagePreference = LanguageCatalog.ParsePreference(_services.Workspace.State.Language);
        Loc.ApplyPreference(_languagePreference, CultureInfo.CurrentUICulture.Name);
        StatusText = Loc.T("status.ready");
        DeviceStatus = Loc.T("deploy.deviceNone");
        ShowLibraryCommand = new RelayCommand(ShowLibrary);
        ShowDeployCommand = new RelayCommand(ShowDeploy);
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        CloseSettingsCommand = new RelayCommand(CloseSettings);
        DeployCommand = new AsyncRelayCommand(() => RunDeployAsync(), () => CanDeploy);
        ConfirmOrphanedDeployCommand = new AsyncRelayCommand(() => RunDeployAsync(acceptOrphaned: true), () => CanConfirmOrphanedDeploy);
        StopDeployCommand = new RelayCommand(StopDeploy, () => CanStopDeploy);
        BuildAllCommand = new AsyncRelayCommand(() => BuildAllGamesAsync(), () => !IsBusy && Games.Count > 0);
        SelectAllCommand = new RelayCommand(() => SetAllSelected(true));
        SelectNoneCommand = new RelayCommand(() => SetAllSelected(false));
        RefreshDevicesCommand = new AsyncRelayCommand(() => RefreshDevicesAsync(), () => !IsBusy);
        RefreshPrerequisitesCommand = new AsyncRelayCommand(() => RefreshDeployPrerequisitesAsync(), () => !IsBusy);
        RefreshStatusCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        RefreshReadinessCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        OpenImpactorCommand = new RelayCommand(OpenImpactor, () => !IsBusy);
        OpenWorkspaceCommand = new RelayCommand(OpenWorkspace);
        ExportLogCommand = new RelayCommand(() => ExportLogRequested?.Invoke());
        ToggleDiagnosticsCommand = new RelayCommand(ToggleDiagnostics);
        ToggleDeployLogCommand = new RelayCommand(ToggleDeployLog);
        ImportBuildPackageCommand = new AsyncRelayCommand(() =>
        {
            ImportBuildPackageRequested?.Invoke();
            return Task.CompletedTask;
        }, () => !IsBusy);
        ConfirmImportReplaceCommand = new AsyncRelayCommand(ConfirmImportReplaceAsync, () => CanConfirmImportReplace);
        ResetAdvancedBuildCommand = new RelayCommand(() => UpdateBuildOptions(AdvancedBuildOptions.Default), () => !IsBusy);
        RebuildLanguageOptions();
        RebuildDeploySteps();
        Log($"workspace: {_services.Workspace.Root} ({_services.Workspace.RootReason})");
        if (_services.Workspace.Migration is { Attempted: true } migration)
        {
            Log(migration.Migrated
                ? $"workspace migrated from {PortableLayout.LegacyWorkspaceRoot()} ({migration.FilesCopied} file(s) copied; the old folder is kept)"
                : "workspace migration warning: " + (migration.Warning ?? "state.json could not be copied"));
        }
        Log($"distribution: {DistributionRoot} ({DistributionLayout.Prepare().Reason ?? "resolved"})");
        Log("hardware: " + _hardware.Describe());
        Log("3ds2apple launcher v2 started. Add your own decrypted .3ds/.cci in Library, then deploy it in one click.");
    }

    public ObservableCollection<GameRow> Games { get; } = new();

    public ObservableCollection<DeployRow> DeployGames { get; } = new();

    public ObservableCollection<DeployStepRow> DeploySteps { get; } = new();

    /// <summary>Five green/red prerequisites shown at the top of the Deploy page.</summary>
    public ObservableCollection<DeployPrerequisiteRow> DeployPrerequisites { get; } = new();

    public ObservableCollection<LanguageChoice> LanguageOptions { get; } = new();

    public ObservableCollection<ToolRow> Tools { get; } = new();

    public ObservableCollection<string> LogLines { get; } = new();

    /// <summary>Raised by the settings "Export log" button; the view shows a save picker.</summary>
    public event Action? ExportLogRequested;

    /// <summary>Raised by the Library "Import .32a" button; the view shows a file picker.</summary>
    public event Action? ImportBuildPackageRequested;

    public RelayCommand ShowLibraryCommand { get; }
    public RelayCommand ShowDeployCommand { get; }
    public RelayCommand OpenSettingsCommand { get; }
    public RelayCommand CloseSettingsCommand { get; }
    public AsyncRelayCommand DeployCommand { get; }
    public AsyncRelayCommand ConfirmOrphanedDeployCommand { get; }
    public RelayCommand StopDeployCommand { get; }
    public AsyncRelayCommand BuildAllCommand { get; }
    public RelayCommand SelectAllCommand { get; }
    public RelayCommand SelectNoneCommand { get; }
    public AsyncRelayCommand RefreshDevicesCommand { get; }
    public AsyncRelayCommand RefreshPrerequisitesCommand { get; }
    public AsyncRelayCommand RefreshStatusCommand { get; }
    public AsyncRelayCommand RefreshReadinessCommand { get; }
    public RelayCommand OpenImpactorCommand { get; }
    public RelayCommand OpenWorkspaceCommand { get; }
    public RelayCommand ExportLogCommand { get; }
    public RelayCommand ToggleDiagnosticsCommand { get; }
    public RelayCommand ToggleDeployLogCommand { get; }
    public AsyncRelayCommand ImportBuildPackageCommand { get; }
    public AsyncRelayCommand ConfirmImportReplaceCommand { get; }
    public RelayCommand ResetAdvancedBuildCommand { get; }

    /// <summary>Localized UI strings; replaced whenever the language changes.</summary>
    public LocalizedText L { get => _localized; private set => SetProperty(ref _localized, value); }

    public string WindowTitle => L.AppTitle + " · " + LauncherInfo.Version;

    // --- view state --------------------------------------------------------

    public bool IsLibrarySection => !_showSettings && _section == "library";

    public bool IsDeploySection => !_showSettings && _section == "deploy";

    public bool ShowSettings => _showSettings;

    public bool ShowDiagnostics => _showDiagnostics;

    public string DiagnosticsToggleLabel => _showDiagnostics ? L.SettingsLogsHide : L.SettingsLogsShow;

    public bool ShowDeployLog => _showDeployLog;

    public string DeployLogToggleLabel => _showDeployLog ? L.DeployLogHide : L.DeployLogShow;

    public bool IsBusy
    {
        get => _isBusy;
        private set
        {
            if (SetProperty(ref _isBusy, value))
            {
                OnPropertyChanged(nameof(IsNotBusy));
                OnPropertyChanged(nameof(CanDeploy));
                RaiseCommandStates();
            }
        }
    }

    public bool IsNotBusy => !IsBusy;

    public string StatusText { get => _statusText; private set => SetProperty(ref _statusText, value); }

    public double ProgressValue { get => _progressValue; private set => SetProperty(ref _progressValue, value); }

    public bool IsImportRunning { get => _importRunning; private set => SetProperty(ref _importRunning, value); }

    public string WorkspaceRoot => _services.Workspace.Root;

    public string DistributionRoot => _services.Locator.DistributionRoot;

    public string DistributionLine => Loc.T("settings.distribution", DistributionRoot);

    /// <summary>Settings/Diagnostics: where games and state live, and why that root was chosen.</summary>
    public string WorkspaceInfoLine => Loc.T("settings.workspaceInfo", WorkspaceRoot, WorkspaceReasonText);

    /// <summary>Settings/Diagnostics: where the bundled tools were extracted, and why.</summary>
    public string DistributionInfoLine => Loc.T("settings.distributionInfo", DistributionRoot, DistributionReasonText);

    public string WorkspaceReasonText => _services.Workspace.RootKind switch
    {
        DataRootKind.Portable => Loc.T("layout.portable"),
        DataRootKind.LocalAppData => Loc.T("layout.localAppData"),
        DataRootKind.Explicit => Loc.T("layout.explicit"),
        _ => Loc.T("layout.temp"),
    };

    public string DistributionReasonText
    {
        get
        {
            try
            {
                var prepared = DistributionLayout.Prepare();
                if (string.Equals(prepared.Root, DistributionRoot, StringComparison.OrdinalIgnoreCase))
                {
                    return prepared.Portable ? Loc.T("layout.portable") : Loc.T("layout.localAppData");
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // never break the settings page because a probe failed
            }
            return Loc.T("layout.explicit");
        }
    }

    /// <summary>Compact Deploy line: cores, RAM and the compiler's automatic parallelism (no jobs setting).</summary>
    public string HardwareLine => Loc.T("deploy.hardware", _hardware.LogicalCores, _hardware.PhysicalCores, _hardware.TotalMemoryGb, _hardware.AvailableMemoryGb);

    public string HardwareDiagnostics => _hardware.Describe();

    public string CurrentLogPath => _services.Workspace.CurrentLogPath;

    // --- library -----------------------------------------------------------

    public bool HasGames => Games.Count > 0;

    public bool IsLibraryEmpty => Games.Count == 0;

    // --- Deploy -> Advanced settings (AOT codegen options, applied to the next build) ---

    public IReadOnlyList<string> AotOptLevelOptions => AdvancedBuildOptions.OptLevels;

    public string SelectedAotOptLevel
    {
        get => _services.Workspace.BuildOptions.OptLevel;
        set
        {
            if (!AdvancedBuildOptions.OptLevels.Contains(value) || string.Equals(value, SelectedAotOptLevel, StringComparison.Ordinal))
            {
                return;
            }
            UpdateBuildOptions(new AdvancedBuildOptions(value, AotLto, AotFastMath));
        }
    }

    public bool AotLto
    {
        get => _services.Workspace.BuildOptions.Lto;
        set
        {
            if (value == AotLto)
            {
                return;
            }
            UpdateBuildOptions(new AdvancedBuildOptions(SelectedAotOptLevel, value, AotFastMath));
        }
    }

    public bool AotFastMath
    {
        get => _services.Workspace.BuildOptions.FastMath;
        set
        {
            if (value == AotFastMath)
            {
                return;
            }
            UpdateBuildOptions(new AdvancedBuildOptions(SelectedAotOptLevel, AotLto, value));
        }
    }

    public bool IsAdvancedBuildCustomized => !_services.Workspace.BuildOptions.IsDefault;

    public string AdvancedBuildSummary => Loc.T("deploy.advanced.summary", _services.Workspace.BuildOptions.Describe());

    /// <summary>Persist one advanced-option change; the cache key includes it, so affected packs rebuild.</summary>
    private void UpdateBuildOptions(AdvancedBuildOptions options)
    {
        var normalized = options.Normalized();
        _services.Workspace.SetBuildOptions(normalized);
        OnPropertyChanged(nameof(SelectedAotOptLevel));
        OnPropertyChanged(nameof(AotLto));
        OnPropertyChanged(nameof(AotFastMath));
        OnPropertyChanged(nameof(IsAdvancedBuildCustomized));
        OnPropertyChanged(nameof(AdvancedBuildSummary));
        Log("advanced build settings: " + normalized.CacheMarker
            + " (applied to the next build; the build cache key includes these options)");
        _ = RefreshAfterAdvancedOptionsChangeAsync();
    }

    private async Task RefreshAfterAdvancedOptionsChangeAsync()
    {
        await ResolveBuildCompatibilityAsync().ConfigureAwait(true);
        foreach (var row in Games)
        {
            row.Refresh();
        }
    }

    public string GameCountText => Loc.T("library.count", Games.Count);

    public string BuildAllLabel => L.LibraryBuildAll;

    /// <summary>true while a Library "Build now"/"Build all" batch is compiling.</summary>
    public bool IsLibraryBuildRunning
    {
        get => _libraryBuildRunning;
        private set
        {
            if (SetProperty(ref _libraryBuildRunning, value))
            {
                OnPropertyChanged(nameof(IsLibraryBuildProgressVisible));
            }
        }
    }

    public bool IsLibraryBuildProgressVisible => _libraryBuildRunning;

    /// <summary>Result of the last .32a export/import: output path or the exact error/conflict.</summary>
    public string BuildPackageStatus
    {
        get => _buildPackageStatus;
        private set => SetProperty(ref _buildPackageStatus, value);
    }

    public bool HasBuildPackageStatus
    {
        get => _hasBuildPackageStatus;
        private set => SetProperty(ref _hasBuildPackageStatus, value);
    }

    /// <summary>true: the status is a warning/conflict (red); false: a success path (accent).</summary>
    public bool IsBuildPackageWarning
    {
        get => _isBuildPackageWarning;
        private set => SetProperty(ref _isBuildPackageWarning, value);
    }

    public bool CanConfirmImportReplace => _pendingImportReplacePath is not null && !IsBusy;

    /// <summary>Current local-build recipe identity; null until the toolchain probe finished.</summary>
    public BuildCompatibility? CurrentBuildCompatibility => _buildCompatibility;

    /// <summary>Automatic startup self-check result (green/red status light in the status bar).</summary>
    public bool IsReadinessReady => _readinessState == "ready";

    public bool IsReadinessFailed => _readinessState == "failed";

    public bool IsReadinessChecking => _readinessState == "checking";

    public string ReadinessLabel => _readinessState switch
    {
        "ready" => Loc.T("readiness.status.ready"),
        "failed" => Loc.T("readiness.status.failed"),
        _ => Loc.T("readiness.status.checking"),
    };

    public string ReadinessDetail => _readinessDetail;

    public async Task ImportAsync(IReadOnlyList<string> paths)
    {
        var pack = _services.Pack;
        if (pack is null)
        {
            Log("3ds2apple-pack.exe was not found. Reinstall the launcher package so Bin/3ds2apple-pack.exe exists.");
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
                // Re-importing an existing library game passes --force so the pack CLI
                // refreshes SMDH metadata and re-extracts a stale (pre-0.2.5) cover.png;
                // an existing built GamePack and the queue state are kept.
                var alreadyImported = _services.Workspace.Find(inspect.Roms[0].TitleID) is not null;
                var added = await pack.AddAsync(new[] { path }, null, force: alreadyImported).ConfigureAwait(true);
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
                entry.DisplayNames = imported.DisplayNames is null
                    ? entry.DisplayNames
                    : new Dictionary<string, string>(imported.DisplayNames, StringComparer.OrdinalIgnoreCase);
                entry.Publisher = GameNames.ResolvePublisher(imported.Publisher);
                entry.ProductCode = imported.ProductCode;
                entry.Region = string.IsNullOrWhiteSpace(imported.Region) ? entry.Region : imported.Region.Trim();
                entry.RomPath = path;
                entry.PackageDir = imported.PackageDir;
                entry.CoverPath = GameNames.ResolveCoverPath(imported.PackageDir, imported.CoverPath);
                entry.State = "queued";
                entry.LastError = null;
                _services.Workspace.Upsert(entry);
                _services.Workspace.SaveState();
                Log($"imported {imported.TitleID}  {imported.DisplayName}  {imported.ProductCode}"
                    + (string.IsNullOrWhiteSpace(entry.Publisher) ? string.Empty : "  " + entry.Publisher)
                    + (entry.CoverPath is null ? "  (no SMDH icon)" : "  (SMDH icon + " + entry.DisplayNames.Count + " language name(s))")
                    + (alreadyImported ? "  (re-import: SMDH metadata refreshed)" : string.Empty)
                    + "  (headers only; Deploy sends it later)");
            }
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            StatusText = Loc.T("status.importFinished");
            ShowLibrary();
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
                if (info.DisplayNames is { Count: > 0 })
                {
                    entry.DisplayNames = new Dictionary<string, string>(info.DisplayNames, StringComparer.OrdinalIgnoreCase);
                }
                if (!string.IsNullOrWhiteSpace(info.Publisher))
                {
                    entry.Publisher = GameNames.ResolvePublisher(info.Publisher);
                }
                if (!string.IsNullOrWhiteSpace(info.Region))
                {
                    entry.Region = info.Region.Trim();
                }
                entry.ProductCode = info.ProductCode;
                entry.State = info.State;
                entry.Pack = info.Pack;
                entry.PackageDir ??= Path.Combine(_services.Workspace.OutRoot, "packages", info.TitleID);
                entry.CoverPath = GameNames.ResolveCoverPath(entry.PackageDir, info.CoverPath ?? entry.CoverPath);
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
        var previousSelection = DeployGames.ToDictionary(row => row.TitleID, row => row.IsSelected, StringComparer.OrdinalIgnoreCase);
        DeployGames.Clear();
        foreach (var entry in _services.Workspace.State.Games.OrderBy(game => game.TitleID, StringComparer.Ordinal))
        {
            var selected = !previousSelection.TryGetValue(entry.TitleID, out var wasSelected) || wasSelected;
            DeployGames.Add(new DeployRow(this, entry, selected));
        }
        _services.Workspace.SaveState();
        OnPropertyChanged(nameof(HasGames));
        OnPropertyChanged(nameof(IsLibraryEmpty));
        OnPropertyChanged(nameof(GameCountText));
        OnPropertyChanged(nameof(DeploySelectedCountText));
        OnPropertyChanged(nameof(CanDeploy));
        OnPropertyChanged(nameof(IsDeployEmpty));
        RaiseCommandStates();
    }

    public async Task RemoveGameAsync(GameRow row)
    {
        var title = row.TitleID;
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

    // --- library "Build now" + build cache ---------------------------------

    /// <summary>
    /// Library card build state: "Built · cache bXXXX", or the exact reason a rebuild is
    /// needed (no marker yet / build recipe changed / ROM changed). Cheap: only the ROM
    /// file size + last-write time are checked here; Deploy/Build now re-hash when needed.
    /// </summary>
    public (string Text, bool Current) DescribeBuild(LibraryEntry entry)
    {
        if (entry.Pack is null || entry.Pack.IsPlaceholder)
        {
            return (Loc.T("library.card.notBuilt"), false);
        }
        var artifact = entry.Build;
        if (artifact is null || string.IsNullOrWhiteSpace(artifact.BuildCompatVersion))
        {
            return (Loc.T("library.buildStatus.noRecord"), false);
        }
        if (_buildCompatibility is not null
            && !string.Equals(artifact.BuildCompatVersion, _buildCompatibility.BuildCompatVersion, StringComparison.Ordinal))
        {
            return (Loc.T("library.buildStatus.rebuildCompat"), false);
        }
        if (RomFingerprintChanged(entry, artifact))
        {
            return (Loc.T("library.buildStatus.rebuildRom"), false);
        }
        var label = string.IsNullOrWhiteSpace(artifact.BuildCompatShort)
            ? BuildCompatibility.ShortLabel(artifact.BuildCompatVersion)
            : artifact.BuildCompatShort;
        return (Loc.T("library.buildStatus.built", label), true);
    }

    private static bool RomFingerprintChanged(LibraryEntry entry, BuildArtifact artifact)
    {
        try
        {
            var info = new FileInfo(entry.RomPath);
            if (!info.Exists)
            {
                return true;
            }
            if (artifact.RomBytes > 0 && info.Length != artifact.RomBytes)
            {
                return true;
            }
            return artifact.RomLastWriteUtc is { } recorded && info.LastWriteTimeUtc != recorded.UtcDateTime;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return true;
        }
    }

    /// <summary>Library card "Build now": compile (or reuse) this one game's GamePack.</summary>
    public async Task BuildGameAsync(GameRow row)
    {
        if (IsBusy)
        {
            return;
        }
        await BuildEntriesAsync(new[] { row.Entry }).ConfigureAwait(true);
    }

    /// <summary>Library "Build all": compile (or reuse) every imported game in order.</summary>
    public Task BuildAllGamesAsync() =>
        IsBusy ? Task.CompletedTask : BuildEntriesAsync(Games.Select(row => row.Entry).ToList());

    private async Task BuildEntriesAsync(IReadOnlyList<LibraryEntry> entries)
    {
        if (entries.Count == 0)
        {
            return;
        }
        var service = _services.CreateLibraryBuildService();
        IsLibraryBuildRunning = true;
        SetBusy(true, Loc.T("status.building"));
        ProgressValue = 0;
        try
        {
            var progress = new Progress<BuildProgress>(value =>
            {
                if (value.Percent is { } percent)
                {
                    ProgressValue = Math.Clamp(percent, 0, 100);
                }
                if (!string.IsNullOrWhiteSpace(value.Message))
                {
                    StatusText = value.Message!;
                }
            });
            var report = await service.BuildAsync(
                entries,
                entry => GameNames.Resolve(entry.DisplayNames, entry.DisplayName, Loc.CurrentTag),
                progress,
                line => Log("[build] " + line)).ConfigureAwait(true);
            ProgressValue = 100;
            StatusText = Loc.T("status.buildSummary", report.BuiltCount, report.ReusedCount, report.FailedCount);
            foreach (var failed in report.Items.Where(item => !item.Success))
            {
                Log("build failed (" + failed.TitleID + "): " + (failed.ErrorMessage ?? failed.ErrorCode));
            }
            foreach (var reused in report.Items.Where(item => item.Success && item.Reused))
            {
                Log("build: " + reused.TitleID + " reused the cached GamePack");
            }
        }
        catch (Exception exception)
        {
            Log("build failed: " + exception.Message);
            StatusText = Loc.T("status.buildFailed");
        }
        finally
        {
            IsLibraryBuildRunning = false;
            SetBusy(false, Loc.T("status.ready"));
            await ResolveBuildCompatibilityAsync().ConfigureAwait(true);
            await RefreshLibraryAsync().ConfigureAwait(true);
        }
    }

    // --- library build packages (.32a) -------------------------------------

    /// <summary>Library card "Export .32a": write the portable build package for one game.</summary>
    public async Task ExportBuildPackageAsync(GameRow row)
    {
        if (IsBusy)
        {
            return;
        }
        var service = _services.CreateBuildPackageService();
        SetBusy(true, Loc.T("status.buildPackageExport"));
        try
        {
            var compatibility = _buildCompatibility ?? await _services.BuildCompatibility.ResolveAsync().ConfigureAwait(true);
            _buildCompatibility = compatibility;
            var outcome = await service.ExportAsync(new[] { row.TitleID }, compatibility).ConfigureAwait(true);
            if (!outcome.Ok)
            {
                var detail = outcome.Errors.Count > 0 ? string.Join("; ", outcome.Errors) : outcome.Error ?? "no build package was written";
                SetBuildPackageStatus(Loc.T("library.buildPackage.exportFailed", detail), warning: true);
                Log("build package export failed (" + row.TitleID + "): " + detail);
                StatusText = Loc.T("status.buildPackageExportFailed");
                return;
            }
            var package = outcome.Packages[0];
            var rom = package.RomIncluded
                ? Loc.T("library.buildPackage.withRom")
                : Loc.T("library.buildPackage.withoutRom");
            SetBuildPackageStatus(Loc.T("library.buildPackage.exported", package.Path, rom), warning: !package.RomIncluded);
            Log("exported build package " + package.TitleID + " -> " + package.Path
                + " (" + package.Bytes + " bytes, sha256 " + package.Sha256
                + ", rom " + (package.RomIncluded ? "included" : "not included") + ")");
            if (!package.RomIncluded)
            {
                Log("warning: the .32a does not contain game data; deploy it together with the original ROM.");
            }
            Log("warning: a .32a can contain game data; keep it local and never upload or commit it.");
            foreach (var warning in package.Warnings)
            {
                Log("build package: " + warning);
            }
            StatusText = Loc.T("status.buildPackageExported");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            SetBuildPackageStatus(Loc.T("library.buildPackage.exportFailed", exception.Message), warning: true);
            Log("build package export failed: " + exception.Message);
            StatusText = Loc.T("status.buildPackageExportFailed");
        }
        finally
        {
            SetBusy(false, Loc.T("status.ready"));
        }
    }

    /// <summary>Library "Import .32a": called by the view after its file picker.</summary>
    public Task ImportBuildPackageAsync(string path) => ImportBuildPackageCoreAsync(path, replace: false);

    private async Task ConfirmImportReplaceAsync()
    {
        var path = _pendingImportReplacePath;
        if (path is null)
        {
            return;
        }
        await ImportBuildPackageCoreAsync(path, replace: true).ConfigureAwait(true);
    }

    private async Task ImportBuildPackageCoreAsync(string path, bool replace)
    {
        if (IsBusy)
        {
            return;
        }
        var service = _services.CreateBuildPackageService();
        SetBusy(true, Loc.T("status.buildPackageImport"));
        try
        {
            var outcome = await service.ImportAsync(path, replace).ConfigureAwait(true);
            if (!outcome.Ok)
            {
                var message = outcome.Error ?? "unknown error";
                if (!replace && message.Contains("--replace", StringComparison.OrdinalIgnoreCase))
                {
                    _pendingImportReplacePath = path;
                    SetBuildPackageStatus(Loc.T("library.buildPackage.conflict", message), warning: true);
                    Log("build package import needs confirmation: " + message);
                    StatusText = Loc.T("status.buildPackageConflict");
                    return;
                }
                _pendingImportReplacePath = null;
                SetBuildPackageStatus(Loc.T("library.buildPackage.importFailed", message), warning: true);
                Log("build package import failed: " + message);
                StatusText = Loc.T("status.buildPackageImportFailed");
                return;
            }
            _pendingImportReplacePath = null;
            var package = outcome.Package!;
            SetBuildPackageStatus(Loc.T("library.buildPackage.imported", package.DisplayName, package.PackageDir), warning: false);
            foreach (var warning in outcome.Warnings)
            {
                Log("build package: " + warning);
            }
            await RefreshLibraryAsync().ConfigureAwait(true);
            Log("imported build package " + package.TitleID + " from " + package.Path + " -> " + package.PackageDir
                + " (pack sha256 " + package.PackSha256 + ", rom " + (package.RomIncluded ? "included" : "not included") + ")");
            StatusText = Loc.T("status.buildPackageImported");
            ShowLibrary();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _pendingImportReplacePath = null;
            SetBuildPackageStatus(Loc.T("library.buildPackage.importFailed", exception.Message), warning: true);
            Log("build package import failed: " + exception.Message);
            StatusText = Loc.T("status.buildPackageImportFailed");
        }
        finally
        {
            SetBusy(false, Loc.T("status.ready"));
        }
    }

    /// <summary>Library card "Export IPA": compose one unsigned single-game IPA from the shell template.</summary>
    public async Task ExportIpaAsync(GameRow row)
    {
        if (IsBusy)
        {
            return;
        }
        if (_services.Pack is not { } packCli)
        {
            SetBuildPackageStatus(Loc.T("library.ipaExportFailed", "3ds2apple-pack was not found; reinstall the launcher package."), warning: true);
            return;
        }
        var packPath = row.Entry.PackPath;
        if (string.IsNullOrWhiteSpace(packPath) || !File.Exists(packPath))
        {
            SetBuildPackageStatus(Loc.T("library.ipaNeedsPack"), warning: true);
            return;
        }
        var shell = _shell ??= await _services.LoadShellAsync().ConfigureAwait(true);
        if (shell is null)
        {
            SetBuildPackageStatus(Loc.T("library.ipaExportFailed", Loc.T("library.ipaLibraryUnavailable")), warning: true);
            return;
        }
        var romPath = ResolveIpaRomPath(row);
        if (string.IsNullOrWhiteSpace(romPath) || !File.Exists(romPath))
        {
            SetBuildPackageStatus(Loc.T("library.ipaNeedsRom"), warning: true);
            return;
        }
        SetBusy(true, Loc.T("status.exportIpa"));
        try
        {
            var template = Path.Combine(_services.ShellDirectory, shell.FileName);
            var outputDirectory = Path.Combine(_services.Workspace.Root, SingleGameIpaExporter.ExportsDirectoryName);
            var exporter = new SingleGameIpaExporter(packCli);
            var pack = new ComposedPack(row.TitleID, row.Entry.DisplayName, row.Entry.ProductCode, 1, packPath);
            var result = await exporter.ExportAsync(
                template,
                pack,
                row.Entry.CoverPath,
                romPath,
                LauncherInfo.Version,
                outputDirectory,
                line => Log("[ipa] " + line)).ConfigureAwait(true);
            if (!result.Ok)
            {
                SetBuildPackageStatus(Loc.T("library.ipaExportFailed", result.Error ?? "unknown error"), warning: true);
                Log("single-game IPA export failed (" + row.TitleID + "): " + (result.Error ?? "unknown error"));
                StatusText = Loc.T("status.ipaExportFailed");
                return;
            }
            SetBuildPackageStatus(
                Loc.T("library.ipaExported", result.IpaPath!, result.Bytes + " bytes", Loc.T("library.ipaUnsignedHint")),
                warning: false);
            Log("exported unsigned single-game IPA " + result.IpaPath + " (" + result.Bytes + " bytes, sha256 " + result.Sha256
                + ", icons replaced " + result.ReplacedIconCount + ", embedded game data " + result.RomRelativePath
                + " " + result.RomBytes + " bytes) - contains the user's own game data; sign it yourself (Sideloadly/AltStore), keep it local, never upload it");
            foreach (var warning in result.Warnings)
            {
                Log("IPA export: " + warning);
            }
            StatusText = Loc.T("status.ipaExported");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            SetBuildPackageStatus(Loc.T("library.ipaExportFailed", exception.Message), warning: true);
            Log("single-game IPA export failed: " + exception.Message);
            StatusText = Loc.T("status.ipaExportFailed");
        }
        finally
        {
            SetBusy(false, Loc.T("status.ready"));
        }
    }

    /// <summary>ROM used for the single-game IPA: the library path, else the package's GameRom copy.</summary>
    private static string? ResolveIpaRomPath(GameRow row)
    {
        if (!string.IsNullOrWhiteSpace(row.Entry.RomPath) && File.Exists(row.Entry.RomPath))
        {
            return row.Entry.RomPath;
        }
        var packageDirectory = row.Entry.PackageDir;
        if (string.IsNullOrWhiteSpace(packageDirectory))
        {
            return null;
        }
        foreach (var extension in SingleGameIpaExporter.RomExtensions)
        {
            var candidate = Path.Combine(packageDirectory, "GameRom." + extension);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    private void SetBuildPackageStatus(string text, bool warning)
    {
        BuildPackageStatus = text;
        IsBuildPackageWarning = warning;
        HasBuildPackageStatus = !string.IsNullOrWhiteSpace(text);
        OnPropertyChanged(nameof(CanConfirmImportReplace));
        RaiseCommandStates();
    }

    /// <summary>Probe the local build recipe (toolchain ABI + versions) for the cache labels.</summary>
    private async Task ResolveBuildCompatibilityAsync()
    {
        try
        {
            _buildCompatibility = await _services.BuildCompatibility.ResolveAsync().ConfigureAwait(true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _buildCompatibility = null;
            Log("build compatibility probe failed: " + exception.Message);
        }
    }

    // --- deploy ------------------------------------------------------------

    public bool IsDeployEmpty => DeployGames.Count == 0;

    public int SelectedDeployCount => DeployGames.Count(row => row.IsSelected);

    public string DeploySelectedCountText => Loc.T("deploy.selectedCount", SelectedDeployCount, DeployGames.Count);

    public bool CanDeploy => !IsBusy && SelectedDeployCount > 0;

    public string DeployState => _deployState;

    public string DeployStateLabel => _deployState switch
    {
        "running" => Loc.T("deploy.state.running"),
        "done" => Loc.T("deploy.state.done"),
        "failed" => Loc.T("deploy.state.failed"),
        "cancelled" => Loc.T("deploy.state.cancelled"),
        _ => Loc.T("deploy.state.idle"),
    };

    public bool IsDeployIdle => _deployState == "idle";

    public bool IsDeployRunning => _deployState == "running";

    public bool IsDeployDone => _deployState == "done";

    public bool IsDeployFailed => _deployState == "failed";

    public bool IsDeployCancelled => _deployState == "cancelled";

    /// <summary>True while the running deploy can still be stopped (no stop requested yet).</summary>
    public bool CanStopDeploy => _deployState == "running" && _deployCancellation is { IsCancellationRequested: false };

    /// <summary>True while a deploy task is in flight; the window close handler waits on it.</summary>
    public bool HasRunningDeploy => _deployCompletion is not null;

    /// <summary>True while any tool-spawning operation runs (deploy, Library build or import).</summary>
    public bool HasActiveWork => HasRunningDeploy || IsLibraryBuildRunning || IsImportRunning;

    /// <summary>"n of 5 prerequisites ready" (or a checking label before the first probe).</summary>
    public string DeployPrereqSummary => DeployPrerequisites.Count == 0
        ? L.ReadinessStatusChecking
        : L.DeployPrereqSummary(DeployPrerequisites.Count(row => row.IsReady), DeployPrerequisites.Count);

    public string DeployMessage { get => _deployMessage; private set => SetProperty(ref _deployMessage, value); }

    public string DeployStepName { get => _deployStepName; private set => SetProperty(ref _deployStepName, value); }

    public string DeployErrorTitle { get => _deployErrorTitle; private set => SetProperty(ref _deployErrorTitle, value); }

    public string DeployErrorDetail { get => _deployErrorDetail; private set => SetProperty(ref _deployErrorDetail, value); }

    public string DeployErrorFix { get => _deployErrorFix; private set => SetProperty(ref _deployErrorFix, value); }

    public string DeviceStatus { get => _deviceStatus; private set => SetProperty(ref _deviceStatus, value); }

    public string ShellStatus { get => _shellStatus; private set => SetProperty(ref _shellStatus, value); }

    public string InstalledStatus { get => _installedStatus; private set => SetProperty(ref _installedStatus, value); }

    /// <summary>Device-aware Deploy lines: installed app version/package, installed game data, plan.</summary>
    public string DeviceAppStatus { get => _deviceAppStatus; private set => SetProperty(ref _deviceAppStatus, value); }

    public string DeviceGamesStatus { get => _deviceGamesStatus; private set => SetProperty(ref _deviceGamesStatus, value); }

    public string DeployPlanStatus
    {
        get => _deployPlanStatus;
        private set
        {
            if (SetProperty(ref _deployPlanStatus, value))
            {
                OnPropertyChanged(nameof(HasDeployPlanStatus));
            }
        }
    }

    public bool HasDeployPlanStatus => !string.IsNullOrWhiteSpace(_deployPlanStatus);

    /// <summary>Games that only exist on the phone (not in this library): data kept, app entry at risk.</summary>
    public string DeviceOrphanStatus
    {
        get => _deviceOrphanStatus;
        private set
        {
            if (SetProperty(ref _deviceOrphanStatus, value))
            {
                OnPropertyChanged(nameof(HasDeviceOrphans));
            }
        }
    }

    public bool HasDeviceOrphans => !string.IsNullOrWhiteSpace(_deviceOrphanStatus);

    public string OrphanedGamesWarning { get => _orphanedGamesWarning; private set => SetProperty(ref _orphanedGamesWarning, value); }

    public bool HasOrphanedGamesBlock
    {
        get => _hasOrphanedGamesBlock;
        private set
        {
            if (SetProperty(ref _hasOrphanedGamesBlock, value))
            {
                OnPropertyChanged(nameof(CanConfirmOrphanedDeploy));
                RaiseCommandStates();
            }
        }
    }

    /// <summary>True when the blocked-update confirmation button can run.</summary>
    public bool CanConfirmOrphanedDeploy => _hasOrphanedGamesBlock && !IsBusy && SelectedDeployCount > 0;

    public void OnDeploySelectionChanged()
    {
        OnPropertyChanged(nameof(SelectedDeployCount));
        OnPropertyChanged(nameof(DeploySelectedCountText));
        OnPropertyChanged(nameof(CanDeploy));
        RaiseCommandStates();
    }

    private void SetAllSelected(bool selected)
    {
        foreach (var row in DeployGames)
        {
            row.IsSelected = selected;
        }
        OnDeploySelectionChanged();
    }

    private void RebuildDeploySteps()
    {
        var kinds = new (DeployStepKind Kind, string Label)[]
        {
            (DeployStepKind.Build, L.DeployStepBuild),
            (DeployStepKind.Compose, L.DeployStepCompose),
            (DeployStepKind.Install, L.DeployStepInstall),
            (DeployStepKind.Push, L.DeployStepPush),
            (DeployStepKind.Verify, L.DeployStepVerify),
        };
        DeploySteps.Clear();
        foreach (var (kind, label) in kinds)
        {
            DeploySteps.Add(new DeployStepRow(kind, label));
        }
        OnPropertyChanged(nameof(DeploySteps));
    }

    private void ResetDeploySteps()
    {
        foreach (var row in DeploySteps)
        {
            row.Update(DeployStepStatus.Pending, string.Empty);
        }
    }

    private void SetDeployRunning()
    {
        _deployState = "running";
        DeployMessage = string.Empty;
        DeployStepName = string.Empty;
        DeployErrorTitle = string.Empty;
        DeployErrorDetail = string.Empty;
        DeployErrorFix = string.Empty;
        DeployPlanStatus = string.Empty;
        HasOrphanedGamesBlock = false;
        OrphanedGamesWarning = string.Empty;
        ProgressValue = 0;
        OnPropertyChanged(nameof(DeployState));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(IsDeployIdle));
        OnPropertyChanged(nameof(IsDeployRunning));
        OnPropertyChanged(nameof(IsDeployDone));
        OnPropertyChanged(nameof(IsDeployFailed));
        OnPropertyChanged(nameof(IsDeployCancelled));
        RaiseCommandStates();
    }

    public async Task RunDeployAsync(bool acceptOrphaned = false)
    {
        if (IsBusy)
        {
            return;
        }
        var selected = DeployGames.Where(row => row.IsSelected).Select(row => row.Entry).ToList();
        if (selected.Count == 0)
        {
            DeployMessage = Loc.T("deploy.needSelection");
            OnPropertyChanged(nameof(DeployMessage));
            StatusText = Loc.T("deploy.needSelection");
            return;
        }
        _shell ??= await _services.LoadShellAsync().ConfigureAwait(true);
        if (_shell is null)
        {
            SetDeployFailed(DeployStepKind.Compose, "shell_missing", L.DeployNeedShell, L.DeployToolchainFix);
            return;
        }
        var orchestrator = _services.CreateDeployOrchestrator(_shell);
        ResetDeploySteps();
        SetDeployRunning();
        Log("[deploy] hardware: " + _hardware.Describe());
        SetBusy(true, L.DeployRunning);
        var cancellation = new CancellationTokenSource();
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _deployCancellation = cancellation;
        _deployCompletion = completion;
        RaiseCommandStates();
        try
        {
            var templateIpa = Path.Combine(_services.ShellDirectory, _shell.FileName);
            var request = new DeployRequest(
                selected.Select(entry => entry.TitleID).ToList(),
                templateIpa,
                BundleIdOverride: null,
                DeviceUdid: _device?.Udid,
                RebuildExistingPacks: false,
                AcceptOrphanedGames: acceptOrphaned);
            var progress = new Progress<DeployProgress>(ApplyDeployProgress);
            var outcome = await orchestrator.RunAsync(request, progress, line => Log("[deploy] " + line), cancellation.Token).ConfigureAwait(true);
            ApplyDeployOutcome(outcome);
        }
        catch (OperationCanceledException)
        {
            // The orchestrator normally turns a stop into a Cancelled outcome; this is the
            // belt-and-braces path if a stage throws directly.
            Log("deploy stopped: the running step observed the stop request.");
            ApplyDeployCancelled();
        }
        catch (Exception exception)
        {
            Log("deploy crashed: " + exception.Message);
            SetDeployFailed(DeployStepKind.Build, "deploy_exception", exception.Message, L.DeployFailedHelp);
        }
        finally
        {
            _deployCancellation = null;
            cancellation.Dispose();
            completion.TrySetResult();
            _deployCompletion = null;
            SetBusy(false, Loc.T("status.ready"));
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            await RefreshDeployPrerequisitesAsync().ConfigureAwait(true);
        }
    }

    private void ApplyDeployProgress(DeployProgress progress)
    {
        var row = DeploySteps.FirstOrDefault(step => step.Kind == progress.Step);
        row?.Update(progress.Status, progress.Message);
        if (progress.Percent is { } percent)
        {
            ProgressValue = Math.Clamp(percent, 0, 100);
        }
        if (row is not null)
        {
            DeployStepName = row.Label + " · " + progress.Message;
        }
        if (progress.Status == DeployStepStatus.Failed)
        {
            DeployErrorDetail = progress.Message;
            OnPropertyChanged(nameof(DeployErrorDetail));
        }
    }

    private void ApplyDeployOutcome(DeployOutcome outcome)
    {
        foreach (var game in outcome.Games)
        {
            var row = DeployGames.FirstOrDefault(item => string.Equals(item.TitleID, game.TitleID, StringComparison.OrdinalIgnoreCase));
            row?.Refresh();
        }
        if (outcome.Cancelled)
        {
            ApplyDeployCancelled();
            return;
        }
        if (outcome.Success)
        {
            _deployState = "done";
            ProgressValue = 100;
            DeployMessage = L.DeployDoneBody;
            DeployStepName = string.Empty;
            DeployErrorTitle = string.Empty;
            DeployErrorDetail = string.Empty;
            DeployErrorFix = string.Empty;
            StatusText = L.DeployDoneTitle;
            Log("deploy done: " + L.DeployDoneTitle + (outcome.ComposedIpaPath is null ? string.Empty : " (" + outcome.ComposedIpaPath + ")"));
            DeployPlanStatus = outcome.DeviceSummary is { } deviceSummary
                ? LocalizeDeployMode(deviceSummary.Mode, deviceSummary.IpaGameCount, deviceSummary.PushedGameCount)
                : string.Empty;
            HasOrphanedGamesBlock = false;
            OrphanedGamesWarning = string.Empty;
        }
        else if (outcome.ErrorCode == "orphaned_games_need_confirmation"
                 && outcome.OrphanedGames is { Count: > 0 } orphaned)
        {
            // Explicit confirmation required: the update would remove these games' app entries
            // (their GameRom/saves stay in Documents; nothing is deleted).
            HasOrphanedGamesBlock = true;
            OrphanedGamesWarning = Loc.T("deploy.orphans.blockedDetail", orphaned.Count,
                string.Join(", ", orphaned.Select(game => game.Describe())));
            SetDeployFailed(
                outcome.FailedStep ?? DeployStepKind.Install,
                outcome.ErrorCode!,
                L.DeployOrphansBlockedTitle,
                L.DeployOrphansConfirmHint);
            DeployErrorDetail = OrphanedGamesWarning;
            OnPropertyChanged(nameof(DeployErrorDetail));
            StatusText = L.DeployFailedTitle;
            Log("deploy paused for confirmation: " + orphaned.Count + " phone-only game(s) would lose their app entries: "
                + string.Join(", ", orphaned.Select(game => game.Describe())));
        }
        else
        {
            HasOrphanedGamesBlock = false;
            OrphanedGamesWarning = string.Empty;
            var failedStep = outcome.FailedStep is { } kind ? DeploySteps.FirstOrDefault(step => step.Kind == kind) : null;
            var stepLabel = failedStep?.Label ?? Loc.T("deploy.state.failed");
            SetDeployFailed(
                outcome.FailedStep ?? DeployStepKind.Build,
                outcome.ErrorCode ?? "deploy_failed",
                Loc.T("deploy.failedAt", stepLabel) + " — " + (outcome.ErrorMessage ?? "unknown error"),
                outcome.ErrorFix ?? L.DeployFailedHelp);
            StatusText = L.DeployFailedTitle;
        }
        OnPropertyChanged(nameof(DeployState));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(IsDeployIdle));
        OnPropertyChanged(nameof(IsDeployRunning));
        OnPropertyChanged(nameof(IsDeployDone));
        OnPropertyChanged(nameof(IsDeployFailed));
        OnPropertyChanged(nameof(IsDeployCancelled));
        OnPropertyChanged(nameof(DeployMessage));
        OnPropertyChanged(nameof(DeployStepName));
        RaiseCommandStates();
    }

    private void SetDeployFailed(DeployStepKind step, string code, string message, string fix)
    {
        _deployState = "failed";
        var row = DeploySteps.FirstOrDefault(item => item.Kind == step);
        row?.Update(DeployStepStatus.Failed, message);
        DeployErrorTitle = L.DeployFailedTitle;
        DeployErrorDetail = message;
        DeployErrorFix = fix;
        DeployMessage = L.DeployFailedHelp;
        DeployStepName = row is null ? step.ToString() : row.Label;
        Log($"deploy failed ({code}) at {DeployStepName}: {message}");
        OnPropertyChanged(nameof(DeployState));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(IsDeployIdle));
        OnPropertyChanged(nameof(IsDeployRunning));
        OnPropertyChanged(nameof(IsDeployDone));
        OnPropertyChanged(nameof(IsDeployFailed));
        OnPropertyChanged(nameof(IsDeployCancelled));
        OnPropertyChanged(nameof(DeployMessage));
        OnPropertyChanged(nameof(DeployStepName));
        OnPropertyChanged(nameof(DeployErrorTitle));
        OnPropertyChanged(nameof(DeployErrorDetail));
        OnPropertyChanged(nameof(DeployErrorFix));
        RaiseCommandStates();
    }

    /// <summary>Stop the running deploy: cancel the current stage and terminate its process tree.</summary>
    public void StopDeploy()
    {
        var cancellation = _deployCancellation;
        if (cancellation is null || cancellation.IsCancellationRequested)
        {
            return;
        }
        Log("deploy: stop requested; cancelling the running step and terminating its tool processes.");
        DeployMessage = L.DeployStopping;
        OnPropertyChanged(nameof(DeployMessage));
        StatusText = L.DeployStopping;
        cancellation.Cancel();
        RaiseCommandStates();
    }

    /// <summary>Show the stopped state and let the user deploy again; built packs stay cached.</summary>
    private void ApplyDeployCancelled()
    {
        _deployState = "cancelled";
        ProgressValue = 0;
        DeployMessage = L.DeployCancelledBody;
        DeployStepName = string.Empty;
        DeployErrorTitle = string.Empty;
        DeployErrorDetail = string.Empty;
        DeployErrorFix = string.Empty;
        foreach (var row in DeploySteps)
        {
            if (row.IsRunning)
            {
                row.Update(DeployStepStatus.Cancelled, string.Empty);
            }
        }
        StatusText = L.DeployCancelledTitle;
        Log("deploy cancelled: the running step was stopped and its tool process trees were terminated. Built GamePacks are kept; press Deploy selected to start again.");
        OnPropertyChanged(nameof(DeployState));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(IsDeployIdle));
        OnPropertyChanged(nameof(IsDeployRunning));
        OnPropertyChanged(nameof(IsDeployDone));
        OnPropertyChanged(nameof(IsDeployFailed));
        OnPropertyChanged(nameof(IsDeployCancelled));
        OnPropertyChanged(nameof(DeployMessage));
        OnPropertyChanged(nameof(DeployStepName));
        OnPropertyChanged(nameof(DeployErrorTitle));
        OnPropertyChanged(nameof(DeployErrorDetail));
        OnPropertyChanged(nameof(DeployErrorFix));
        RaiseCommandStates();
    }

    /// <summary>
    /// Window-close cleanup: cancel a running deploy, wait for the orchestrator to unwind
    /// (ProcessRunner kills the running stage's process tree), then force-kill any tool
    /// process tree that is still tracked. The window only closes after this finishes.
    /// </summary>
    public async Task ShutdownAsync(TimeSpan timeout)
    {
        var completion = _deployCompletion;
        if (completion is null)
        {
            LauncherProcessRegistry.KillAll(new ProcessTreeKiller(), Log);
            return;
        }
        Log("shutdown: stopping the running deploy before exit.");
        StopDeploy();
        var finished = await Task.WhenAny(completion.Task, Task.Delay(timeout)).ConfigureAwait(true) == completion.Task;
        if (!finished)
        {
            Log("shutdown: the deploy did not stop within " + (int)timeout.TotalSeconds + "s; terminating the remaining tool process trees.");
        }
        var killed = LauncherProcessRegistry.KillAll(new ProcessTreeKiller(), Log);
        if (killed > 0)
        {
            Log("shutdown: terminated " + killed + " remaining tool process tree(s).");
        }
        if (!finished)
        {
            await Task.WhenAny(completion.Task, Task.Delay(TimeSpan.FromSeconds(5))).ConfigureAwait(true);
        }
    }

    // --- settings / status -------------------------------------------------

    /// <summary>
    /// Automatic readiness self-check. Called once at startup and again when the user clicks
    /// the status light. A failed probe turns the light red; it never breaks the UI.
    /// </summary>
    public async Task RefreshStatusAsync()
    {
        SetReadinessState("checking");
        try
        {
            var readiness = await _services.CheckAsync().ConfigureAwait(true);
            Tools.Clear();
            foreach (var tool in readiness.Tools)
            {
                Tools.Add(new ToolRow(tool.Name, tool.State, tool.Message));
            }
            var missing = Tools.Where(tool => !tool.Ready).ToList();
            _readinessDetail = BuildReadinessDetail(readiness.Summary);
            OnPropertyChanged(nameof(ReadinessDetail));
            SetReadinessState(missing.Count == 0 ? "ready" : "failed");
            Log("readiness: " + readiness.Summary);
            foreach (var tool in missing)
            {
                Log($"readiness detail: {tool.Name} = {tool.State} — {tool.Message}");
            }
        }
        catch (Exception exception)
        {
            _readinessDetail = Loc.T("readiness.status.failed") + ": " + exception.Message;
            OnPropertyChanged(nameof(ReadinessDetail));
            SetReadinessState("failed");
            Log("status check failed: " + exception.Message);
        }
    }

    private string BuildReadinessDetail(string summary)
    {
        var lines = new List<string> { summary };
        foreach (var tool in Tools)
        {
            lines.Add($"{tool.Name}: {tool.StateLabel}" + (string.IsNullOrWhiteSpace(tool.Message) ? string.Empty : " — " + tool.Message));
        }
        lines.Add(Loc.T("readiness.status.retryHint"));
        return string.Join(Environment.NewLine, lines);
    }

    private void SetReadinessState(string state)
    {
        _readinessState = state;
        OnPropertyChanged(nameof(IsReadinessReady));
        OnPropertyChanged(nameof(IsReadinessFailed));
        OnPropertyChanged(nameof(IsReadinessChecking));
        OnPropertyChanged(nameof(ReadinessLabel));
    }

    /// <summary>
    /// Refresh the five Deploy prerequisites. Runs at startup, every time the Deploy page
    /// opens and from the panel's Refresh status button; concurrent calls share one run.
    /// </summary>
    public Task RefreshDeployPrerequisitesAsync()
    {
        if (_prerequisiteRefresh is { IsCompleted: false })
        {
            return _prerequisiteRefresh;
        }
        _prerequisiteRefresh = RefreshDeployPrerequisitesCoreAsync();
        return _prerequisiteRefresh;
    }

    private async Task RefreshDeployPrerequisitesCoreAsync()
    {
        try
        {
            var report = await _services.CheckDeployPrerequisitesAsync().ConfigureAwait(true);
            DeployPrerequisites.Clear();
            foreach (var prerequisite in report.Prerequisites)
            {
                DeployPrerequisites.Add(new DeployPrerequisiteRow(prerequisite, L));
            }
            OnPropertyChanged(nameof(DeployPrereqSummary));
            Log(report.AllReady
                ? "deploy prerequisites: all 5 ready"
                : "deploy prerequisites red: " + string.Join(", ", report.Blocked.Select(item => item.Kind + (string.IsNullOrWhiteSpace(item.Detail) ? string.Empty : " (" + item.Detail + ")"))));
            await RefreshDeviceDeployStateAsync().ConfigureAwait(true);
        }
        catch (Exception exception)
        {
            Log("deploy prerequisite check failed: " + exception.Message);
        }
    }

    /// <summary>
    /// Read the connected phone's app identity, installed game data and deploy marker and show
    /// what the next Deploy would do. Best-effort: without a phone, devpush or shell template the
    /// lines are cleared; the deploy steps still report any real failure.
    /// </summary>
    private async Task RefreshDeviceDeployStateAsync()
    {
        if (!IsDeploySection)
        {
            return;
        }
        try
        {
            _shell ??= await _services.LoadShellAsync().ConfigureAwait(true);
            var inspector = _services.CreateDeviceDeployInspector();
            if (_shell is null || inspector is null)
            {
                DeviceAppStatus = string.Empty;
                DeviceGamesStatus = string.Empty;
                DeployPlanStatus = string.Empty;
                DeviceOrphanStatus = string.Empty;
                return;
            }
            var selected = DeployGames.Where(row => row.IsSelected).Select(row => row.Entry).ToList();
            var bundleId = _services.Workspace.State.InstalledBundleId ?? _shell.BundleId;
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            var device = await inspector.InspectAsync(
                new DeviceDeployInspectRequest(
                    bundleId,
                    _device?.Udid ?? _services.Workspace.State.LastDeviceUdid,
                    selected.Select(entry => entry.TitleID).ToList()),
                line => Log("[device] " + line),
                timeout.Token).ConfigureAwait(true);
            var expected = _services.ResolveExpectedAppPackageVersion(_shell);
            DeviceAppStatus = device.App.Installed
                ? Loc.T("deploy.deviceapp.version",
                    string.IsNullOrWhiteSpace(device.App.ShortVersion) ? Loc.T("deploy.deviceapp.unknown") : device.App.ShortVersion,
                    string.IsNullOrWhiteSpace(device.App.PackageVersion) ? Loc.T("deploy.deviceapp.unknown") : device.App.PackageVersion,
                    expected)
                : L.DeployDeviceAppNotInstalled;
            var installedCount = device.InstalledGameTitleIds.Count;
            DeviceGamesStatus = installedCount == 0
                ? L.DeployDeviceGamesNone
                : Loc.T("deploy.devicegames.some", installedCount,
                    selected.Count(entry => DeviceDeployPlanner.IsDataCurrent(device, entry, LocalRomBytes(entry))), selected.Count);
            var orphans = DeviceDeployPlanner.FindOrphanedInstalledGames(
                device,
                _services.Workspace.State.Games,
                titleId => _services.Workspace.Find(titleId) is { } orphanEntry && LocalRomBytes(orphanEntry) is not null);
            DeviceOrphanStatus = orphans.Count == 0
                ? string.Empty
                : Loc.T("deploy.orphans.summary", orphans.Count,
                    string.Join(", ", orphans.Select(game => game.Describe())));
            if (selected.Count == 0)
            {
                DeployPlanStatus = string.Empty;
            }
            else
            {
                var decision = DeviceDeployPlanner.Decide(device, expected, selected, _services.Workspace.State.Games,
                    titleId =>
                    {
                        var entry = _services.Workspace.Find(titleId);
                        return entry is null ? (long?)null : LocalRomBytes(entry);
                    });
                DeployPlanStatus = LocalizeDeployMode(decision.Mode, decision.IpaGames.Count, decision.PushGames.Count)
                    + (decision.Mode is DeviceDeployMode.Reinstall && orphans.Count > 0
                        ? " " + Loc.T("deploy.orphans.planSuffix", orphans.Count)
                        : string.Empty);
            }
        }
        catch (Exception error) when (error is LauncherToolException or IOException or UnauthorizedAccessException or OperationCanceledException)
        {
            DeviceAppStatus = Loc.T("deploy.deviceapp.unavailable");
            DeviceGamesStatus = string.Empty;
            DeployPlanStatus = string.Empty;
            DeviceOrphanStatus = string.Empty;
            Log("device deploy state unavailable: " + (error is LauncherToolException tool ? tool.Code + ": " + tool.Message : error.Message));
        }
    }

    private string LocalizeDeployMode(DeviceDeployMode mode, int ipaGames, int pushGames) => mode switch
    {
        DeviceDeployMode.FullInstall => Loc.T("deploy.mode.full", pushGames),
        DeviceDeployMode.Reinstall => Loc.T("deploy.mode.reinstall", ipaGames, pushGames),
        DeviceDeployMode.PushOnly => Loc.T("deploy.mode.push", pushGames),
        _ => Loc.T("deploy.mode.uptodate"),
    };

    /// <summary>Local ROM size for the "n of m current" line (cheap; never reads the file).</summary>
    private static long? LocalRomBytes(LibraryEntry entry)
    {
        if (string.IsNullOrWhiteSpace(entry.RomPath))
        {
            return null;
        }
        try
        {
            var info = new FileInfo(entry.RomPath);
            return info.Exists ? info.Length : null;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    private void RefreshDeployPrerequisiteLabels()
    {
        foreach (var row in DeployPrerequisites)
        {
            row.RefreshLabels(L);
        }
        OnPropertyChanged(nameof(DeployPrereqSummary));
    }

    private async Task RefreshDevicesAsync()
    {
        SetBusy(true, Loc.T("status.devices"));
        try
        {
            List<DeviceInfo> devices = new();
            if (_services.DevPush is { } devPush)
            {
                devices = (await devPush.DevicesAsync().ConfigureAwait(true)).ToList();
            }
            else if (_services.Mux is { } mux)
            {
                var muxDevices = await mux.ListDevicesAsync().ConfigureAwait(true);
                devices = muxDevices.Select(device => new DeviceInfo(device.Udid, null, null, null, device.ConnectionType, Paired: true)).ToList();
            }
            _device = devices.FirstOrDefault();
            // Non-identifying device row: the UDID stays internal (deploy commands only).
            DeviceStatus = _device is null
                ? L.DeployDeviceNone
                : Loc.T("deploy.device", Privacy.DescribeDevice(_device.Model, _device.Connection, _device.IosVersion));
            _services.Workspace.State.LastDeviceUdid = _device?.Udid;
            _services.Workspace.SaveState();
            Log(DeviceStatus);
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
            SetBusy(false, Loc.T("status.ready"));
        }
    }

    private void UpdateShellStatus()
    {
        InstalledStatus = _services.Workspace.State.InstalledAt is null
            ? L.DeployNotInstalled
            : Loc.T("deploy.installed", _services.Workspace.State.InstalledBundleId ?? L.CommonNone) + " · " + Loc.T("settings.bundleId", _services.Workspace.State.InstalledBundleId ?? L.CommonNone);
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
        ShellStatus = Loc.T("shell.pending", _shell.Version, _shell.BundleId);
    }

    public string InstalledBundleIdLine => _services.Workspace.State.InstalledAt is null
        ? L.DeployNotInstalled
        : Loc.T("settings.bundleId", _services.Workspace.State.InstalledBundleId ?? L.CommonNone);

    // --- navigation / language --------------------------------------------

    public void ShowLibrary()
    {
        _section = "library";
        _showSettings = false;
        RaiseViewState();
    }

    public void ShowDeploy()
    {
        _section = "deploy";
        _showSettings = false;
        RaiseViewState();
        // Re-probe every time the user opens Deploy: the phone may have been plugged in since.
        _ = RefreshDeployPrerequisitesAsync();
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

    /// <summary>Developer-only `--ui-smoke` hook: render the Deploy page in its running state.</summary>
    internal void ShowDeployRunningForSmoke()
    {
        SetDeployRunning();
        // A live (never cancelled) source keeps the Stop button enabled in the capture;
        // this is a screenshot-only hook and no deploy task exists.
        _deployCancellation = new CancellationTokenSource();
        SetBusy(true, L.DeployRunning);
        RaiseCommandStates();
        ProgressValue = 46;
        foreach (var row in DeploySteps)
        {
            switch (row.Kind)
            {
                case DeployStepKind.Build:
                    row.Update(DeployStepStatus.Succeeded, "GamePack ready");
                    break;
                case DeployStepKind.Compose:
                    row.Update(DeployStepStatus.Succeeded, "Verified 1 pack + schema-2 catalogue");
                    break;
                case DeployStepKind.Install:
                    row.Update(DeployStepStatus.Running, "Signing and installing the app with the bundled Impactor/plumesign…");
                    break;
            }
        }
        DeployStepName = DeploySteps.FirstOrDefault(row => row.IsRunning)?.Label ?? string.Empty;
    }

    /// <summary>Developer-only `--ui-smoke` hook: render the stopped Deploy state and its banner.</summary>
    internal void ShowDeployCancelledForSmoke() => ApplyDeployCancelled();

    public void ToggleDeployLog()
    {
        _showDeployLog = !_showDeployLog;
        OnPropertyChanged(nameof(ShowDeployLog));
        OnPropertyChanged(nameof(DeployLogToggleLabel));
    }

    private void RaiseViewState()
    {
        OnPropertyChanged(nameof(IsLibrarySection));
        OnPropertyChanged(nameof(IsDeploySection));
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

    /// <summary>Build the language items once; a later switch refreshes their labels in place.</summary>
    private void RebuildLanguageOptions()
    {
        LanguageOptions.Clear();
        foreach (var choice in LanguageChoices.Create(Loc.CurrentTag))
        {
            LanguageOptions.Add(choice);
        }
        _selectedLanguage = LanguageOptions.FirstOrDefault(option => option.Preference == _languagePreference) ?? LanguageOptions.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedLanguage));
    }

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
        // Refresh the labels IN PLACE: replacing the ComboBox items would drop the selected
        // item object and leave the language box blank after a switch (task-20 L3).
        LanguageChoices.RefreshLabels(LanguageOptions, Loc.CurrentTag);
        if (_selectedLanguage is null || _selectedLanguage.Preference != preference)
        {
            _selectedLanguage = LanguageOptions.FirstOrDefault(option => option.Preference == preference) ?? LanguageOptions.FirstOrDefault();
            OnPropertyChanged(nameof(SelectedLanguage));
        }
        foreach (var row in Games)
        {
            row.Refresh();
        }
        foreach (var row in DeployGames)
        {
            row.Refresh();
        }
        var stepLabels = new[]
        {
            L.DeployStepBuild, L.DeployStepCompose, L.DeployStepInstall, L.DeployStepPush, L.DeployStepVerify,
        };
        for (var index = 0; index < DeploySteps.Count && index < stepLabels.Length; index++)
        {
            DeploySteps[index].Label = stepLabels[index];
            DeploySteps[index].RefreshLabels();
        }
        foreach (var tool in Tools)
        {
            tool.RefreshLabels();
        }
        OnPropertyChanged(nameof(WindowTitle));
        OnPropertyChanged(nameof(StatusText));
        OnPropertyChanged(nameof(ReadinessLabel));
        OnPropertyChanged(nameof(ReadinessDetail));
        OnPropertyChanged(nameof(GameCountText));
        OnPropertyChanged(nameof(BuildAllLabel));
        OnPropertyChanged(nameof(AdvancedBuildSummary));
        OnPropertyChanged(nameof(DeploySelectedCountText));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(DeployMessage));
        OnPropertyChanged(nameof(DeployStepName));
        OnPropertyChanged(nameof(DeployErrorTitle));
        OnPropertyChanged(nameof(DeployErrorDetail));
        OnPropertyChanged(nameof(DeployErrorFix));
        OnPropertyChanged(nameof(DeviceStatus));
        OnPropertyChanged(nameof(ShellStatus));
        OnPropertyChanged(nameof(InstalledStatus));
        OnPropertyChanged(nameof(InstalledBundleIdLine));
        OnPropertyChanged(nameof(DistributionLine));
        OnPropertyChanged(nameof(WorkspaceInfoLine));
        OnPropertyChanged(nameof(DistributionInfoLine));
        OnPropertyChanged(nameof(WorkspaceReasonText));
        OnPropertyChanged(nameof(DistributionReasonText));
        OnPropertyChanged(nameof(HardwareLine));
        OnPropertyChanged(nameof(HardwareDiagnostics));
        RefreshDeployPrerequisiteLabels();
        OnPropertyChanged(nameof(DiagnosticsToggleLabel));
        OnPropertyChanged(nameof(DeployLogToggleLabel));
        UpdateShellStatus();
        StatusText = Loc.T("status.languageChanged");
    }

    // --- misc --------------------------------------------------------------

    private void OpenImpactor()
    {
        if (_services.PlumeSign is null)
        {
            Log("The bundled Impactor/plumesign was not found (ThirdParty/Impactor). Reinstall the launcher package.");
            return;
        }
        try
        {
            _services.Impactor.StartImpactor();
            Log("Impactor started. Sign in with your own Apple ID there; the launcher never sees the password. Then press Deploy.");
        }
        catch (Exception exception)
        {
            Log("could not start Impactor: " + exception.Message);
        }
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

    /// <summary>Called by the view after the save picker returned a target path.</summary>
    public void ExportLogTo(string targetPath)
    {
        try
        {
            var source = CurrentLogPath;
            if (!File.Exists(source))
            {
                File.WriteAllText(source, string.Empty);
            }
            File.Copy(source, targetPath, overwrite: true);
            Log(Loc.T("settings.logsExported", targetPath));
        }
        catch (Exception exception)
        {
            Log(Loc.T("settings.exportFailed", exception.Message));
        }
    }

    public void Log(string message)
    {
        // Logs and the diagnostics export must never contain a device UDID/usbmux id/serial:
        // call sites pass non-identifying descriptions and this is the UI-level safety net.
        var safe = Privacy.SanitizeLogLine(message);
        var line = $"{DateTimeOffset.Now:HH:mm:ss} {safe}";
        LogLines.Add(line);
        if (LogLines.Count > 4000)
        {
            LogLines.RemoveAt(0);
        }
        try
        {
            _services.Workspace.AppendLog(safe);
        }
        catch (IOException)
        {
            // logging must never break the launcher
        }
    }

    public async Task InitializeAsync()
    {
        try
        {
            await ResolveBuildCompatibilityAsync().ConfigureAwait(true);
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            _shell = await _services.LoadShellAsync().ConfigureAwait(true);
            UpdateShellStatus();
            OnPropertyChanged(nameof(InstalledBundleIdLine));
            await RefreshDevicesAsync().ConfigureAwait(true);
            await RefreshDeployPrerequisitesAsync().ConfigureAwait(true);
            Log(_shell is null
                ? "Shell template manifest not found in Shell/. Reinstall the launcher package; Deploy needs the ROM-free base shell IPA."
                : $"Shell template: v{_shell.Version} {_shell.BundleId} ({_shell.FileName}); the app IPA is composed at deploy time.");
            StatusText = Loc.T("status.ready");
        }
        catch (Exception exception)
        {
            Log("initialize failed: " + exception.Message);
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
                     DeployCommand, ConfirmOrphanedDeployCommand, StopDeployCommand, BuildAllCommand, RefreshDevicesCommand, RefreshPrerequisitesCommand,
                     RefreshStatusCommand, RefreshReadinessCommand, OpenImpactorCommand,
                     ImportBuildPackageCommand, ConfirmImportReplaceCommand, ResetAdvancedBuildCommand,
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
}
