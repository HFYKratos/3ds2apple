using System.Security.Cryptography;
using System.Text;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Canonical identity of the local GamePack build recipe. Two builds are
/// interchangeable only when every component below is identical; a launcher or
/// shell update that does not change the recipe must NOT invalidate the cache.
/// The recorded string plus the ROM SHA-256 is persisted in state.json (user data,
/// never in the launcher log) and is shown in the Library as a short build label.
/// </summary>
public sealed record BuildCompatibility(
    int FormatVersion,
    int RecompilerAbi,
    int GamePackAbi,
    int ShimAbi,
    int CatalogSchemaVersion,
    int GameInfoSchemaVersion,
    string RecompilerVersion,
    string ClangVersion,
    string Ld64Version)
{
    /// <summary>Bumped when this compatibility model itself changes shape.</summary>
    public const int CurrentFormatVersion = 1;

    /// <summary>Bumped when 3dsrecomp's ROM -> generated-C ABI/generation changes.</summary>
    public const int CurrentRecompilerAbi = 1;

    /// <summary>Bumped when the hand-written GamePack shim contract changes.</summary>
    public const int CurrentShimAbi = 1;

    /// <summary>Catalogue schema the shell template must accept (IpaComposer/verifier).</summary>
    public const int CurrentCatalogSchemaVersion = 2;

    public const string UnknownVersion = "unknown";

    /// <summary>Build the compatibility identity for this launcher + toolchain.</summary>
    public static BuildCompatibility Create(string? recompilerVersion = null, string? clangVersion = null, string? ld64Version = null) => new(
        CurrentFormatVersion,
        CurrentRecompilerAbi,
        LauncherInfo.GamePackAbiVersion,
        CurrentShimAbi,
        CurrentCatalogSchemaVersion,
        LauncherInfo.GameInfoSchemaVersion,
        Normalize(recompilerVersion),
        Normalize(clangVersion),
        Normalize(ld64Version));

    /// <summary>
    /// Canonical version marker recorded in the build artifact. It intentionally
    /// excludes the launcher version and the shell template version: both can be
    /// updated without changing how a GamePack is produced.
    /// </summary>
    public string BuildCompatVersion => string.Join(";", new[]
    {
        "build=" + FormatVersion,
        "recomp=" + RecompilerAbi,
        "gamepack=" + GamePackAbi,
        "shim=" + ShimAbi,
        "catalog=" + CatalogSchemaVersion,
        "gameinfo=" + GameInfoSchemaVersion,
        "recompiler=" + RecompilerVersion,
        "clang=" + ClangVersion,
        "ld64=" + Ld64Version,
    });

    /// <summary>Short stable label for the UI ("b1a2b3c4"); derived from the canonical string.</summary>
    public string ShortVersion => ShortLabel(BuildCompatVersion);

    /// <summary>Deterministic short label for any recorded compatibility string.</summary>
    public static string ShortLabel(string? buildCompatVersion)
    {
        if (string.IsNullOrWhiteSpace(buildCompatVersion))
        {
            return "?";
        }
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(buildCompatVersion));
        return "b" + Convert.ToHexStringLower(hash)[..8];
    }

    private static string Normalize(string? version) =>
        string.IsNullOrWhiteSpace(version) ? UnknownVersion : version.Trim();
}

/// <summary>Resolves the compatibility identity of the current toolchain (cached per process).</summary>
public interface IBuildCompatibilityProvider
{
    Task<BuildCompatibility> ResolveAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Probes the resolved {@code 3dsrecomp} / {@code clang} / {@code ld64.lld} binaries for
/// their version banners and composes <see cref="BuildCompatibility"/>. A missing or
/// unprobeable tool becomes "unknown" rather than a fabricated success; the local build
/// itself still fails with its actionable missing-toolchain error.
/// </summary>
public sealed class ToolchainBuildCompatibilityProvider : IBuildCompatibilityProvider
{
    private static readonly TimeSpan ProbeTimeout = TimeSpan.FromSeconds(15);

    private readonly IProcessRunner _runner;
    private readonly LocalToolchain? _tools;
    private readonly object _gate = new();
    private BuildCompatibility? _cached;
    private Task<BuildCompatibility>? _pending;

    public ToolchainBuildCompatibilityProvider(IProcessRunner runner, LocalToolchain? tools)
    {
        _runner = runner;
        _tools = tools;
    }

    public Task<BuildCompatibility> ResolveAsync(CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            if (_cached is { } cached)
            {
                return Task.FromResult(cached);
            }
            // The probe result is process-wide and toolchain paths cannot change without a
            // launcher rebuild/settings reload, so a cancelled caller must not poison the cache.
            return _pending ??= ResolveCoreAsync(CancellationToken.None);
        }
    }

    private async Task<BuildCompatibility> ResolveCoreAsync(CancellationToken cancellationToken)
    {
        var recompiler = await ProbeVersionAsync(_tools?.RecompilerPath, cancellationToken).ConfigureAwait(false);
        var clang = await ProbeVersionAsync(_tools?.ClangPath, cancellationToken).ConfigureAwait(false);
        var ld64 = await ProbeVersionAsync(_tools?.Ld64LldPath, cancellationToken).ConfigureAwait(false);
        var compatibility = BuildCompatibility.Create(recompiler, clang, ld64);
        lock (_gate)
        {
            _cached = compatibility;
        }
        return compatibility;
    }

    private async Task<string> ProbeVersionAsync(string? path, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            return BuildCompatibility.UnknownVersion;
        }
        try
        {
            var result = await _runner.RunAsync(
                new ProcessRequest(path, new[] { "--version" }, Timeout: ProbeTimeout),
                cancellationToken: cancellationToken).ConfigureAwait(false);
            return ToolLocator.FirstVersionLikeToken(result.Combined) ?? BuildCompatibility.UnknownVersion;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return BuildCompatibility.UnknownVersion;
        }
    }
}

/// <summary>Why a cached GamePack can (not) be reused.</summary>
public enum BuildReuseStatus
{
    Reusable,
    NoRecordedBuild,
    BuildMethodChanged,
    RomChanged,
    PackMissing,
}

/// <summary>The reuse decision for one library entry.</summary>
public sealed record BuildReuseDecision(bool Reuse, BuildReuseStatus Status, string Detail)
{
    public static BuildReuseDecision Rebuild(BuildReuseStatus status, string detail) => new(false, status, detail);
}

/// <summary>
/// Pure decision table for the build cache: reuse a GamePack only when its recorded
/// {@code buildCompatVersion} AND its ROM SHA-256 both match the current state and the
/// pack file is still on disk. A launcher/shell update with an unchanged recipe keeps
/// matching; a toolchain/shim/schema change or a changed ROM forces a rebuild.
/// </summary>
public static class BuildCachePolicy
{
    public static BuildReuseDecision Evaluate(
        BuildArtifact? artifact,
        string? currentBuildCompatVersion,
        string? currentRomSha256,
        string? packPath,
        Func<string, bool>? fileExists = null)
    {
        var exists = fileExists ?? File.Exists;
        if (artifact is null || string.IsNullOrWhiteSpace(artifact.BuildCompatVersion))
        {
            return BuildReuseDecision.Rebuild(BuildReuseStatus.NoRecordedBuild,
                "no build compatibility marker is recorded for this GamePack");
        }
        if (string.IsNullOrWhiteSpace(currentBuildCompatVersion))
        {
            return BuildReuseDecision.Rebuild(BuildReuseStatus.BuildMethodChanged,
                "the current local build recipe could not be resolved");
        }
        if (!string.Equals(artifact.BuildCompatVersion, currentBuildCompatVersion, StringComparison.Ordinal))
        {
            return BuildReuseDecision.Rebuild(BuildReuseStatus.BuildMethodChanged,
                "the local build recipe changed (cached " + BuildCompatibility.ShortLabel(artifact.BuildCompatVersion)
                + ", now " + BuildCompatibility.ShortLabel(currentBuildCompatVersion) + ")");
        }
        if (string.IsNullOrWhiteSpace(currentRomSha256)
            || !string.Equals(artifact.RomSha256, currentRomSha256, StringComparison.OrdinalIgnoreCase))
        {
            return BuildReuseDecision.Rebuild(BuildReuseStatus.RomChanged,
                "the ROM data changed since this GamePack was built");
        }
        if (string.IsNullOrWhiteSpace(packPath) || !exists(packPath))
        {
            return BuildReuseDecision.Rebuild(BuildReuseStatus.PackMissing,
                "the built GamePack file is missing");
        }
        return new BuildReuseDecision(true, BuildReuseStatus.Reusable,
            "build compatibility and ROM SHA-256 match; reusing the cached GamePack");
    }

    /// <summary>Short ROM digest for user-facing text (never a device identifier).</summary>
    public static string ShortHash(string? sha256) =>
        string.IsNullOrWhiteSpace(sha256) ? "?" : sha256.Length > 12 ? sha256[..12] + "…" : sha256;
}

/// <summary>
/// Cheap ROM fingerprint shortcut: when the file size and last-write time still match
/// the recorded build, the stored SHA-256 remains valid and a multi-GB ROM does not
/// need to be re-read. The deploy/build decision still re-hashes when either changes.
/// </summary>
public static class BuildFingerprint
{
    public static bool MatchesUnchangedRom(BuildArtifact? artifact, string? romPath)
    {
        if (artifact is null || string.IsNullOrWhiteSpace(romPath) || string.IsNullOrWhiteSpace(artifact.RomSha256))
        {
            return false;
        }
        try
        {
            var info = new FileInfo(romPath);
            if (!info.Exists)
            {
                return false;
            }
            if (artifact.RomBytes > 0 && info.Length != artifact.RomBytes)
            {
                return false;
            }
            return artifact.RomLastWriteUtc is not { } recorded || info.LastWriteTimeUtc == recorded.UtcDateTime;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }
}

/// <summary>Creates the state.json build record from one successful build outcome.</summary>
public static class BuildArtifacts
{
    public static async Task<BuildArtifact> CaptureAsync(
        PackBuildOutcome outcome,
        BuildCompatibility? compatibility,
        string? romPath,
        DateTimeOffset builtAt,
        CancellationToken cancellationToken = default)
    {
        long romBytes = 0;
        DateTimeOffset? romLastWriteUtc = null;
        var romSha256 = outcome.RomSha256;
        if (!string.IsNullOrWhiteSpace(romPath) && File.Exists(romPath))
        {
            try
            {
                var info = new FileInfo(romPath);
                romBytes = info.Length;
                romLastWriteUtc = info.LastWriteTimeUtc;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or NotSupportedException)
            {
                // The build itself was recorded; only the cheap fingerprint fields are missing.
            }
            if (string.IsNullOrWhiteSpace(romSha256))
            {
                romSha256 = await FileHashes.Sha256Async(romPath, cancellationToken).ConfigureAwait(false);
            }
        }
        var version = outcome.Compatibility?.BuildCompatVersion
                      ?? compatibility?.BuildCompatVersion
                      ?? string.Empty;
        return new BuildArtifact
        {
            BuildCompatVersion = version,
            BuildCompatShort = outcome.Compatibility?.ShortVersion
                               ?? compatibility?.ShortVersion
                               ?? BuildCompatibility.ShortLabel(version),
            RomSha256 = string.IsNullOrWhiteSpace(outcome.RomSha256) ? romSha256 ?? string.Empty : outcome.RomSha256!,
            RomBytes = outcome.RomBytes ?? romBytes,
            RomLastWriteUtc = romLastWriteUtc,
            PackSha256 = outcome.Pack?.Sha256 ?? string.Empty,
            PackBytes = outcome.Pack?.Bytes ?? 0,
            BuildName = outcome.BuildName,
            LauncherVersion = LauncherInfo.Version,
            BuiltAt = builtAt,
        };
    }
}
