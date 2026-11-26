using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;
using ThreeDsTwoApple.Launcher.Core.LauncherState;

namespace ThreeDsTwoApple.Launcher.Core;

/// <summary>One row of the launcher's host/tool readiness panel.</summary>
public sealed record ToolStatus(string Name, bool Ready, string State, string Message);

/// <summary>What this PC can currently do (drives which buttons are enabled).</summary>
public sealed record HostReadiness(
    IReadOnlyList<ToolStatus> Tools,
    bool CanPreviewBuild,
    bool CanInstallShell,
    bool CanPush,
    bool CanLocalBuild,
    bool CanDeploy)
{
    public string Summary
    {
        get
        {
            var blocked = Tools.Where(tool => !tool.Ready).Select(tool => tool.Name).ToList();
            return blocked.Count == 0 ? "All launcher tools are ready." : "Not ready: " + string.Join(", ", blocked);
        }
    }
}

/// <summary>
/// Composition root for the launcher: owns the process runner, the workspace,
/// the tool locator and the typed tool clients. The UI never news up a client
/// on its own, so Settings changes (paths, mock directory) are applied in one place.
/// </summary>
public sealed class LauncherServices
{
    private readonly IProcessRunner _runner;
    private readonly LauncherWorkspace _workspace;
    private readonly ToolLocator _locator;
    private string? _expectedAppPackageVersion;
    private string? _expectedAppPackageVersionKey;

    private LauncherServices(IProcessRunner runner, LauncherWorkspace workspace, ToolLocator locator)
    {
        _runner = runner;
        _workspace = workspace;
        _locator = locator;
        Impactor = ImpactorBundle.Locate(locator.DistributionRoot);
        Reload();
    }

    public IProcessRunner Runner => _runner;

    public LauncherWorkspace Workspace => _workspace;

    public ToolLocator Locator => _locator;

    /// <summary>Resolved local-build toolchain (3dsrecomp + LLVM/LLD); null when unresolved.</summary>
    public LocalToolchain? LocalTools { get; private set; }

    /// <summary>
    /// Identity of the current local build recipe (recomp/shim/pack ABI + clang/ld64
    /// versions), probed once per process. The build cache stores this marker with every
    /// GamePack and only reuses a pack whose marker and ROM SHA-256 both still match.
    /// </summary>
    public IBuildCompatibilityProvider BuildCompatibility { get; private set; } = null!;

    public ImpactorBundle Impactor { get; }

    public UsbMuxClient Mux { get; } = new();

    public PackCli? Pack { get; private set; }

    public DevPushClient? DevPush { get; private set; }

    public PlumeSignRunner? PlumeSign { get; private set; }

    public ShellManifest? Shell { get; private set; }

    public string ShellDirectory => _locator.ShellDirectory;

    public static LauncherServices Create(string? workspaceRoot = null, string? distributionRoot = null, IProcessRunner? runner = null)
    {
        var workspace = LauncherWorkspace.Open(workspaceRoot);
        var distribution = string.IsNullOrWhiteSpace(distributionRoot)
            ? DistributionLayout.Resolve()
            : distributionRoot;
        var locator = new ToolLocator(distribution);
        foreach (var (key, path) in workspace.State.ToolOverrides)
        {
            locator.Override(key, path);
        }
        return new LauncherServices(runner ?? new ProcessRunner(), workspace, locator);
    }

    /// <summary>Rebuild tool clients after a path/settings change (no state write here).</summary>
    public void Reload()
    {
        Pack = PackCli.Create(_runner, _locator, _workspace.OutRoot);
        DevPush = BuildDevPush();
        var plumeSignPath = _locator.FindPlumeSign();
        PlumeSign = plumeSignPath is null ? null : new PlumeSignRunner(_runner, plumeSignPath, _workspace.LogsDirectory);
        LocalTools = LocalToolchainResolver.Resolve(_locator);
        BuildCompatibility = new ToolchainBuildCompatibilityProvider(_runner, LocalTools);
    }

    private DevPushClient? BuildDevPush()
    {
        var path = _locator.FindDevPush();
        if (path is null)
        {
            return null;
        }
        var mock = string.IsNullOrWhiteSpace(_workspace.State.DevPushMockDirectory) ? null : _workspace.State.DevPushMockDirectory;
        return new DevPushClient(_runner, path, mock);
    }

    /// <summary>Save one tool path override and reload the clients.</summary>
    public void SetToolOverride(string toolKey, string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            _workspace.State.ToolOverrides.Remove(toolKey);
            _locator.Override(toolKey, null);
        }
        else
        {
            _workspace.State.ToolOverrides[toolKey] = path;
            _locator.Override(toolKey, path);
        }
        _workspace.SaveState();
        Reload();
    }

    public IPackBuildProvider? CreateBuildProvider(PackBuildMode mode) => mode switch
    {
        PackBuildMode.Preview => Pack is null ? null : new PreviewBuildProvider(Pack),
        // v2: the Windows local LLVM/3dsrecomp build is the only build path the UI
        // offers. It is always created; a missing toolchain is reported by the provider
        // as ONE actionable build failure (Retry on the Deploy page), never as a silent
        // fallback to a placeholder or a remote macOS host.
        PackBuildMode.LocalWinbuild => Pack is null ? null : new LocalWinbuildPackProvider(LocalTools, Pack, _runner, compatibility: BuildCompatibility),
        _ => null,
    };

    /// <summary>The local build provider the Deploy page uses (there is no build-mode choice in the UI).</summary>
    public IPackBuildProvider? CreateDeployBuildProvider() => CreateBuildProvider(PackBuildMode.LocalWinbuild);

    /// <summary>One batch deploy pipeline over the currently resolved tools.</summary>
    public DeployOrchestrator CreateDeployOrchestrator(ShellManifest shell) => new(
        _workspace,
        shell,
        ShellDirectory,
        CreateDeployBuildProvider(),
        CreateComposer(),
        CreateShellInstallService(),
        CreatePushService() is { } push ? new LauncherGameDataPusher(push) : null,
        BuildCompatibility,
        CreateDeviceDeployInspector(),
        ResolveExpectedAppPackageVersion(shell));

    /// <summary>
    /// Device-aware deploy inspection (app identity, installed games, deploy marker); null when
    /// the devpush bridge is missing. The Deploy page and the orchestrator share this factory.
    /// </summary>
    public IDeviceDeployInspector? CreateDeviceDeployInspector() =>
        DevPush is null ? null : new DevPushDeviceDeployInspector(DevPush, _workspace.StagingDirectory);

    /// <summary>
    /// The app package version the bundled shell template would install (read from its
    /// Info.plist <c>ThreeDS2ApplePackageVersion</c>; cached per template).
    /// </summary>
    public string ResolveExpectedAppPackageVersion(ShellManifest shell)
    {
        var key = shell.Version + "|" + shell.Sha256 + "|" + shell.Bytes.ToString();
        if (_expectedAppPackageVersion is not null && string.Equals(_expectedAppPackageVersionKey, key, StringComparison.Ordinal))
        {
            return _expectedAppPackageVersion;
        }
        var resolved = ShellPackageVersion.Resolve(shell, ShellDirectory);
        _expectedAppPackageVersion = resolved;
        _expectedAppPackageVersionKey = key;
        return resolved;
    }

    /// <summary>"Build now" service for the Library page (one game or every imported game).</summary>
    public LibraryBuildService CreateLibraryBuildService() => new(_workspace, CreateDeployBuildProvider(), BuildCompatibility);

    /// <summary>Library "Export .32a" / "Import .32a" service (user-data build packages).</summary>
    public BuildPackageService CreateBuildPackageService() => new(_workspace, Pack);

    /// <summary>
    /// Deploy pre-check: the five green/red prerequisites the Deploy page shows before the
    /// user presses Deploy. Every probe is best-effort, so a missing tool, an unreachable
    /// device service or a corrupt shell template becomes a red row, never an exception.
    /// </summary>
    public async Task<DeployPrerequisiteReport> CheckDeployPrerequisitesAsync(CancellationToken cancellationToken = default)
    {
        var deviceSummaries = new List<string>();
        var bridgeFound = DevPush is not null;
        var bridgeEnumerates = false;
        string? bridgeVersion = null;
        if (DevPush is { } devPush)
        {
            try
            {
                using var probeTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                probeTimeout.CancelAfter(TimeSpan.FromSeconds(8));
                var probe = await devPush.ProbeAsync(probeTimeout.Token).ConfigureAwait(false);
                bridgeVersion = probe.Version;
                if (probe.Ready)
                {
                    using var devicesTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    devicesTimeout.CancelAfter(TimeSpan.FromSeconds(8));
                    var devices = await devPush.DevicesAsync(devicesTimeout.Token).ConfigureAwait(false);
                    bridgeEnumerates = true;
                    // Deploy installs/pushes over USB; a network-paired phone is not enough.
                    deviceSummaries.AddRange(devices.Where(device => device.IsUsb).Select(device => device.Display));
                }
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested
                                               && exception is LauncherToolException or OperationCanceledException or IOException or UnauthorizedAccessException)
            {
                // A missing or unresponsive bridge is a red prerequisite, not a crash.
            }
        }
        if (deviceSummaries.Count == 0)
        {
            // Fall back to the read-only usbmuxd list so the device light can still be green
            // when only the device bridge is missing.
            try
            {
                using var muxTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                muxTimeout.CancelAfter(TimeSpan.FromSeconds(4));
                var muxDevices = await Mux.ListDevicesAsync(TimeSpan.FromSeconds(3), muxTimeout.Token).ConfigureAwait(false);
                deviceSummaries.AddRange(muxDevices.Where(device => device.IsUsb)
                    .Select(device => Privacy.DescribeDevice(null, device.ConnectionType)));
            }
            catch (Exception exception) when (!cancellationToken.IsCancellationRequested
                                               && exception is LauncherToolException or OperationCanceledException or IOException or UnauthorizedAccessException)
            {
                // No Apple device service on this PC: the device row stays red with its hint.
            }
        }

        var signingPinned = false;
        try
        {
            signingPinned = Impactor.Verify().BinariesOk;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            signingPinned = false;
        }

        var localTools = LocalTools;
        IReadOnlyList<string> missingLocalTools = localTools is null
            ? new[] { "3dsrecomp.exe + LLVM 23.1.6" }
            : localTools.MissingTools().Select(ShortToolName).ToArray();

        var shell = Shell ?? await LoadShellAsync(cancellationToken).ConfigureAwait(false);
        var shellManifestPresent = shell is not null;
        var shellVerified = false;
        string? shellDetail = null;
        if (shell is not null)
        {
            shellDetail = "v" + shell.Version + " build " + shell.Build;
            try
            {
                var verification = shell.Verify(ShellDirectory);
                var compatibility = ShellTemplateRules.ValidateManifest(shell);
                shellVerified = verification.Ok && compatibility.Ok;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                shellVerified = false;
            }
        }

        return DeployPrerequisiteEvaluator.Evaluate(new DeployPrerequisiteInputs(
            SigningToolsPinned: signingPinned,
            SigningDetail: "Impactor v" + ImpactorPins.TestedVersion + " + plumesign",
            LocalToolchainResolved: localTools is not null,
            MissingLocalTools: missingLocalTools,
            LocalToolchainDetail: "3dsrecomp · LLVM clang/llvm-ar/ld64.lld",
            DeviceBridgeFound: bridgeFound,
            DeviceBridgeEnumerates: bridgeEnumerates,
            DeviceBridgeVersion: bridgeVersion,
            DeviceSummaries: deviceSummaries,
            ShellManifestPresent: shellManifestPresent,
            ShellVerified: shellVerified,
            ShellDetail: shellDetail));
    }

    /// <summary>Short tool name from a <see cref="LocalToolchain.MissingTools"/> sentence (the explanation starts at " (").</summary>
    private static string ShortToolName(string message)
    {
        var index = message.IndexOf(" (", StringComparison.Ordinal);
        return index > 0 ? message[..index] : message;
    }

    public PushService? CreatePushService() => DevPush is null ? null : new PushService(DevPush);

    /// <summary>Composes the installable app IPA (shell template + packs + catalogue).</summary>
    public IpaComposer? CreateComposer() => Pack is null ? null : new IpaComposer(Pack);

    public ShellInstallService? CreateShellInstallService() =>
        PlumeSign is null ? null : new ShellInstallService(Impactor, Mux, PlumeSign, _workspace.WorkDirectory);

    public async Task<ShellManifest?> LoadShellAsync(CancellationToken cancellationToken = default)
    {
        Shell = await ShellManifest.ReadAsync(_locator.ShellDirectory, cancellationToken).ConfigureAwait(false);
        return Shell;
    }

    /// <summary>Probe every tool without blocking on the phone or the Mac.</summary>
    public async Task<HostReadiness> CheckAsync(CancellationToken cancellationToken = default)
    {
        var tools = new List<ToolStatus>();
        var packPath = _locator.FindPackCli();
        var packProbe = await ToolLocator.ProbeAsync("3ds2apple-pack", packPath, _runner, new[] { "--version" }, cancellationToken).ConfigureAwait(false);
        tools.Add(new ToolStatus("3ds2apple-pack", packProbe.Ready, packProbe.Ready ? "ready" : "missing", packProbe.Describe()));

        var devPushPath = _locator.FindDevPush();
        if (devPushPath is null)
        {
            tools.Add(new ToolStatus("devpush", false, "missing", "Device bridge not found — put devpush.exe into Bin/ or set its path in Settings."));
        }
        else
        {
            var client = new DevPushClient(_runner, devPushPath);
            var probe = await client.ProbeAsync(cancellationToken).ConfigureAwait(false);
            tools.Add(new ToolStatus("devpush", probe.Ready, probe.Ready ? "ready" : "failed", probe.Describe()));
        }

        var localMissing = LocalTools?.MissingTools() ?? new[] { "local build toolchain not resolved" };
        tools.Add(new ToolStatus(
            "local build (3dsrecomp + LLVM/LLD)",
            localMissing.Count == 0,
            localMissing.Count == 0 ? "ready" : "missing",
            localMissing.Count == 0
                ? $"{LocalTools!.RecompilerPath} + {LocalTools.LlvmBinDirectory}"
                : "local build needs: " + string.Join("; ", localMissing) + " — " + DeployOrchestrator.LocalBuildFix));

        var bundle = Impactor.Verify();
        tools.Add(new ToolStatus("Impactor v" + ImpactorPins.TestedVersion, bundle.Ready, bundle.Ready ? "ready" : "missing", bundle.Summary));

        var shell = await LoadShellAsync(cancellationToken).ConfigureAwait(false);
        if (shell is null)
        {
            tools.Add(new ToolStatus("Base shell IPA", false, "missing", "Shell/manifest.json is missing; bundle a base shell IPA before installing."));
        }
        else
        {
            var verification = shell.Verify(ShellDirectory);
            var compatibility = ShellTemplateRules.ValidateManifest(shell);
            var ready = verification.Ok && compatibility.Ok;
            var state = ready ? "ready" : "invalid";
            var message = ready
                ? $"v{shell.Version} build {shell.Build} ({shell.BundleId})"
                : (verification.Ok ? "template rejected: " + compatibility.Error : verification.Error ?? "invalid");
            tools.Add(new ToolStatus("Shell template IPA", ready, state, message));
        }

        var shellReady = shell is not null && shell.Verify(ShellDirectory).Ok;
        var localBuildReady = LocalTools is { } localTools && localTools.MissingTools().Count == 0;
        var installReady = PlumeSign is not null && Impactor.Verify().BinariesOk && shellReady;
        return new HostReadiness(
            tools,
            CanPreviewBuild: false,
            CanInstallShell: installReady,
            CanPush: DevPush is not null,
            CanLocalBuild: localBuildReady,
            CanDeploy: Pack is not null && localBuildReady && installReady && DevPush is not null);
    }
}
