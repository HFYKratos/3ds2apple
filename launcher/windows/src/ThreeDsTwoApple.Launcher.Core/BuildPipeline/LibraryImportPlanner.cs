using System.Text;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// One Library "Import" file-picker selection split by file type: decrypted ROMs
/// go through the ROM import (multi-select), .32a files go through the build
/// package import (with its existing replace-conflict flow). Pure and testable so
/// the view only has to call one method with the picked paths.
/// </summary>
public sealed record LibraryImportSelection(
    IReadOnlyList<string> RomPaths,
    IReadOnlyList<string> BuildPackagePaths,
    IReadOnlyList<string> Errors)
{
    public bool HasRom => RomPaths.Count > 0;

    public bool HasBuildPackage => BuildPackagePaths.Count > 0;

    public bool HasWork => HasRom || HasBuildPackage;

    public static LibraryImportSelection Empty { get; } =
        new(Array.Empty<string>(), Array.Empty<string>(), Array.Empty<string>());
}

/// <summary>Extension dispatch for the merged Library "Import" picker.</summary>
public static class LibraryImportPlanner
{
    /// <summary>Decrypted ROM containers the launcher imports (the pack CLI's list).</summary>
    public static readonly IReadOnlyList<string> RomExtensions = new[] { ".3ds", ".cci", ".ncch", ".cxi" };

    /// <summary>Portable build package extension written by <c>3ds2apple-pack builds export</c>.</summary>
    public const string BuildPackageExtension = ".32a";

    /// <summary>True when the path is a build package (case-insensitive, .32a only).</summary>
    public static bool IsBuildPackage(string path) =>
        string.Equals(Path.GetExtension(path), BuildPackageExtension, StringComparison.OrdinalIgnoreCase);

    /// <summary>True when the path has a decrypted ROM extension (case-insensitive).</summary>
    public static bool IsRom(string path) =>
        RomExtensions.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Split a picker selection into ROM paths and build package paths. Unsupported
    /// files and missing paths become actionable errors; duplicates are collapsed
    /// (case-insensitive on Windows semantics) while keeping the picker order.
    /// </summary>
    public static LibraryImportSelection Classify(IEnumerable<string> paths)
    {
        var roms = new List<string>();
        var packages = new List<string>();
        var errors = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in paths)
        {
            var path = (raw ?? string.Empty).Trim();
            if (path.Length == 0 || !seen.Add(path))
            {
                continue;
            }
            if (!File.Exists(path))
            {
                errors.Add("File not found: " + path);
                continue;
            }
            if (IsBuildPackage(path))
            {
                packages.Add(path);
                continue;
            }
            if (IsRom(path))
            {
                roms.Add(path);
                continue;
            }
            errors.Add("Unsupported file: " + Path.GetFileName(path)
                + ". Choose a decrypted .3ds/.cci/.ncch/.cxi ROM, or a .32a build package.");
        }
        return new LibraryImportSelection(roms, packages, errors);
    }

    /// <summary>Human summary used in the launcher log ("2 ROM(s), 1 build package(s), 1 skipped").</summary>
    public static string Describe(LibraryImportSelection selection) =>
        selection.RomPaths.Count + " ROM(s), " + selection.BuildPackagePaths.Count + " build package(s)"
        + (selection.Errors.Count == 0 ? string.Empty : ", " + selection.Errors.Count + " rejected");
}
