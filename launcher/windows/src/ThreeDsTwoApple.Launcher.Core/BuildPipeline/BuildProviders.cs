using System.Text;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>How a GamePack is produced.</summary>
public enum PackBuildMode
{
    /// <summary>Local placeholder pack (preview only, never installable).</summary>
    Preview = 0,

    /// <summary>macOS Build Agent per-game IPA, then extract and record the real pack.</summary>
    MacAgentIpa = 1,

    /// <summary>Future Agent "packbuild" stage (documented, not implemented by the current Agent).</summary>
    MacAgentPack = 2,

    /// <summary>
    /// Experimental local build on this PC: 3dsrecomp turns the user's ROM into
    /// generated C, then the official open-source LLVM/Clang + ld64.lld toolchain
    /// links the arm64 GamePack with tools/winbuild darwin stubs and
    /// -undefined dynamic_lookup. No Apple SDK and no Mac are needed. Feature-
    /// flagged (state.LocalBuildEnabled) until the runtime end-to-end check ships;
    /// the macOS Build Agent stays the supported fallback.
    /// </summary>
    LocalWinbuild = 3,
}

/// <summary>One pack build request.</summary>
public sealed record PackBuildRequest(
    string TitleID,
    string DisplayName,
    string? ProductCode,
    string RomPath,
    string? BuildHost,
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

/// <summary>
/// Real build through the user's macOS host using today's builder-windows flow,
/// then extract <c>Frameworks/GamePack-&lt;TITLEID&gt;.dylib</c> from the produced IPA
/// and record it locally. The IPA itself is never installed.
/// </summary>
public sealed class MacAgentIpaBuildProvider : IPackBuildProvider
{
    private readonly BuilderCli _builder;
    private readonly PackCli _packCli;

    public MacAgentIpaBuildProvider(BuilderCli builder, PackCli packCli)
    {
        _builder = builder;
        _packCli = packCli;
    }

    public string Name => "macOS Build Agent (existing per-game IPA -> extract GamePack)";

    public bool Installable => true;

    public async Task<PackBuildOutcome> BuildAsync(
        PackBuildRequest request,
        IProgress<BuildProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(request.BuildHost))
        {
            return PackBuildOutcome.Failure("build_host_missing",
                "No macOS build host is configured. Add one in Settings (the same builder-windows/zkb host profile), then retry. See docs/windows-build.md.");
        }
        var buildName = BuildSlug.From(request.DisplayName, request.TitleID);
        var downloadDirectory = Path.Combine(request.WorkDirectory, "agent-builds", buildName);
        Directory.CreateDirectory(downloadDirectory);
        log?.Invoke($"Build Agent '{request.BuildHost}': {request.RomPath} -> {buildName} (this is the long stage)");
        progress?.Report(new BuildProgress("agent", null, "Uploading ROM and building on the macOS host…"));

        var result = await _builder.BuildIpaAsync(
            new BuildAgentBuildRequest(request.BuildHost, request.RomPath, buildName, request.DisplayName, downloadDirectory),
            onLogLine: line => log?.Invoke("[agent] " + line),
            onProgress: agentEvent => progress?.Report(new BuildProgress(agentEvent.Stage, agentEvent.Percent, agentEvent.Message)),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!result.Success || result.IpaPath is null)
        {
            return PackBuildOutcome.Failure(result.ErrorCode ?? "agent_build_failed", result.ErrorMessage ?? "The Build Agent build failed.");
        }
        log?.Invoke($"Agent IPA: {result.IpaPath}");
        progress?.Report(new BuildProgress("extract", null, "Extracting GamePack.dylib from the IPA…"));

        ExtractedGamePack extracted;
        try
        {
            extracted = IpaPackExtractor.ExtractGamePack(result.IpaPath, Path.Combine(request.WorkDirectory, "extracted", request.TitleID), request.TitleID);
        }
        catch (LauncherToolException error)
        {
            return PackBuildOutcome.Failure(error.Code, error.Message);
        }
        log?.Invoke($"Extracted {extracted.PackPath} ({extracted.PackSha256[..16]}…)");

        var record = await _packCli.RecordAsync(request.TitleID, extracted.PackPath, extracted.DisplayName, extracted.ProductCode, cancellationToken).ConfigureAwait(false);
        if (!record.Ok)
        {
            return PackBuildOutcome.Failure("record_failed", PackCli.FirstMeaningfulLine(record));
        }
        var list = await _packCli.ListAsync(cancellationToken).ConfigureAwait(false);
        var package = list.Packages.FirstOrDefault(p => p.TitleID == request.TitleID);
        if (package?.Pack is null)
        {
            return PackBuildOutcome.Failure("record_failed", "The pack CLI recorded no pack for this title.");
        }
        progress?.Report(new BuildProgress("done", 100, "Real GamePack ready"));
        return new PackBuildOutcome(true, true, extracted.PackPath, package.Pack, null, null, buildName);
    }
}

/// <summary>
/// Placeholder for the recommended future Agent stage that builds a GamePack
/// directly (no per-game IPA). It refuses instead of pretending to work; see
/// docs/windows-build.md for the contract to implement on the host side.
/// </summary>
public sealed class MacAgentPackBuildProvider : IPackBuildProvider
{
    public string Name => "macOS Build Agent (packbuild stage — not implemented yet)";

    public bool Installable => true;

    public Task<PackBuildOutcome> BuildAsync(
        PackBuildRequest request,
        IProgress<BuildProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(PackBuildOutcome.Failure("agent_packbuild_unsupported",
            "The configured Build Agent does not implement the 'packbuild' stage yet. Use the 'macOS Build Agent (existing per-game IPA)' mode, or implement the stage described in docs/windows-build.md."));
}

/// <summary>Builds a deterministic ASCII build slug the macOS scripts accept.</summary>
public static class BuildSlug
{
    public static string From(string displayName, string titleId)
    {
        var normalized = (displayName ?? string.Empty).Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder();
        var lastWasDash = false;
        foreach (var c in normalized)
        {
            if (c is >= 'A' and <= 'Z')
            {
                builder.Append(char.ToLowerInvariant(c));
                lastWasDash = false;
            }
            else if (c is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                builder.Append(c);
                lastWasDash = false;
            }
            else if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) == System.Globalization.UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            else if (!lastWasDash && builder.Length > 0)
            {
                builder.Append('-');
                lastWasDash = true;
            }
        }
        var slug = builder.ToString().Trim('-');
        if (slug.Length > 40)
        {
            slug = slug[..40].TrimEnd('-');
        }
        var suffix = titleId.Length >= 8 ? titleId[^8..].ToLowerInvariant() : titleId.ToLowerInvariant();
        return slug.Length == 0 ? "game-" + suffix : slug + "-" + suffix;
    }
}
