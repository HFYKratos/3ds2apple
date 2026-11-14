using System.IO.Compression;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Pack adopted from a per-game IPA built by a macOS host.</summary>
public sealed record ExtractedGamePack(
    string TitleID,
    string DisplayName,
    string ProductCode,
    string PackPath,
    long PackBytes,
    string PackSha256);

/// <summary>
/// Transitional bridge between the existing macOS IPA pipeline and the
/// launcher's push model: when the Build Agent only produces a per-game IPA
/// (today's builder-windows/zkb flow), extract the very same
/// <c>Frameworks/GamePack-&lt;TITLEID&gt;.dylib</c> from the app bundle and record it
/// into the local package with the pack CLI. The phone never installs that IPA;
/// only the base shell is installed and this pack/ROM are pushed.
/// </summary>
public static class IpaPackExtractor
{
    public const string GameCatalogEntrySuffix = "GameCatalog.json";

    public static ExtractedGamePack ExtractGamePack(string ipaPath, string outputDirectory, string? expectedTitleId = null)
    {
        if (!File.Exists(ipaPath))
        {
            throw new LauncherToolException("ipa_missing", $"The Build Agent produced no IPA at {ipaPath}.", "Check the build log; the agent may have failed before packaging.");
        }
        Directory.CreateDirectory(outputDirectory);

        using var archive = ZipFile.OpenRead(ipaPath);
        var catalogEntry = FindCatalogEntry(archive);
        var titleFromCatalog = expectedTitleId is null && catalogEntry is not null
            ? TryReadOnlyCatalogTitle(archive, catalogEntry)
            : null;
        var titleId = GameInfoWriter.NormalizeTitleId(expectedTitleId ?? titleFromCatalog
            ?? throw new LauncherToolException("pack_not_found", "The IPA contains no GameCatalog.json entry to identify the title.", "Pass the title ID explicitly or rebuild with the current scripts."));

        var packEntry = archive.Entries.FirstOrDefault(entry =>
            entry.FullName.EndsWith(".dylib", StringComparison.OrdinalIgnoreCase)
            && entry.FullName.Contains("/Frameworks/GamePack-", StringComparison.OrdinalIgnoreCase)
            && entry.FullName.Contains(titleId, StringComparison.OrdinalIgnoreCase))
            ?? archive.Entries.FirstOrDefault(entry =>
                entry.FullName.EndsWith(".dylib", StringComparison.OrdinalIgnoreCase)
                && entry.FullName.Contains("GamePack", StringComparison.OrdinalIgnoreCase));
        if (packEntry is null)
        {
            throw new LauncherToolException("pack_not_found",
                $"The IPA has no Frameworks/GamePack-<TITLEID>.dylib for {titleId}.",
                "The macOS host built a shell without an AOT pack. Update the build host and rebuild.");
        }

        var packPath = Path.Combine(outputDirectory, "GamePack.dylib");
        packEntry.ExtractToFile(packPath, overwrite: true);
        VerifyMachO(packPath);
        var (sha256, bytes) = HashFile(packPath);

        var displayName = titleId;
        var productCode = string.Empty;
        if (catalogEntry is not null)
        {
            var catalog = TryReadCatalog(archive, catalogEntry);
            if (catalog is { } document)
            {
                foreach (var game in Json.Array(document.RootElement, "games"))
                {
                    var gameTitle = Json.String(game, "titleID", "titleId");
                    if (gameTitle is null || !string.Equals(gameTitle, titleId, StringComparison.OrdinalIgnoreCase))
                    {
                        continue;
                    }
                    displayName = Json.String(game, "displayName") ?? displayName;
                    productCode = Json.String(game, "productCode") ?? productCode;
                }
            }
        }
        return new ExtractedGamePack(titleId, displayName, productCode, packPath, bytes, sha256);
    }

    /// <summary>Mach-O magic check so a placeholder pack can never pass as AOT code.</summary>
    public static void VerifyMachO(string path)
    {
        using var stream = File.OpenRead(path);
        Span<byte> magic = stackalloc byte[4];
        if (stream.Read(magic) != 4)
        {
            throw new LauncherToolException("pack_invalid", $"{path} is too small to be a Mach-O dylib.", "Rebuild the GamePack on the macOS host.");
        }
        var value = (uint)(magic[0] | (magic[1] << 8) | (magic[2] << 16) | (magic[3] << 24));
        // 0xFEEDFACF (64-bit), 0xFEEDFACE (32-bit), 0xCAFEBABE (fat), and their byte swaps.
        var isMachO = value is 0xFEEDFACF or 0xFEEDFACE or 0xCAFEBABE or 0xCFFAEDFE or 0xCEFAEDFE or 0xBEBAFECA;
        if (!isMachO)
        {
            throw new LauncherToolException("pack_placeholder",
                $"{path} is not a Mach-O dylib (magic 0x{value:X8}); it is a preview placeholder, not installable AOT code.",
                "Build the GamePack on the macOS Build Agent (real clang link), not with the local --fake preview.");
        }
    }

    private static ZipArchiveEntry? FindCatalogEntry(ZipArchive archive) =>
        archive.Entries.FirstOrDefault(entry =>
            entry.FullName.EndsWith(GameCatalogEntrySuffix, StringComparison.OrdinalIgnoreCase)
            && entry.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase))
        ?? archive.Entries.FirstOrDefault(entry => entry.FullName.EndsWith(GameCatalogEntrySuffix, StringComparison.OrdinalIgnoreCase));

    private static string? TryReadOnlyCatalogTitle(ZipArchive archive, ZipArchiveEntry catalogEntry)
    {
        var catalog = TryReadCatalog(archive, catalogEntry);
        if (catalog is null)
        {
            return null;
        }
        var games = Json.Array(catalog.RootElement, "games");
        return games.Count == 1 ? Json.String(games[0], "titleID", "titleId") : null;
    }

    private static JsonDocument? TryReadCatalog(ZipArchive archive, ZipArchiveEntry catalogEntry)
    {
        try
        {
            using var stream = catalogEntry.Open();
            using var reader = new StreamReader(stream);
            return Json.TryParse(reader.ReadToEnd());
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static (string Sha256, long Bytes) HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = System.Security.Cryptography.SHA256.Create();
        return (Convert.ToHexStringLower(sha.ComputeHash(stream)), stream.Length);
    }
}
