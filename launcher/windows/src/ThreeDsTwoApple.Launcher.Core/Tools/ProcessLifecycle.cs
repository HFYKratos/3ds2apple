using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;

namespace ThreeDsTwoApple.Launcher.Core.Tools;

/// <summary>
/// Kills one tool process together with every child it spawned. Deploy cancellation
/// and launcher shutdown both use it, so a cancelled build can never leave an orphan
/// 3dsrecomp/clang/lld/devpush/plumesign process behind.
/// </summary>
public interface IProcessTreeKiller
{
    /// <summary>Kill the process and its descendants; must not throw when they already exited.</summary>
    void Kill(int processId);
}

/// <summary>
/// Default <see cref="IProcessTreeKiller"/>. On Windows it runs the documented
/// process-tree form <c>taskkill /PID &lt;pid&gt; /T /F</c> after a best-effort
/// <see cref="Process.Kill(bool)"/>, because the .NET tree walk can miss descendants
/// that re-parented themselves. On other operating systems the .NET process-tree kill
/// (which walks the OS child list) is enough.
/// </summary>
public sealed class ProcessTreeKiller : IProcessTreeKiller
{
    /// <summary>The exact argv of the Windows process-tree kill (public for tests and docs).</summary>
    public static IReadOnlyList<string> WindowsTaskKillArguments(int processId) => new[]
    {
        "/PID",
        processId.ToString(CultureInfo.InvariantCulture),
        "/T",
        "/F",
    };

    public void Kill(int processId)
    {
        if (processId <= 0)
        {
            return;
        }
        try
        {
            using var process = Process.GetProcessById(processId);
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (ArgumentException)
        {
            // The process (or a parent) already exited; nothing to kill.
        }
        catch (InvalidOperationException)
        {
            // Already exited between GetProcessById and Kill.
        }
        catch (Win32Exception)
        {
            // Access denied / race with exit; the Windows taskkill fallback below still runs.
        }
        catch (NotSupportedException)
        {
            // Process.GetProcessById is not supported on this platform variant.
        }

        if (OperatingSystem.IsWindows())
        {
            KillWindowsTree(processId);
        }
    }

    private static void KillWindowsTree(int processId)
    {
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = "taskkill",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var argument in WindowsTaskKillArguments(processId))
            {
                startInfo.ArgumentList.Add(argument);
            }
            using var taskkill = Process.Start(startInfo);
            if (taskkill is null)
            {
                return;
            }
            taskkill.WaitForExit(5000);
        }
        catch (Win32Exception)
        {
            // taskkill is part of Windows; if it cannot start there is nothing else to try.
        }
        catch (InvalidOperationException)
        {
            // taskkill raced with the process exit.
        }
    }
}

/// <summary>
/// Every tool process the launcher starts while an operation is running, so a launcher
/// shutdown can terminate the whole set even when the normal cancellation path did not
/// finish in time. Entries are removed when the tool process exits.
/// </summary>
public static class LauncherProcessRegistry
{
    private static readonly object Gate = new();
    private static readonly Dictionary<int, string> Running = new();

    /// <summary>Number of tool processes currently tracked (test/diagnostic hook).</summary>
    public static int Count
    {
        get
        {
            lock (Gate)
            {
                return Running.Count;
            }
        }
    }

    public static void Register(int processId, string displayName)
    {
        if (processId <= 0)
        {
            return;
        }
        lock (Gate)
        {
            Running[processId] = displayName;
        }
    }

    public static void Unregister(int processId)
    {
        lock (Gate)
        {
            Running.Remove(processId);
        }
    }

    /// <summary>Pids still tracked; a defensive copy that is safe to enumerate while tools exit.</summary>
    public static IReadOnlyList<int> Snapshot()
    {
        lock (Gate)
        {
            return Running.Keys.ToArray();
        }
    }

    /// <summary>Drop every entry without killing anything (test isolation hook).</summary>
    public static void Clear()
    {
        lock (Gate)
        {
            Running.Clear();
        }
    }

    /// <summary>
    /// Kill the tree of every tracked tool process and clear the registry. Returns how
    /// many process trees were targeted; safe to call when nothing is running.
    /// </summary>
    public static int KillAll(IProcessTreeKiller killer, Action<string>? log = null)
    {
        ArgumentNullException.ThrowIfNull(killer);
        KeyValuePair<int, string>[] targets;
        lock (Gate)
        {
            targets = Running.ToArray();
            Running.Clear();
        }
        foreach (var (processId, displayName) in targets)
        {
            log?.Invoke("shutdown: terminating tool process tree " + processId + " (" + displayName + ").");
            killer.Kill(processId);
        }
        return targets.Length;
    }
}
