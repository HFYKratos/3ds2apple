using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Result of exporting .32a build packages from the Library.</summary>
public sealed record BuildPackageExportOutcome(
    IReadOnlyList<ExportedBuildPackageInfo> Packages,
    IReadOnlyList<string> Errors,
    string OutputDirectory,
    string? Error)
{
    public bool Ok => Error is null && Errors.Count == 0 && Packages.Count > 0;
}

/// <summary>Result of importing one .32a build package.</summary>
public sealed record BuildPackageImportOutcome(
    ImportedBuildPackageInfo? Package,
    IReadOnlyList<string> Warnings,
    string? Error)
{
    public bool Ok => Package is not null && Error is null;
}

/// <summary>
/// Library "Export .32a" / "Import .32a": composes the pack CLI arguments, parses
/// the JSON and keeps the launcher state in sync. The Rust CLI is the single
/// manifest/format writer; this class never parses a .32a itself.
///
/// Export writes to &lt;portable data root&gt;/workspace/builds, a gitignored user-data
/// directory: a .32a can contain the user's ROM, so the UI must tell the user to
/// keep it local and never upload or commit it.
/// </summary>
public sealed class BuildPackageService
{
    /// <summary>Directory (below the portable workspace root) that holds the .32a files.</summary>
    public const string BuildsDirectoryName = "builds";

    private readonly LauncherWorkspace _workspace;
    private readonly PackCli? _packCli;

    public BuildPackageService(LauncherWorkspace workspace, PackCli? packCli)
    {
        _workspace = workspace;
        _packCli = packCli;
    }

    /// <summary>Portable data root workspace/builds (user data, gitignored).</summary>
    public string BuildsDirectory => Path.Combine(_workspace.Root, BuildsDirectoryName);

    /// <summary>
    /// Export one or more built games into .32a files. The ROM bundled in the file
    /// is resolved by the CLI (package copy, then the queued ROM path, then
    /// workspace/launcher-roms); a title without a ROM still exports, with a
    /// warning that deploying it needs the original ROM.
    /// </summary>
    public async Task<BuildPackageExportOutcome> ExportAsync(
        IReadOnlyList<string> titleIds,
        BuildCompatibility? compatibility,
        IReadOnlyList<string>? romDirectories = null,
        string? outputDirectory = null,
        CancellationToken cancellationToken = default)
    {
        var targetDirectory = string.IsNullOrWhiteSpace(outputDirectory) ? BuildsDirectory : Path.GetFullPath(outputDirectory);
        if (_packCli is null)
        {
            return new BuildPackageExportOutcome(
                Array.Empty<ExportedBuildPackageInfo>(),
                Array.Empty<string>(),
                targetDirectory,
                "3ds2apple-pack was not found; reinstall the launcher package so Bin/3ds2apple-pack.exe exists.");
        }
        try
        {
            Directory.CreateDirectory(targetDirectory);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new BuildPackageExportOutcome(
                Array.Empty<ExportedBuildPackageInfo>(),
                Array.Empty<string>(),
                targetDirectory,
                "The export folder could not be created: " + targetDirectory + ": " + exception.Message);
        }
        // Only a real file can be statically inspected; a fake-runner test path is left
        // to the runner (a genuinely missing CLI fails the probe/process with its own message).
        var capabilityError = File.Exists(_packCli.ExecutablePath)
            ? PackCli.CapabilityError(_packCli.ExecutablePath)
            : null;
        if (capabilityError is not null)
        {
            return new BuildPackageExportOutcome(
                Array.Empty<ExportedBuildPackageInfo>(),
                Array.Empty<string>(),
                targetDirectory,
                capabilityError);
        }
        var clang = VersionOrEmpty(compatibility?.ClangVersion);
        var llvm = VersionOrEmpty(compatibility?.Ld64Version);
        var result = await _packCli.ExportBuildsAsync(
            titleIds,
            targetDirectory,
            LauncherInfo.Version,
            LauncherInfo.Version,
            clang,
            llvm,
            "O2",
            lto: false,
            fastMath: false,
            romDirectories ?? Array.Empty<string>(),
            cancellationToken).ConfigureAwait(false);
        var error = result.Ok
            ? null
            : result.Errors.Count > 0
                ? null
                : PackCli.ActionableFailure(result.Process);
        return new BuildPackageExportOutcome(result.Packages, result.Errors, result.OutputDirectory ?? targetDirectory, error);
    }

    /// <summary>
    /// Validate and install a .32a into the portable workspace, then refresh the
    /// launcher's library entry so the imported game is immediately deployable.
    /// An existing package is left untouched unless <paramref name="replace"/> is true.
    /// </summary>
    public async Task<BuildPackageImportOutcome> ImportAsync(
        string packagePath,
        bool replace,
        CancellationToken cancellationToken = default)
    {
        if (_packCli is null)
        {
            return new BuildPackageImportOutcome(null, Array.Empty<string>(),
                "3ds2apple-pack was not found; reinstall the launcher package so Bin/3ds2apple-pack.exe exists.");
        }
        if (string.IsNullOrWhiteSpace(packagePath) || !File.Exists(packagePath))
        {
            return new BuildPackageImportOutcome(null, Array.Empty<string>(),
                "The build package does not exist: " + packagePath);
        }
        var result = await _packCli.ImportBuildAsync(packagePath, replace, cancellationToken).ConfigureAwait(false);
        if (!result.Ok)
        {
            return new BuildPackageImportOutcome(result.Package, result.Warnings,
                result.Error ?? PackCli.FirstMeaningfulLine(result.Process));
        }
        var entry = await UpsertLibraryEntryAsync(result.Package!.TitleID, cancellationToken).ConfigureAwait(false);
        return new BuildPackageImportOutcome(
            result.Package,
            result.Warnings,
            entry is null
                ? "The package was imported, but the launcher could not refresh its library entry (3ds2apple-pack packages list failed)."
                : null);
    }

    /// <summary>Read the imported package back from the CLI and upsert the library entry.</summary>
    private async Task<LibraryEntry?> UpsertLibraryEntryAsync(string titleId, CancellationToken cancellationToken)
    {
        if (_packCli is null)
        {
            return null;
        }
        var list = await _packCli.ListAsync(cancellationToken).ConfigureAwait(false);
        var info = list.Packages.FirstOrDefault(package =>
            string.Equals(package.TitleID, titleId, StringComparison.OrdinalIgnoreCase));
        if (info is null)
        {
            return null;
        }
        var entry = _workspace.Find(info.TitleID) ?? new LibraryEntry
        {
            TitleID = info.TitleID,
            ImportedAt = DateTimeOffset.UtcNow,
        };
        entry.DisplayName = info.DisplayName;
        if (info.DisplayNames is { Count: > 0 })
        {
            entry.DisplayNames = new Dictionary<string, string>(info.DisplayNames, StringComparer.OrdinalIgnoreCase);
        }
        if (!string.IsNullOrWhiteSpace(info.Publisher))
        {
            entry.Publisher = GameNames.ResolvePublisher(info.Publisher);
        }
        if (!string.IsNullOrWhiteSpace(info.Region))
        {
            entry.Region = info.Region.Trim();
        }
        entry.ProductCode = info.ProductCode;
        entry.State = info.State;
        entry.Pack = info.Pack;
        entry.PackageDir ??= Path.Combine(_workspace.OutRoot, "packages", info.TitleID);
        entry.CoverPath = GameNames.ResolveCoverPath(entry.PackageDir, info.CoverPath ?? entry.CoverPath);
        if (info.Pack is not null)
        {
            entry.PackPath = Path.Combine(_workspace.OutRoot, "packages", info.TitleID, Deploy.GameInfoWriter.GamePackFileName);
        }
        _workspace.Upsert(entry);
        _workspace.SaveState();
        return entry;
    }

    private static string? VersionOrEmpty(string? version) =>
        string.IsNullOrWhiteSpace(version) || string.Equals(version, BuildCompatibility.UnknownVersion, StringComparison.OrdinalIgnoreCase)
            ? null
            : version.Trim();
}
