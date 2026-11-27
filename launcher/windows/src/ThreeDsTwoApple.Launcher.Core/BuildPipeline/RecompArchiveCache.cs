using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Identity of one successful 3dsrecomp ROM -> generated-C -> archive run. The
/// archive is only reused when EVERY field matches the current request and the
/// archive file still hashes to the recorded digest; this makes the reuse a
/// strict cache hit rather than a heuristic.
/// </summary>
public sealed record RecompArchiveKey(
    string TitleID,
    string RomSha256,
    long RomBytes,
    string BuildCompatVersion,
    string RecompilerVersion,
    string RecompilerSha256,
    long RecompilerBytes,
    string BuildOptions,
    string ArchiveRelativePath);

/// <summary>Result of a cache probe: hit (archive path) or a human-readable miss reason.</summary>
public sealed record RecompArchiveReuse(bool Reused, string Detail, string? ArchivePath = null);

/// <summary>
/// Persists the generated-C archive produced by 3dsrecomp so a retry after a
/// shim/link/record failure (or a missing pack record) does not recompile the
/// whole ROM. The cold path is unchanged: it still runs 3dsrecomp and only adds
/// a marker write after the archive exists. Reuse requires the same ROM SHA-256 +
/// title id, build-compat marker (pack/shim/schema/toolchain/flags/options), and
/// exact 3dsrecomp binary identity, and re-hashes the archive before using it.
/// </summary>
public static class RecompArchiveCache
{
    public const int CurrentSchemaVersion = 1;
    public const string MarkerFileName = "recomp-cache.json";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static string MarkerPath(string buildRoot) => Path.Combine(buildRoot, MarkerFileName);

    /// <summary>Probe the marker + archive without running any tool.</summary>
    public static async Task<RecompArchiveReuse> TryReuseAsync(
        string buildRoot,
        RecompArchiveKey key,
        CancellationToken cancellationToken = default)
    {
        var markerPath = MarkerPath(buildRoot);
        if (!File.Exists(markerPath))
        {
            return new RecompArchiveReuse(false, "no generated-C archive marker yet");
        }

        RecompArchiveCacheRecord? record;
        try
        {
            var json = await File.ReadAllTextAsync(markerPath, cancellationToken).ConfigureAwait(false);
            record = JsonSerializer.Deserialize<RecompArchiveCacheRecord>(json, JsonOptions);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new RecompArchiveReuse(false, "cached archive marker is unreadable: " + exception.Message);
        }

        if (record is null)
        {
            return new RecompArchiveReuse(false, "cached archive marker is empty");
        }
        if (record.SchemaVersion != CurrentSchemaVersion)
        {
            return new RecompArchiveReuse(false, "cached archive marker schema changed");
        }
        if (!string.Equals(record.TitleID, key.TitleID, StringComparison.Ordinal))
        {
            return new RecompArchiveReuse(false, "title id changed");
        }
        if (!string.Equals(record.RomSha256, key.RomSha256, StringComparison.OrdinalIgnoreCase)
            || record.RomBytes != key.RomBytes)
        {
            return new RecompArchiveReuse(false, "ROM changed");
        }
        if (!string.Equals(record.BuildCompatVersion, key.BuildCompatVersion, StringComparison.Ordinal))
        {
            return new RecompArchiveReuse(false, "build recipe/toolchain/flags changed");
        }
        if (!string.Equals(record.RecompilerVersion, key.RecompilerVersion, StringComparison.Ordinal)
            || !string.Equals(record.RecompilerSha256, key.RecompilerSha256, StringComparison.OrdinalIgnoreCase)
            || record.RecompilerBytes != key.RecompilerBytes)
        {
            return new RecompArchiveReuse(false, "3dsrecomp binary changed");
        }
        if (!string.Equals(record.BuildOptions, key.BuildOptions, StringComparison.Ordinal))
        {
            return new RecompArchiveReuse(false, "advanced build options changed");
        }
        if (!string.Equals(Normalize(record.ArchiveRelativePath), Normalize(key.ArchiveRelativePath), StringComparison.Ordinal))
        {
            return new RecompArchiveReuse(false, "cached archive path changed");
        }

        var archivePath = ResolveArchivePath(buildRoot, record.ArchiveRelativePath);
        if (archivePath is null)
        {
            return new RecompArchiveReuse(false, "cached archive path is not inside the build folder");
        }
        if (!File.Exists(archivePath))
        {
            return new RecompArchiveReuse(false, "cached generated-C archive is missing");
        }

        try
        {
            var (sha, bytes) = await FileHashes.Sha256WithSizeAsync(archivePath, cancellationToken).ConfigureAwait(false);
            if (bytes != record.ArchiveBytes || !string.Equals(sha, record.ArchiveSha256, StringComparison.OrdinalIgnoreCase))
            {
                return new RecompArchiveReuse(false, "cached generated-C archive does not match the marker (size/SHA-256)");
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return new RecompArchiveReuse(false, "cached generated-C archive cannot be read: " + exception.Message);
        }

        return new RecompArchiveReuse(true,
            "ROM SHA-256, build recipe and 3dsrecomp identity match; reusing the cached generated-C archive",
            archivePath);
    }

    /// <summary>
    /// Write the marker atomically: serialize to a unique temp file in the build
    /// folder, flush it, then rename it over the old marker. Returns false (and
    /// leaves the build result usable) when the marker cannot be written.
    /// </summary>
    public static async Task<bool> SaveAsync(
        string buildRoot,
        RecompArchiveKey key,
        string archivePath,
        CancellationToken cancellationToken = default)
    {
        var archiveRelative = Normalize(Path.GetRelativePath(buildRoot, archivePath));
        var (sha, bytes) = await FileHashes.Sha256WithSizeAsync(archivePath, cancellationToken).ConfigureAwait(false);
        var record = new RecompArchiveCacheRecord(
            CurrentSchemaVersion,
            key.TitleID,
            key.RomSha256,
            key.RomBytes,
            key.BuildCompatVersion,
            key.RecompilerVersion,
            key.RecompilerSha256,
            key.RecompilerBytes,
            key.BuildOptions,
            archiveRelative,
            sha,
            bytes);
        var json = JsonSerializer.Serialize(record, JsonOptions);
        var markerPath = MarkerPath(buildRoot);
        Directory.CreateDirectory(buildRoot);
        var temporary = markerPath + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            await using (var stream = new FileStream(
                temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.WriteThrough))
            {
                var bytesToWrite = Encoding.UTF8.GetBytes(json);
                await stream.WriteAsync(bytesToWrite, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, markerPath, overwrite: true);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            try
            {
                File.Delete(temporary);
            }
            catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException)
            {
                // best effort: a leftover temp file is harmless and never read as the marker
            }
            return false;
        }
    }

    private static string? ResolveArchivePath(string buildRoot, string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath))
        {
            return null;
        }
        var root = Path.GetFullPath(buildRoot);
        var full = Path.GetFullPath(Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = root.EndsWith(Path.DirectorySeparatorChar) ? root : root + Path.DirectorySeparatorChar;
        return full.StartsWith(prefix, StringComparison.Ordinal) ? full : null;
    }

    private static string Normalize(string path) =>
        path.Replace(Path.DirectorySeparatorChar, '/').Replace('\\', '/');
}

/// <summary>On-disk marker for <see cref="RecompArchiveCache"/> (camelCase JSON).</summary>
public sealed record RecompArchiveCacheRecord(
    int SchemaVersion,
    string TitleID,
    string RomSha256,
    long RomBytes,
    string BuildCompatVersion,
    string RecompilerVersion,
    string RecompilerSha256,
    long RecompilerBytes,
    string BuildOptions,
    string ArchiveRelativePath,
    string ArchiveSha256,
    long ArchiveBytes);
