using System.IO.Compression;
using ThreeDsTwoApple.Launcher.Core.Models;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Resolved ROM bytes for a library entry.</summary>
public sealed record ResolvedGameRom(string Path, string Extension, long Bytes);

/// <summary>
/// Resolves the ROM used by the single-game IPA export, deploy builds and the
/// data push. A game imported from a .32a stores the package path in
/// RomPath (0.2.2-beta4); the real ROM is the package's GameRom copy:
/// first the imported package directory (the pack CLI extracts it there), then
/// the GameRom.&lt;ext&gt; entry inside the .32a ZIP, extracted into a
/// launcher-owned cache. A plain ROM path keeps working exactly as before.
/// </summary>
public static class GameRomResolver
{
    public const string BuildPackageExtension = ".32a";

    public const string GameRomPrefix = "GameRom";

    /// <summary>ROM extensions the runtime boots (same list as the builder catalogue).</summary>
    public static readonly IReadOnlyList<string> RomExtensions = new[] { "cci", "3ds", "ncch", "cxi" };

    public static bool IsBuildPackage(string? path) =>
        !string.IsNullOrWhiteSpace(path)
        && string.Equals(Path.GetExtension(path), BuildPackageExtension, StringComparison.OrdinalIgnoreCase);

    public static bool IsRom(string? path) =>
        !string.IsNullOrWhiteSpace(path)
        && RomExtensions.Contains(Path.GetExtension(path).TrimStart('.').ToLowerInvariant());

    /// <summary>Canonical bundled-ROM file in an imported package, or null.</summary>
    public static string? FindPackageRom(string? packageDirectory)
    {
        if (string.IsNullOrWhiteSpace(packageDirectory))
        {
            return null;
        }
        foreach (var extension in RomExtensions)
        {
            var candidate = Path.Combine(packageDirectory, GameRomPrefix + "." + extension);
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return null;
    }

    /// <summary>
    /// Resolve the entry's ROM. <paramref name="cacheDirectory"/> is where a ROM
    /// pulled out of a .32a is written when the imported package has no GameRom
    /// copy. Returns null with an actionable error when no game data is available.
    /// </summary>
    public static ResolvedGameRom? Resolve(LibraryEntry entry, string cacheDirectory, out string? error) =>
        Resolve(entry.RomPath, entry.PackageDir, entry.TitleID, cacheDirectory, out error);

    /// <summary>Path-based overload for callers that only have the recorded path.</summary>
    public static ResolvedGameRom? Resolve(
        string? romPath,
        string? packageDirectory,
        string? titleId,
        string cacheDirectory,
        out string? error)
    {
        error = null;
        if (!string.IsNullOrWhiteSpace(romPath) && File.Exists(romPath) && IsRom(romPath))
        {
            return new ResolvedGameRom(Path.GetFullPath(romPath), Path.GetExtension(romPath).TrimStart('.').ToLowerInvariant(),
                new FileInfo(romPath).Length);
        }
        if (FindPackageRom(packageDirectory) is { } packageRom)
        {
            return new ResolvedGameRom(Path.GetFullPath(packageRom),
                Path.GetExtension(packageRom).TrimStart('.').ToLowerInvariant(), new FileInfo(packageRom).Length);
        }
        if (!string.IsNullOrWhiteSpace(romPath) && File.Exists(romPath) && IsBuildPackage(romPath))
        {
            var extracted = ExtractFromBuildPackage(romPath, titleId, cacheDirectory, out error);
            if (extracted is { } extractedRom)
            {
                return new ResolvedGameRom(Path.GetFullPath(extractedRom.Path),
                    extractedRom.Extension, new FileInfo(extractedRom.Path).Length);
            }
            return null;
        }
        error = "The game's ROM is missing" + (string.IsNullOrWhiteSpace(romPath) ? "." : ": " + romPath + ".")
            + " Import the ROM again (or re-import a .32a that contains game data) and retry.";
        return null;
    }

    /// <summary>
    /// Extract GameRom.&lt;ext&gt; from a .32a ZIP into the launcher cache. Returns the
    /// cached path plus extension, or null with an actionable error.
    /// </summary>
    public static (string Path, string Extension)? ExtractFromBuildPackage(
        string packagePath,
        string? titleId,
        string cacheDirectory,
        out string? error)
    {
        error = null;
        try
        {
            using var archive = ZipFile.OpenRead(packagePath);
            var entry = archive.Entries.FirstOrDefault(candidate =>
                candidate.FullName.IndexOf('/') < 0 && candidate.Name.StartsWith(GameRomPrefix + ".", StringComparison.OrdinalIgnoreCase)
                && IsRom(candidate.Name));
            if (entry is null)
            {
                error = "The .32a " + Path.GetFileName(packagePath)
                    + " does not contain game data (no GameRom.<cci|3ds|ncch|cxi> entry), so the single-game IPA/deploy cannot read the ROM. "
                    + "Import the ROM again (or re-import a .32a that contains game data) and retry.";
                return null;
            }
            var extension = Path.GetExtension(entry.Name).TrimStart('.').ToLowerInvariant();
            var folder = Path.Combine(cacheDirectory, NormalizeFolderName(titleId), "rom-from-32a");
            Directory.CreateDirectory(folder);
            var destination = Path.Combine(folder, GameRomPrefix + "." + extension);
            var temporary = destination + ".tmp";
            entry.ExtractToFile(temporary, overwrite: true);
            File.Move(temporary, destination, overwrite: true);
            return (destination, extension);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                           or InvalidDataException or NotSupportedException or System.Security.SecurityException)
        {
            error = "The .32a " + Path.GetFileName(packagePath) + " could not be read: " + exception.Message;
            return null;
        }
    }

    private static string NormalizeFolderName(string? titleId)
    {
        var normalized = ExportNaming.NormalizeTitleId(titleId);
        if (normalized.Length == 0)
        {
            return "unknown-title";
        }
        foreach (var character in Path.GetInvalidFileNameChars().Concat(new[] { '/', '\\' }))
        {
            normalized = normalized.Replace(character, '_');
        }
        return normalized;
    }
}
