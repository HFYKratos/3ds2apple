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
///  - Documents only carries the user's GameRom.cci plus this manifest;
///  - the optional pack{} block is informational metadata (bundle-relative path,
///    size, hash) and must not be resolved as a Documents file;
///  - the shell verifies the ROM size/sha256 when present and otherwise shows
///    "Data missing" until the push completes.
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
    [property: JsonPropertyName("notes")] string? Notes = null);

/// <summary>Builds and writes the pushed GameInfo.json (single writer for the launcher).</summary>
public static class GameInfoWriter
{
    public const string GamePackFileName = "GamePack.dylib";
    public const string GameRomFileName = "GameRom.cci";
    public const string GameInfoFileName = "GameInfo.json";
    public const string FrameworksDirectory = "Frameworks";

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
        string? notes = null)
    {
        var normalizedTitle = NormalizeTitleId(titleId);
        ValidateSha256(romSha256, nameof(romSha256));
        if (romBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(romBytes), "GameRom size must be positive.");
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
            string.IsNullOrWhiteSpace(displayName) ? normalizedTitle : displayName,
            string.IsNullOrWhiteSpace(productCode) ? null : productCode,
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
            string.IsNullOrWhiteSpace(notes) ? null : notes);
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
}
