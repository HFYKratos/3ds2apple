using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>One game's "Build now" result.</summary>
public sealed record LibraryBuildItemResult(
    string TitleID,
    string DisplayName,
    bool Success,
    bool Reused,
    string? ErrorCode,
    string? ErrorMessage,
    BuildArtifact? Artifact);

/// <summary>Aggregate result of one "Build now" / "Build all" run.</summary>
public sealed record LibraryBuildReport(IReadOnlyList<LibraryBuildItemResult> Items)
{
    public bool Success => Items.All(item => item.Success);

    public int BuiltCount => Items.Count(item => item.Success && !item.Reused);

    public int ReusedCount => Items.Count(item => item.Success && item.Reused);

    public int FailedCount => Items.Count(item => !item.Success);
}

/// <summary>
/// Library "Build now" (one game) / "Build all": compiles the GamePack locally ahead of a
/// deploy, or reuses a cached pack when the recorded buildCompatVersion and ROM SHA-256
/// still match. Deploy uses the same decision table, so a pack built here is reused by
/// Deploy and vice versa. State is persisted after every game, so an interrupted batch
/// keeps the packs it already finished.
/// </summary>
public sealed class LibraryBuildService
{
    public const string ToolchainMissingCode = "local_build_unavailable";
    public const string RomMissingCode = "rom_missing";

    private readonly LauncherWorkspace _workspace;
    private readonly IPackBuildProvider? _provider;
    private readonly IBuildCompatibilityProvider? _compatibility;

    public LibraryBuildService(LauncherWorkspace workspace, IPackBuildProvider? provider, IBuildCompatibilityProvider? compatibility)
    {
        _workspace = workspace;
        _provider = provider;
        _compatibility = compatibility;
    }

    /// <summary>Build (or reuse) the GamePack for each entry, in order.</summary>
    public async Task<LibraryBuildReport> BuildAsync(
        IReadOnlyList<LibraryEntry> entries,
        Func<LibraryEntry, string> displayName,
        IProgress<BuildProgress>? progress = null,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        var results = new List<LibraryBuildItemResult>();
        var total = Math.Max(1, entries.Count);
        for (var index = 0; index < entries.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var entry = entries[index];
            var name = displayName(entry);
            if (_provider is null)
            {
                results.Add(Fail(entry, name, ToolchainMissingCode,
                    "The Windows local build toolchain is not available, so no game can be compiled."));
                continue;
            }
            if (!File.Exists(entry.RomPath))
            {
                results.Add(Fail(entry, name, RomMissingCode, "The ROM for " + name + " is missing: " + entry.RomPath));
                continue;
            }

            var cached = await ResolveCachedBuildAsync(entry, cancellationToken).ConfigureAwait(false);
            if (cached.PackPath is not null)
            {
                entry.State = "built";
                entry.LastError = null;
                _workspace.SaveState();
                var label = cached.Artifact?.BuildCompatShort ?? "?";
                log?.Invoke("build: " + entry.TitleID + " (" + name + ") reusing the cached GamePack ("
                            + label + ", ROM sha256 " + BuildCachePolicy.ShortHash(cached.Artifact?.RomSha256)
                            + "): " + cached.Detail);
                progress?.Report(new BuildProgress("cached", OverallPercent(index, total, 100),
                    name + ": reusing the cached GamePack (" + label + ")"));
                results.Add(new LibraryBuildItemResult(entry.TitleID, name, true, true, null, null, entry.Build));
                continue;
            }
            if (cached.Detail is not null)
            {
                log?.Invoke("build: " + entry.TitleID + " (" + name + ") needs a build: " + cached.Detail);
            }

            var outcome = await _provider.BuildAsync(
                new PackBuildRequest(entry.TitleID, name, entry.ProductCode, entry.RomPath, _workspace.WorkDirectory, _workspace.BuildOptions),
                new ScaledProgress(progress, index, total),
                line => log?.Invoke("[build] " + line),
                cancellationToken).ConfigureAwait(false);
            if (!outcome.Success)
            {
                entry.State = "build_failed";
                entry.LastError = outcome.ErrorMessage;
                _workspace.SaveState();
                log?.Invoke("build: " + entry.TitleID + " failed: " + (outcome.ErrorMessage ?? "unknown error"));
                progress?.Report(new BuildProgress("failed", OverallPercent(index, total, 100),
                    name + ": build failed — " + (outcome.ErrorMessage ?? "unknown error")));
                results.Add(new LibraryBuildItemResult(entry.TitleID, name, false, false,
                    outcome.ErrorCode ?? "build_failed", outcome.ErrorMessage, entry.Build));
                continue;
            }
            if (!outcome.Installable)
            {
                entry.State = "build_failed";
                entry.LastError = "The build produced a placeholder pack, which cannot run on a phone.";
                _workspace.SaveState();
                results.Add(new LibraryBuildItemResult(entry.TitleID, name, false, false,
                    "pack_placeholder", entry.LastError, entry.Build));
                continue;
            }

            var builtAt = DateTimeOffset.UtcNow;
            entry.Pack = outcome.Pack;
            entry.PackPath = outcome.PackPath ?? DefaultPackPath(entry.TitleID);
            entry.State = "built";
            entry.BuiltAt = builtAt;
            entry.LastBuildName = outcome.BuildName;
            entry.LastError = null;
            var compatibility = _compatibility is null
                ? null
                : await _compatibility.ResolveAsync(cancellationToken).ConfigureAwait(false);
            entry.Build = await BuildArtifacts.CaptureAsync(outcome, compatibility, entry.RomPath, builtAt, cancellationToken).ConfigureAwait(false);
            _workspace.SaveState();
            log?.Invoke("build: " + entry.TitleID + " ok -> " + entry.PackPath
                        + " (compat " + entry.Build.BuildCompatShort + ", ROM sha256 " + BuildCachePolicy.ShortHash(entry.Build.RomSha256)
                        + ", " + entry.Build.PackBytes + " bytes)");
            progress?.Report(new BuildProgress("done", OverallPercent(index, total, 100),
                name + ": GamePack built (" + entry.Build.BuildCompatShort + ")"));
            results.Add(new LibraryBuildItemResult(entry.TitleID, name, true, false, null, null, entry.Build));
        }
        return new LibraryBuildReport(results);
    }

    /// <summary>Path where the pack CLI records the GamePack for a title.</summary>
    public static string DefaultPackPath(LauncherWorkspace workspace, string titleId) =>
        Path.Combine(workspace.OutRoot, "packages", Deploy.GameInfoWriter.NormalizeTitleId(titleId), Deploy.GameInfoWriter.GamePackFileName);

    private string DefaultPackPath(string titleId) => DefaultPackPath(_workspace, titleId);

    private async Task<CachedBuild> ResolveCachedBuildAsync(LibraryEntry entry, CancellationToken cancellationToken)
    {
        var packPath = !string.IsNullOrWhiteSpace(entry.PackPath) && File.Exists(entry.PackPath) ? entry.PackPath : null;
        if (_compatibility is null)
        {
            return packPath is null
                ? new CachedBuild(null, null, "no built GamePack exists")
                : new CachedBuild(packPath, entry.Build, "the existing GamePack is reused");
        }
        var compatibility = await _compatibility.ResolveAsync(cancellationToken).ConfigureAwait(false);
        var romSha256 = BuildFingerprint.MatchesUnchangedRom(entry.Build, entry.RomPath)
            ? entry.Build!.RomSha256
            : await FileHashes.Sha256Async(entry.RomPath, cancellationToken).ConfigureAwait(false);
        var decision = BuildCachePolicy.Evaluate(entry.Build, compatibility.BuildCompatVersion, romSha256, packPath);
        return decision.Reuse
            ? new CachedBuild(packPath, entry.Build, decision.Detail)
            : new CachedBuild(null, null, decision.Detail);
    }

    private LibraryBuildItemResult Fail(LibraryEntry entry, string name, string code, string message)
    {
        entry.State = "build_failed";
        entry.LastError = message;
        _workspace.SaveState();
        return new LibraryBuildItemResult(entry.TitleID, name, false, false, code, message, entry.Build);
    }

    private static double OverallPercent(int index, int total, double innerPercent) =>
        total <= 0 ? 0 : Math.Clamp((index + Math.Clamp(innerPercent / 100.0, 0, 1)) / total * 100.0, 0, 100);

    private sealed record CachedBuild(string? PackPath, BuildArtifact? Artifact, string Detail);

    /// <summary>Maps one game's provider progress onto the whole batch percentage.</summary>
    private sealed class ScaledProgress : IProgress<BuildProgress>
    {
        private readonly IProgress<BuildProgress>? _outer;
        private readonly int _index;
        private readonly int _total;

        public ScaledProgress(IProgress<BuildProgress>? outer, int index, int total)
        {
            _outer = outer;
            _index = index;
            _total = total;
        }

        public void Report(BuildProgress value) =>
            _outer?.Report(value with { Percent = OverallPercent(_index, _total, value.Percent ?? 0) });
    }
}
