using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Portable;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.LauncherState;

/// <summary>Persisted launcher state (one JSON file under the workspace root).</summary>
public sealed class LauncherStateDocument
{
    public int SchemaVersion { get; set; } = 1;

    /// <summary>builder-windows / zkb host profile name used for macOS builds.</summary>
    public string? BuildHost { get; set; }

    /// <summary>Selected build mode (stored as a string so the file stays readable).</summary>
    public string BuildMode { get; set; } = nameof(PackBuildMode.Preview);

    /// <summary>UI language preference: "system" (default), "en" or "zh-Hans".</summary>
    public string Language { get; set; } = "system";

    /// <summary>
    /// Feature flag for the experimental local build (3dsrecomp + LLVM/LLD on
    /// this PC, no macOS host). Off by default: the macOS Build Agent is the
    /// supported path until the local pack passes the runtime end-to-end check.
    /// </summary>
    public bool LocalBuildEnabled { get; set; }

    /// <summary>Optional override of the app bundle id (free account 9401 fallback).</summary>
    public string? ShellBundleIdOverride { get; set; }

    /// <summary>Bundle id of the last successfully installed app (template + packs).</summary>
    public string? InstalledBundleId { get; set; }

    /// <summary>When the app IPA was last signed/installed.</summary>
    public DateTimeOffset? InstalledAt { get; set; }

    /// <summary>How many game packs were inside the last installed app.</summary>
    public int InstalledGameCount { get; set; }

    public string? LastDeviceUdid { get; set; }

    public string? DevPushMockDirectory { get; set; }

    /// <summary>Tool binary overrides (tool key -> absolute path).</summary>
    public Dictionary<string, string> ToolOverrides { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public List<LibraryEntry> Games { get; set; } = new();

    public PackBuildMode Mode =>
        Enum.TryParse<PackBuildMode>(BuildMode, ignoreCase: true, out var mode) ? mode : PackBuildMode.Preview;
}

/// <summary>
/// Launcher data root: package output tree, staging, logs and the persisted state.
/// Portable layout: <c>&lt;exe-dir&gt;\3ds2apple-data\workspace</c> when the launcher
/// folder is writable; otherwise fall back to <c>%LOCALAPPDATA%\3ds2apple\launcher</c>
/// (the pre-portable location, also the migration source). ROMs and built artifacts
/// stay out of git because the whole root is user data.
/// </summary>
public sealed class LauncherWorkspace
{
    private readonly object _stateLock = new();
    private readonly object _logLock = new();

    private LauncherWorkspace(string root, LauncherStateDocument state, DataRootDecision location, WorkspaceMigrationResult? migration)
    {
        Root = root;
        State = state;
        Location = location;
        Migration = migration;
    }

    public string Root { get; }

    /// <summary>How the root was chosen (portable / LocalAppData fallback / explicit).</summary>
    public DataRootDecision Location { get; }

    /// <summary>Present when this run adopted (or tried to adopt) the pre-portable workspace.</summary>
    public WorkspaceMigrationResult? Migration { get; }

    /// <summary>Machine-readable reason for the chosen root (see <see cref="DataRootKind"/>).</summary>
    public DataRootKind RootKind => Location.Kind;

    /// <summary>Human-readable English reason (logged and shown in Diagnostics).</summary>
    public string RootReason => Location.Reason;

    /// <summary><c>3ds2apple-pack --out</c> root (packages live in <c>packages/</c>).</summary>
    public string OutRoot => Path.Combine(Root, "out");

    public string StagingDirectory => Path.Combine(Root, "staging");

    public string WorkDirectory => Path.Combine(Root, "work");

    public string DownloadsDirectory => Path.Combine(Root, "downloads");

    public string LogsDirectory => Path.Combine(Root, "logs");

    public string StatePath => Path.Combine(Root, "state.json");

    public LauncherStateDocument State { get; }

    /// <summary>Open the default (portable) workspace, migrating the old LocalAppData one.</summary>
    public static LauncherWorkspace Open(string? root = null)
    {
        if (!string.IsNullOrWhiteSpace(root))
        {
            return OpenAt(Path.GetFullPath(root), ExplicitLocation(Path.GetFullPath(root), "explicit workspace path"), migration: null);
        }
        var configured = Environment.GetEnvironmentVariable(WorkspaceEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            var explicitRoot = Path.GetFullPath(configured);
            return OpenAt(explicitRoot, ExplicitLocation(explicitRoot, "explicit override (" + WorkspaceEnvironmentVariable + ")"), migration: null);
        }

        var decision = PortableLayout.Resolve();
        WorkspaceMigrationResult? migration = null;
        var resolved = decision.WorkspaceRoot;
        if (decision.Kind == DataRootKind.Portable)
        {
            try
            {
                migration = PortableLayout.MigrateIfNeeded(resolved, PortableLayout.LegacyWorkspaceRoot());
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Security.SecurityException)
            {
                migration = new WorkspaceMigrationResult(true, false, 0, exception.Message, Path.Combine(resolved, PortableLayout.MigrationMarkerFileName));
            }
            if (migration is { Attempted: true, StateCopied: false })
            {
                // Never hide an existing library because of a failed copy: keep using the
                // old workspace this run and leave the portable folder in place for retry.
                var legacy = PortableLayout.LegacyWorkspaceRoot();
                if (Directory.Exists(legacy))
                {
                    var fallback = decision with
                    {
                        WorkspaceRoot = legacy,
                        DataRoot = PortableLayout.LegacyDataRoot(),
                        DistributionBase = PortableLayout.LegacyDistributionBase(),
                        Kind = DataRootKind.LocalAppData,
                        Reason = "kept the existing workspace at " + legacy + " because the portable migration failed: " + (migration.Warning ?? "unknown error"),
                    };
                    return OpenAt(legacy, fallback, migration);
                }
            }
        }
        return OpenAt(resolved, decision, migration);
    }

    /// <summary>Optional explicit workspace override for QA/screenshot runs; the shipped launcher never sets it.</summary>
    public const string WorkspaceEnvironmentVariable = "THREEDS2APPLE_WORKSPACE";

    /// <summary>Default workspace: portable beside the executable when writable.</summary>
    public static string DefaultRoot()
    {
        var configured = Environment.GetEnvironmentVariable(WorkspaceEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            return Path.GetFullPath(configured);
        }
        return PortableLayout.Resolve().WorkspaceRoot;
    }

    public LibraryEntry? Find(string titleId) =>
        State.Games.FirstOrDefault(game => string.Equals(game.TitleID, titleId, StringComparison.OrdinalIgnoreCase));

    public void Upsert(LibraryEntry entry)
    {
        lock (_stateLock)
        {
            var index = State.Games.FindIndex(game => string.Equals(game.TitleID, entry.TitleID, StringComparison.OrdinalIgnoreCase));
            if (index >= 0)
            {
                State.Games[index] = entry;
            }
            else
            {
                State.Games.Add(entry);
            }
        }
    }

    public bool Remove(string titleId)
    {
        lock (_stateLock)
        {
            return State.Games.RemoveAll(game => string.Equals(game.TitleID, titleId, StringComparison.OrdinalIgnoreCase)) > 0;
        }
    }

    /// <summary>Atomic-ish save (temp + replace) so a crash cannot truncate the state file.</summary>
    public void SaveState()
    {
        string json;
        lock (_stateLock)
        {
            json = System.Text.Json.JsonSerializer.Serialize(State, Json.WriteOptions) + "\n";
        }
        var temporary = StatePath + ".tmp";
        File.WriteAllText(temporary, json);
        if (File.Exists(StatePath))
        {
            File.Replace(temporary, StatePath, null);
        }
        else
        {
            File.Move(temporary, StatePath);
        }
    }

    /// <summary>Append one line to the per-day launcher log (also useful for bug reports).</summary>
    public void AppendLog(string line)
    {
        var path = Path.Combine(LogsDirectory, $"launcher-{DateTimeOffset.Now:yyyyMMdd}.log");
        var entry = $"{DateTimeOffset.Now:yyyy-MM-dd'T'HH:mm:ss.fffzzz} {line}{Environment.NewLine}";
        lock (_logLock)
        {
            File.AppendAllText(path, entry);
        }
    }

    public string CurrentLogPath => Path.Combine(LogsDirectory, $"launcher-{DateTimeOffset.Now:yyyyMMdd}.log");

    private static LauncherWorkspace OpenAt(string resolved, DataRootDecision location, WorkspaceMigrationResult? migration)
    {
        EnsureDirectories(resolved);
        LauncherStateDocument state;
        var statePath = Path.Combine(resolved, "state.json");
        try
        {
            state = File.Exists(statePath)
                ? System.Text.Json.JsonSerializer.Deserialize<LauncherStateDocument>(File.ReadAllText(statePath), Json.ReadOptions) ?? new LauncherStateDocument()
                : new LauncherStateDocument();
        }
        catch (System.Text.Json.JsonException)
        {
            state = new LauncherStateDocument();
        }
        return new LauncherWorkspace(resolved, state, location, migration);
    }

    private static void EnsureDirectories(string root)
    {
        foreach (var directory in new[] { root, Path.Combine(root, "out"), Path.Combine(root, "staging"), Path.Combine(root, "work"), Path.Combine(root, "downloads"), Path.Combine(root, "logs") })
        {
            Directory.CreateDirectory(directory);
        }
    }

    private static DataRootDecision ExplicitLocation(string root, string reason) => new(
        root,
        root,
        root,
        DataRootKind.Explicit,
        reason,
        PortableLayout.ExeDirectory(),
        null,
        PortableLayout.LegacyWorkspaceRoot());
}
