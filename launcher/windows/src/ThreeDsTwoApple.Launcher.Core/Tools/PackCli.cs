using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Tools;

/// <summary>Result of <c>3ds2apple-pack rom inspect --json</c>.</summary>
public sealed record RomInspectResult(
    IReadOnlyList<RomInfo> Roms,
    IReadOnlyList<string> Errors,
    string RawOutput)
{
    public bool Ok => Errors.Count == 0;
}

/// <summary>One package entry returned by <c>packages add --json</c>.</summary>
public sealed record ImportedPackage(
    string TitleID,
    string DisplayName,
    string ProductCode,
    string PackageDir,
    string RomPath,
    string Status);

/// <summary>Result of <c>packages add --json</c>.</summary>
public sealed record PackageAddResult(
    IReadOnlyList<ImportedPackage> Packages,
    IReadOnlyList<string> Errors,
    ProcessResult Process)
{
    public bool Ok => Errors.Count == 0 && Process.Ok;
}

/// <summary>Result of <c>packages list --json</c>.</summary>
public sealed record PackageListResult(
    IReadOnlyList<PackageInfo> Packages,
    IReadOnlyList<string> Errors,
    ProcessResult Process);

/// <summary>Probe result for the desktop pack CLI.</summary>
public sealed record PackCliProbe(bool Ready, string? Path, string? Version, string? Error);

/// <summary>
/// Thin, typed wrapper around the existing <c>3ds2apple-pack</c> CLI
/// (builder/pack). The launcher never re-implements ROM detection, package
/// manifests or catalogue allocation: it calls this CLI and only reads JSON.
/// All invocations are argument arrays, never shell strings.
/// </summary>
public sealed class PackCli
{
    private readonly IProcessRunner _runner;

    public PackCli(IProcessRunner runner, string executablePath, string outRoot)
    {
        _runner = runner;
        ExecutablePath = executablePath;
        OutRoot = outRoot;
    }

    public string ExecutablePath { get; }

    /// <summary>Output root; packages live in <c>&lt;out&gt;/packages/&lt;TITLE_ID&gt;</c>.</summary>
    public string OutRoot { get; }

    public static PackCli? Create(IProcessRunner runner, ToolLocator locator, string outRoot)
    {
        var path = locator.FindPackCli();
        return path is null ? null : new PackCli(runner, path, outRoot);
    }

    public async Task<PackCliProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var result = await _runner.RunAsync(
            new ProcessRequest(ExecutablePath, new[] { "--version" }, Timeout: TimeSpan.FromSeconds(20)),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!result.Started)
        {
            return new PackCliProbe(false, ExecutablePath, null, result.Combined.Trim());
        }
        if (!result.Ok)
        {
            return new PackCliProbe(false, ExecutablePath, null, result.Combined.Trim());
        }
        return new PackCliProbe(true, ExecutablePath, ToolLocator.FirstVersionLikeToken(result.Combined), null);
    }

    /// <summary>Detect title ID / product code / display name from ROM headers only.</summary>
    public async Task<RomInspectResult> InspectAsync(string romPath, CancellationToken cancellationToken = default)
    {
        var process = await RunPackAsync(new[] { "rom", "inspect", romPath }, cancellationToken).ConfigureAwait(false);
        using var document = Json.TryParse(process.StdOut);
        var roms = new List<RomInfo>();
        var errors = new List<string>();
        if (document is not null)
        {
            foreach (var element in Json.Array(document.RootElement, "roms"))
            {
                var titleId = Json.String(element, "titleID", "titleId", "title_id");
                if (string.IsNullOrWhiteSpace(titleId))
                {
                    continue;
                }
                roms.Add(new RomInfo(
                    Json.String(element, "path") ?? romPath,
                    Json.String(element, "container") ?? "?",
                    titleId.ToUpperInvariant(),
                    Json.String(element, "productCode"),
                    Json.String(element, "displayName") ?? Path.GetFileNameWithoutExtension(romPath),
                    Json.Long(element, "bytes") ?? 0,
                    Json.Long(element, "contentBytes"),
                    (int?)Json.Long(element, "titleVersion")));
            }
            foreach (var element in Json.Array(document.RootElement, "errors"))
            {
                errors.Add(Json.String(element, "error") ?? Json.String(element, "message") ?? element.GetRawText());
            }
        }
        else if (!process.Ok)
        {
            errors.Add(FirstMeaningfulLine(process));
        }
        return new RomInspectResult(roms, errors, process.StdOut);
    }

    /// <summary>Import one or more ROMs: creates package dirs and queue entries (headers only).</summary>
    public async Task<PackageAddResult> AddAsync(IReadOnlyList<string> romPaths, string? displayName, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "packages", "add", "--roms" };
        arguments.AddRange(romPaths);
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            arguments.Add("--display-name");
            arguments.Add(displayName);
        }
        var process = await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
        return ParseAdd(process);
    }

    /// <summary>List queued/built packages.</summary>
    public async Task<PackageListResult> ListAsync(CancellationToken cancellationToken = default)
    {
        var process = await RunPackAsync(new[] { "packages", "list" }, cancellationToken).ConfigureAwait(false);
        using var document = Json.TryParse(process.StdOut);
        var packages = new List<PackageInfo>();
        var errors = new List<string>();
        if (document is not null)
        {
            foreach (var element in Json.Array(document.RootElement, "packages"))
            {
                var titleId = Json.String(element, "titleID", "titleId", "title_id");
                if (string.IsNullOrWhiteSpace(titleId))
                {
                    continue;
                }
                PackRecord? pack = null;
                if (Json.Obj(element, "pack") is { } packElement)
                {
                    pack = new PackRecord(
                        Json.String(packElement, "sha256") ?? string.Empty,
                        Json.Long(packElement, "bytes") ?? 0,
                        Json.String(packElement, "format") ?? string.Empty);
                }
                packages.Add(new PackageInfo(
                    titleId.ToUpperInvariant(),
                    Json.String(element, "displayName") ?? titleId,
                    Json.String(element, "productCode") ?? string.Empty,
                    (int)(Json.Long(element, "aotVersion") ?? 1),
                    Json.String(element, "state") ?? "?",
                    pack,
                    Json.Array(element, "issues").Select(i => i.GetString() ?? i.GetRawText()).ToList()));
            }
            foreach (var element in Json.Array(document.RootElement, "errors"))
            {
                errors.Add(Json.String(element, "error") ?? element.GetRawText());
            }
        }
        else if (!process.Ok)
        {
            errors.Add(FirstMeaningfulLine(process));
        }
        return new PackageListResult(packages, errors, process);
    }

    /// <summary>Adopt a real GamePack.dylib into a package (single manifest writer is the CLI).</summary>
    public async Task<ProcessResult> RecordAsync(
        string titleId,
        string packPath,
        string? displayName = null,
        string? productCode = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "packages", "record", "--title-id", titleId, "--pack", packPath };
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            arguments.Add("--display-name");
            arguments.Add(displayName);
        }
        if (!string.IsNullOrWhiteSpace(productCode))
        {
            arguments.Add("--product-code");
            arguments.Add(productCode);
        }
        return await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Write deterministic placeholder packs (preview only; never installable).</summary>
    public async Task<ProcessResult> BuildFakeAsync(bool force, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "build", "--queued", "--fake" };
        if (force)
        {
            arguments.Add("--force");
        }
        return await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Verify every package manifest and pack hash.</summary>
    public Task<ProcessResult> VerifyAsync(CancellationToken cancellationToken = default) =>
        RunPackAsync(new[] { "packages", "verify" }, cancellationToken);

    /// <summary>
    /// Generate the GameCatalog.json injected into the app bundle. The Rust CLI
    /// remains the single catalogue schema writer; the launcher only copies the
    /// file it produced (and fills the optional registrationSymbol contract field).
    /// </summary>
    public async Task<ProcessResult> CatalogAsync(IReadOnlyList<string> titleIds, string catalogOutPath, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "catalog" };
        foreach (var titleId in titleIds)
        {
            arguments.Add("--title-id");
            arguments.Add(titleId);
        }
        arguments.Add("--catalog-out");
        arguments.Add(catalogOutPath);
        return await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
    }

    private Task<ProcessResult> RunPackAsync(IReadOnlyList<string> command, CancellationToken cancellationToken)
    {
        var arguments = new List<string> { "--out", OutRoot, "--json" };
        arguments.AddRange(command);
        return _runner.RunAsync(
            new ProcessRequest(ExecutablePath, arguments, Timeout: TimeSpan.FromMinutes(5)),
            cancellationToken: cancellationToken);
    }

    private static PackageAddResult ParseAdd(ProcessResult process)
    {
        var packages = new List<ImportedPackage>();
        var errors = new List<string>();
        using var document = Json.TryParse(process.StdOut);
        if (document is not null)
        {
            foreach (var element in Json.Array(document.RootElement, "packages"))
            {
                var titleId = Json.String(element, "titleID", "titleId", "title_id");
                if (string.IsNullOrWhiteSpace(titleId))
                {
                    continue;
                }
                packages.Add(new ImportedPackage(
                    titleId.ToUpperInvariant(),
                    Json.String(element, "displayName") ?? titleId,
                    Json.String(element, "productCode") ?? string.Empty,
                    Json.String(element, "packageDir") ?? string.Empty,
                    Json.String(element, "romPath") ?? string.Empty,
                    Json.String(element, "status") ?? "imported"));
            }
            foreach (var element in Json.Array(document.RootElement, "errors"))
            {
                errors.Add(Json.String(element, "error") ?? element.GetRawText());
            }
        }
        else if (!process.Ok)
        {
            errors.Add(FirstMeaningfulLine(process));
        }
        return new PackageAddResult(packages, errors, process);
    }

    /// <summary>First non-empty diagnostic line: used when a CLI fails without emitting JSON.</summary>
    public static string FirstMeaningfulLine(ProcessResult process)
    {
        foreach (var line in process.StdOutLines.Concat(process.StdErrLines).Reverse())
        {
            var trimmed = line.Trim();
            if (trimmed.Length > 0)
            {
                return trimmed;
            }
        }
        return $"tool exited with code {process.ExitCode}" + (process.TimedOut ? " (timed out)" : string.Empty);
    }
}
