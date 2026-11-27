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
    IReadOnlyList<string> Warnings,
    long RomBytes = 0,
    string RomRelativePath = "")
{
    public static SingleGameIpaExportResult Failure(string error) =>
        new(false, error, null, string.Empty, 0, 0, 0, Array.Empty<string>());
}

/// <summary>
/// Composes one unsigned, single-game IPA from the shell template: the game's
/// GamePack, a schema-2 GameCatalog.json with the root autoLaunch marker, the
/// game's own ROM embedded as Roms/&lt;TITLEID&gt;.&lt;ext&gt;, and the SMDH cover
/// replacing the template AppIcon*.png set.
///
/// Reuses <see cref="IpaComposer"/> for the ROM-free template+packs+catalog
/// composition, then rewrites the result to add autoLaunch, romFile, the ROM and
/// the app icons so the tested deploy composition path stays untouched. Nothing
/// is signed, installed or uploaded; the caller tells the user to sign it
/// (Sideloadly / AltStore). The output contains the user's own game data: it is
/// user data under workspace/export/ipa and must never be uploaded or committed.
/// </summary>
public sealed class SingleGameIpaExporter
{
    public const string GameCatalogFileName = "GameCatalog.json";
    public const string RomsDirectoryName = "Roms";

    /// <summary>ROM extensions the runtime boots and the builder catalogue accepts.</summary>
    public static readonly IReadOnlyList<string> RomExtensions = new[] { "cci", "3ds", "ncch", "cxi" };

    private readonly PackCli _packCli;
    private readonly IpaComposer _composer;

    public SingleGameIpaExporter(PackCli packCli)
    {
        _packCli = packCli;
        _composer = new IpaComposer(packCli);
    }

    /// <summary>
    /// Output file name for one game: TITLE_ID-English game name.ipa (0.2.2-beta4;
    /// no build slug, launcher version or "unsigned" suffix). Illegal file-name
    /// characters become '_'; callers that allow a custom name keep the user's input.
    /// </summary>
    public static string OutputFileName(string displayName, string titleId) =>
        ExportNaming.IpaFileName(displayName, titleId);

    /// <summary>
    /// Canonical bundle-relative ROM path for one title: Roms/&lt;TITLEID&gt;.&lt;ext&gt;
    /// (lower-case extension), matching builder/pack catalog rom_relative_path.
    /// </summary>
    public static string RomRelativePath(string titleId, string extension) =>
        RomsDirectoryName + "/" + GameInfoWriter.NormalizeTitleId(titleId) + "." + extension.TrimStart('.').ToLowerInvariant();

    /// <summary>Validate the ROM source and return its path plus canonical relative path.</summary>
    public static (string Path, string Extension, string RelativePath, long Bytes)? ResolveRom(string? romPath, string titleId, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(romPath) || !File.Exists(romPath))
        {
            error = "The game's ROM is missing: " + (romPath ?? "(no ROM path recorded)")
                + ". The single-game IPA embeds the game data, so import/re-add the ROM (or copy it back to its original path) and export again.";
            return null;
        }
        var extension = Path.GetExtension(romPath).TrimStart('.').ToLowerInvariant();
        if (!RomExtensions.Contains(extension))
        {
            error = "Cannot embed " + Path.GetFileName(romPath) + ": only ." + string.Join("/.", RomExtensions)
                + " ROMs are supported (or export the .32a build package instead).";
            return null;
        }
        return (Path.GetFullPath(romPath), extension, RomRelativePath(titleId, extension), new FileInfo(romPath).Length);
    }

    public async Task<SingleGameIpaExportResult> ExportAsync(
        string shellTemplateIpaPath,
        ComposedPack pack,
        string? coverPath,
        string? romPath,
        string version,
        string outputDirectory,
        string? outputFileName = null,
        IReadOnlyDictionary<string, string>? displayNames = null,
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
        var capabilityError = File.Exists(_packCli.ExecutablePath)
            ? PackCli.CapabilityError(_packCli.ExecutablePath)
            : null;
        if (capabilityError is not null)
        {
            return SingleGameIpaExportResult.Failure(capabilityError);
        }
        var rom = ResolveRom(romPath, pack.TitleID, out var romError);
        if (rom is null)
        {
            return SingleGameIpaExportResult.Failure(romError ?? "The game's ROM could not be resolved.");
        }
        var resolvedRom = rom.Value;

        Directory.CreateDirectory(outputDirectory);
        var staging = Path.Combine(outputDirectory, ".single-game-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(staging);
        var warnings = new List<string>();
        try
        {
            var title = GameInfoWriter.NormalizeTitleId(pack.TitleID);
            log?.Invoke("single-game IPA: template " + shellTemplateIpaPath + "; game " + title
                + "; ROM " + resolvedRom.RelativePath + " (" + resolvedRom.Bytes + " bytes)");
            var catalogPath = Path.Combine(staging, "GameCatalog.generated.json");
            var catalogProcess = await _packCli.CatalogAsync(new[] { title }, catalogPath, autoLaunch: true, cancellationToken).ConfigureAwait(false);
            if (!catalogProcess.Ok || !File.Exists(catalogPath))
            {
                return SingleGameIpaExportResult.Failure(
                    "The pack CLI could not generate GameCatalog.json: " + PackCli.ActionableFailure(catalogProcess));
            }
            var catalogJson = await File.ReadAllTextAsync(catalogPath, cancellationToken).ConfigureAwait(false);
            catalogJson = IpaComposer.NormalizeCatalog(catalogJson, new[] { title });
            catalogJson = AddSingleGameFields(catalogJson, resolvedRom.RelativePath);

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

            var fileName = string.IsNullOrWhiteSpace(outputFileName)
                ? OutputFileName(pack.DisplayName, title)
                : Path.GetFileName(outputFileName);
            if (!fileName.EndsWith(".ipa", StringComparison.OrdinalIgnoreCase))
            {
                return SingleGameIpaExportResult.Failure("The IPA file name must end with .ipa (got " + fileName + ").");
            }
            var finalPath = Path.Combine(outputDirectory, fileName);
            var replacedIcons = RewriteIpa(
                composed.IpaPath,
                finalPath,
                composed.AppRoot,
                catalogJson,
                replacements,
                composed.AppRoot + resolvedRom.RelativePath,
                resolvedRom.Path,
                pack.DisplayName,
                displayNames);
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
                + ", " + replacedCount + " icon(s) replaced, ROM " + resolvedRom.RelativePath
                + " " + resolvedRom.Bytes + " bytes, autoLaunch=true)");
            warnings.Add(
                "This IPA contains your own game data (" + resolvedRom.RelativePath + ", "
                + resolvedRom.Bytes + " bytes). Keep it local, never upload or share it, and sign it yourself (Sideloadly/AltStore).");
            return new SingleGameIpaExportResult(true, null, finalPath, sha256, bytes, 1, replacedCount, warnings,
                resolvedRom.Bytes, resolvedRom.RelativePath);
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

    /// <summary>
    /// Add the root autoLaunch marker and the game's canonical romFile to a
    /// normalised single-game catalogue (builder-compatible Roms/&lt;TITLEID&gt;.&lt;ext&gt;).
    /// </summary>
    internal static string AddSingleGameFields(string catalogJson, string romRelativePath)
    {
        using var document = Json.TryParse(catalogJson);
        if (document is null)
        {
            throw new LauncherToolException("catalog_failed", "The generated GameCatalog.json is not valid JSON.", "Update 3ds2apple-pack; this is a tool mismatch.");
        }
        var games = new List<Dictionary<string, object?>>();
        foreach (var game in Json.Array(document.RootElement, "games"))
        {
            var copy = new Dictionary<string, object?>();
            foreach (var property in game.EnumerateObject())
            {
                copy[property.Name] = property.Value.Clone();
            }
            games.Add(copy);
        }
        if (games.Count != 1)
        {
            throw new LauncherToolException("catalog_failed",
                "GameCatalog.json must list exactly one game for a single-game IPA (found " + games.Count + ").",
                "Update 3ds2apple-pack; this is a tool mismatch.");
        }
        games[0]["romFile"] = romRelativePath;
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
        IReadOnlyDictionary<string, byte[]>? iconReplacements,
        string romEntryName,
        string romPath,
        string displayName,
        IReadOnlyDictionary<string, string>? displayNames)
    {
        var catalogEntryName = appRoot + GameCatalogFileName;
        var infoPlistEntryName = appRoot + AppDisplayNameRewriter.InfoPlistName;
        var localizedNames = AppDisplayNameRewriter.LocalizedNames(displayName, displayNames);
        var localizedEntryNames = localizedNames.Keys
            .Select(language => appRoot + language + ".lproj/" + AppDisplayNameRewriter.InfoPlistStringsName)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var replacedIcons = 0;
        TryDelete(destinationIpaPath);
        using var source = ZipFile.OpenRead(sourceIpaPath);
        using (var destination = ZipFile.Open(destinationIpaPath, ZipArchiveMode.Create))
        {
            foreach (var entry in source.Entries)
            {
                var relative = entry.FullName.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase)
                    ? entry.FullName[appRoot.Length..]
                    : entry.FullName;
                if (string.Equals(entry.FullName, catalogEntryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                if (relative.StartsWith(RomsDirectoryName + "/", StringComparison.OrdinalIgnoreCase))
                {
                    // The template must be ROM-free; drop anything stale so exactly one ROM remains.
                    continue;
                }
                if (string.Equals(entry.FullName, infoPlistEntryName, StringComparison.OrdinalIgnoreCase))
                {
                    // Rename the home-screen app: CFBundleDisplayName/CFBundleName = game name.
                    using var plistSource = entry.Open();
                    using var plistMemory = new MemoryStream();
                    plistSource.CopyTo(plistMemory);
                    var rewritten = AppDisplayNameRewriter.RewriteInfoPlist(plistMemory.ToArray(), displayName);
                    var plistEntry = destination.CreateEntry(entry.FullName, CompressionLevel.Optimal);
                    plistEntry.LastWriteTime = entry.LastWriteTime;
                    plistEntry.ExternalAttributes = entry.ExternalAttributes;
                    using var plistTarget = plistEntry.Open();
                    plistTarget.Write(rewritten);
                    continue;
                }
                if (localizedEntryNames.Contains(entry.FullName))
                {
                    // Replaced below with the current game's localized display name.
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
            var romEntry = destination.CreateEntry(romEntryName, CompressionLevel.Optimal);
            romEntry.ExternalAttributes = 0x81A4 << 16;
            using (var romSource = File.OpenRead(romPath))
            using (var romTarget = romEntry.Open())
            {
                romSource.CopyTo(romTarget);
            }
            var catalog = destination.CreateEntry(catalogEntryName, CompressionLevel.Optimal);
            catalog.ExternalAttributes = 0x81A4 << 16;
            using (var writer = new StreamWriter(catalog.Open(), new UTF8Encoding(false)))
            {
                writer.Write(catalogJson);
            }
            foreach (var pair in localizedNames)
            {
                var stringsEntry = destination.CreateEntry(
                    appRoot + pair.Key + ".lproj/" + AppDisplayNameRewriter.InfoPlistStringsName,
                    CompressionLevel.Optimal);
                stringsEntry.ExternalAttributes = 0x81A4 << 16;
                using var stringsStream = stringsEntry.Open();
                stringsStream.Write(AppDisplayNameRewriter.InfoPlistStrings(pair.Value));
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
            var normalizedTitle = GameInfoWriter.NormalizeTitleId(titleId);
            var catalogTitle = Json.String(game, "titleID", "titleId") ?? string.Empty;
            if (!string.Equals(catalogTitle, normalizedTitle, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "GameCatalog.json lists " + catalogTitle + ", expected " + titleId);
            }
            var expectedPackRelative = IpaComposer.FrameworksDirectory + "/GamePack-" + normalizedTitle + ".dylib";
            var expectedPack = appRoot + expectedPackRelative;
            var packEntry = archive.Entries.FirstOrDefault(entry =>
                string.Equals(entry.FullName, expectedPack, StringComparison.OrdinalIgnoreCase));
            if (packEntry is null || packEntry.Length <= 0)
            {
                return (false, "the GamePack is missing from " + expectedPack);
            }
            var packFile = Json.String(game, "packFile") ?? string.Empty;
            if (!string.Equals(packFile, expectedPackRelative, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "GameCatalog.json names packFile " + packFile + ", expected " + expectedPackRelative);
            }

            // Exactly one game-data entry: Roms/<TITLEID>.<cci|3ds|ncch|cxi>, non-empty,
            // named by the catalogue; any other Roms/ entry is refused.
            var romFile = Json.String(game, "romFile") ?? string.Empty;
            var romRelative = romFile.StartsWith(RomsDirectoryName + "/", StringComparison.OrdinalIgnoreCase)
                ? romFile[(RomsDirectoryName.Length + 1)..]
                : string.Empty;
            var stem = romRelative.Contains('.') ? romRelative[..romRelative.LastIndexOf('.')] : romRelative;
            var extension = romRelative.Contains('.') ? romRelative[(romRelative.LastIndexOf('.') + 1)..].ToLowerInvariant() : string.Empty;
            if (string.IsNullOrWhiteSpace(romRelative)
                || !string.Equals(stem, normalizedTitle, StringComparison.OrdinalIgnoreCase)
                || !RomExtensions.Contains(extension))
            {
                return (false, "GameCatalog.json romFile must be " + RomsDirectoryName + "/" + normalizedTitle
                    + ".<" + string.Join("|", RomExtensions) + "> (got " + (romFile.Length == 0 ? "<missing>" : romFile) + ")");
            }
            var expectedRom = appRoot + RomsDirectoryName + "/" + stem + "." + extension;
            var romEntries = archive.Entries
                .Where(entry => entry.FullName.StartsWith(appRoot + RomsDirectoryName + "/", StringComparison.OrdinalIgnoreCase)
                                && !entry.FullName.EndsWith("/", StringComparison.Ordinal))
                .ToList();
            if (romEntries.Count != 1)
            {
                return (false, "the IPA must contain exactly one game-data entry in " + RomsDirectoryName
                    + " (found " + romEntries.Count + ")");
            }
            var singleRom = romEntries[0];
            if (!string.Equals(singleRom.FullName, expectedRom, StringComparison.OrdinalIgnoreCase))
            {
                return (false, "the IPA game-data entry is " + singleRom.FullName + ", expected " + expectedRom);
            }
            if (singleRom.Length <= 0)
            {
                return (false, "the embedded game data is empty (" + singleRom.FullName + ")");
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
