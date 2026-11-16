using System.IO.Compression;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>Result of checking a composed app IPA before it is signed and installed.</summary>
public sealed record ComposedIpaVerification(
    bool Ok,
    string? ErrorCode,
    string? Error,
    string? Fix,
    int GameCount,
    IReadOnlyList<string> TitleIDs)
{
    public static ComposedIpaVerification Pass(int gameCount, IReadOnlyList<string> titleIds) =>
        new(true, null, null, null, gameCount, titleIds);

    public static ComposedIpaVerification Fail(string code, string error, string? fix = null) =>
        new(false, code, error, fix, 0, Array.Empty<string>());

    public string Describe() => Ok
        ? GameCount.ToString() + " game pack(s): " + string.Join(", ", TitleIDs)
        : (ErrorCode ?? "invalid") + ": " + (Error ?? "unknown");
}

/// <summary>
/// Hard gate between composition and signing: a deploy request must never sign or
/// install an app that does not actually contain the selected real GamePacks and a
/// non-empty schema-2 GameCatalog.json. This is the regression guard for the
/// "installed the shell but no game appeared" bug: an empty/bare shell is rejected
/// here even if a caller (or a future composer change) produced one by mistake.
/// </summary>
public static class ComposedIpaVerifier
{
    public const string GameCatalogFileName = "GameCatalog.json";
    public const string FrameworksDirectory = "Frameworks";
    public const string RomsDirectory = "Roms";
    public const int ExpectedCatalogSchemaVersion = 2;

    public static ComposedIpaVerification Verify(string ipaPath, IReadOnlyList<ComposedPack> packs)
    {
        if (string.IsNullOrWhiteSpace(ipaPath) || !File.Exists(ipaPath))
        {
            return ComposedIpaVerification.Fail("composed_ipa_missing",
                "The composed app IPA was not written: " + ipaPath,
                "This is a launcher bug; retry the deploy. If it repeats, copy the launcher log when reporting.");
        }
        if (packs.Count == 0)
        {
            return ComposedIpaVerification.Fail("composed_ipa_no_packs",
                "No real GamePack is built yet, so the app would be an empty shell with no playable game.",
                "Build at least one game first (the Deploy action never installs a bare shell).");
        }

        try
        {
            using var archive = ZipFile.OpenRead(ipaPath);
            var appRoot = FindAppRoot(archive);
            if (appRoot is null)
            {
                return ComposedIpaVerification.Fail("composed_ipa_invalid",
                    "The composed IPA has no Payload/*.app directory.",
                    "This is a launcher bug; retry and report the log.");
            }

            var catalogEntry = archive.Entries.FirstOrDefault(entry =>
                string.Equals(entry.FullName, appRoot + GameCatalogFileName, StringComparison.OrdinalIgnoreCase))
                ?? archive.Entries.FirstOrDefault(entry =>
                    entry.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase)
                    && entry.FullName.EndsWith("/" + GameCatalogFileName, StringComparison.OrdinalIgnoreCase));
            if (catalogEntry is null)
            {
                return ComposedIpaVerification.Fail("composed_ipa_catalog_missing",
                    "The composed IPA has no " + appRoot + GameCatalogFileName + ".",
                    "This is a launcher bug (or a stale shell template); retry and report the log.");
            }

            string catalogJson;
            using (var reader = new StreamReader(catalogEntry.Open()))
            {
                catalogJson = reader.ReadToEnd();
            }
            using var document = Json.TryParse(catalogJson);
            if (document is null)
            {
                return ComposedIpaVerification.Fail("composed_ipa_catalog_invalid",
                    "The composed GameCatalog.json is not valid JSON.",
                    "Rebuild/repack the shell template or retry; the launcher log has the tool output.");
            }

            var schema = Json.Long(document.RootElement, "schemaVersion");
            if (schema != ExpectedCatalogSchemaVersion)
            {
                return ComposedIpaVerification.Fail("composed_ipa_catalog_invalid",
                    "The composed GameCatalog.json has schemaVersion " + (schema?.ToString() ?? "<missing>")
                    + ", expected " + ExpectedCatalogSchemaVersion + ".",
                    "The shell template or pack CLI is the wrong build; rebuild the ROM-free template.");
            }
            var games = Json.Array(document.RootElement, "games");
            if (games.Count == 0)
            {
                return ComposedIpaVerification.Fail("composed_ipa_catalog_empty",
                    "The composed GameCatalog.json lists no games (the phone would show an empty library).",
                    "Build at least one game and deploy again; the bare shell is never installed by Deploy.");
            }
            if (games.Count != packs.Count)
            {
                return ComposedIpaVerification.Fail("composed_ipa_catalog_mismatch",
                    "The composed GameCatalog.json lists " + games.Count + " game(s), but "
                    + packs.Count + " pack(s) were selected.",
                    "This is a launcher bug; retry the deploy and report the log.");
            }

            var titleIds = new List<string>();
            foreach (var pack in packs)
            {
                var title = GameInfoWriter.NormalizeTitleId(pack.TitleID);
                if (titleIds.Contains(title, StringComparer.OrdinalIgnoreCase))
                {
                    return ComposedIpaVerification.Fail("composed_ipa_duplicate",
                        "The selected game list contains " + title + " more than once.",
                        "This is a launcher bug; remove/re-add the duplicate library entry.");
                }
                var expectedPackEntry = appRoot + FrameworksDirectory + "/GamePack-" + title + ".dylib";
                var packEntry = archive.Entries.FirstOrDefault(entry =>
                    string.Equals(entry.FullName, expectedPackEntry, StringComparison.OrdinalIgnoreCase));
                if (packEntry is null)
                {
                    return ComposedIpaVerification.Fail("composed_ipa_pack_missing",
                        "The composed IPA is missing " + expectedPackEntry + " (no playable code for this game).",
                        "Rebuild that game and deploy again; this is the bug that installed an empty shell before.");
                }
                if (packEntry.Length <= 0)
                {
                    return ComposedIpaVerification.Fail("composed_ipa_pack_empty",
                        expectedPackEntry + " is empty in the composed IPA.",
                        "Rebuild that game (the pack file was truncated) and deploy again.");
                }

                var expectedPackFile = FrameworksDirectory + "/GamePack-" + title + ".dylib";
                var catalogGame = games.FirstOrDefault(game =>
                    string.Equals(Json.String(game, "titleID", "titleId"), title, StringComparison.OrdinalIgnoreCase));
                if (catalogGame.ValueKind != JsonValueKind.Object)
                {
                    return ComposedIpaVerification.Fail("composed_ipa_catalog_mismatch",
                        "GameCatalog.json does not list " + title + " even though its pack is in the IPA.",
                        "This is a launcher bug; retry the deploy and report the log.");
                }
                var packFile = Json.String(catalogGame, "packFile");
                if (!string.Equals(packFile, expectedPackFile, StringComparison.OrdinalIgnoreCase))
                {
                    return ComposedIpaVerification.Fail("composed_ipa_catalog_mismatch",
                        "GameCatalog.json entry " + title + " names packFile '" + (packFile ?? "<missing>")
                        + "', expected '" + expectedPackFile + "'.",
                        "This is a launcher bug; retry the deploy and report the log.");
                }
                titleIds.Add(title);
            }

            foreach (var entry in archive.Entries)
            {
                var relative = entry.FullName.StartsWith(appRoot, StringComparison.OrdinalIgnoreCase)
                    ? entry.FullName[appRoot.Length..]
                    : entry.FullName;
                if (relative.StartsWith(RomsDirectory + "/", StringComparison.OrdinalIgnoreCase))
                {
                    return ComposedIpaVerification.Fail("composed_ipa_contains_rom",
                        "The composed IPA contains game data (" + entry.FullName + "); the app must be ROM-free.",
                        "Use the ROM-free shell template; ROM data is pushed separately into Documents.");
                }
            }

            return ComposedIpaVerification.Pass(packs.Count, titleIds);
        }
        catch (InvalidDataException)
        {
            return ComposedIpaVerification.Fail("composed_ipa_invalid",
                "The composed IPA is not a readable zip archive: " + ipaPath,
                "Reinstall the launcher package / rebuild the shell template, then retry.");
        }
        catch (IOException error)
        {
            return ComposedIpaVerification.Fail("composed_ipa_io",
                "Could not read the composed IPA: " + error.Message,
                "Close tools that may hold the file open and retry.");
        }
    }

    /// <summary>`Payload/&lt;name&gt;.app/` of the first app bundle in the IPA; null when absent.</summary>
    public static string? FindAppRoot(ZipArchive archive)
    {
        var appEntry = archive.Entries.FirstOrDefault(entry =>
            entry.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase)
            && entry.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase) > 0);
        if (appEntry is null)
        {
            return null;
        }
        var index = appEntry.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase);
        return appEntry.FullName[..(index + ".app/".Length)];
    }
}
