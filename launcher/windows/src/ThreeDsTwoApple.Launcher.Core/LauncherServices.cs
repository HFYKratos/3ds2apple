using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.LauncherState;

namespace ThreeDsTwoApple.Launcher.Core;

/// <summary>One row of the launcher's host/tool readiness panel.</summary>
public sealed record ToolStatus(string Name, bool Ready, string State, string Message);

/// <summary>What this PC can currently do (drives which buttons are enabled).</summary>
public sealed record HostReadiness(
    IReadOnlyList<ToolStatus> Tools,
    bool CanPreviewBuild,
    bool CanAgentBuild,
    bool CanInstallShell,
    bool CanPush,
    bool CanLocalBuild)
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

    /// <summary>Resolved experimental local-build toolchain (3dsrecomp + LLVM/LLD); null when unresolved.</summary>
    public LocalToolchain? LocalTools { get; private set; }

    public ImpactorBundle Impactor { get; }

    public UsbMuxClient Mux { get; } = new();

    public PackCli? Pack { get; private set; }

    public DevPushClient? DevPush { get; private set; }

    public BuilderCli? Builder { get; private set; }

    public PlumeSignRunner? PlumeSign { get; private set; }

    public ShellManifest? Shell { get; private set; }

    public string ShellDirectory => _locator.ShellDirectory;

    public static LauncherServices Create(string? workspaceRoot = null, string? distributionRoot = null, IProcessRunner? runner = null)
    {
        var workspace = LauncherWorkspace.Open(workspaceRoot);
        var distribution = string.IsNullOrWhiteSpace(distributionRoot)
            ? Environment.GetEnvironmentVariable("THREEDS2APPLE_DIST") ?? AppContext.BaseDirectory
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
        Builder = BuilderCli.Create(_runner, _locator);
        var plumeSignPath = _locator.FindPlumeSign();
        PlumeSign = plumeSignPath is null ? null : new PlumeSignRunner(_runner, plumeSignPath, _workspace.LogsDirectory);
        LocalTools = LocalToolchainResolver.Resolve(_locator);
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
        PackBuildMode.MacAgentIpa => Builder is null || Pack is null ? null : new MacAgentIpaBuildProvider(Builder, Pack),
        PackBuildMode.MacAgentPack => new MacAgentPackBuildProvider(),
        PackBuildMode.LocalWinbuild => _workspace.State.LocalBuildEnabled
            ? (Pack is null ? null : new LocalWinbuildPackProvider(LocalTools, Pack, _runner))
            : null,
        _ => null,
    };

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

        var builderPath = _locator.FindBuilderCli();
        var builderProbe = await ToolLocator.ProbeAsync("builder-windows", builderPath, _runner, new[] { "--version" }, cancellationToken).ConfigureAwait(false);
        tools.Add(new ToolStatus("builder-windows", builderProbe.Ready, builderProbe.Ready ? "ready" : "missing", builderProbe.Describe()));

        var localMissing = LocalTools?.MissingTools() ?? new[] { "local build toolchain not configured" };
        tools.Add(new ToolStatus(
            "local build (3dsrecomp + LLVM/LLD)",
            localMissing.Count == 0,
            localMissing.Count == 0 ? "ready" : "missing",
            localMissing.Count == 0
                ? $"experimental, feature flag {(Workspace.State.LocalBuildEnabled ? "on" : "off")}: {LocalTools!.RecompilerPath} + {LocalTools.LlvmBinDirectory}"
                : "experimental local build needs: " + string.Join(", ", localMissing)));

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

        return new HostReadiness(
            tools,
            CanPreviewBuild: Pack is not null,
            CanAgentBuild: Builder is not null && Pack is not null,
            CanInstallShell: PlumeSign is not null && Impactor.Verify().BinariesOk && shell is not null,
            CanPush: DevPush is not null,
            CanLocalBuild: Workspace.State.LocalBuildEnabled && LocalTools is { } local && local.MissingTools().Count == 0);
    }
}
