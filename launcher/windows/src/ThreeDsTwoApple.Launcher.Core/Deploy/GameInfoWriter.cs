using System.Text.Json.Serialization;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>Pack record in the pushed GameInfo.json (informational: the pack itself lives in the app bundle).</summary>
public sealed record GameInfoPack(
    [property: JsonPropertyName("file")] string File,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("sha256")] string Sha256);

/// <summary>ROM record exactly as the iOS shell expects it in GameInfo.json.</summary>
public sealed record GameInfoRom(
    [property: JsonPropertyName("file")] string File,
    [property: JsonPropertyName("size")] long Size,
    [property: JsonPropertyName("sha256")] string Sha256);

/// <summary>
/// <c>Documents/Games/&lt;TITLEID&gt;/GameInfo.json</c>, schemaVersion 1.
/// </summary>
/// <remarks>
/// Split agreed with the shell task after the architecture correction:
///  - the shell loads GamePack.dylib from the app bundle through the bundle
///    GameCatalog.json (signed as part of the app IPA);
///  - Documents only carries the user's GameRom.cci, an optional cover.png and
///    this manifest;
///  - the optional pack{} block is informational metadata (bundle-relative path,
///    size, hash) and must not be resolved as a Documents file;
///  - the shell verifies the ROM size/sha256 when present and otherwise shows
///    "Data missing" until the push completes.
///
/// The launcher already reads the ROM's SMDH while importing (icon, localized
/// titles, publisher, region lockout). So the pushed manifest carries that base
/// metadata too, and the phone's library card needs no ROM parsing at all:
///  - <see cref="DisplayName"/> is the title for the launcher's current UI
///    language (GameNames.Resolve: zh-Hans/en, then the pack CLI's default);
///  - <see cref="DisplayNames"/> keeps every localized SMDH title as written
///    (original languages preserved) so the shell can re-pick for its own UI;
///  - <see cref="Publisher"/>, <see cref="Region"/> and <see cref="Cover"/> are
///    optional additive fields (old shells ignore them, old launchers omit them);
///  - <see cref="Cover"/> is the file name pushed next to the manifest
///    (<c>cover.png</c>), never an absolute path and never committed to git;
///  - <see cref="GameInfoRom.Size"/> is the real size of the pushed data file
///    (the shell cross-checks it while scanning), <see cref="PushedAt"/> and
///    <see cref="LauncherVersion"/> record the push provenance.
/// Unknown fields are ignored by the shell, so launcher additions stay safe.
/// </remarks>
public sealed record GameInfoDocument(
    [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
    [property: JsonPropertyName("titleID")] string TitleID,
    [property: JsonPropertyName("displayName")] string DisplayName,
    [property: JsonPropertyName("productCode")] string? ProductCode,
    [property: JsonPropertyName("aot")] bool Aot,
    [property: JsonPropertyName("aotVersion")] int AotVersion,
    [property: JsonPropertyName("packABIVersion")] int PackAbiVersion,
    [property: JsonPropertyName("registrationSymbol")] string RegistrationSymbol,
    [property: JsonPropertyName("saveNamespace")] string SaveNamespace,
    [property: JsonPropertyName("pack")] GameInfoPack? Pack,
    [property: JsonPropertyName("packBundled")] bool? PackBundled,
    [property: JsonPropertyName("rom")] GameInfoRom Rom,
    [property: JsonPropertyName("launcherVersion")] string LauncherVersion,
    [property: JsonPropertyName("pushedAt")] string PushedAt,
    [property: JsonPropertyName("notes")] string? Notes = null,
    [property: JsonPropertyName("displayNames")] IReadOnlyDictionary<string, string>? DisplayNames = null,
    [property: JsonPropertyName("publisher")] string? Publisher = null,
    [property: JsonPropertyName("region")] string? Region = null,
    [property: JsonPropertyName("cover")] string? Cover = null);

/// <summary>Builds and writes the pushed GameInfo.json (single writer for the launcher).</summary>
public static class GameInfoWriter
{
    public const string GamePackFileName = "GamePack.dylib";
    public const string GameRomFileName = "GameRom.cci";
    public const string GameInfoFileName = "GameInfo.json";
    public const string FrameworksDirectory = "Frameworks";

    /// <summary>Cover image pushed next to the ROM (the SMDH icon or a user cover).</summary>
    public const string CoverFileName = "cover.png";

    public static GameInfoDocument Build(
        string titleId,
        string displayName,
        string? productCode,
        int aotVersion,
        string? packSha256,
        long? packBytes,
        string romSha256,
        long romBytes,
        DateTimeOffset pushedAt,
        string? notes = null,
        IReadOnlyDictionary<string, string>? displayNames = null,
        string? publisher = null,
        string? region = null,
        string? cover = null)
    {
        var normalizedTitle = NormalizeTitleId(titleId);
        ValidateSha256(romSha256, nameof(romSha256));
        if (romBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(romBytes), "GameRom size must be positive.");
        }
        if (string.IsNullOrWhiteSpace(displayName))
        {
            displayName = normalizedTitle;
        }
        else
        {
            displayName = displayName.Trim();
        }
        GameInfoPack? pack = null;
        if (!string.IsNullOrWhiteSpace(packSha256))
        {
            ValidateSha256(packSha256, nameof(packSha256));
            if (packBytes is not > 0)
            {
                throw new ArgumentOutOfRangeException(nameof(packBytes), "GamePack size must be positive when a pack hash is recorded.");
            }
            pack = new GameInfoPack(FrameworksDirectory + "/GamePack-" + normalizedTitle + ".dylib", packBytes.Value, packSha256);
        }
        return new GameInfoDocument(
            LauncherInfo.GameInfoSchemaVersion,
            normalizedTitle,
            displayName,
            TrimOptional(productCode, nameof(productCode), 64),
            true,
            Math.Max(1, aotVersion),
            LauncherInfo.GamePackAbiVersion,
            LauncherInfo.RegistrationSymbol,
            normalizedTitle,
            pack,
            pack is null ? null : true,
            new GameInfoRom(GameRomFileName, romBytes, romSha256),
            LauncherInfo.GameInfoLauncherVersion,
            pushedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'"),
            TrimOptional(notes, nameof(notes), 500),
            NormalizeDisplayNames(displayNames),
            TrimOptional(publisher, nameof(publisher), 120),
            TrimOptional(region, nameof(region), 40),
            NormalizeCover(cover));
    }

    public static async Task WriteAsync(string path, GameInfoDocument document, CancellationToken cancellationToken = default)
    {
        var directory = Path.GetDirectoryName(Path.GetFullPath(path));
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        var json = System.Text.Json.JsonSerializer.Serialize(document, Json.WriteOptions) + "\n";
        await File.WriteAllTextAsync(path, json, cancellationToken).ConfigureAwait(false);
    }

    public static async Task<GameInfoDocument?> ReadAsync(string path, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path))
        {
            return null;
        }
        var text = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        try
        {
            return System.Text.Json.JsonSerializer.Deserialize<GameInfoDocument>(text, Json.ReadOptions);
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
    }

    public static string NormalizeTitleId(string titleId)
    {
        var normalized = (titleId ?? string.Empty).Trim().ToUpperInvariant();
        if (normalized.Length != 16 || normalized.Any(c => !Uri.IsHexDigit(c)))
        {
            throw new ArgumentException("titleID must be 16 hex digits, got '" + titleId + "'.", nameof(titleId));
        }
        return normalized;
    }

    public static void ValidateSha256(string sha256, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(sha256) || sha256.Length != 64 || sha256.Any(c => !Uri.IsHexDigit(c)))
        {
            throw new ArgumentException(parameterName + " must be a 64-character hex SHA-256.", parameterName);
        }
    }

    /// <summary>Trim an optional single-line metadata string; null/blank becomes null.</summary>
    private static string? TrimOptional(string? value, string parameterName, int maxLength)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }
        var trimmed = value.Trim();
        ValidateSingleLine(trimmed, parameterName, maxLength);
        return trimmed;
    }

    /// <summary>
    /// Normalize the SMDH localized-title map: trimmed keys/values, sorted by
    /// language key for deterministic output, empty entries dropped. The values
    /// are game names, so control characters and over-long text are rejected
    /// rather than written into a shell manifest.
    /// </summary>
    private static IReadOnlyDictionary<string, string>? NormalizeDisplayNames(IReadOnlyDictionary<string, string>? displayNames)
    {
        if (displayNames is null || displayNames.Count == 0)
        {
            return null;
        }
        var normalized = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var pair in displayNames)
        {
            var key = (pair.Key ?? string.Empty).Trim();
            var value = (pair.Value ?? string.Empty).Trim();
            if (key.Length == 0 || value.Length == 0)
            {
                continue;
            }
            if (key.Length > 20 || key.Any(c => c is ' ' || char.IsControl(c)))
            {
                throw new ArgumentException("displayNames key must be a single BCP-47-like language tag, got '" + key + "'.", nameof(displayNames));
            }
            ValidateSingleLine(value, "displayNames[" + key + "]", 120);
            normalized[key] = value;
        }
        if (normalized.Count > 32)
        {
            throw new ArgumentException("displayNames must hold at most 32 languages.", nameof(displayNames));
        }
        return normalized.Count == 0 ? null : normalized;
    }

    /// <summary>The cover is a fixed file name pushed next to the ROM, never a path.</summary>
    private static string? NormalizeCover(string? cover)
    {
        if (string.IsNullOrWhiteSpace(cover))
        {
            return null;
        }
        var trimmed = cover.Trim();
        if (!string.Equals(trimmed, CoverFileName, StringComparison.Ordinal))
        {
            throw new ArgumentException("cover must be '" + CoverFileName + "' (got '" + cover + "').", nameof(cover));
        }
        return CoverFileName;
    }

    private static void ValidateSingleLine(string value, string parameterName, int maxLength)
    {
        if (value.Any(c => char.IsControl(c)))
        {
            throw new ArgumentException(parameterName + " must not contain control characters.", parameterName);
        }
        if (value.Length > maxLength)
        {
            throw new ArgumentException(parameterName + " must be at most " + maxLength + " characters.", parameterName);
        }
    }
}
