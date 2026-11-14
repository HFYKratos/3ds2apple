using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Models;
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
/// Launcher data root: package output tree, staging, logs and the persisted
/// state. Defaults to <c>%LOCALAPPDATA%\3ds2apple\launcher</c>; ROMs and built
/// artifacts stay out of git because the whole root is user data.
/// </summary>
public sealed class LauncherWorkspace
{
    private readonly object _stateLock = new();
    private readonly object _logLock = new();

    private LauncherWorkspace(string root, LauncherStateDocument state)
    {
        Root = root;
        State = state;
    }

    public string Root { get; }

    /// <summary><c>3ds2apple-pack --out</c> root (packages live in <c>packages/</c>).</summary>
    public string OutRoot => Path.Combine(Root, "out");

    public string StagingDirectory => Path.Combine(Root, "staging");

    public string WorkDirectory => Path.Combine(Root, "work");

    public string DownloadsDirectory => Path.Combine(Root, "downloads");

    public string LogsDirectory => Path.Combine(Root, "logs");

    public string StatePath => Path.Combine(Root, "state.json");

    public LauncherStateDocument State { get; }

    public static LauncherWorkspace Open(string? root = null)
    {
        var resolved = string.IsNullOrWhiteSpace(root)
            ? DefaultRoot()
            : Path.GetFullPath(root);
        foreach (var directory in new[] { resolved, Path.Combine(resolved, "out"), Path.Combine(resolved, "staging"), Path.Combine(resolved, "work"), Path.Combine(resolved, "downloads"), Path.Combine(resolved, "logs") })
        {
            Directory.CreateDirectory(directory);
        }
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
        return new LauncherWorkspace(resolved, state);
    }

    public static string DefaultRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
        }
        return Path.Combine(localAppData, "3ds2apple", "launcher");
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
}
