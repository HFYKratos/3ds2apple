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

/// <summary>One card in the Library: name / state / ROM path + remove (no build/install/push buttons).</summary>
public sealed class GameRow : ObservableObject
{
    private readonly MainViewModel _owner;
    private string _state = "imported";

    public GameRow(MainViewModel owner, LibraryEntry entry)
    {
        _owner = owner;
        Entry = entry;
        RemoveCommand = new AsyncRelayCommand(() => _owner.RemoveGameAsync(this), () => !_owner.IsBusy);
    }

    public LibraryEntry Entry { get; }

    public string TitleID => Entry.TitleID;

    public string DisplayName
    {
        get => string.IsNullOrWhiteSpace(Entry.DisplayNameOverride) ? Entry.DisplayName : Entry.DisplayNameOverride;
        set
        {
            var trimmed = (value ?? string.Empty).Trim();
            if (string.Equals(DisplayName, trimmed, StringComparison.Ordinal))
            {
                return;
            }
            Entry.DisplayNameOverride = trimmed;
            _owner.PersistName(Entry);
            OnPropertyChanged();
            OnPropertyChanged(nameof(DisplayNameText));
        }
    }

    public string DisplayNameText => DisplayName;

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
        ? Loc.T("library.card.notBuilt")
        : Entry.Pack.IsPlaceholder
            ? Loc.T("library.card.pack.placeholder", FormatBytes(Entry.Pack.Bytes))
            : Loc.T("library.card.pack.built", FormatBytes(Entry.Pack.Bytes), Entry.Pack.Sha256[..12]);

    public string RemoveLabel => Loc.T("library.card.remove");

    public AsyncRelayCommand RemoveCommand { get; }

    public void Refresh()
    {
        State = Entry.Pack is null
            ? Entry.State
            : Entry.Pack.IsPlaceholder ? "preview" : "built";
        OnPropertyChanged(nameof(StateLabel));
        OnPropertyChanged(nameof(PackLine));
        OnPropertyChanged(nameof(DisplayName));
        OnPropertyChanged(nameof(DisplayNameText));
        OnPropertyChanged(nameof(HasRealPack));
        OnPropertyChanged(nameof(IsPushed));
        OnPropertyChanged(nameof(TitleIdLine));
        OnPropertyChanged(nameof(RomLine));
        OnPropertyChanged(nameof(RemoveLabel));
    }

    public void RaiseCommandStates() => RemoveCommand.RaiseCanExecuteChanged();

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

    public string DisplayName => string.IsNullOrWhiteSpace(Entry.DisplayNameOverride) ? Entry.DisplayName : Entry.DisplayNameOverride;

    public bool HasRealPack => Entry.Pack is { IsPlaceholder: false }
                               && !string.IsNullOrWhiteSpace(Entry.PackPath)
                               && File.Exists(Entry.PackPath);

    public string StateLabel => Entry.PushedAt is not null
        ? Loc.T("library.card.state.pushed")
        : HasRealPack ? Loc.T("library.card.state.built") : Loc.T("library.card.state.imported");

    public string DetailLine => HasRealPack
        ? Loc.T("library.card.pack.built", FormatBytes(Entry.Pack?.Bytes ?? 0), (Entry.Pack?.Sha256 ?? string.Empty).PadRight(12)[..12])
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

/// <summary>A selectable UI language with its localized label.</summary>
public sealed record LanguageChoice(UiLanguagePreference Preference, string Label);

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
/// Settings overlay. Library imports/lists/removes games; Deploy selects one or many
/// and runs one chained action (compile -> compose -> sign/install -> push -> verify).
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
    private string _toolchainStatus = string.Empty;
    private bool _toolchainReady;
    private string _readinessState = "checking";
    private string _readinessDetail = string.Empty;
    private string _deployState = "idle";
    private string _deployMessage = string.Empty;
    private string _deployStepName = string.Empty;
    private string _deployErrorTitle = string.Empty;
    private string _deployErrorDetail = string.Empty;
    private string _deployErrorFix = string.Empty;
    private double _progressValue;
    private LocalizedText _localized = new();
    private LanguageChoice? _selectedLanguage;
    private UiLanguagePreference _languagePreference = UiLanguagePreference.System;

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
        ToolchainStatus = Loc.T("readiness.unchecked");
        ShowLibraryCommand = new RelayCommand(ShowLibrary);
        ShowDeployCommand = new RelayCommand(ShowDeploy);
        OpenSettingsCommand = new RelayCommand(OpenSettings);
        CloseSettingsCommand = new RelayCommand(CloseSettings);
        DeployCommand = new AsyncRelayCommand(() => RunDeployAsync(), () => CanDeploy);
        SelectAllCommand = new RelayCommand(() => SetAllSelected(true));
        SelectNoneCommand = new RelayCommand(() => SetAllSelected(false));
        RefreshDevicesCommand = new AsyncRelayCommand(() => RefreshDevicesAsync(), () => !IsBusy);
        RefreshStatusCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        RefreshReadinessCommand = new AsyncRelayCommand(() => RefreshStatusAsync(), () => !IsBusy);
        OpenImpactorCommand = new RelayCommand(OpenImpactor, () => !IsBusy);
        OpenWorkspaceCommand = new RelayCommand(OpenWorkspace);
        ExportLogCommand = new RelayCommand(() => ExportLogRequested?.Invoke());
        ToggleDiagnosticsCommand = new RelayCommand(ToggleDiagnostics);
        ToggleDeployLogCommand = new RelayCommand(ToggleDeployLog);
        RebuildLanguageOptions();
        RebuildDeploySteps();
        Log($"workspace: {_services.Workspace.Root}");
        Log($"distribution: {_services.Locator.DistributionRoot}");
        Log("3ds2apple launcher v2 started. Add your own decrypted .3ds/.cci in Library, then deploy it in one click.");
    }

    public ObservableCollection<GameRow> Games { get; } = new();

    public ObservableCollection<DeployRow> DeployGames { get; } = new();

    public ObservableCollection<DeployStepRow> DeploySteps { get; } = new();

    public ObservableCollection<LanguageChoice> LanguageOptions { get; } = new();

    public ObservableCollection<ToolRow> Tools { get; } = new();

    public ObservableCollection<string> LogLines { get; } = new();

    /// <summary>Raised by the settings "Export log" button; the view shows a save picker.</summary>
    public event Action? ExportLogRequested;

    public RelayCommand ShowLibraryCommand { get; }
    public RelayCommand ShowDeployCommand { get; }
    public RelayCommand OpenSettingsCommand { get; }
    public RelayCommand CloseSettingsCommand { get; }
    public AsyncRelayCommand DeployCommand { get; }
    public RelayCommand SelectAllCommand { get; }
    public RelayCommand SelectNoneCommand { get; }
    public AsyncRelayCommand RefreshDevicesCommand { get; }
    public AsyncRelayCommand RefreshStatusCommand { get; }
    public AsyncRelayCommand RefreshReadinessCommand { get; }
    public RelayCommand OpenImpactorCommand { get; }
    public RelayCommand OpenWorkspaceCommand { get; }
    public RelayCommand ExportLogCommand { get; }
    public RelayCommand ToggleDiagnosticsCommand { get; }
    public RelayCommand ToggleDeployLogCommand { get; }

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

    public string CurrentLogPath => _services.Workspace.CurrentLogPath;

    // --- library -----------------------------------------------------------

    public bool HasGames => Games.Count > 0;

    public bool IsLibraryEmpty => Games.Count == 0;

    public string GameCountText => Loc.T("library.count", Games.Count);

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

    public void PersistName(LibraryEntry entry)
    {
        _services.Workspace.SaveState();
        OnPropertyChanged(nameof(Games));
    }

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
                var added = await pack.AddAsync(new[] { path }, null).ConfigureAwait(true);
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
                Log($"imported {imported.TitleID}  {imported.DisplayName}  {imported.ProductCode}  (headers only; Deploy sends it later)");
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
        _ => Loc.T("deploy.state.idle"),
    };

    public bool IsDeployIdle => _deployState == "idle";

    public bool IsDeployRunning => _deployState == "running";

    public bool IsDeployDone => _deployState == "done";

    public bool IsDeployFailed => _deployState == "failed";

    public string DeployMessage { get => _deployMessage; private set => SetProperty(ref _deployMessage, value); }

    public string DeployStepName { get => _deployStepName; private set => SetProperty(ref _deployStepName, value); }

    public string DeployErrorTitle { get => _deployErrorTitle; private set => SetProperty(ref _deployErrorTitle, value); }

    public string DeployErrorDetail { get => _deployErrorDetail; private set => SetProperty(ref _deployErrorDetail, value); }

    public string DeployErrorFix { get => _deployErrorFix; private set => SetProperty(ref _deployErrorFix, value); }

    public string DeviceStatus { get => _deviceStatus; private set => SetProperty(ref _deviceStatus, value); }

    public string ShellStatus { get => _shellStatus; private set => SetProperty(ref _shellStatus, value); }

    public string InstalledStatus { get => _installedStatus; private set => SetProperty(ref _installedStatus, value); }

    public string ToolchainStatus { get => _toolchainStatus; private set => SetProperty(ref _toolchainStatus, value); }

    public bool IsToolchainReady { get => _toolchainReady; private set => SetProperty(ref _toolchainReady, value); }

    public string ToolchainFix => L.DeployToolchainFix;

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
        ProgressValue = 0;
        OnPropertyChanged(nameof(DeployState));
        OnPropertyChanged(nameof(DeployStateLabel));
        OnPropertyChanged(nameof(IsDeployIdle));
        OnPropertyChanged(nameof(IsDeployRunning));
        OnPropertyChanged(nameof(IsDeployDone));
        OnPropertyChanged(nameof(IsDeployFailed));
    }

    public async Task RunDeployAsync()
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
        SetBusy(true, L.DeployRunning);
        try
        {
            var templateIpa = Path.Combine(_services.ShellDirectory, _shell.FileName);
            var request = new DeployRequest(
                selected.Select(entry => entry.TitleID).ToList(),
                templateIpa,
                BundleIdOverride: null,
                DeviceUdid: _device?.Udid,
                RebuildExistingPacks: false);
            var progress = new Progress<DeployProgress>(ApplyDeployProgress);
            var outcome = await orchestrator.RunAsync(request, progress, line => Log("[deploy] " + line)).ConfigureAwait(true);
            ApplyDeployOutcome(outcome);
        }
        catch (Exception exception)
        {
            Log("deploy crashed: " + exception.Message);
            SetDeployFailed(DeployStepKind.Build, "deploy_exception", exception.Message, L.DeployFailedHelp);
        }
        finally
        {
            SetBusy(false, Loc.T("status.ready"));
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            await RefreshDeployReadinessAsync().ConfigureAwait(true);
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
        }
        else
        {
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
        OnPropertyChanged(nameof(DeployMessage));
        OnPropertyChanged(nameof(DeployStepName));
        OnPropertyChanged(nameof(DeployErrorTitle));
        OnPropertyChanged(nameof(DeployErrorDetail));
        OnPropertyChanged(nameof(DeployErrorFix));
        RaiseCommandStates();
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

    private async Task RefreshDeployReadinessAsync()
    {
        try
        {
            var readiness = await _services.CheckDeployReadinessAsync().ConfigureAwait(true);
            IsToolchainReady = readiness.CanDeploy;
            ToolchainStatus = readiness.CanDeploy
                ? L.DeployToolchainReady
                : Loc.T("deploy.toolchain.missing", string.Join(", ", readiness.Missing));
            OnPropertyChanged(nameof(ToolchainStatus));
            OnPropertyChanged(nameof(ToolchainFix));
            if (!readiness.CanDeploy)
            {
                Log("deploy readiness: " + readiness.Summary);
            }
        }
        catch (Exception exception)
        {
            IsToolchainReady = false;
            ToolchainStatus = Loc.T("deploy.toolchain.missing", exception.Message);
            OnPropertyChanged(nameof(ToolchainStatus));
        }
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
            DeviceStatus = _device is null
                ? L.DeployDeviceNone
                : Loc.T("deploy.device", Privacy.RedactUdid(_device.Udid) + " (" + _device.Connection + ")");
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
        OnPropertyChanged(nameof(ToolchainStatus));
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

    public async Task InitializeAsync()
    {
        try
        {
            await RefreshLibraryAsync().ConfigureAwait(true);
            await RefreshStatusAsync().ConfigureAwait(true);
            _shell = await _services.LoadShellAsync().ConfigureAwait(true);
            UpdateShellStatus();
            OnPropertyChanged(nameof(InstalledBundleIdLine));
            await RefreshDevicesAsync().ConfigureAwait(true);
            await RefreshDeployReadinessAsync().ConfigureAwait(true);
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
                     DeployCommand, RefreshDevicesCommand, RefreshStatusCommand, RefreshReadinessCommand,
                     OpenImpactorCommand,
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
