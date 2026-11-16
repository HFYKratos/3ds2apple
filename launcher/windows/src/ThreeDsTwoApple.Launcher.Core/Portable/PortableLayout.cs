using System.Text.Json;

namespace ThreeDsTwoApple.Launcher.Core.Portable;

/// <summary>Where the launcher keeps its writable data for this run.</summary>
public enum DataRootKind
{
    /// <summary>Explicit path from THREEDS2APPLE_DATA_DIR or a test/QA argument.</summary>
    Explicit = 0,

    /// <summary>&lt;exe-dir&gt;\3ds2apple-data — the portable, preferred location.</summary>
    Portable = 1,

    /// <summary>%LOCALAPPDATA%\3ds2apple — fallback when the launcher folder is read-only.</summary>
    LocalAppData = 2,

    /// <summary>Last-resort temporary folder (read-only install AND unusable LocalAppData).</summary>
    TempFallback = 3,
}

/// <summary>
/// The resolved data root. Workspace and payload extraction locations are both derived
/// from it so a launcher copied to a USB stick keeps everything beside the executable.
/// </summary>
public sealed record DataRootDecision(
    string DataRoot,
    string WorkspaceRoot,
    string DistributionBase,
    DataRootKind Kind,
    string Reason,
    string ExeDirectory,
    string? PortableCandidate,
    string LegacyWorkspaceRoot)
{
    /// <summary>True when the data lives beside the executable.</summary>
    public bool IsPortable => Kind == DataRootKind.Portable;

    /// <summary>Extraction directory for one launcher version.</summary>
    public string DistributionRoot(string version) => Path.Combine(DistributionBase, version);
}

/// <summary>Outcome of adopting data from the previous %LOCALAPPDATA% layout.</summary>
public sealed record WorkspaceMigrationResult(
    bool Attempted,
    bool StateCopied,
    int FilesCopied,
    string? Warning,
    string MarkerPath)
{
    public bool Migrated => Attempted && StateCopied;
}

/// <summary>
/// Portable layout policy for the Windows launcher:
/// writable data goes to &lt;exe-dir&gt;\3ds2apple-data, and only a read-only launcher
/// folder falls back to %LOCALAPPDATA%\3ds2apple. An existing old workspace is copied
/// over on first run (state.json first) so imported games are not lost.
/// </summary>
public static class PortableLayout
{
    public const string DataDirectoryName = "3ds2apple-data";

    public const string WorkspaceDirectoryName = "workspace";

    public const string DistributionDirectoryName = "distribution";

    /// <summary>Optional QA override for the whole portable data root.</summary>
    public const string DataRootEnvironmentVariable = "THREEDS2APPLE_DATA_DIR";

    /// <summary>Test hook: force the LocalAppData fallback on a writable host.</summary>
    public const string ForceFallbackEnvironmentVariable = "THREEDS2APPLE_FORCE_LOCALAPPDATA";

    public const string MigrationMarkerFileName = "migration.json";

    /// <summary>Launcher-version-independent directory name inside LocalAppData.</summary>
    public const string LegacyDirectoryName = "3ds2apple";

    /// <summary>Old workspace directory below %LOCALAPPDATA%\3ds2apple.</summary>
    public const string LegacyWorkspaceDirectoryName = "launcher";

    /// <summary>%LOCALAPPDATA% (or ~/.local/share off Windows); never throws.</summary>
    public static string LocalAppDataRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
        }
        return Path.GetFullPath(localAppData);
    }

    /// <summary>Old <c>%LOCALAPPDATA%\3ds2apple</c> data root.</summary>
    public static string LegacyDataRoot() => Path.Combine(LocalAppDataRoot(), LegacyDirectoryName);

    /// <summary>Old <c>%LOCALAPPDATA%\3ds2apple\launcher</c> workspace (games + state).</summary>
    public static string LegacyWorkspaceRoot() => Path.Combine(LegacyDataRoot(), LegacyWorkspaceDirectoryName);

    /// <summary>Old payload extraction base (<c>%LOCALAPPDATA%\3ds2apple\distribution</c>).</summary>
    public static string LegacyDistributionBase() => Path.Combine(LegacyDataRoot(), DistributionDirectoryName);

    /// <summary>Executable directory (single-file launches report the exe folder here).</summary>
    public static string ExeDirectory()
    {
        var baseDirectory = AppContext.BaseDirectory;
        if (string.IsNullOrWhiteSpace(baseDirectory))
        {
            return Path.GetFullPath(".");
        }
        return Path.TrimEndingDirectorySeparator(Path.GetFullPath(baseDirectory));
    }

    /// <summary>
    /// Resolve the writable data root. Pure enough for tests: every input can be supplied
    /// (executable folder, LocalAppData, writability probe, explicit override).
    /// </summary>
    public static DataRootDecision Resolve(
        string? exeDirectory = null,
        string? localAppDataRoot = null,
        Func<string, bool>? isWritable = null,
        string? dataRootOverride = null)
    {
        exeDirectory = string.IsNullOrWhiteSpace(exeDirectory) ? ExeDirectory() : Path.TrimEndingDirectorySeparator(Path.GetFullPath(exeDirectory));
        var localData = string.IsNullOrWhiteSpace(localAppDataRoot) ? LocalAppDataRoot() : Path.GetFullPath(localAppDataRoot);
        var legacyWorkspace = Path.Combine(localData, LegacyDirectoryName, LegacyWorkspaceDirectoryName);
        var writable = isWritable ?? ProbeWritable;

        var explicitRoot = dataRootOverride;
        if (string.IsNullOrWhiteSpace(explicitRoot))
        {
            explicitRoot = Environment.GetEnvironmentVariable(DataRootEnvironmentVariable);
        }
        if (!string.IsNullOrWhiteSpace(explicitRoot))
        {
            var root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(explicitRoot));
            return new DataRootDecision(root, Path.Combine(root, WorkspaceDirectoryName), Path.Combine(root, DistributionDirectoryName),
                DataRootKind.Explicit, "explicit override (" + DataRootEnvironmentVariable + ")", exeDirectory, null, legacyWorkspace);
        }

        var portableCandidate = Path.Combine(exeDirectory, DataDirectoryName);
        var forceFallback = IsTruthy(Environment.GetEnvironmentVariable(ForceFallbackEnvironmentVariable));
        if (!forceFallback && writable(portableCandidate))
        {
            return new DataRootDecision(portableCandidate, Path.Combine(portableCandidate, WorkspaceDirectoryName),
                Path.Combine(portableCandidate, DistributionDirectoryName), DataRootKind.Portable,
                "portable beside the launcher (the launcher folder is writable)", exeDirectory, portableCandidate, legacyWorkspace);
        }

        var legacyRoot = Path.Combine(localData, LegacyDirectoryName);
        if (forceFallback || writable(legacyRoot))
        {
            return new DataRootDecision(legacyRoot, legacyWorkspace, Path.Combine(legacyRoot, DistributionDirectoryName),
                DataRootKind.LocalAppData,
                forceFallback
                    ? "forced LocalAppData fallback (test hook " + ForceFallbackEnvironmentVariable + ")"
                    : "fallback: the launcher folder is read-only (" + exeDirectory + ")",
                exeDirectory, portableCandidate, legacyWorkspace);
        }

        var temporary = Path.Combine(Path.GetTempPath(), LegacyDirectoryName, "launcher-data-" + Environment.ProcessId);
        return new DataRootDecision(temporary, Path.Combine(temporary, WorkspaceDirectoryName), Path.Combine(temporary, DistributionDirectoryName),
            DataRootKind.TempFallback,
            "fallback: both the launcher folder and LocalAppData are read-only; using a temporary folder",
            exeDirectory, portableCandidate, legacyWorkspace);
    }

    /// <summary>Create the directory and write a probe file in it; false instead of throwing.</summary>
    public static bool ProbeWritable(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var probe = Path.Combine(directory, ".write-probe-" + Guid.NewGuid().ToString("N")[..8] + ".tmp");
            using (var stream = new FileStream(probe, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.WriteByte(0);
            }
            File.Delete(probe);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException or NotSupportedException or ArgumentException)
        {
            return false;
        }
    }

    /// <summary>
    /// Copy the old workspace (state.json first, then packages/logs; build scratch such as
    /// work/ and staging/ is regenerable and skipped) into the new portable workspace.
    /// The legacy tree is left untouched so a failed migration never loses data.
    /// </summary>
    public static WorkspaceMigrationResult MigrateLegacyWorkspace(
        string workspaceRoot,
        string legacyWorkspaceRoot,
        Action<string>? log = null,
        Func<string, string, bool>? copyFile = null,
        Func<string, bool>? directoryExists = null,
        Func<string, bool>? fileExists = null)
    {
        var migrationMarker = Path.Combine(workspaceRoot, MigrationMarkerFileName);
        var stateSource = Path.Combine(legacyWorkspaceRoot, "state.json");
        var stateDestination = Path.Combine(workspaceRoot, "state.json");
        var fileExistsCheck = fileExists ?? File.Exists;
        var directoryExistsCheck = directoryExists ?? Directory.Exists;
        var copy = copyFile ?? ((source, destination) =>
        {
            var directory = Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.Copy(source, destination, overwrite: false);
            return true;
        });

        if (!directoryExistsCheck(legacyWorkspaceRoot) || !fileExistsCheck(stateSource))
        {
            return new WorkspaceMigrationResult(false, false, 0, null, migrationMarker);
        }

        var copied = 0;
        var warnings = new List<string>();
        try
        {
            Directory.CreateDirectory(workspaceRoot);
            copy(stateSource, stateDestination);
            copied++;
            log?.Invoke("migrating the previous workspace from " + legacyWorkspaceRoot + " to " + workspaceRoot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return new WorkspaceMigrationResult(true, false, copied, "could not copy state.json from " + legacyWorkspaceRoot + ": " + exception.Message, migrationMarker);
        }

        foreach (var source in EnumerateMigratableFiles(legacyWorkspaceRoot))
        {
            var relative = Path.GetRelativePath(legacyWorkspaceRoot, source);
            if (relative.Equals("state.json", StringComparison.OrdinalIgnoreCase)
                || relative.StartsWith("work" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)
                || relative.StartsWith("staging" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }
            var destination = Path.Combine(workspaceRoot, relative);
            try
            {
                if (fileExistsCheck(destination))
                {
                    continue;
                }
                if (copy(source, destination))
                {
                    copied++;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                if (warnings.Count < 8)
                {
                    warnings.Add(relative + ": " + exception.Message);
                }
            }
        }

        string? warning = warnings.Count == 0 ? null : warnings.Count + " file(s) could not be migrated: " + string.Join("; ", warnings);
        try
        {
            var marker = new MigrationMarkerDocument
            {
                SchemaVersion = 1,
                Source = legacyWorkspaceRoot,
                MigratedAt = DateTimeOffset.UtcNow,
                FilesCopied = copied,
                Warning = warning,
            };
            File.WriteAllText(migrationMarker, JsonSerializer.Serialize(marker, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            warning ??= "could not write " + migrationMarker + ": " + exception.Message;
        }
        log?.Invoke("workspace migration: " + copied + " file(s) copied" + (warning is null ? string.Empty : "; " + warning));
        return new WorkspaceMigrationResult(true, true, copied, warning, migrationMarker);
    }

    /// <summary>Files below an old workspace worth copying (build scratch is skipped by the caller).</summary>
    public static IEnumerable<string> EnumerateMigratableFiles(string workspaceRoot)
    {
        foreach (var file in Directory.EnumerateFiles(workspaceRoot, "*", SearchOption.AllDirectories))
        {
            yield return file;
        }
    }

    /// <summary>Migrate only when the new workspace has no state yet and the old one has data.</summary>
    public static WorkspaceMigrationResult MigrateIfNeeded(string workspaceRoot, string legacyWorkspaceRoot, Action<string>? log = null)
    {
        if (File.Exists(Path.Combine(workspaceRoot, "state.json")) || !File.Exists(Path.Combine(legacyWorkspaceRoot, "state.json")))
        {
            return new WorkspaceMigrationResult(false, false, 0, null, Path.Combine(workspaceRoot, MigrationMarkerFileName));
        }
        return MigrateLegacyWorkspace(workspaceRoot, legacyWorkspaceRoot, log);
    }

    private static bool IsTruthy(string? value) =>
        !string.IsNullOrWhiteSpace(value)
        && (value.Equals("1", StringComparison.OrdinalIgnoreCase)
            || value.Equals("true", StringComparison.OrdinalIgnoreCase)
            || value.Equals("yes", StringComparison.OrdinalIgnoreCase));
}

/// <summary>Marker written into the portable workspace after adopting an old workspace.</summary>
public sealed class MigrationMarkerDocument
{
    public int SchemaVersion { get; set; } = 1;

    public string? Source { get; set; }

    public DateTimeOffset MigratedAt { get; set; }

    public int FilesCopied { get; set; }

    public string? Warning { get; set; }
}
