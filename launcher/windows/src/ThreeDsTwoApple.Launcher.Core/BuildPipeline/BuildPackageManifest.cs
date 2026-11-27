using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Platform;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Where an imported .32a's build cache entry ended up.</summary>
public enum BuildCacheImportStatus
{
    /// <summary>The package manifest matched the current recipe; the GamePack can be reused.</summary>
    Recorded,

    /// <summary>Manifest exists but was built with another toolchain/build recipe; Deploy must recompile.</summary>
    Mismatch,

    /// <summary>The package has no embedded game data, so no safe cache record can be written.</summary>
    NoGameData,

    /// <summary>No usable manifest (old CLI/malformed package); Deploy will recompile.</summary>
    Missing,
}

/// <summary>Manifest v1 fields read from a .32a (builder/pack/src/builds.rs).</summary>
public sealed record BuildPackageManifestInfo(
    string Format,
    int SchemaVersion,
    string TitleID,
    string DisplayName,
    string ProductCode,
    int AotVersion,
    string AppVersion,
    DateTimeOffset BuiltAt,
    string Platform,
    string ClangVersion,
    string LlvmVersion,
    string OptLevel,
    bool Lto,
    bool FastMath,
    string PackFile,
    long PackBytes,
    string PackSha256,
    int PackAbiVersion,
    bool RomIncluded,
    string? RomSha256,
    long? RomBytes,
    string SourceLauncherVersion)
{
    public string BuildOptionsMarker =>
        "opt=" + OptLevel + ";lto=" + (Lto ? 1 : 0) + ";fastmath=" + (FastMath ? 1 : 0);
}

/// <summary>
/// Reads and validates the manifest.json inside a .32a ZIP and, when the package
/// was built with the current launcher's recipe/toolchain, turns it into the
/// LibraryEntry.Build cache record (0.2.2-beta6). The pack CLI is still the only
/// writer/parser of the format; this reader never re-implements the package layout:
/// it reads one JSON entry and stores the recorded build identity.
/// </summary>
public static class BuildPackageManifestReader
{
    public const string ManifestEntryName = "manifest.json";
    public const string BuildFormat = "3ds2apple-build";
    public const int SupportedSchemaVersion = 1;
    private const int MaxManifestBytes = 1_048_576;

    /// <summary>True for a 64 lower-case hex SHA-256 (the builder's canonical form).</summary>
    public static bool IsSha256(string? value) =>
        !string.IsNullOrWhiteSpace(value)
        && value.Length == 64
        && value.All(character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    /// <summary>
    /// Read the manifest from the .32a ZIP. Returns false with a readable reason for
    /// old/malformed packages; callers fall back to "no build cache recorded".
    /// </summary>
    public static bool TryRead(string packagePath, out BuildPackageManifestInfo? manifest, out string? error)
    {
        manifest = null;
        error = null;
        try
        {
            using var archive = ZipFile.OpenRead(packagePath);
            var entry = archive.Entries.FirstOrDefault(candidate =>
                string.Equals(candidate.FullName, ManifestEntryName, StringComparison.OrdinalIgnoreCase));
            if (entry is null)
            {
                error = "the .32a has no " + ManifestEntryName + " (older CLI); the build cache cannot be recorded";
                return false;
            }
            if (entry.Length <= 0 || entry.Length > MaxManifestBytes)
            {
                error = "the .32a " + ManifestEntryName + " has an unsupported size (" + entry.Length + " bytes)";
                return false;
            }
            string text;
            using (var stream = entry.Open())
            using (var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true))
            {
                text = reader.ReadToEnd();
            }
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
            {
                error = "the .32a " + ManifestEntryName + " is not a JSON object";
                return false;
            }
            var format = Text(root, "format");
            var schemaVersion = Integer(root, "schemaVersion");
            if (!string.Equals(format, BuildFormat, StringComparison.Ordinal))
            {
                error = "unsupported build manifest format " + (format ?? "(missing)");
                return false;
            }
            if (schemaVersion != SupportedSchemaVersion)
            {
                error = "unsupported build manifest schemaVersion " + (schemaVersion?.ToString() ?? "(missing)");
                return false;
            }
            var titleId = NormalizeTitleId(Text(root, "titleID"));
            if (titleId.Length == 0)
            {
                error = "the build manifest has no titleID";
                return false;
            }
            var pack = Object(root, "pack");
            var packFile = Text(pack, "file") ?? string.Empty;
            var packBytes = Long(pack, "bytes") ?? 0;
            var packSha = Text(pack, "sha256");
            var packAbi = Integer(pack, "abiVersion") ?? 0;
            if (packBytes <= 0 || !IsSha256(packSha))
            {
                error = "the build manifest pack reference is incomplete";
                return false;
            }
            var buildOptions = Object(root, "buildOptions");
            var optLevel = Text(buildOptions, "optLevel") ?? string.Empty;
            if (optLevel is not ("O1" or "O2" or "O3" or "Oz"))
            {
                error = "the build manifest buildOptions.optLevel is invalid";
                return false;
            }
            var builtAtText = Text(root, "builtAt");
            if (!DateTimeOffset.TryParse(
                    builtAtText,
                    System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
                    out var builtAt))
            {
                error = "the build manifest builtAt timestamp is invalid";
                return false;
            }
            var toolchain = Object(root, "toolchain");
            var rom = Object(root, "rom");
            var sourceLauncher = Object(root, "sourceLauncher");
            manifest = new BuildPackageManifestInfo(
                format!,
                schemaVersion!.Value,
                titleId,
                Text(root, "displayName") ?? titleId,
                Text(root, "productCode") ?? string.Empty,
                Integer(root, "aotVersion") ?? 0,
                Text(root, "appVersion") ?? string.Empty,
                builtAt,
                Text(root, "platform") ?? string.Empty,
                Text(toolchain, "clang") ?? string.Empty,
                Text(toolchain, "llvm") ?? string.Empty,
                optLevel,
                Boolean(buildOptions, "lto") ?? false,
                Boolean(buildOptions, "fastMath") ?? false,
                packFile,
                packBytes,
                packSha!,
                packAbi,
                Boolean(rom, "included") ?? false,
                Text(rom, "sha256"),
                Long(rom, "bytes"),
                Text(sourceLauncher, "version") ?? string.Empty);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException
                                           or JsonException or NotSupportedException or System.Security.SecurityException)
        {
            error = "the .32a manifest could not be read: " + exception.Message;
            return false;
        }
    }

    /// <summary>
    /// Build the LibraryEntry.Build record for an imported .32a. Mirrors
    /// <see cref="BuildArtifacts.CaptureAsync"/> so the same BuildCachePolicy decides
    /// reuse vs recompile. Only fields the pack CLI records in manifest v1 are
    /// compared; recompiler/shim/catalogue ABI are launcher constants, and a missing
    /// toolchain marker (old CLI) is treated as a mismatch rather than assumed.
    /// </summary>
    public static bool TryCreateArtifact(
        string packagePath,
        BuildCompatibility current,
        out BuildArtifact? artifact,
        out BuildCacheImportStatus status,
        out string? detail)
    {
        artifact = null;
        status = BuildCacheImportStatus.Missing;
        detail = null;
        if (!TryRead(packagePath, out var manifest, out var error) || manifest is null)
        {
            detail = error;
            return false;
        }
        if (!manifest.RomIncluded || !IsSha256(manifest.RomSha256) || manifest.RomBytes is not > 0)
        {
            status = BuildCacheImportStatus.NoGameData;
            detail = "the .32a does not embed the game data, so a ROM hash cannot be recorded";
            return false;
        }
        if (manifest.PackAbiVersion != current.GamePackAbi)
        {
            status = BuildCacheImportStatus.Mismatch;
            detail = "the package GamePack ABI " + manifest.PackAbiVersion + " differs from this launcher (" + current.GamePackAbi + ")";
            return false;
        }
        // Linux cannot recompile AOT GamePacks locally (P2), so a package built on
        // Windows/macOS is the only source of a real GamePack. Its recorded toolchain
        // is therefore not comparable to this host's (missing) Windows toolchain; trust
        // the package's ABI + embedded ROM and record the artifact under the current
        // (stable) Linux recipe marker so BuildCachePolicy reuses it on Deploy.
        if (!LauncherPlatform.IsLinux)
        {
            var clang = manifest.ClangVersion.Trim();
            var llvm = manifest.LlvmVersion.Trim();
            if (clang.Length == 0 || llvm.Length == 0
                || string.Equals(clang, BuildCompatibility.UnknownVersion, StringComparison.OrdinalIgnoreCase)
                || string.Equals(llvm, BuildCompatibility.UnknownVersion, StringComparison.OrdinalIgnoreCase))
            {
                status = BuildCacheImportStatus.Mismatch;
                detail = "the package manifest does not record the toolchain versions (old CLI); recompiling is required";
                return false;
            }
            if (!string.Equals(clang, current.ClangVersion, StringComparison.Ordinal)
                || !string.Equals(llvm, current.Ld64Version, StringComparison.Ordinal))
            {
                status = BuildCacheImportStatus.Mismatch;
                detail = "the package was built with another toolchain (clang " + clang + ", llvm " + llvm
                    + "; this launcher has clang " + current.ClangVersion + ", llvm " + current.Ld64Version + ")";
                return false;
            }
            if (!string.Equals(manifest.BuildOptionsMarker, current.BuildOptions, StringComparison.OrdinalIgnoreCase))
            {
                status = BuildCacheImportStatus.Mismatch;
                detail = "the package was built with different AOT build options (" + manifest.BuildOptionsMarker
                    + "; this launcher uses " + current.BuildOptions + ")";
                return false;
            }
        }
        artifact = new BuildArtifact
        {
            BuildCompatVersion = current.BuildCompatVersion,
            BuildCompatShort = current.ShortVersion,
            RomSha256 = manifest.RomSha256!,
            RomBytes = manifest.RomBytes!.Value,
            PackSha256 = manifest.PackSha256,
            PackBytes = manifest.PackBytes,
            BuildName = BuildSlug.From(manifest.DisplayName, manifest.TitleID),
            LauncherVersion = manifest.SourceLauncherVersion,
            BuiltAt = manifest.BuiltAt,
        };
        status = BuildCacheImportStatus.Recorded;
        detail = LauncherPlatform.IsLinux
            ? "build cache recorded from the package manifest; Linux reuses the imported GamePack without recompiling"
            : "build cache recorded from the package manifest (" + current.ShortVersion + ")";
        return true;
    }

    private static string NormalizeTitleId(string? titleId) =>
        (titleId ?? string.Empty).Trim().ToUpperInvariant();

    private static JsonElement? Object(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty(name, out var child)
            || child.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        return child;
    }

    private static string? Text(JsonElement? parent, string name) =>
        parent is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(name, out var child)
            && child.ValueKind == JsonValueKind.String
            ? child.GetString()
            : null;

    private static int? Integer(JsonElement? parent, string name) =>
        parent is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(name, out var child)
            && child.ValueKind == JsonValueKind.Number && child.TryGetInt32(out var number)
            ? number
            : null;

    private static long? Long(JsonElement? parent, string name)
    {
        if (parent is not { ValueKind: JsonValueKind.Object } value || !value.TryGetProperty(name, out var child)
            || child.ValueKind != JsonValueKind.Number)
        {
            return null;
        }
        return child.TryGetInt64(out var number) ? number : null;
    }

    private static bool? Boolean(JsonElement? parent, string name) =>
        parent is { ValueKind: JsonValueKind.Object } value && value.TryGetProperty(name, out var child)
            ? child.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null,
            }
            : null;
}
