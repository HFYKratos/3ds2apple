using System.IO.Compression;
using System.Security.Cryptography;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>One real AOT pack injected as Frameworks/GamePack-TITLEID.dylib inside the signed app.</summary>
public sealed record ComposedPack(string TitleID, string DisplayName, string? ProductCode, int AotVersion, string PackPath);

/// <summary>Result of composing the installable app IPA.</summary>
public sealed record ComposedAppIpa(
    string IpaPath,
    string Sha256,
    long Bytes,
    int GameCount,
    IReadOnlyList<string> TitleIDs,
    string AppRoot);

/// <summary>
/// Composes the installable, ROM-free app IPA from the pinned shell template plus
/// every built GamePack and a generated GameCatalog.json.
/// </summary>
/// <remarks>
/// iOS cannot dlopen a loose, unsigned dylib pushed into Documents, so game packs
/// must live inside the app bundle that plumesign signs and installs (IPA signing
/// covers the nested Frameworks dylibs). The launcher:
///   1. starts from the pristine shell template IPA (empty catalogue, no packs, no ROMs);
///   2. asks the Rust pack CLI for GameCatalog.json (single schema writer) and
///      fills the optional registrationSymbol contract field when absent;
///   3. copies the template app entries (preserving Unix modes) and adds
///      Frameworks/GamePack-TITLEID.dylib for every real pack;
///   4. replaces GameCatalog.json and refuses any Roms/ entry in the template;
///   5. hands the result to the signing/install step.
/// Adding or removing a game rebuilds this IPA and reinstalls the app; the ROM and
/// GameInfo.json already pushed into Documents/Games/TITLEID survive an overwrite
/// install and are not part of the IPA.
/// </remarks>
public sealed class IpaComposer
{
    public const string GameCatalogFileName = "GameCatalog.json";
    public const string FrameworksDirectory = "Frameworks";
    public const string RomsDirectory = "Roms";
    public const string RegistrationSymbol = "zk_gamepack_register";

    // Unix mode bits live in the upper 16 bits of the zip external attributes, as
    // the macOS zip tool stores them. Copied entries keep their original modes.
    private const int UnixRegularFile0644 = 0x81A4 << 16;
    private const int UnixExecutable0755 = 0x81ED << 16;
    private const int UnixDirectory0755 = 0x41ED << 16;

    private readonly PackCli _packCli;

    public IpaComposer(PackCli packCli) => _packCli = packCli;

    public async Task<ComposedAppIpa> ComposeAsync(
        string shellTemplateIpaPath,
        IReadOnlyList<ComposedPack> packs,
        string outputDirectory,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(shellTemplateIpaPath))
        {
            throw new LauncherToolException("shell_invalid", "The shell template IPA is missing: " + shellTemplateIpaPath, "Reinstall the launcher package or set the shell path in Settings.");
        }
        var templateInspection = IpaTemplateInspector.Inspect(shellTemplateIpaPath, requireEmptyCatalog: true);
        if (!templateInspection.Ok)
        {
            throw new LauncherToolException("shell_template_incompatible", templateInspection.Error!, templateInspection.Fix);
        }
        if (packs.Count == 0)
        {
            throw new LauncherToolException("pack_missing", "No real GamePack is built yet; build at least one game with the macOS Build Agent before installing the app.", "Preview placeholders cannot be installed on a phone.");
        }

        var titleIds = new List<string>();
        foreach (var pack in packs)
        {
            var title = GameInfoWriter.NormalizeTitleId(pack.TitleID);
            if (titleIds.Contains(title, StringComparer.OrdinalIgnoreCase))
            {
                throw new LauncherToolException("pack_duplicate", "Package list contains " + title + " more than once.", "This is a launcher bug; rebuild the library.");
            }
            if (!File.Exists(pack.PackPath))
            {
                throw new LauncherToolException("pack_missing", "GamePack.dylib for " + title + " is missing: " + pack.PackPath, "Rebuild that game with the macOS Build Agent.");
            }
            IpaPackExtractor.VerifyMachO(pack.PackPath);
            titleIds.Add(title);
        }

        Directory.CreateDirectory(outputDirectory);
        var catalogPath = Path.Combine(outputDirectory, "GameCatalog.generated.json");
        var catalogProcess = await _packCli.CatalogAsync(titleIds, catalogPath, cancellationToken).ConfigureAwait(false);
        if (!catalogProcess.Ok || !File.Exists(catalogPath))
        {
            throw new LauncherToolException("catalog_failed",
                "The pack CLI could not generate GameCatalog.json: " + PackCli.FirstMeaningfulLine(catalogProcess),
                "Make sure every game was built/recorded by 3ds2apple-pack (packages list shows a real pack).");
        }
        var catalogJson = await File.ReadAllTextAsync(catalogPath, cancellationToken).ConfigureAwait(false);
        catalogJson = NormalizeCatalog(catalogJson, titleIds);

        using var template = ZipFile.OpenRead(shellTemplateIpaPath);
        var appRoot = FindAppRoot(template);
        var catalogEntryName = appRoot + GameCatalogFileName;
        if (!template.Entries.Any(entry => string.Equals(entry.FullName, catalogEntryName, StringComparison.OrdinalIgnoreCase)))
        {
            var fallback = template.Entries
                .FirstOrDefault(entry => entry.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase)
                                         && entry.FullName.EndsWith(GameCatalogFileName, StringComparison.OrdinalIgnoreCase));
            if (fallback is null)
            {
                throw new LauncherToolException("shell_invalid", "The shell template IPA has no GameCatalog.json entry.", "The shell template is not the launcher-compatible build; rebuild it on macOS.");
            }
            catalogEntryName = fallback.FullName;
        }

        foreach (var entry in template.Entries)
        {
            var relative = entry.FullName.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase) ? entry.FullName[appRoot.Length..] : entry.FullName;
            if (relative.StartsWith(RomsDirectory + "/", StringComparison.OrdinalIgnoreCase))
            {
                throw new LauncherToolException("base_shell_not_rom_free", "The shell template contains game data (" + entry.FullName + ").", "Use the ROM-free shell template described in shell/README.md; ROM data is pushed separately.");
            }
        }

        var ipaName = "3ds2apple-app-" + packs.Count.ToString() + "games-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + ".ipa";
        var ipaPath = Path.Combine(outputDirectory, ipaName);
        var frameworksPrefix = appRoot + FrameworksDirectory + "/";
        var packEntryNames = new HashSet<string>(packs.Select(pack => frameworksPrefix + "GamePack-" + GameInfoWriter.NormalizeTitleId(pack.TitleID) + ".dylib"), StringComparer.OrdinalIgnoreCase);
        var hasFrameworksDirectoryEntry = template.Entries.Any(entry => string.Equals(entry.FullName, frameworksPrefix, StringComparison.OrdinalIgnoreCase));

        using (var output = ZipFile.Open(ipaPath, ZipArchiveMode.Create))
        {
            foreach (var entry in template.Entries)
            {
                if (string.Equals(entry.FullName, catalogEntryName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }
                if (packEntryNames.Contains(entry.FullName)
                    || (entry.FullName.StartsWith(frameworksPrefix, StringComparison.OrdinalIgnoreCase)
                        && entry.FullName.EndsWith(".dylib", StringComparison.OrdinalIgnoreCase)
                        && entry.FullName.Contains("GamePack-", StringComparison.OrdinalIgnoreCase)))
                {
                    continue;
                }
                var copied = output.CreateEntry(entry.FullName, CompressionLevel.Optimal);
                copied.LastWriteTime = entry.LastWriteTime;
                copied.ExternalAttributes = entry.ExternalAttributes;
                await using var source = entry.Open();
                await using var target = copied.Open();
                await source.CopyToAsync(target, cancellationToken).ConfigureAwait(false);
            }

            if (!hasFrameworksDirectoryEntry)
            {
                var frameworksDirectory = output.CreateEntry(frameworksPrefix, CompressionLevel.NoCompression);
                frameworksDirectory.ExternalAttributes = UnixDirectory0755;
            }
            var catalogEntry = output.CreateEntry(catalogEntryName, CompressionLevel.Optimal);
            catalogEntry.ExternalAttributes = UnixRegularFile0644;
            await using (var writer = new StreamWriter(catalogEntry.Open()))
            {
                await writer.WriteAsync(catalogJson.AsMemory(), cancellationToken).ConfigureAwait(false);
            }

            foreach (var pack in packs)
            {
                var title = GameInfoWriter.NormalizeTitleId(pack.TitleID);
                var packEntry = output.CreateEntry(frameworksPrefix + "GamePack-" + title + ".dylib", CompressionLevel.Optimal);
                packEntry.ExternalAttributes = UnixExecutable0755;
                await using var target = packEntry.Open();
                await using var source = File.OpenRead(pack.PackPath);
                await source.CopyToAsync(target, cancellationToken).ConfigureAwait(false);
            }
        }

        var (sha256, bytes) = HashFile(ipaPath);
        return new ComposedAppIpa(ipaPath, sha256, bytes, packs.Count, titleIds, appRoot);
    }

    internal static string FindAppRoot(ZipArchive archive)
    {
        var appEntry = archive.Entries.FirstOrDefault(entry =>
            entry.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase)
            && entry.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase) > 0);
        if (appEntry is null)
        {
            throw new LauncherToolException("shell_invalid", "The shell template IPA has no Payload/*.app entry.", "The bundled template is not a valid IPA; rebuild/reinstall the launcher package.");
        }
        var index = appEntry.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase);
        return appEntry.FullName[..(index + ".app/".Length)];
    }

    /// <summary>Validate the generated catalogue against the packs and fill registrationSymbol.</summary>
    internal static string NormalizeCatalog(string catalogJson, IReadOnlyList<string> titleIds)
    {
        using var document = Json.TryParse(catalogJson);
        if (document is null)
        {
            throw new LauncherToolException("catalog_failed", "The generated GameCatalog.json is not valid JSON.", "Update 3ds2apple-pack; this is a tool mismatch.");
        }
        var games = Json.Array(document.RootElement, "games");
        if (games.Count != titleIds.Count)
        {
            throw new LauncherToolException("catalog_failed", "GameCatalog.json lists " + games.Count.ToString() + " game(s), expected " + titleIds.Count.ToString() + ".", "Rebuild/record the packs, then retry the app install.");
        }
        var normalized = new List<Dictionary<string, object?>>();
        foreach (var game in games)
        {
            var title = Json.String(game, "titleID", "titleId");
            var packFile = Json.String(game, "packFile");
            if (title is null || !titleIds.Contains(title, StringComparer.OrdinalIgnoreCase))
            {
                throw new LauncherToolException("catalog_failed", "GameCatalog.json contains an unexpected title '" + title + "'.", "Remove stale packages and rebuild.");
            }
            var expected = FrameworksDirectory + "/GamePack-" + GameInfoWriter.NormalizeTitleId(title) + ".dylib";
            if (!string.Equals(packFile, expected, StringComparison.OrdinalIgnoreCase))
            {
                throw new LauncherToolException("catalog_failed", "GameCatalog.json entry " + title + " names packFile '" + packFile + "', expected '" + expected + "'.", "Update 3ds2apple-pack or rebuild the package.");
            }
            var copy = new Dictionary<string, object?>();
            foreach (var property in game.EnumerateObject())
            {
                copy[property.Name] = property.Value.Clone();
            }
            copy["titleID"] = GameInfoWriter.NormalizeTitleId(title);
            copy["packFile"] = expected;
            copy["packABIVersion"] = 1;
            if (!copy.ContainsKey("aot"))
            {
                copy["aot"] = true;
            }
            if (!copy.ContainsKey("aotVersion"))
            {
                copy["aotVersion"] = 1;
            }
            if (!copy.ContainsKey("registrationSymbol"))
            {
                copy["registrationSymbol"] = RegistrationSymbol;
            }
            normalized.Add(copy);
        }
        var documentOut = new Dictionary<string, object?>
        {
            ["schemaVersion"] = Json.Long(document.RootElement, "schemaVersion") ?? 2,
            ["games"] = normalized,
        };
        return System.Text.Json.JsonSerializer.Serialize(documentOut, Json.WriteOptions) + "\n";
    }

    private static (string Sha256, long Bytes) HashFile(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        return (Convert.ToHexStringLower(sha.ComputeHash(stream)), stream.Length);
    }
}
