using System.Text.Json;
using System.Text.Json.Serialization;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>Installed app identity read with <c>devpush app-attr --json</c>.</summary>
public sealed record DeviceAppIdentity(bool Installed, string? ShortVersion = null, string? BuildVersion = null, string? PackageVersion = null)
{
    /// <summary>The launcher shell template is not installed yet.</summary>
    public static readonly DeviceAppIdentity NotInstalled = new(false);

    /// <summary>Short non-identifying description for logs/UI ("package 0.1.6-beta2" / "not installed").</summary>
    public string Describe() => !Installed
        ? "not installed"
        : (string.IsNullOrWhiteSpace(PackageVersion) ? "package unknown" : "package " + PackageVersion);
}

/// <summary>Remote data presence for one game under Documents/Games/&lt;TITLEID&gt;.</summary>
public sealed record DeviceGameData(string TitleID, long? GameRomBytes, long? GameInfoBytes)
{
    public bool Complete => GameRomBytes is > 0 && GameInfoBytes is > 0;
}

/// <summary>
/// A game whose data exists on the phone (Documents/Games/&lt;TITLEID&gt;) but whose TITLEID is
/// not in the launcher library or has no local ROM, so its GamePack cannot be rebuilt for the
/// next app version. The GameRom and saves are user data and are NEVER deleted; only the app
/// entry (GamePack inside the app) would disappear after an overwrite install. The deploy
/// therefore stops and asks for explicit confirmation before updating, and the marker records
/// such a game as data-only.
/// </summary>
public sealed record DeviceOrphanedGame(string TitleID, string? DisplayName, long? GameRomBytes, long? GameInfoBytes)
{
    /// <summary>Short label for logs/UI: "Name (TITLEID)" or the bare title id.</summary>
    public string Describe() => string.IsNullOrWhiteSpace(DisplayName)
        ? TitleID
        : DisplayName + " (" + TitleID + ")";
}

/// <summary>One game's build identity recorded on the phone by the launcher's deploy marker.</summary>
public sealed record DeviceGameBuildRecord(
    [property: JsonPropertyName("titleId")] string TitleID,
    [property: JsonPropertyName("buildCompatVersion")] string BuildCompatVersion,
    [property: JsonPropertyName("buildCompatShort")] string BuildCompatShort,
    [property: JsonPropertyName("packSha256")] string PackSha256,
    [property: JsonPropertyName("romSha256")] string RomSha256,
    [property: JsonPropertyName("romBytes")] long RomBytes,
    [property: JsonPropertyName("dataOnly")] bool DataOnly = false);

/// <summary>
/// <c>Documents/.3ds2apple-deploy.json</c>: what the launcher last installed/pushed on
/// this phone. It is a launcher-only marker (the iOS shell ignores dot files at the
/// Documents root); it is the only way a later deploy can tell whether the app and the
/// game data are already current without reinstalling or re-pushing everything.
/// A missing marker on an existing install is "unknown" and triggers one update to seed it.
/// </summary>
public sealed record DeviceDeployMarker(
    [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
    [property: JsonPropertyName("launcherVersion")] string LauncherVersion,
    [property: JsonPropertyName("appPackageVersion")] string AppPackageVersion,
    [property: JsonPropertyName("appShortVersion")] string AppShortVersion,
    [property: JsonPropertyName("appBuild")] int AppBuild,
    [property: JsonPropertyName("updatedAt")] string UpdatedAt,
    [property: JsonPropertyName("games")] IReadOnlyList<DeviceGameBuildRecord> Games)
{
    public const int CurrentSchemaVersion = 1;

    /// <summary>Marker path relative to the app data container (Documents is exposed by AFC).</summary>
    public const string RemotePath = "Documents/.3ds2apple-deploy.json";

    public DeviceGameBuildRecord? Find(string titleId) =>
        Games.FirstOrDefault(game => string.Equals(game.TitleID, titleId, StringComparison.OrdinalIgnoreCase));

    /// <summary>Serialize with the shared camelCase launcher JSON options (newline-terminated).</summary>
    public string ToJson() => JsonSerializer.Serialize(this, Json.WriteOptions) + "\n";

    /// <summary>Parse a remote marker; null when the content is missing or not a marker.</summary>
    public static DeviceDeployMarker? Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            return null;
        }
        try
        {
            var marker = JsonSerializer.Deserialize<DeviceDeployMarker>(json, Json.ReadOptions);
            if (marker is null || marker.SchemaVersion != CurrentSchemaVersion)
            {
                return null;
            }
            return marker with { Games = marker.Games ?? Array.Empty<DeviceGameBuildRecord>() };
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// Build the marker written after a successful deploy. Games that are installed but no
    /// longer in the library keep their previous record so a later deploy does not lose them.
    /// </summary>
    public static DeviceDeployMarker Create(
        string launcherVersion,
        string appPackageVersion,
        string appShortVersion,
        int appBuild,
        IReadOnlyList<LibraryEntry> installedEntries,
        DeviceDeployMarker? previous,
        IReadOnlyList<DeviceOrphanedGame>? dataOnlyGames = null)
    {
        var records = new List<DeviceGameBuildRecord>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in installedEntries)
        {
            var record = BuildRecord(entry);
            if (record is null || !seen.Add(record.TitleID))
            {
                continue;
            }
            records.Add(record);
        }
        // Phone-only games have no GamePack in the app: record them as data-only so a future
        // deploy/UI knows their Documents data is intentionally kept without an app entry.
        if (dataOnlyGames is not null)
        {
            foreach (var game in dataOnlyGames)
            {
                var titleId = GameInfoWriter.NormalizeTitleId(game.TitleID);
                if (!seen.Add(titleId))
                {
                    continue;
                }
                records.Add(new DeviceGameBuildRecord(
                    titleId,
                    string.Empty,
                    string.Empty,
                    string.Empty,
                    string.Empty,
                    game.GameRomBytes ?? 0,
                    DataOnly: true));
            }
        }
        if (previous is not null)
        {
            foreach (var record in previous.Games)
            {
                if (seen.Add(record.TitleID))
                {
                    records.Add(record);
                }
            }
        }
        return new DeviceDeployMarker(
            CurrentSchemaVersion,
            launcherVersion,
            appPackageVersion,
            appShortVersion,
            appBuild,
            DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
            records);
    }

    /// <summary>Build identity recorded for one library entry, or null when it was never built.</summary>
    public static DeviceGameBuildRecord? BuildRecord(LibraryEntry entry)
    {
        var artifact = entry.Build;
        if (artifact is null || string.IsNullOrWhiteSpace(artifact.BuildCompatVersion))
        {
            return null;
        }
        var packSha = !string.IsNullOrWhiteSpace(artifact.PackSha256)
            ? artifact.PackSha256
            : entry.Pack?.Sha256 ?? string.Empty;
        return new DeviceGameBuildRecord(
            GameInfoWriter.NormalizeTitleId(entry.TitleID),
            artifact.BuildCompatVersion,
            string.IsNullOrWhiteSpace(artifact.BuildCompatShort)
                ? BuildPipeline.BuildCompatibility.ShortLabel(artifact.BuildCompatVersion)
                : artifact.BuildCompatShort,
            packSha,
            artifact.RomSha256,
            artifact.RomBytes > 0 ? artifact.RomBytes : 0);
    }
}

/// <summary>Everything read from the phone before a deploy decides what to do.</summary>
public sealed record DeviceDeploySnapshot(
    DeviceAppIdentity App,
    IReadOnlyList<string> InstalledGameTitleIds,
    IReadOnlyDictionary<string, DeviceGameData> GameData,
    DeviceDeployMarker? Marker)
{
    public DeviceGameData? DataFor(string titleId) =>
        GameData.TryGetValue(titleId, out var data) ? data : null;
}

/// <summary>Result of comparing the installed app with the launcher's shell template.</summary>
public enum DeviceAppState
{
    NotInstalled,
    Current,
    VersionMismatch,
    VersionUnknown,
}

/// <summary>What one Deploy run has to do for the connected phone.</summary>
public enum DeviceDeployMode
{
    /// <summary>Nothing is installed: compose, sign, install and push the selected games.</summary>
    FullInstall,

    /// <summary>The installed app version/build identity is outdated: recompose a union IPA and overwrite-install.</summary>
    Reinstall,

    /// <summary>The app is current; only missing/outdated game data is pushed.</summary>
    PushOnly,

    /// <summary>The app and every selected game's data are current: no install, no push.</summary>
    UpToDate,
}

/// <summary>The device-aware deploy decision (pure; produced by <see cref="DeviceDeployPlanner"/>).</summary>
public sealed record DeviceDeployDecision(
    DeviceDeployMode Mode,
    DeviceAppState AppState,
    IReadOnlyList<LibraryEntry> IpaGames,
    IReadOnlyList<LibraryEntry> PushGames,
    IReadOnlyList<string> Notes,
    IReadOnlyList<DeviceOrphanedGame> OrphanedGames)
{
    /// <summary>True when an overwrite install would drop these games' app entries.</summary>
    public bool HasOrphanedGames => OrphanedGames.Count > 0;

    /// <summary>Selected games whose data is already current (nothing to push).</summary>
    public bool SkipInstall => Mode is DeviceDeployMode.PushOnly or DeviceDeployMode.UpToDate;

    public bool SkipPush => PushGames.Count == 0;
}

/// <summary>Compact device-aware deploy evidence attached to <see cref="DeployOutcome"/>.</summary>
public sealed record DeployDeviceSummary(
    DeviceDeployMode Mode,
    int IpaGameCount,
    int PushedGameCount,
    string DevicePackageVersion,
    string ExpectedPackageVersion);

/// <summary>
/// Pure decision table for the device-aware incremental deploy. It never touches the
/// phone or the file system: the orchestrator feeds it one <see cref="DeviceDeploySnapshot"/>
/// plus the library entries (with their recorded build identities) and it explains in
/// <see cref="DeviceDeployDecision.Notes"/> why an install or a push is needed.
/// </summary>
/// <remarks>
/// Rules (see .internal/round-016-beta2.md section 5):
/// - app not installed -> full flow (compose + install + push the selected games);
/// - app package version differs from the launcher shell (or is unknown) -> recompose an IPA
///   with the union of the installed games' GamePacks and the selected ones, overwrite-install
///   (Documents/saves are preserved by the overwrite install), then push missing data;
/// - marker missing on an existing install -> unknown, so update once (union with every built
///   library game) and seed the marker;
/// - app current and a GamePack build identity changed -> recompose + overwrite-install;
/// - app current and only data missing/outdated -> push only;
/// - everything current -> no-op ("already up to date").
/// The app is never uninstalled (a clean uninstall would clear Documents/saves).
/// </remarks>
public static class DeviceDeployPlanner
{
    /// <summary>Compare the installed app package version with the launcher shell version.</summary>
    public static DeviceAppState EvaluateApp(DeviceDeploySnapshot snapshot, string expectedPackageVersion)
    {
        if (!snapshot.App.Installed)
        {
            return DeviceAppState.NotInstalled;
        }
        var installed = snapshot.App.PackageVersion;
        if (string.IsNullOrWhiteSpace(installed))
        {
            // An old shell without ThreeDS2ApplePackageVersion: unknown, update once.
            return DeviceAppState.VersionUnknown;
        }
        if (string.IsNullOrWhiteSpace(expectedPackageVersion))
        {
            return DeviceAppState.VersionUnknown;
        }
        return string.Equals(installed.Trim(), expectedPackageVersion.Trim(), StringComparison.OrdinalIgnoreCase)
            ? DeviceAppState.Current
            : DeviceAppState.VersionMismatch;
    }

    /// <summary>Compare the recorded build identity of one GamePack with the device marker.</summary>
    public static bool BuildIdentityCurrent(DeviceDeployMarker? marker, LibraryEntry entry)
    {
        if (marker is null)
        {
            return false;
        }
        var record = marker.Find(entry.TitleID);
        var artifact = entry.Build;
        if (record is null || artifact is null || string.IsNullOrWhiteSpace(artifact.BuildCompatVersion))
        {
            return false;
        }
        if (!string.Equals(record.BuildCompatVersion, artifact.BuildCompatVersion, StringComparison.Ordinal))
        {
            return false;
        }
        if (!string.Equals(record.RomSha256, artifact.RomSha256, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        var packSha = !string.IsNullOrWhiteSpace(artifact.PackSha256)
            ? artifact.PackSha256
            : entry.Pack?.Sha256 ?? string.Empty;
        return string.IsNullOrWhiteSpace(record.PackSha256)
               || string.IsNullOrWhiteSpace(packSha)
               || string.Equals(record.PackSha256, packSha, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// True when Documents/Games/&lt;TITLEID&gt;/GameRom.cci + GameInfo.json are present with the
    /// expected ROM size and the marker records the same ROM SHA-256 as the current build.
    /// Only sizes are read from the phone (a full remote hash of a multi-GB ROM is not worth it;
    /// the push itself verifies the SHA-256 it writes).
    /// </summary>
    public static bool IsDataCurrent(DeviceDeploySnapshot snapshot, LibraryEntry entry, long? localRomBytes)
    {
        var data = snapshot.DataFor(entry.TitleID);
        if (data is null || !data.Complete)
        {
            return false;
        }
        if (localRomBytes is { } bytes && data.GameRomBytes != bytes)
        {
            return false;
        }
        var record = snapshot.Marker?.Find(entry.TitleID);
        if (record is null)
        {
            return false;
        }
        var romSha = entry.Build?.RomSha256;
        if (string.IsNullOrWhiteSpace(romSha) || !string.Equals(record.RomSha256, romSha, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        return record.RomBytes <= 0 || localRomBytes is null || record.RomBytes == localRomBytes;
    }

    /// <summary>
    /// The authoritative decision. Call it before the build to plan which extra GamePacks an
    /// app update must keep, and again after the build for the final install/push decision.
    /// </summary>
    public static DeviceDeployDecision Decide(
        DeviceDeploySnapshot snapshot,
        string expectedAppPackageVersion,
        IReadOnlyList<LibraryEntry> selected,
        IReadOnlyList<LibraryEntry> library,
        Func<string, long?> localRomBytes,
        bool markerMissingIncludesAllBuiltGames = true)
    {
        var notes = new List<string>();
        var appState = EvaluateApp(snapshot, expectedAppPackageVersion);
        var selectedIds = new HashSet<string>(selected.Select(entry => GameInfoWriter.NormalizeTitleId(entry.TitleID)), StringComparer.OrdinalIgnoreCase);
        var installedIds = CollectInstalledIds(snapshot);
        // Phone data whose TITLEID cannot be built locally: an overwrite install would remove
        // its app entry while keeping the Documents data. The orchestrator blocks the update
        // unless the user explicitly confirms (never deletes the data).
        var orphaned = FindOrphanedInstalledGames(snapshot, library, titleId => localRomBytes(titleId) is not null);
        if (orphaned.Count > 0)
        {
            notes.Add(orphaned.Count + " phone-only game(s) are not in the launcher library: "
                      + string.Join(", ", orphaned.Select(game => game.TitleID))
                      + " (data stays in Documents; an app update would remove their app entries)");
        }

        if (appState == DeviceAppState.NotInstalled)
        {
            notes.Add("the app is not installed on the phone: full compose + install + push");
            return new DeviceDeployDecision(DeviceDeployMode.FullInstall, appState, selected.ToList(), selected.ToList(), notes, orphaned);
        }

        var union = BuildIpaGames(selected, installedIds, library, snapshot.Marker, markerMissingIncludesAllBuiltGames, notes);

        var install = false;
        switch (appState)
        {
            case DeviceAppState.VersionMismatch:
                install = true;
                notes.Add("the installed app package " + (snapshot.App.PackageVersion ?? "?") + " differs from the launcher shell " + expectedAppPackageVersion);
                break;
            case DeviceAppState.VersionUnknown:
                install = true;
                notes.Add("the installed app does not report ThreeDS2ApplePackageVersion: updating once to seed the identity");
                break;
        }
        if (snapshot.Marker is null)
        {
            install = true;
            notes.Add("no deploy marker on the phone (unknown install state): updating once to seed it");
        }
        foreach (var entry in union)
        {
            if (entry.Build is null || string.IsNullOrWhiteSpace(entry.Build.BuildCompatVersion))
            {
                // A GamePack built before the build-cache era has no recorded recipe, so the
                // marker cannot describe it: keep it in the app but do not force an install
                // on every deploy (it is rebuilt once when selected, then it gets a record).
                if (!selectedIds.Contains(GameInfoWriter.NormalizeTitleId(entry.TitleID)))
                {
                    notes.Add("the build identity of installed game " + GameInfoWriter.NormalizeTitleId(entry.TitleID) + " is unknown; keeping its current GamePack");
                }
                continue;
            }
            if (!BuildIdentityCurrent(snapshot.Marker, entry))
            {
                install = true;
                notes.Add("GamePack build identity is outdated for " + GameInfoWriter.NormalizeTitleId(entry.TitleID) + " (" + DisplayName(entry) + ")");
            }
        }

        var push = selected.Where(entry => !IsDataCurrent(snapshot, entry, localRomBytes(entry.TitleID))).ToList();
        if (push.Count > 0 && !install)
        {
            notes.Add("the app is current; " + push.Count + " selected game(s) need data pushed");
        }
        if (!install && push.Count == 0)
        {
            notes.Add("the app and every selected game's data are already current: nothing to do");
            return new DeviceDeployDecision(DeviceDeployMode.UpToDate, appState, Array.Empty<LibraryEntry>(), Array.Empty<LibraryEntry>(), notes, orphaned);
        }
        if (!install)
        {
            return new DeviceDeployDecision(DeviceDeployMode.PushOnly, appState, Array.Empty<LibraryEntry>(), push, notes, orphaned);
        }
        return new DeviceDeployDecision(DeviceDeployMode.Reinstall, appState, union, push, notes, orphaned);
    }

    /// <summary>Every game title id the phone reports (Documents/Games dirs plus marker records).</summary>
    public static IReadOnlyList<string> CollectInstalledIds(DeviceDeploySnapshot snapshot)
    {
        var ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var id in snapshot.InstalledGameTitleIds)
        {
            if (!string.IsNullOrWhiteSpace(id))
            {
                ids.Add(GameInfoWriter.NormalizeTitleId(id));
            }
        }
        if (snapshot.Marker is not null)
        {
            foreach (var record in snapshot.Marker.Games)
            {
                if (!string.IsNullOrWhiteSpace(record.TitleID))
                {
                    ids.Add(GameInfoWriter.NormalizeTitleId(record.TitleID));
                }
            }
        }
        return ids.ToList();
    }

    /// <summary>
    /// Games the phone has real data for (a GameRom.cci under Documents/Games/TITLEID) but the
    /// launcher cannot rebuild a GamePack for: no library entry, or the library entry has no
    /// ROM file any more. Pure: the caller supplies the "local ROM exists" probe.
    /// These are the games an overwrite install would silently drop from the app; the deploy
    /// blocks on them unless the user explicitly confirms (their data is never deleted).
    /// </summary>
    public static IReadOnlyList<DeviceOrphanedGame> FindOrphanedInstalledGames(
        DeviceDeploySnapshot snapshot,
        IReadOnlyList<LibraryEntry> library,
        Func<string, bool> hasLocalRom)
    {
        var orphans = new List<DeviceOrphanedGame>();
        foreach (var titleId in CollectInstalledIds(snapshot))
        {
            var data = snapshot.DataFor(titleId);
            if (data is null || data.GameRomBytes is not > 0)
            {
                // No real data on the phone for this id (empty directory or marker-only entry).
                continue;
            }
            var entry = library.FirstOrDefault(item => string.Equals(item.TitleID, titleId, StringComparison.OrdinalIgnoreCase));
            if (entry is not null && hasLocalRom(titleId))
            {
                continue;
            }
            orphans.Add(new DeviceOrphanedGame(
                GameInfoWriter.NormalizeTitleId(titleId),
                entry is null ? null : DisplayName(entry),
                data.GameRomBytes,
                data.GameInfoBytes));
        }
        return orphans;
    }

    /// <summary>
    /// Games whose GamePack must stay inside the app when it is recomposed: the selected games
    /// plus every game the phone already has. A missing marker is unknown state, so all built
    /// library games are kept too (an update must never silently drop a game).
    /// </summary>
    public static List<LibraryEntry> BuildIpaGames(
        IReadOnlyList<LibraryEntry> selected,
        IReadOnlyList<string> installedIds,
        IReadOnlyList<LibraryEntry> library,
        DeviceDeployMarker? marker,
        bool markerMissingIncludesAllBuiltGames,
        List<string> notes)
    {
        var games = new List<LibraryEntry>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in selected)
        {
            if (seen.Add(GameInfoWriter.NormalizeTitleId(entry.TitleID)))
            {
                games.Add(entry);
            }
        }
        foreach (var id in installedIds)
        {
            if (seen.Contains(id))
            {
                continue;
            }
            var entry = library.FirstOrDefault(item => string.Equals(item.TitleID, id, StringComparison.OrdinalIgnoreCase));
            if (entry is null)
            {
                notes.Add("phone-only game " + id + " is not in the launcher library; keeping its data without a GamePack (data-only)");
                continue;
            }
            seen.Add(id);
            games.Add(entry);
        }
        if (marker is null && markerMissingIncludesAllBuiltGames)
        {
            foreach (var entry in library)
            {
                if (entry.Pack is { IsPlaceholder: false } && seen.Add(GameInfoWriter.NormalizeTitleId(entry.TitleID)))
                {
                    games.Add(entry);
                }
            }
        }
        return games;
    }

    private static string DisplayName(LibraryEntry entry)
    {
        if (!string.IsNullOrWhiteSpace(entry.DisplayName))
        {
            return entry.DisplayName;
        }
        return string.IsNullOrWhiteSpace(entry.DisplayNames.Values.FirstOrDefault())
            ? GameInfoWriter.NormalizeTitleId(entry.TitleID)
            : entry.DisplayNames.Values.First();
    }
}
