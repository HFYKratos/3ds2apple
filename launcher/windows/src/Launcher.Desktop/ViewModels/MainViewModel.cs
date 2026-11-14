using System.Collections.ObjectModel;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;
using ThreeDsTwoApple.Launcher.Core.LauncherState;

namespace ThreeDsTwoApple.Launcher.App.ViewModels;

/// <summary>One row of the launcher game library.</summary>
public sealed class GameRow : ObservableObject
{
    private string _state = "imported";

    public GameRow(LibraryEntry entry)
    {
        Entry = entry;
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

    public string PackDescription => Entry.Pack is null
        ? "no pack"
        : Entry.Pack.IsPlaceholder
            ? $"preview placeholder ({FormatBytes(Entry.Pack.Bytes)}) — not installable"
            : $"{FormatBytes(Entry.Pack.Bytes)} · {Entry.Pack.Sha256[..12]}…";

    public void Refresh()
    {
        State = Entry.Pack is null
            ? Entry.State
            : Entry.Pack.IsPlaceholder ? "preview" : "built";
        OnPropertyChanged(nameof(PackDescription));
        OnPropertyChanged(nameof(DisplayName));
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
    private string _statusText = "Ready.";
    private string _header = string.Empty;
    private double _progressValue;
    private string _deviceStatus = "Devices not refreshed yet.";
    private string _shellStatus = "Base shell not checked yet.";
    private string _pushStatus = "Select a game and push its ROM data to the phone.";
    private string _importPath = string.Empty;
    private string _displayNameOverride = string.Empty;
    private string _buildModeText = "Preview (fake placeholder, not installable)";
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
        Header = $"3ds2apple Launcher (Windows) · {LauncherInfo.Version}";
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
        BuildHost = _services.Workspace.State.BuildHost ?? string.Empty;
        BundleIdOverride = _services.Workspace.State.ShellBundleIdOverride ?? string.Empty;
        MockDirectory = _services.Workspace.State.DevPushMockDirectory ?? string.Empty;
        LocalBuildEnabled = _services.Workspace.State.LocalBuildEnabled;
        RecompPathSetting = _services.Locator.OverrideFor(ToolLocator.RecompTool) ?? string.Empty;
        LlvmDirSetting = _services.Locator.OverrideFor(ToolLocator.LlvmTool) ?? string.Empty;
        PackPathSetting = _services.Locator.OverrideFor(ToolLocator.PackCliTool) ?? string.Empty;
        DevPushPathSetting = _services.Locator.OverrideFor(ToolLocator.DevPushTool) ?? string.Empty;
        BuilderPathSetting = _services.Locator.OverrideFor(ToolLocator.BuilderTool) ?? string.Empty;
        BuildModeText = _services.Workspace.State.Mode switch
        {
            PackBuildMode.MacAgentIpa => "macOS Build Agent (existing per-game IPA)",
            PackBuildMode.LocalWinbuild => LocalModeText,
            _ => "Preview (fake placeholder, not installable)",
        };
        ResetBuildModes();
        Log($"workspace: {_services.Workspace.Root}");
        Log($"distribution: {_services.Locator.DistributionRoot}");
        Log("3ds2apple launcher started. Import your own decrypted .3ds/.cci ROM to begin.");
    }

    public ObservableCollection<GameRow> Games { get; } = new();

    /// <summary>Choices shown in the Build tab; the experimental local build is feature-flagged.</summary>
    public ObservableCollection<string> BuildModes { get; } = new();

    private const string LocalModeText = "Local build (3dsrecomp + open-source LLVM/LLD on this PC — experimental)";

    private void ResetBuildModes()
    {
        var wanted = new List<string>
        {
            "Preview (fake placeholder, not installable)",
            "macOS Build Agent (existing per-game IPA)",
        };
        if (LocalBuildEnabled)
        {
            wanted.Add(LocalModeText);
        }
        if (BuildModes.SequenceEqual(wanted))
        {
            return;
        }
        BuildModes.Clear();
        foreach (var mode in wanted)
        {
            BuildModes.Add(mode);
        }
        if (!BuildModes.Contains(BuildModeText))
        {
            BuildModeText = wanted[0];
        }
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

    public string Header { get => _header; private set => SetProperty(ref _header, value); }

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

    public string ReadinessSummary { get; private set; } = "Status not checked yet.";

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

    public string BuildModeText { get => _buildModeText; set => SetProperty(ref _buildModeText, value); }

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

    public string ShellBundleId => _shell?.BundleId ?? (string.IsNullOrWhiteSpace(BundleIdOverride) ? "(base shell not bundled)" : BundleIdOverride);

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
        ? "No game selected."
        : $"{_selectedGame.DisplayName} ({_selectedGame.TitleID}) · ROM: {_selectedGame.RomPath} · pack: {_selectedGame.PackDescription}";

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
        SetBusy(true, "Importing ROM headers…");
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
            StatusText = "Import finished.";
        }
        catch (Exception exception)
        {
            Log("import failed: " + exception.Message);
            StatusText = "Import failed.";
        }
        finally
        {
            SetBusy(false, "Ready.");
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
            Games.Add(new GameRow(entry));
        }
        _services.Workspace.SaveState();
        SelectedGame = Games.FirstOrDefault();
        OnPropertyChanged(nameof(SelectedSummary));
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
        SetBusy(true, "Building GamePack…");
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
                StatusText = "Build failed.";
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
            StatusText = "Build finished.";
        }
        catch (Exception exception)
        {
            Log("build failed: " + exception.Message);
            StatusText = "Build failed.";
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private PackBuildMode ModeFromUi()
    {
        if (BuildModeText.StartsWith("macOS", StringComparison.OrdinalIgnoreCase))
        {
            return PackBuildMode.MacAgentIpa;
        }
        if (BuildModeText.StartsWith("Local build", StringComparison.OrdinalIgnoreCase))
        {
            return PackBuildMode.LocalWinbuild;
        }
        return PackBuildMode.Preview;
    }

    // --- device / shell ----------------------------------------------------

    private async Task RefreshDevicesAsync()
    {
        SetBusy(true, "Refreshing devices…");
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
                    ? "No iPhone/iPad found: connect by USB, unlock, tap Trust."
                    : $"{devices.Count} device(s): " + string.Join(", ", devices.Select(d => Privacy.RedactUdid(d.Udid)));
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
            DeviceStatus = $"{error.Code}: {error.Message}" + (error.Hint is null ? string.Empty : " — " + error.Hint);
            Log(DeviceStatus);
        }
        catch (Exception exception)
        {
            DeviceStatus = "device refresh failed: " + exception.Message;
            Log(DeviceStatus);
        }
        finally
        {
            SetBusy(false, "Ready.");
        }
    }

    private string devPushFallbackNote(int count) => count == 0
        ? "No device found via the Apple device service. (devpush is not bundled, so this is a read-only fallback list.)"
        : $"{count} device(s) via the Apple device service. Note: devpush is not bundled, so pushing is disabled.";

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
        SetBusy(true, "Composing the app IPA (template + game packs)…");
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
            SetBusy(true, "Signing and installing the whole app IPA…");
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
                ShellStatus = $"App installed: {outcome.BundleId} ({gameCount} game pack(s))";
                Log($"app installed: {outcome.BundleId}" + (outcome.SignedIpaPath is null ? string.Empty : $" (signed IPA: {outcome.SignedIpaPath})")
                    + (gameCount == 0 ? " — no game packs yet; build packs and reinstall to add games." : string.Empty));
                PushStatus = gameCount == 0
                    ? "App installed without game packs. Build packs, reinstall the app, then push ROM data."
                    : "App installed. Push the selected game's ROM data to Documents next.";
                StatusText = "App installed.";
            }
            else
            {
                var error = outcome.Error;
                ShellStatus = error is null ? "Base shell install failed." : $"{error.Title} — {error.Fix}";
                Log("base shell install failed: " + (error?.Title ?? "unknown") + (error?.Detail is null ? string.Empty : " — " + error.Detail));
                if (error is not null)
                {
                    Log("fix: " + error.Fix);
                }
            }
        }
        catch (LauncherToolException error)
        {
            ShellStatus = $"{error.Code}: {error.Message}";
            Log(ShellStatus + (error.Hint is null ? string.Empty : " — " + error.Hint));
        }
        catch (Exception exception)
        {
            ShellStatus = "install failed: " + exception.Message;
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
            ShellStatus = "Waiting for Apple ID sign-in in Impactor…";
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
            ShellStatus = "Shell template not bundled (Shell/manifest.json missing).";
            return;
        }
        var verification = _shell.Verify(_services.ShellDirectory);
        if (!verification.Ok)
        {
            ShellStatus = verification.Error ?? "Shell template invalid.";
            return;
        }
        var compatibility = ShellTemplateRules.ValidateManifest(_shell);
        if (!compatibility.Ok)
        {
            ShellStatus = "Template rejected: " + compatibility.Error + " " + compatibility.Fix;
            return;
        }
        var installed = _services.Workspace.State.InstalledAt;
        ShellStatus = installed is null
            ? $"Shell template v{_shell.Version} ready ({_shell.BundleId}); app not installed yet."
            : $"App {_services.Workspace.State.InstalledBundleId} installed {installed:yyyy-MM-dd HH:mm} with {_services.Workspace.State.InstalledGameCount} pack(s).";
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
            return;
        }
        var pushService = _services.CreatePushService();
        if (pushService is null)
        {
            Log("devpush was not found (Bin/devpush.exe). The device bridge is required to push files.");
            return;
        }
        var shell = _shell ?? await _services.LoadShellAsync().ConfigureAwait(true);
        var bundleId = string.IsNullOrWhiteSpace(BundleIdOverride) ? shell?.BundleId : BundleIdOverride.Trim();
        if (string.IsNullOrWhiteSpace(bundleId))
        {
            Log("No bundle id: bundle the base shell manifest or set the shell bundle id in Settings.");
            return;
        }
        if (!File.Exists(entry.RomPath))
        {
            Log("The imported ROM is gone from " + entry.RomPath + ". Re-import it first.");
            return;
        }
        SetBusy(true, "Preparing push plan…");
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
            PushStatus = $"Pushing ROM data ({FormatBytes(plan.TotalBytes)}) to {plan.RemoteDirectory}…";
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
                PushStatus = $"Pushed and verified to {outcome.RemoteDirectory} (device " + (SelectedDevice is null ? "auto" : Privacy.RedactUdid(SelectedDevice.Udid)) + ").";
                Log(PushStatus);
                StatusText = "Push finished.";
            }
            else
            {
                PushStatus = $"Push failed ({outcome.ErrorCode}): {outcome.ErrorMessage}";
                Log(PushStatus);
                StatusText = "Push failed.";
            }
        }
        catch (LauncherToolException error)
        {
            PushStatus = $"{error.Code}: {error.Message}";
            Log(PushStatus + (error.Hint is null ? string.Empty : " — " + error.Hint));
        }
        catch (Exception exception)
        {
            PushStatus = "push failed: " + exception.Message;
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
            PushStatus = problems.Count == 0 ? "Remote files match the local pack/ROM/GameInfo." : string.Join("; ", problems);
            Log(PushStatus);
        }
        catch (Exception exception)
        {
            Log("verify failed: " + exception.Message);
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
            ReadinessSummary = readiness.Summary;
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
            _services.Workspace.SaveState();
            _services.Reload();
            ResetBuildModes();
            _shell = await _services.LoadShellAsync().ConfigureAwait(true);
            UpdateShellStatus();
            await RefreshStatusAsync().ConfigureAwait(true);
            Log("settings saved and tools reloaded.");
        }
        catch (Exception exception)
        {
            Log("saving settings failed: " + exception.Message);
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

    private void SetBusy(bool busy, string status)
    {
        IsBusy = busy;
        StatusText = status;
        if (!busy)
        {
            ProgressValue = 0;
        }
    }

    private void RaiseCommandStates()
    {
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
