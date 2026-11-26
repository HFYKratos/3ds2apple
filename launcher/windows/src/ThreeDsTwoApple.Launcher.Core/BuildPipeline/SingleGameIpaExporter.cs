using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Result of one single-game IPA export (Library row "Export IPA").</summary>
public sealed record SingleGameIpaExportResult(
    bool Ok,
    string? Error,
    string? IpaPath,
    string Sha256,
    long Bytes,
    int GameCount,
    int ReplacedIconCount,
    IReadOnlyList<string> Warnings)
{
    public static SingleGameIpaExportResult Failure(string error) =>
        new(false, error, null, string.Empty, 0, 0, 0, Array.Empty<string>());
}

/// <summary>
/// Composes one unsigned, single-game IPA from the shell template: the game's
/// GamePack, a schema-2 GameCatalog.json with the root autoLaunch marker, and
/// the game's SMDH cover replacing the template AppIcon*.png set.
///
/// Reuses <see cref="IpaComposer"/> for the ROM-free template+packs+catalog
/// composition, then rewrites the result to add autoLaunch and the app icons so
/// the tested deploy composition path stays untouched. Nothing is signed,
/// installed or uploaded; the caller tells the user to sign it (Sideloadly /
/// AltStore). The output is user data under workspace/exports.
/// </summary>
public sealed class SingleGameIpaExporter
{
    public const string ExportsDirectoryName = "exports";
    public const string GameCatalogFileName = "GameCatalog.json";

    private readonly PackCli _packCli;
    private readonly IpaComposer _composer;

    public SingleGameIpaExporter(PackCli packCli)
    {
        _packCli = packCli;
        _composer = new IpaComposer(packCli);
    }

    /// <summary>Output file name for one game: build slug + launcher version + unsigned.</summary>
    public static string OutputFileName(string displayName, string titleId, string version)
    {
        var slug = BuildSlug.From(displayName, titleId);
        var safeVersion = new string(version.Where(c => char.IsLetterOrDigit(c) || c == '.' || c == '-' || c == '_').ToArray());
        if (string.IsNullOrWhiteSpace(safeVersion))
        {
            safeVersion = LauncherInfo.Version;
        }
        return slug + "-" + safeVersion + "-unsigned.ipa";
    }

    public async Task<SingleGameIpaExportResult> ExportAsync(
        string shellTemplateIpaPath,
        ComposedPack pack,
        string? coverPath,
        string version,
        string outputDirectory,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(shellTemplateIpaPath) || !File.Exists(shellTemplateIpaPath))
        {
            return SingleGameIpaExportResult.Failure(
                "The shell template IPA is missing: " + shellTemplateIpaPath
                + ". Reinstall the launcher package so Shell/ contains the ROM-free template.");
        }
        if (string.IsNullOrWhiteSpace(pack.PackPath) || !File.Exists(pack.PackPath))
        {
            return SingleGameIpaExportResult.Failure(
                "The GamePack for " + pack.TitleID + " is missing: " + pack.PackPath
                + ". Build the game before exporting an IPA.");
        }
        try
        {
            GamePackInspector.VerifyMachO(pack.PackPath);
        }
        catch (LauncherToolException exception)
        {
            return SingleGameIpaExportResult.Failure(exception.Message);
        }
        var templateInspection = IpaTemplateInspector.Inspect(shellTemplateIpaPath, requireEmptyCatalog: true);
        if (!templateInspection.Ok)
        {
            return SingleGameIpaExportResult.Failure(
                templateInspection.Error ?? "The shell template is not a launcher-compatible ROM-free IPA.");
        }

        Directory.CreateDirectory(outputDirectory);
        var staging = Path.Combine(outputDirectory, ".single-game-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(staging);
        var warnings = new List<string>();
        try
        {
            var title = GameInfoWriter.NormalizeTitleId(pack.TitleID);
            log?.Invoke("single-game IPA: template " + shellTemplateIpaPath + "; game " + title);
            var catalogPath = Path.Combine(staging, "GameCatalog.generated.json");
            var catalogProcess = await _packCli.CatalogAsync(new[] { title }, catalogPath, autoLaunch: true, cancellationToken).ConfigureAwait(false);
            if (!catalogProcess.Ok || !File.Exists(catalogPath))
            {
                return SingleGameIpaExportResult.Failure(
                    "The pack CLI could not generate GameCatalog.json: " + PackCli.FirstMeaningfulLine(catalogProcess));
            }
            var catalogJson = await File.ReadAllTextAsync(catalogPath, cancellationToken).ConfigureAwait(false);
            catalogJson = IpaComposer.NormalizeCatalog(catalogJson, new[] { title });
            catalogJson = AddAutoLaunch(catalogJson);

            var composed = await _composer.ComposeAsync(
                shellTemplateIpaPath,
                new[] { pack },
                staging,
                log,
                cancellationToken).ConfigureAwait(false);

            var templateIcons = ReadTemplateIcons(composed.IpaPath, composed.AppRoot);
            var replacements = AppIconGenerator.Render(coverPath, templateIcons);
            if (replacements is null)
            {
                warnings.Add(coverPath is null
                    ? "The game has no SMDH cover (cover.png); the template app icon was kept."
                    : "The game's cover.png could not be read; the template app icon was kept.");
            }

            var fileName = OutputFileName(pack.DisplayName, title, version);
            var finalPath = Path.Combine(outputDirectory, fileName);
            var replacedIcons = RewriteIpa(
                composed.IpaPath,
                finalPath,
                composed.AppRoot,
                catalogJson,
                replacements);
            File.Delete(composed.IpaPath);

            var verification = VerifyStructure(finalPath, title);
            if (!verification.Ok)
            {
                TryDelete(finalPath);
                return SingleGameIpaExportResult.Failure(
                    "The composed single-game IPA failed verification: " + verification.Error);
            }
            var (sha256, bytes) = HashFile(finalPath);
            var replacedCount = replacements is null ? 0 : replacedIcons;
            log?.Invoke("single-game IPA: wrote " + finalPath + " (" + bytes + " bytes, sha256 " + sha256
                        + ", " + replacedCount + " icon(s) replaced, autoLaunch=true)");
            return new SingleGameIpaExportResult(true, null, finalPath, sha256, bytes, 1, replacedCount, warnings);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or LauncherToolException)
        {
            return SingleGameIpaExportResult.Failure(exception.Message);
        }
        finally
        {
            TryDeleteDirectory(staging);
        }
    }

    /// <summary>Add the additive root field autoLaunch:true to a normalised catalogue.</summary>
    internal static string AddAutoLaunch(string catalogJson)
    {
        using var document = Json.TryParse(catalogJson);
        if (document is null)
        {
            throw new LauncherToolException("catalog_failed", "The generated GameCatalog.json is not valid JSON.", "Update 3ds2apple-pack; this is a tool mismatch.");
        }
        var games = new List<JsonElement>();
        foreach (var game in Json.Array(document.RootElement, "games"))
        {
            games.Add(game.Clone());
        }
        var output = new Dictionary<string, object?>
        {
            ["schemaVersion"] = Json.Long(document.RootElement, "schemaVersion") ?? 2,
            ["autoLaunch"] = true,
            ["games"] = games,
        };
        return JsonSerializer.Serialize(output, Json.WriteOptions) + "\n";
    }

    private static List<AppIconGenerator.TemplateIcon> ReadTemplateIcons(string ipaPath, string appRoot)
    {
        using var archive = ZipFile.OpenRead(ipaPath);
        var entries = new List<(string, byte[])>();
        foreach (var entry in archive.Entries)
        {
            var relative = entry.FullName.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase)
                ? entry.FullName[appRoot.Length..]
                : entry.FullName;
            if (!relative.StartsWith("AppIcon", StringComparison.OrdinalIgnoreCase)
                || !relative.EndsWith(".png", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            using var stream = entry.Open();
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            entries.Add((entry.FullName, memory.ToArray()));
        }
        return AppIconGenerator.ReadTemplateIcons(entries).ToList();
    }

    private static int RewriteIpa(
        string sourceIpaPath,
        string destinationIpaPath,
        string appRoot,
        string catalogJson,
        IReadOnlyDictionary<string, byte[]>? iconReplacements)
    {
        var catalogEntryName = appRoot + GameCatalogFileName;
        var replacedIcons = 0;
        TryDelete(destinationIpaPath);
        using var source = ZipFile.OpenRead(sourceIpaPath);
        using (var destination = ZipFile.Open(destinationIpaPath, ZipArchiveMode.Create))
        {
            foreach (var entry in source.Entries)
            {
                if (string.Equals(entry.FullName, catalogEntryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                if (iconReplacements is not null
                    && iconReplacements.TryGetValue(entry.FullName, out var replacement))
                {
                    var iconEntry = destination.CreateEntry(entry.FullName, CompressionLevel.Optimal);
                    iconEntry.LastWriteTime = entry.LastWriteTime;
                    iconEntry.ExternalAttributes = entry.ExternalAttributes;
                    using var iconStream = iconEntry.Open();
                    iconStream.Write(replacement);
                    replacedIcons++;
                    continue;
                }
                var copied = destination.CreateEntry(entry.FullName, CompressionLevel.Optimal);
                copied.LastWriteTime = entry.LastWriteTime;
                copied.ExternalAttributes = entry.ExternalAttributes;
                using var sourceStream = entry.Open();
                using var targetStream = copied.Open();
                sourceStream.CopyTo(targetStream);
            }
            var catalog = destination.CreateEntry(catalogEntryName, CompressionLevel.Optimal);
            catalog.ExternalAttributes = 0x81A4 << 16;
            using (var writer = new StreamWriter(catalog.Open(), new UTF8Encoding(false)))
            {
                writer.Write(catalogJson);
            }
        }
        return replacedIcons;
    }

    /// <summary>Structure gate for the exported IPA (also used by the tests).</summary>
    public static (bool Ok, string? Error) VerifyStructure(string ipaPath, string titleId)
    {
        if (!File.Exists(ipaPath))
        {
            return (false, "the IPA was not written");
        }
        try
        {
            using var archive = ZipFile.OpenRead(ipaPath);
            var appRoot = ComposedIpaVerifier.FindAppRoot(archive);
            if (appRoot is null)
            {
                return (false, "the IPA has no Payload/*.app directory");
            }
            if (!archive.Entries.Any(entry => string.Equals(entry.FullName, appRoot + "Info.plist", StringComparison.OrdinalIgnoreCase)))
            {
                return (false, "the app bundle has no Info.plist");
            }
            var catalogEntry = archive.Entries.FirstOrDefault(entry =>
                string.Equals(entry.FullName, appRoot + GameCatalogFileName, StringComparison.OrdinalIgnoreCase));
            if (catalogEntry is null)
            {
                return (false, "the app bundle has no GameCatalog.json");
            }
            string catalogJson;
            using (var reader = new StreamReader(catalogEntry.Open()))
            {
                catalogJson = reader.ReadToEnd();
            }
            using var catalog = Json.TryParse(catalogJson);
            if (catalog is null)
            {
                return (false, "GameCatalog.json is not valid JSON");
            }
            if (Json.Long(catalog.RootElement, "schemaVersion") != 2)
            {
                return (false, "GameCatalog.json is not schema 2");
            }
            if (Json.Bool(catalog.RootElement, "autoLaunch") != true)
            {
                return (false, "GameCatalog.json has no autoLaunch marker");
            }
            var games = Json.Array(catalog.RootElement, "games");
            if (games.Count != 1)
            {
                return (false, "GameCatalog.json must list exactly one game (found " + games.Count + ")");
            }
            var game = games[0];
            var catalogTitle = Json.String(game, "titleID", "titleId") ?? string.Empty;
            if (!string.Equals(catalogTitle, GameInfoWriter.NormalizeTitleId(titleId), StringComparison.OrdinalIgnoreCase))
            {
                return (false, "GameCatalog.json lists " + catalogTitle + ", expected " + titleId);
            }
            var expectedPack = appRoot + IpaComposer.FrameworksDirectory + "/GamePack-" + GameInfoWriter.NormalizeTitleId(titleId) + ".dylib";
            var packEntry = archive.Entries.FirstOrDefault(entry =>
                string.Equals(entry.FullName, expectedPack, StringComparison.OrdinalIgnoreCase));
            if (packEntry is null || packEntry.Length <= 0)
            {
                return (false, "the GamePack is missing from " + expectedPack);
            }
            var packFile = Json.String(game, "packFile") ?? string.Empty;
            var expectedRelative = IpaComposer.FrameworksDirectory + "/GamePack-" + GameInfoWriter.NormalizeTitleId(titleId) + ".dylib";
            if (!string.Equals(packFile, expectedRelative, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "GameCatalog.json names packFile " + packFile + ", expected " + expectedRelative);
            }
            foreach (var entry in archive.Entries)
            {
                var relative = entry.FullName.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase)
                    ? entry.FullName[appRoot.Length..]
                    : entry.FullName;
                if (relative.StartsWith("Roms/", StringComparison.OrdinalIgnoreCase))
                {
                    return (false, "the IPA contains game data (" + entry.FullName + ")");
                }
            }
            return (true, null);
        }
        catch (InvalidDataException)
        {
            return (false, "the IPA is not a readable zip archive");
        }
        catch (IOException exception)
        {
            return (false, "the IPA could not be read: " + exception.Message);
        }
    }

    private static (string Sha256, long Bytes) HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        var bytes = stream.Length;
        return (Convert.ToHexStringLower(sha.ComputeHash(stream)), bytes);
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (IOException)
        {
            // best effort
        }
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (IOException)
        {
            // best effort
        }
    }
}
