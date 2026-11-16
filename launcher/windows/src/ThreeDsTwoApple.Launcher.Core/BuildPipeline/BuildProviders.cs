using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>How a GamePack is produced.</summary>
public enum PackBuildMode
{
    /// <summary>Local placeholder pack (preview only, never installable).</summary>
    Preview = 0,

    /// <summary>
    /// Local build on this PC: 3dsrecomp turns the user's ROM into
    /// generated C, then the official open-source LLVM/Clang + ld64.lld toolchain
    /// links the arm64 GamePack with tools/winbuild darwin stubs and
    /// -undefined dynamic_lookup. No Apple SDK and no Mac are needed. This is the
    /// only build path the v2 UI offers; the old remote macOS Build Agent path was
    /// removed together with its Rust front ends in 2026-11.
    /// </summary>
    LocalWinbuild = 1,
}

/// <summary>One pack build request.</summary>
public sealed record PackBuildRequest(
    string TitleID,
    string DisplayName,
    string? ProductCode,
    string RomPath,
    string WorkDirectory);

/// <summary>Progress from a pack build (stage + optional percent + human message).</summary>
public sealed record BuildProgress(string Stage, double? Percent, string Message);

/// <summary>Outcome of building one pack.</summary>
public sealed record PackBuildOutcome(
    bool Success,
    bool Installable,
    string? PackPath,
    PackRecord? Pack,
    string? ErrorCode,
    string? ErrorMessage,
    string? BuildName)
{
    public static PackBuildOutcome Failure(string code, string message) => new(false, false, null, null, code, message, null);
}

/// <summary>Produces a GamePack for one title. The launcher picks the provider by <see cref="PackBuildMode"/>.</summary>
public interface IPackBuildProvider
{
    string Name { get; }

    /// <summary>true only when the produced pack is real AOT code that a phone can dlopen.</summary>
    bool Installable { get; }

    Task<PackBuildOutcome> BuildAsync(
        PackBuildRequest request,
        IProgress<BuildProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default);
}

/// <summary>Builds a deterministic placeholder pack locally (preview; never installable).</summary>
public sealed class PreviewBuildProvider : IPackBuildProvider
{
    private readonly PackCli _packCli;

    public PreviewBuildProvider(PackCli packCli) => _packCli = packCli;

    public string Name => "Local preview (--fake placeholder)";

    public bool Installable => false;

    public async Task<PackBuildOutcome> BuildAsync(
        PackBuildRequest request,
        IProgress<BuildProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        log?.Invoke("Preview build: writing deterministic placeholder packs (NOT installable).");
        progress?.Report(new BuildProgress("preview", 0, "Writing placeholder pack"));
        var process = await _packCli.BuildFakeAsync(force: true, cancellationToken).ConfigureAwait(false);
        if (!process.Ok)
        {
            return PackBuildOutcome.Failure("preview_build_failed", PackCli.FirstMeaningfulLine(process));
        }
        var list = await _packCli.ListAsync(cancellationToken).ConfigureAwait(false);
        var package = list.Packages.FirstOrDefault(p => p.TitleID == request.TitleID);
        if (package?.Pack is null)
        {
            return PackBuildOutcome.Failure("preview_build_failed", "The pack CLI reported success but no pack record was written.");
        }
        progress?.Report(new BuildProgress("preview", 100, "Placeholder pack ready (preview only)"));
        return new PackBuildOutcome(true, false, null, package.Pack, null, null, BuildSlug.From(request.DisplayName, request.TitleID));
    }
}
