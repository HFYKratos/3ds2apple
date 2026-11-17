using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Localization;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>The five user-visible stages of one Deploy run, in order.</summary>
public enum DeployStepKind
{
    /// <summary>Compile every selected game's GamePack locally (reuses real packs already built).</summary>
    Build = 0,

    /// <summary>Compose one ROM-free app IPA with all selected packs + GameCatalog, then verify it.</summary>
    Compose = 1,

    /// <summary>Sign and install the composed app with the bundled Impactor/plumesign.</summary>
    Install = 2,

    /// <summary>Push each selected ROM + GameInfo.json into the installed app's Documents.</summary>
    Push = 3,

    /// <summary>Read back sizes/sha and mark the games ready on the phone.</summary>
    Verify = 4,
}

/// <summary>Status of one Deploy step.</summary>
public enum DeployStepStatus
{
    Pending,
    Running,
    Succeeded,
    Failed,
    Skipped,
}

/// <summary>One progress event from the Deploy pipeline (all steps, all games).</summary>
public sealed record DeployProgress(
    DeployStepKind Step,
    DeployStepStatus Status,
    string Message,
    double? Percent = null,
    string? TitleID = null);

/// <summary>Per-game result of a Deploy run.</summary>
public sealed record DeployGameResult(
    string TitleID,
    string DisplayName,
    bool Built,
    bool Pushed,
    bool Verified,
    string? ErrorCode = null,
    string? ErrorMessage = null);

/// <summary>What the user selected on the Deploy page.</summary>
public sealed record DeployRequest(
    IReadOnlyList<string> TitleIDs,
    string TemplateIpaPath,
    string? BundleIdOverride,
    string? DeviceUdid,
    bool RebuildExistingPacks = false);

/// <summary>Final result of a Deploy run; the failed step is always the exact one to retry.</summary>
public sealed record DeployOutcome(
    bool Success,
    DeployStepKind? FailedStep,
    string? ErrorCode,
    string? ErrorMessage,
    string? ErrorFix,
    string? ComposedIpaPath,
    string? InstalledBundleId,
    IReadOnlyList<DeployGameResult> Games,
    bool Retryable);

/// <summary>Composes the installable IPA (implemented by <see cref="IpaComposer"/>).</summary>
public interface IComposedIpaComposer
{
    Task<ComposedAppIpa> ComposeAsync(
        string shellTemplateIpaPath,
        IReadOnlyList<ComposedPack> packs,
        string outputDirectory,
        Action<string>? log,
        CancellationToken cancellationToken);
}

/// <summary>Signs and installs the composed IPA (implemented by <see cref="ShellInstallService"/>).</summary>
public interface IAppIpaInstaller
{
    Task<ShellInstallOutcome> InstallAsync(
        ShellManifest shell,
        string shellDirectory,
        string ipaPath,
        string? bundleIdOverride,
        string? deviceUdid,
        Action<string>? log,
        CancellationToken cancellationToken);
}

/// <summary>Pushes/verifies ROM data through the devpush device bridge.</summary>
public interface IGameDataPusher
{
    Task<GamePushPlan> CreatePlanAsync(LibraryEntry entry, string stagingDirectory, Action<string>? log, CancellationToken cancellationToken);

    Task<PushOutcome> PushAsync(
        GamePushPlan plan,
        string bundleId,
        string? deviceUdid,
        bool resume,
        IProgress<PushProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? deviceUdid, CancellationToken cancellationToken);
}

/// <summary>Concrete <see cref="IGameDataPusher"/> over the existing bridge push service.</summary>
public sealed class LauncherGameDataPusher : IGameDataPusher
{
    private readonly PushService _pushService;

    public LauncherGameDataPusher(PushService pushService) => _pushService = pushService;

    public Task<GamePushPlan> CreatePlanAsync(LibraryEntry entry, string stagingDirectory, Action<string>? log, CancellationToken cancellationToken) =>
        GamePushPlan.CreateAsync(
            stagingDirectory,
            entry.TitleID,
            DisplayName(entry),
            entry.ProductCode,
            LauncherInfo.GamePackAbiVersion,
            entry.PackPath,
            entry.RomPath,
            entry.DisplayNames,
            entry.Publisher,
            entry.Region,
            entry.CoverPath,
            log,
            cancellationToken);

    public Task<PushOutcome> PushAsync(
        GamePushPlan plan,
        string bundleId,
        string? deviceUdid,
        bool resume,
        IProgress<PushProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken) =>
        _pushService.PushAsync(plan, bundleId, deviceUdid, resume, progress, log, cancellationToken);

    public Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? deviceUdid, CancellationToken cancellationToken) =>
        _pushService.VerifyAsync(plan, bundleId, deviceUdid, cancellationToken);

    internal static string DisplayName(LibraryEntry entry)
    {
        var fallback = string.IsNullOrWhiteSpace(entry.DisplayNameOverride) ? entry.DisplayName : entry.DisplayNameOverride;
        // The pushed displayName is the title for the launcher's current UI
        // language; displayNames carries every original SMDH language so the
        // phone can pick for its own language.
        return GameNames.Resolve(entry.DisplayNames, fallback, Loc.CurrentTag);
    }
}

/// <summary>
/// One-click batch Deploy: build all selected games -> compose one ROM-free IPA with
/// all selected real packs -> verify the composed IPA (packs + non-empty schema-2
/// catalogue) -> sign/install -> push each selected ROM+GameInfo using the ACTUAL
/// installed bundle id -> read-back verify -> done.
/// </summary>
/// <remarks>
/// Every dependency is injected so the whole order-of-operations contract is unit
/// tested with fakes (no phone, no Mac, no pack CLI). The pipeline never installs a
/// bare shell: it fails at Compose when no real pack exists or when the verifier
/// rejects the composed IPA, so the "app installed but no game appeared" bug cannot
/// silently happen again. On failure the outcome names the exact step and message
/// and <see cref="DeployOutcome.Retryable"/> lets the UI show one Retry button.
/// </remarks>
public sealed class DeployOrchestrator
{
    public const int StepCount = 5;
    private const double BuildEnd = 30;
    private const double ComposeEnd = 45;
    private const double InstallEnd = 60;
    private const double PushEnd = 90;

    private readonly LauncherWorkspace _workspace;
    private readonly ShellManifest? _shell;
    private readonly string _shellDirectory;
    private readonly IPackBuildProvider? _buildProvider;
    private readonly IComposedIpaComposer? _composer;
    private readonly IAppIpaInstaller? _installer;
    private readonly IGameDataPusher? _pusher;
    private readonly IBuildCompatibilityProvider? _buildCompatibility;

    /// <param name="buildCompatibility">
    /// Optional so the pipeline stays constructible with pure fakes; the launcher always
    /// supplies it (see <c>LauncherServices.CreateDeployOrchestrator</c>). With it, a pack
    /// is reused only when the recorded buildCompatVersion AND ROM SHA-256 still match.
    /// </param>
    public DeployOrchestrator(
        LauncherWorkspace workspace,
        ShellManifest? shell,
        string shellDirectory,
        IPackBuildProvider? buildProvider,
        IComposedIpaComposer? composer,
        IAppIpaInstaller? installer,
        IGameDataPusher? pusher,
        IBuildCompatibilityProvider? buildCompatibility = null)
    {
        _workspace = workspace;
        _shell = shell;
        _shellDirectory = shellDirectory;
        _buildProvider = buildProvider;
        _composer = composer;
        _installer = installer;
        _pusher = pusher;
        _buildCompatibility = buildCompatibility;
    }

    /// <summary>True when every component needed to even attempt a deploy is present.</summary>
    public bool HasAllComponents => _buildProvider is not null && _composer is not null && _installer is not null && _pusher is not null;

    /// <summary>Names of missing components (for the Deploy page's pre-check message).</summary>
    public IReadOnlyList<string> MissingComponents()
    {
        var missing = new List<string>();
        if (_buildProvider is null) missing.Add("local build provider");
        if (_composer is null) missing.Add("3ds2apple-pack.exe (IPA composer)");
        if (_installer is null) missing.Add("Impactor/plumesign (installer)");
        if (_pusher is null) missing.Add("devpush.exe (device bridge)");
        return missing;
    }

    public async Task<DeployOutcome> RunAsync(
        DeployRequest request,
        IProgress<DeployProgress>? progress = null,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        var games = new List<DeployGameResult>();
        var selected = new List<LibraryEntry>();
        foreach (var titleId in request.TitleIDs.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var entry = _workspace.Find(titleId);
            if (entry is null)
            {
                return Fail(progress, DeployStepKind.Build, "game_missing",
                    "The selected game is no longer in the library: " + titleId + ".",
                    "Refresh the library and select the game again.", games, retryable: false);
            }
            selected.Add(entry);
        }
        if (selected.Count == 0)
        {
            return Fail(progress, DeployStepKind.Build, "no_games_selected",
                "No game is selected, so there is nothing to deploy.",
                "Tick one or more games on the Deploy page, then press Deploy.", games, retryable: false);
        }

        // --- Step 1: build (or reuse) every selected real GamePack ----------
        Report(progress, DeployStepKind.Build, DeployStepStatus.Running,
            "Compiling " + selected.Count + " selected game(s) locally…", 0);
        log?.Invoke("deploy: " + selected.Count + " selected game(s); local build is the only build path.");
        var packs = new List<ComposedPack>();
        for (var index = 0; index < selected.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var entry = selected[index];
            var displayName = LauncherGameDataPusher.DisplayName(entry);
            var cached = await ResolveCachedBuildAsync(entry, request.RebuildExistingPacks, cancellationToken).ConfigureAwait(false);
            var packPath = cached.PackPath;
            if (packPath is not null)
            {
                log?.Invoke("build: " + entry.TitleID + " (" + displayName + ") reusing the cached GamePack ("
                            + (cached.CompatibilityShort ?? entry.Build?.BuildCompatShort ?? "?")
                            + ", ROM sha256 " + BuildCachePolicy.ShortHash(entry.Build?.RomSha256 ?? cached.RomSha256)
                            + "): " + cached.Detail);
                Report(progress, DeployStepKind.Build, DeployStepStatus.Running,
                    displayName + ": already built, reusing the cached GamePack", BuildPercent(index, selected.Count, 100), entry.TitleID);
            }
            else
            {
                if (cached.Detail is not null)
                {
                    log?.Invoke("build: " + entry.TitleID + " (" + displayName + ") needs a rebuild: " + cached.Detail);
                }
                if (_buildProvider is null)
                {
                    return Fail(progress, DeployStepKind.Build, "local_build_unavailable",
                        "The Windows local build toolchain is not available, so no game can be compiled.",
                        LocalBuildFix, games);
                }
                if (!File.Exists(entry.RomPath))
                {
                    return Fail(progress, DeployStepKind.Build, "rom_missing",
                        "The ROM for " + displayName + " is gone: " + entry.RomPath + ".",
                        "Re-import the ROM, then press Retry.", games);
                }
                var buildProgress = new BuildProgressAdapter(progress, entry.TitleID, displayName, index, selected.Count);
                var outcome = await _buildProvider.BuildAsync(
                    new PackBuildRequest(entry.TitleID, displayName, entry.ProductCode, entry.RomPath, _workspace.WorkDirectory),
                    buildProgress,
                    line => log?.Invoke("[build] " + line),
                    cancellationToken).ConfigureAwait(false);
                if (!outcome.Success)
                {
                    entry.LastError = outcome.ErrorMessage;
                    entry.State = "build_failed";
                    _workspace.SaveState();
                    return Fail(progress, DeployStepKind.Build, outcome.ErrorCode ?? "build_failed",
                        "Compiling " + displayName + " failed: " + (outcome.ErrorMessage ?? "unknown error"),
                        "Fix the toolchain/ROM problem shown above, then press Retry. Packs that already built are reused.", games);
                }
                if (!outcome.Installable)
                {
                    return Fail(progress, DeployStepKind.Build, "pack_placeholder",
                        "The build produced a placeholder pack for " + displayName + ", which cannot run on a phone.",
                        "Only a real local AOT build can be installed; fix the local toolchain and press Retry.", games);
                }
                entry.Pack = outcome.Pack;
                entry.PackPath = outcome.PackPath ?? DefaultPackPath(entry.TitleID);
                entry.State = "built";
                entry.BuiltAt = DateTimeOffset.UtcNow;
                entry.LastBuildName = outcome.BuildName;
                entry.LastError = null;
                entry.Build = await CaptureBuildArtifactAsync(entry, outcome, cancellationToken).ConfigureAwait(false);
                _workspace.SaveState();
                log?.Invoke("build: " + entry.TitleID + " ok -> " + entry.PackPath);
                packPath = entry.PackPath;
            }

            if (string.IsNullOrWhiteSpace(packPath) || !File.Exists(packPath))
            {
                return Fail(progress, DeployStepKind.Build, "pack_missing",
                    "No real GamePack file exists for " + displayName + " after the build step.",
                    "Build this game again (the pack file is missing), then press Retry.", games);
            }
            packs.Add(new ComposedPack(entry.TitleID, displayName, entry.ProductCode, LauncherInfo.GamePackAbiVersion, packPath));
            games.Add(new DeployGameResult(entry.TitleID, displayName, Built: true, Pushed: false, Verified: false));
        }
        Report(progress, DeployStepKind.Build, DeployStepStatus.Succeeded,
            packs.Count + " game pack(s) ready", BuildEnd);

        // --- Step 2: compose one ROM-free IPA with all selected packs -------
        Report(progress, DeployStepKind.Compose, DeployStepStatus.Running,
            "Composing one ROM-free app IPA with " + packs.Count + " game(s)…", BuildEnd);
        if (!File.Exists(request.TemplateIpaPath))
        {
            return Fail(progress, DeployStepKind.Compose, "shell_missing",
                "The ROM-free base shell template IPA is missing: " + request.TemplateIpaPath + ".",
                "Reinstall the launcher ZIP (it contains Shell/3ds2apple-shell.ipa), then press Retry.", games);
        }
        if (_composer is null)
        {
            return Fail(progress, DeployStepKind.Compose, "composer_unavailable",
                "The IPA composer is unavailable because 3ds2apple-pack.exe was not found.",
                "Reinstall the launcher ZIP so Bin/3ds2apple-pack.exe exists, then press Retry.", games);
        }
        ComposedAppIpa composed;
        try
        {
            composed = await _composer.ComposeAsync(
                request.TemplateIpaPath,
                packs,
                Path.Combine(_workspace.WorkDirectory, "deploy-ipa"),
                log,
                cancellationToken).ConfigureAwait(false);
        }
        catch (LauncherToolException error)
        {
            return Fail(progress, DeployStepKind.Compose, error.Code, error.Message, error.Hint, games);
        }
        var verification = ComposedIpaVerifier.Verify(composed.IpaPath, packs);
        if (!verification.Ok)
        {
            return Fail(progress, DeployStepKind.Compose, verification.ErrorCode ?? "composed_ipa_invalid",
                verification.Error ?? "The composed IPA is not installable.", verification.Fix, games);
        }
        log?.Invoke("deploy: composed IPA verified (" + verification.Describe() + ", sha256 " + composed.Sha256[..16] + "…)");
        Report(progress, DeployStepKind.Compose, DeployStepStatus.Succeeded,
            "Verified " + composed.GameCount + " pack(s) + schema-2 catalogue in the app IPA (sha256 " + composed.Sha256[..12] + "…)", ComposeEnd);

        // --- Step 3: sign + install the composed app ------------------------
        Report(progress, DeployStepKind.Install, DeployStepStatus.Running,
            "Signing and installing the app with the bundled Impactor/plumesign…", ComposeEnd);
        if (_shell is null)
        {
            return Fail(progress, DeployStepKind.Install, "shell_missing",
                "The base shell manifest (Shell/manifest.json) is missing.",
                "Reinstall the launcher ZIP, then press Retry.", games);
        }
        if (_installer is null)
        {
            return Fail(progress, DeployStepKind.Install, "impactor_missing",
                "The bundled official Impactor/plumesign was not found.",
                "Reinstall the launcher ZIP (ThirdParty/Impactor) or run tools/fetch-impactor.ps1, then press Retry.", games);
        }
        ShellInstallOutcome install;
        try
        {
            install = await _installer.InstallAsync(
                _shell,
                _shellDirectory,
                composed.IpaPath,
                request.BundleIdOverride,
                request.DeviceUdid,
                log,
                cancellationToken).ConfigureAwait(false);
        }
        catch (LauncherToolException error)
        {
            return Fail(progress, DeployStepKind.Install, error.Code, error.Message, error.Hint, games);
        }
        if (!install.Installed)
        {
            var error = install.Error;
            return Fail(progress, DeployStepKind.Install, error?.Code ?? "device_install_failed",
                error is null ? "Signing/installing the app failed." : error.Title + (string.IsNullOrWhiteSpace(error.Detail) ? string.Empty : " — " + error.Detail),
                error?.Fix ?? "Keep the phone unlocked and connected (Apple Devices running), then press Retry.", games);
        }
        _workspace.State.InstalledBundleId = install.BundleId;
        _workspace.State.InstalledAt = DateTimeOffset.UtcNow;
        _workspace.State.InstalledGameCount = packs.Count;
        _workspace.SaveState();
        log?.Invoke("deploy: installed " + install.BundleId + " with " + packs.Count + " pack(s)");
        Report(progress, DeployStepKind.Install, DeployStepStatus.Succeeded,
            "Installed " + install.BundleId + " with " + packs.Count + " game(s)", InstallEnd);

        // --- Step 4: push ROM data using the ACTUAL installed bundle id ----
        var installedBundleId = _workspace.State.InstalledBundleId;
        var pushBundleId = string.IsNullOrWhiteSpace(installedBundleId)
            ? (string.IsNullOrWhiteSpace(request.BundleIdOverride) ? _shell.BundleId : request.BundleIdOverride.Trim())
            : installedBundleId;
        if (string.IsNullOrWhiteSpace(pushBundleId))
        {
            return Fail(progress, DeployStepKind.Push, "push_no_bundle_id",
                "No installed bundle id is known, so the ROM data cannot be pushed.",
                "Install the app again (Deploy), then press Retry.", games);
        }
        if (_pusher is null)
        {
            return Fail(progress, DeployStepKind.Push, "devpush_missing",
                "The device bridge (devpush.exe) was not found, so ROM data cannot be pushed.",
                "Reinstall the launcher ZIP so Bin/devpush.exe exists, then press Retry.", games);
        }
        Report(progress, DeployStepKind.Push, DeployStepStatus.Running,
            "Pushing " + selected.Count + " ROM(s) + GameInfo.json to " + pushBundleId + "…", InstallEnd);
        var plans = new List<(LibraryEntry Entry, GamePushPlan Plan)>();
        for (var index = 0; index < selected.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var entry = selected[index];
            var displayName = LauncherGameDataPusher.DisplayName(entry);
            GamePushPlan plan;
            try
            {
                plan = await _pusher.CreatePlanAsync(entry, _workspace.StagingDirectory, log, cancellationToken).ConfigureAwait(false);
            }
            catch (LauncherToolException error)
            {
                return Fail(progress, DeployStepKind.Push, error.Code,
                    "Could not prepare the push for " + displayName + ": " + error.Message,
                    error.Hint ?? "Fix the ROM file and press Retry.", games);
            }
            var pushProgress = new PushProgressAdapter(progress, entry.TitleID, displayName, index, selected.Count);
            PushOutcome outcome;
            try
            {
                outcome = await _pusher.PushAsync(plan, pushBundleId, request.DeviceUdid, resume: true, pushProgress,
                    line => log?.Invoke("[push] " + line), cancellationToken).ConfigureAwait(false);
            }
            catch (LauncherToolException error)
            {
                return Fail(progress, DeployStepKind.Push, error.Code,
                    "Pushing " + displayName + " failed: " + error.Message,
                    error.Hint ?? "Check USB/unlock/Trust and Apple Devices running, then press Retry.", games);
            }
            if (!outcome.Success)
            {
                games[index] = games[index] with { Pushed = false, ErrorCode = outcome.ErrorCode, ErrorMessage = outcome.ErrorMessage };
                return Fail(progress, DeployStepKind.Push, outcome.ErrorCode ?? "push_failed",
                    "Pushing " + displayName + " failed: " + (outcome.ErrorMessage ?? "unknown error"),
                    "Check USB/unlock/Trust and Apple Devices running, then press Retry; already-pushed files are resumed by size.", games);
            }
            plans.Add((entry, plan));
            games[index] = games[index] with { Pushed = true };
            log?.Invoke("push: " + displayName + " -> " + plan.RemoteDirectory);
            Report(progress, DeployStepKind.Push, DeployStepStatus.Running,
                displayName + ": ROM + GameInfo.json pushed", PushPercent(index + 1, selected.Count, 100), entry.TitleID);
        }
        Report(progress, DeployStepKind.Push, DeployStepStatus.Succeeded,
            "Pushed " + plans.Count + " game(s) to " + pushBundleId, PushEnd);

        // --- Step 5: read-back verification ---------------------------------
        Report(progress, DeployStepKind.Verify, DeployStepStatus.Running,
            "Verifying the pushed files on the phone…", PushEnd);
        var verifyFailures = new List<string>();
        for (var index = 0; index < plans.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var (entry, plan) = plans[index];
            var displayName = LauncherGameDataPusher.DisplayName(entry);
            var problems = await _pusher.VerifyAsync(plan, pushBundleId, request.DeviceUdid, cancellationToken).ConfigureAwait(false);
            if (problems.Count > 0)
            {
                verifyFailures.Add(displayName + ": " + string.Join("; ", problems));
                games[index] = games[index] with { Verified = false, ErrorCode = "push_verify_failed", ErrorMessage = string.Join("; ", problems) };
                continue;
            }
            entry.PushedAt = DateTimeOffset.UtcNow;
            entry.PushedFiles = plan.Files.Select(file => file.RemoteName).ToList();
            entry.LastError = null;
            _workspace.SaveState();
            games[index] = games[index] with { Verified = true };
            log?.Invoke("deploy: verified " + displayName + " (" + plan.RemoteDirectory + ")");
            Report(progress, DeployStepKind.Verify, DeployStepStatus.Running,
                displayName + ": size/sha verified", PushEnd + 10.0 * (index + 1) / plans.Count, entry.TitleID);
        }
        if (verifyFailures.Count > 0)
        {
            return Fail(progress, DeployStepKind.Verify, "push_verify_failed",
                "Data verification failed: " + string.Join(" | ", verifyFailures),
                "Reconnect the phone and press Retry; the push resumes and verifies again.", games);
        }
        Report(progress, DeployStepKind.Verify, DeployStepStatus.Succeeded,
            "All selected games are installed and their ROM data is verified on the phone.", 100);
        log?.Invoke("deploy: done — " + plans.Count + " game(s) ready in " + pushBundleId);
        return new DeployOutcome(true, null, null, null, null, composed.IpaPath, pushBundleId, games, Retryable: true);
    }

    /// <summary>One actionable message for a missing Windows LLVM/3dsrecomp payload.</summary>
    public const string LocalBuildFix =
        "This launcher needs 3dsrecomp.exe and the official LLVM 21.1.8 tools (clang.exe, llvm-ar.exe, ld64.lld.exe, lib/clang/21/include). "
        + "Install LLVM 21.1.8 for Windows x86_64 and build 3dsrecomp once, or place both under the launcher's distribution Bin/ (Bin/3dsrecomp.exe and Bin/llvm/), then press Retry.";

    /// <summary>
    /// Reuse decision for one selected game: only a recorded buildCompatVersion + ROM
    /// SHA-256 match (and a pack file that still exists) allows skipping the rebuild.
    /// </summary>
    private async Task<CachedBuild> ResolveCachedBuildAsync(LibraryEntry entry, bool forceRebuild, CancellationToken cancellationToken)
    {
        if (forceRebuild)
        {
            return new CachedBuild(null, null, null, "a rebuild was requested");
        }
        var packPath = ResolveExistingPackPath(entry);
        if (_buildCompatibility is null)
        {
            // Compatibility injection is optional so the pipeline stays testable with pure
            // fakes; the shipped launcher always supplies a real provider.
            return packPath is null
                ? new CachedBuild(null, null, null, "no built GamePack exists")
                : new CachedBuild(packPath, entry.Build?.BuildCompatShort, entry.Build?.RomSha256, "the existing GamePack is reused");
        }
        if (!File.Exists(entry.RomPath))
        {
            return new CachedBuild(null, null, null, "the ROM file is missing");
        }
        var compatibility = await _buildCompatibility.ResolveAsync(cancellationToken).ConfigureAwait(false);
        var romSha256 = BuildFingerprint.MatchesUnchangedRom(entry.Build, entry.RomPath)
            ? entry.Build!.RomSha256
            : await FileHashes.Sha256Async(entry.RomPath, cancellationToken).ConfigureAwait(false);
        var decision = BuildCachePolicy.Evaluate(entry.Build, compatibility.BuildCompatVersion, romSha256, packPath);
        return decision.Reuse
            ? new CachedBuild(packPath, compatibility.ShortVersion, romSha256, decision.Detail)
            : new CachedBuild(null, compatibility.ShortVersion, romSha256, decision.Detail);
    }

    /// <summary>Record the buildCompatVersion marker + ROM SHA-256 in the workspace state.</summary>
    private async Task<BuildArtifact> CaptureBuildArtifactAsync(LibraryEntry entry, PackBuildOutcome outcome, CancellationToken cancellationToken)
    {
        var compatibility = _buildCompatibility is null
            ? null
            : await _buildCompatibility.ResolveAsync(cancellationToken).ConfigureAwait(false);
        return await BuildArtifacts.CaptureAsync(outcome, compatibility, entry.RomPath, DateTimeOffset.UtcNow, cancellationToken).ConfigureAwait(false);
    }

    private sealed record CachedBuild(string? PackPath, string? CompatibilityShort, string? RomSha256, string Detail);

    private string? ResolveExistingPackPath(LibraryEntry entry)
    {
        if (entry.Pack is null || entry.Pack.IsPlaceholder)
        {
            return null;
        }
        if (!string.IsNullOrWhiteSpace(entry.PackPath) && File.Exists(entry.PackPath))
        {
            return entry.PackPath;
        }
        var fallback = DefaultPackPath(entry.TitleID);
        return File.Exists(fallback) ? fallback : null;
    }

    private string DefaultPackPath(string titleId) =>
        Path.Combine(_workspace.OutRoot, "packages", GameInfoWriter.NormalizeTitleId(titleId), GameInfoWriter.GamePackFileName);

    private static void Report(IProgress<DeployProgress>? progress, DeployStepKind step, DeployStepStatus status, string message, double? percent = null, string? titleId = null) =>
        progress?.Report(new DeployProgress(step, status, message, percent, titleId));

    private static DeployOutcome Fail(
        IProgress<DeployProgress>? progress,
        DeployStepKind step,
        string code,
        string message,
        string? fix,
        IReadOnlyList<DeployGameResult> games,
        bool retryable = true)
    {
        progress?.Report(new DeployProgress(step, DeployStepStatus.Failed, message));
        return new DeployOutcome(false, step, code, message, fix, null, null, games, retryable);
    }

    private static double BuildPercent(int index, int total, double? innerPercent) =>
        total <= 0 ? 0 : BuildEnd * (index + Math.Clamp((innerPercent ?? 0) / 100.0, 0, 1)) / total;

    private static double PushPercent(int index, int total, double? innerPercent) =>
        total <= 0 ? InstallEnd : InstallEnd + (PushEnd - InstallEnd) * (index + Math.Clamp((innerPercent ?? 0) / 100.0, 0, 1)) / total;

    private sealed class BuildProgressAdapter : IProgress<BuildProgress>
    {
        private readonly IProgress<DeployProgress>? _outer;
        private readonly string _titleId;
        private readonly string _displayName;
        private readonly int _index;
        private readonly int _total;

        public BuildProgressAdapter(IProgress<DeployProgress>? outer, string titleId, string displayName, int index, int total)
        {
            _outer = outer;
            _titleId = titleId;
            _displayName = displayName;
            _index = index;
            _total = total;
        }

        public void Report(BuildProgress value) =>
            _outer?.Report(new DeployProgress(
                DeployStepKind.Build,
                DeployStepStatus.Running,
                _displayName + ": " + value.Message,
                BuildPercent(_index, _total, value.Percent),
                _titleId));
    }

    private sealed class PushProgressAdapter : IProgress<PushProgress>
    {
        private readonly IProgress<DeployProgress>? _outer;
        private readonly string _titleId;
        private readonly string _displayName;
        private readonly int _index;
        private readonly int _total;

        public PushProgressAdapter(IProgress<DeployProgress>? outer, string titleId, string displayName, int index, int total)
        {
            _outer = outer;
            _titleId = titleId;
            _displayName = displayName;
            _index = index;
            _total = total;
        }

        public void Report(PushProgress value) =>
            _outer?.Report(new DeployProgress(
                DeployStepKind.Push,
                DeployStepStatus.Running,
                _displayName + ": " + value.FileName + " " + value.Message,
                PushPercent(_index, _total, value.OverallPercent),
                _titleId));
    }
}
