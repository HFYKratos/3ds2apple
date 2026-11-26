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
    string Status,
    IReadOnlyDictionary<string, string>? DisplayNames = null,
    string? Publisher = null,
    string? CoverPath = null,
    string? Region = null);

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

/// <summary>One .32a reported by <c>builds export --json</c>.</summary>
public sealed record ExportedBuildPackageInfo(
    string TitleID,
    string DisplayName,
    string Path,
    long Bytes,
    string Sha256,
    bool RomIncluded,
    long PackBytes,
    string PackSha256,
    IReadOnlyList<string> Warnings);

/// <summary>Result of <c>builds export --json</c>.</summary>
public sealed record BuildPackageExportResult(
    IReadOnlyList<ExportedBuildPackageInfo> Packages,
    IReadOnlyList<string> Errors,
    string? OutputDirectory,
    ProcessResult Process)
{
    public bool Ok => Errors.Count == 0 && Packages.Count > 0 && Process.Ok;
}

/// <summary>One imported .32a reported by <c>builds import --json</c>.</summary>
public sealed record ImportedBuildPackageInfo(
    string TitleID,
    string DisplayName,
    string Path,
    string PackageDir,
    long PackBytes,
    string PackSha256,
    bool RomIncluded,
    bool Replaced,
    IReadOnlyList<string> Warnings);

/// <summary>Result of <c>builds import --json</c>.</summary>
public sealed record BuildPackageImportResult(
    ImportedBuildPackageInfo? Package,
    IReadOnlyList<string> Warnings,
    string? Error,
    ProcessResult Process)
{
    public bool Ok => Package is not null && Error is null && Process.Ok;
}

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
                    (int?)Json.Long(element, "titleVersion"),
                    Json.String(element, "region")));
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

    /// <summary>
    /// Import one or more ROMs: creates package dirs and queue entries (headers only).
    /// <paramref name="force"/> is set for a re-import of a game that is already in the
    /// library: the CLI then refreshes the SMDH metadata and re-extracts an automatically
    /// generated (coverSource=smdh) cover, while an existing built GamePack is kept.
    /// </summary>
    public async Task<PackageAddResult> AddAsync(IReadOnlyList<string> romPaths, string? displayName, bool force = false, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "packages", "add", "--roms" };
        arguments.AddRange(romPaths);
        if (!string.IsNullOrWhiteSpace(displayName))
        {
            arguments.Add("--display-name");
            arguments.Add(displayName);
        }
        if (force)
        {
            arguments.Add("--force");
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
                    Json.Array(element, "issues").Select(i => i.GetString() ?? i.GetRawText()).ToList(),
                    ParseDisplayNames(element),
                    Json.String(element, "publisher"),
                    Json.String(element, "coverPath"),
                    Json.String(element, "region")));
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
    public async Task<ProcessResult> CatalogAsync(IReadOnlyList<string> titleIds, string catalogOutPath, bool autoLaunch = false, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "catalog" };
        foreach (var titleId in titleIds)
        {
            arguments.Add("--title-id");
            arguments.Add(titleId);
        }
        arguments.Add("--catalog-out");
        arguments.Add(catalogOutPath);
        if (autoLaunch)
        {
            arguments.Add("--auto-launch");
        }
        return await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Host platform tag recorded in build package manifests.</summary>
    public static string PlatformTag() =>
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";

    /// <summary>
    /// Export portable .32a build packages for the given titles (empty list = every
    /// built package). The Rust CLI owns the manifest format; this wrapper only
    /// passes paths/versions and parses the JSON it prints.
    /// </summary>
    public async Task<BuildPackageExportResult> ExportBuildsAsync(
        IReadOnlyList<string> titleIds,
        string outputDirectory,
        string appVersion,
        string launcherVersion,
        string? clangVersion,
        string? llvmVersion,
        string optLevel,
        bool lto,
        bool fastMath,
        IReadOnlyList<string> romDirectories,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "builds", "export" };
        if (titleIds.Count == 0)
        {
            arguments.Add("--all");
        }
        else
        {
            foreach (var titleId in titleIds)
            {
                arguments.Add("--title-id");
                arguments.Add(titleId);
            }
        }
        arguments.Add("--output-dir");
        arguments.Add(outputDirectory);
        arguments.Add("--platform");
        arguments.Add(PlatformTag());
        arguments.Add("--app-version");
        arguments.Add(appVersion);
        arguments.Add("--launcher-version");
        arguments.Add(launcherVersion);
        if (!string.IsNullOrWhiteSpace(clangVersion))
        {
            arguments.Add("--toolchain-clang");
            arguments.Add(clangVersion!);
        }
        if (!string.IsNullOrWhiteSpace(llvmVersion))
        {
            arguments.Add("--toolchain-llvm");
            arguments.Add(llvmVersion!);
        }
        arguments.Add("--opt-level");
        arguments.Add(optLevel);
        if (lto)
        {
            arguments.Add("--lto");
        }
        if (fastMath)
        {
            arguments.Add("--fast-math");
        }
        foreach (var romDirectory in romDirectories)
        {
            if (!string.IsNullOrWhiteSpace(romDirectory))
            {
                arguments.Add("--rom-dir");
                arguments.Add(romDirectory);
            }
        }

        var process = await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
        var packages = new List<ExportedBuildPackageInfo>();
        var errors = new List<string>();
        string? outputDir = outputDirectory;
        using var document = Json.TryParse(process.StdOut);
        if (document is not null)
        {
            outputDir = Json.String(document.RootElement, "outputDir") ?? outputDirectory;
            foreach (var element in Json.Array(document.RootElement, "builds"))
            {
                var titleId = Json.String(element, "titleID", "titleId", "title_id");
                var path = Json.String(element, "path");
                if (string.IsNullOrWhiteSpace(titleId) || string.IsNullOrWhiteSpace(path))
                {
                    continue;
                }
                packages.Add(new ExportedBuildPackageInfo(
                    titleId.ToUpperInvariant(),
                    Json.String(element, "displayName") ?? titleId,
                    path!,
                    Json.Long(element, "bytes") ?? 0,
                    Json.String(element, "sha256") ?? string.Empty,
                    Json.Bool(element, "romIncluded") ?? false,
                    Json.Long(element, "packBytes") ?? 0,
                    Json.String(element, "packSha256") ?? string.Empty,
                    Json.Array(element, "warnings").Select(item => item.GetString() ?? item.GetRawText()).ToList()));
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
        return new BuildPackageExportResult(packages, errors, outputDir, process);
    }

    /// <summary>Validate and install one .32a build package into the packages directory.</summary>
    public async Task<BuildPackageImportResult> ImportBuildAsync(
        string packagePath,
        bool replace,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "builds", "import", packagePath };
        if (replace)
        {
            arguments.Add("--replace");
        }
        var process = await RunPackAsync(arguments, cancellationToken).ConfigureAwait(false);
        using var document = Json.TryParse(process.StdOut);
        if (document is null || !process.Ok)
        {
            var error = process.Ok
                ? "the pack CLI reported success but printed no JSON"
                : FirstMeaningfulLine(process);
            return new BuildPackageImportResult(null, Array.Empty<string>(), error, process);
        }
        var importedElement = Json.Obj(document.RootElement, "imported");
        if (importedElement is null)
        {
            return new BuildPackageImportResult(null, Array.Empty<string>(), "the pack CLI JSON has no imported build package", process);
        }
        var titleId = Json.String(importedElement.Value, "titleID", "titleId", "title_id");
        if (string.IsNullOrWhiteSpace(titleId))
        {
            return new BuildPackageImportResult(null, Array.Empty<string>(), "the imported build package JSON has no titleID", process);
        }
        var warnings = Json.Array(importedElement.Value, "warnings")
            .Select(item => item.GetString() ?? item.GetRawText())
            .ToList();
        var package = new ImportedBuildPackageInfo(
            titleId.ToUpperInvariant(),
            Json.String(importedElement.Value, "displayName") ?? titleId,
            Json.String(importedElement.Value, "path") ?? packagePath,
            Json.String(importedElement.Value, "packageDir") ?? string.Empty,
            Json.Long(importedElement.Value, "packBytes") ?? 0,
            Json.String(importedElement.Value, "packSha256") ?? string.Empty,
            Json.Bool(importedElement.Value, "romIncluded") ?? false,
            Json.Bool(importedElement.Value, "replaced") ?? false,
            warnings);
        return new BuildPackageImportResult(package, warnings, null, process);
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
                    Json.String(element, "status") ?? "imported",
                    ParseDisplayNames(element),
                    Json.String(element, "publisher"),
                    Json.String(element, "coverPath"),
                    Json.String(element, "region")));
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

    /// <summary>Parse the optional "displayNames" object (BCP-47 key -> localized short title).</summary>
    private static IReadOnlyDictionary<string, string>? ParseDisplayNames(JsonElement element)
    {
        if (Json.Obj(element, "displayNames") is not { } map)
        {
            return null;
        }
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var property in map.EnumerateObject())
        {
            if (property.Value.ValueKind == JsonValueKind.String)
            {
                var value = property.Value.GetString();
                if (!string.IsNullOrWhiteSpace(value))
                {
                    names[property.Name] = value;
                }
            }
        }
        return names.Count == 0 ? null : names;
    }

    /// <summary>
    /// Capability descriptor for one pack CLI binary. A stale 0.2.0 CLI (the
    /// 0.2.2-beta2 packaging bug) lacks the `builds` subcommand and
    /// `catalog --auto-launch`, so both Library exports are rejected by clap.
    /// </summary>
    public sealed record PackCliBinaryCapabilities(
        string Path,
        bool HasBuildsCommand,
        bool HasCatalogAutoLaunch,
        string? Error)
    {
        public bool Ok => Error is null && HasBuildsCommand && HasCatalogAutoLaunch;

        public string Describe() =>
            Error ?? (HasBuildsCommand ? "builds ok" : "missing builds")
            + "; " + (HasCatalogAutoLaunch ? "catalog --auto-launch ok" : "missing catalog --auto-launch");
    }

    private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, PackCliBinaryCapabilities> BinaryCapabilities =
        new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Static capability scan of the CLI executable. It works for the Windows PE
    /// payload on non-Windows hosts (the Linux clean-folder self-test cannot run
    /// the PE) as well as for ELF/Mach-O dev builds; the Rust literals survive
    /// stripping, so the clap subcommand/flag names are present in the binary.
    /// </summary>
    public static PackCliBinaryCapabilities InspectBinaryCapabilities(string executablePath)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            return new PackCliBinaryCapabilities(string.Empty, false, false, "the pack CLI path is empty");
        }
        return BinaryCapabilities.GetOrAdd(executablePath, path =>
        {
            try
            {
                if (!File.Exists(path))
                {
                    return new PackCliBinaryCapabilities(path, false, false, "the pack CLI does not exist: " + path);
                }
                var bytes = File.ReadAllBytes(path);
                var text = System.Text.Encoding.Latin1.GetString(bytes);
                var hasBuilds = text.Contains("builds", StringComparison.Ordinal);
                // clap stores a long flag without the leading dashes, so the binary
                // literal is "auto-launch" (help output renders "--auto-launch").
                var hasAutoLaunch = text.Contains("auto-launch", StringComparison.Ordinal);
                return new PackCliBinaryCapabilities(
                    path,
                    hasBuilds,
                    hasAutoLaunch,
                    hasBuilds && hasAutoLaunch
                        ? null
                        : "the bundled 3ds2apple-pack CLI is out of date (no " + (hasBuilds ? "catalog --auto-launch" : "builds")
                          + "); rebuild the launcher package from the current builder sources (cargo build --release -p builder-pack --target x86_64-pc-windows-gnu)");
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                return new PackCliBinaryCapabilities(path, false, false, "could not read the pack CLI: " + exception.Message);
            }
        });
    }

    /// <summary>null when the binary has the required capabilities; otherwise an actionable error.</summary>
    public static string? CapabilityError(string executablePath)
    {
        var report = InspectBinaryCapabilities(executablePath);
        return report.Ok ? null : report.Error;
    }

    /// <summary>
    /// Error text for a failed CLI invocation: when clap rejected an unknown
    /// subcommand/flag (an old bundled CLI) return an actionable rebuild hint
    /// instead of the bare "For more information, try '--help'." line.
    /// </summary>
    public static string ActionableFailure(ProcessResult process)
    {
        var combined = process.Combined;
        if (combined.Contains("For more information, try", StringComparison.OrdinalIgnoreCase)
            || combined.Contains("unexpected argument", StringComparison.OrdinalIgnoreCase)
            || combined.Contains("unrecognized subcommand", StringComparison.OrdinalIgnoreCase))
        {
            return "The bundled 3ds2apple-pack CLI is out of date (it does not support the builds / catalog --auto-launch commands). "
                + "Rebuild the launcher package from the current builder sources, or set THREEDS2APPLE_PACK to a current CLI. Detail: "
                + FirstMeaningfulLine(process);
        }
        return FirstMeaningfulLine(process);
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
