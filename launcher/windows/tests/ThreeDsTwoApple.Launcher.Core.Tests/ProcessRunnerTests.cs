using System.Diagnostics;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Tests for the real process layer: a stopped deploy must kill the whole tool process
/// tree (not just the launcher's direct child) and surface OperationCanceledException so
/// the UI can show "cancelled" instead of a tool failure. The tests use the real
/// operating-system process host on the host running the suite (Linux/WSL or Windows).
/// </summary>
public sealed class ProcessRunnerTests
{
    public ProcessRunnerTests() => LauncherProcessRegistry.Clear();

    [Fact]
    public void WindowsTaskKillArgumentsUseTheDocumentedProcessTreeForm()
    {
        Assert.Equal(new[] { "/PID", "4321", "/T", "/F" }, ProcessTreeKiller.WindowsTaskKillArguments(4321));
    }

    [Fact]
    public void KillAllTerminatesEveryTrackedProcessTreeAndClearsTheRegistry()
    {
        LauncherProcessRegistry.Clear();
        LauncherProcessRegistry.Register(101, "3dsrecomp.exe");
        LauncherProcessRegistry.Register(202, "devpush.exe");
        var killer = new FakeKiller();
        var log = new List<string>();

        var targeted = LauncherProcessRegistry.KillAll(killer, log.Add);

        Assert.Equal(2, targeted);
        Assert.Equal(new[] { 101, 202 }, killer.ProcessIds.OrderBy(processId => processId));
        Assert.Equal(0, LauncherProcessRegistry.Count);
        Assert.Contains(log, line => line.Contains("3dsrecomp.exe", StringComparison.Ordinal));
        // A second kill is a no-op: nothing is tracked and nothing is killed twice.
        Assert.Equal(0, LauncherProcessRegistry.KillAll(killer));
        Assert.Equal(2, killer.ProcessIds.Count);
    }

    [Fact]
    public void UnregisterRemovesOnlyTheFinishedProcess()
    {
        LauncherProcessRegistry.Clear();
        LauncherProcessRegistry.Register(303, "plumesign.exe");
        LauncherProcessRegistry.Register(404, "3dsrecomp.exe");

        LauncherProcessRegistry.Unregister(303);

        Assert.Equal(new[] { 404 }, LauncherProcessRegistry.Snapshot());
    }

    [Fact]
    public async Task RunAsyncReturnsOutputAndExitCode()
    {
        var result = await new ProcessRunner().RunAsync(EchoRequest());

        Assert.True(result.Started);
        Assert.True(result.Ok, result.Combined);
        Assert.False(result.TimedOut);
        Assert.Contains("3ds2apple-process-test", result.StdOut, StringComparison.Ordinal);
    }

    [Fact]
    public async Task CancellingRunAsyncKillsTheProcessAndThrowsOperationCanceled()
    {
        var killer = new RecordingTreeKiller();
        var runner = new ProcessRunner(killer);
        using var cancellation = new CancellationTokenSource();
        var run = runner.RunAsync(SleeperRequest(), cancellationToken: cancellation.Token);
        await Task.Delay(500);

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run.WaitAsync(TimeSpan.FromSeconds(20)));
        var processId = Assert.Single(killer.ProcessIds);
        await AssertProcessIsGoneAsync(processId, TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task CancellingRunAsyncKillsEveryChildOfTheToolProcess()
    {
        using var temp = new TempDir();
        var pidFile = Path.Combine(temp.Path, "child.pid");
        var runner = new ProcessRunner(new RecordingTreeKiller());
        using var cancellation = new CancellationTokenSource();
        var run = runner.RunAsync(ChildTreeRequest(pidFile), cancellationToken: cancellation.Token);
        var childProcessId = await ReadPidAsync(pidFile, TimeSpan.FromSeconds(15));

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run.WaitAsync(TimeSpan.FromSeconds(20)));
        await AssertProcessIsGoneAsync(childProcessId, TimeSpan.FromSeconds(20));
    }

    [Fact]
    public async Task ATimedOutProcessIsKilledAndReportedAsTimedOutNotCancelled()
    {
        var killer = new RecordingTreeKiller();
        var runner = new ProcessRunner(killer);

        var result = await runner.RunAsync(SleeperRequest() with { Timeout = TimeSpan.FromMilliseconds(400) });

        Assert.True(result.Started);
        Assert.True(result.TimedOut);
        Assert.False(result.Ok);
        var processId = Assert.Single(killer.ProcessIds);
        await AssertProcessIsGoneAsync(processId, TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task KillAllEndsARunningToolForLauncherShutdown()
    {
        // The launcher-close path force-kills tracked tools without cancelling the
        // ProcessRunner token; the caller must simply see a failed (not hung) tool.
        var runner = new ProcessRunner(new RecordingTreeKiller());
        var run = runner.RunAsync(SleeperRequest());
        await WaitUntilTrackedAsync(TimeSpan.FromSeconds(10));

        var killed = LauncherProcessRegistry.KillAll(new ProcessTreeKiller());

        Assert.Equal(1, killed);
        var result = await run.WaitAsync(TimeSpan.FromSeconds(20));
        Assert.True(result.Started);
        Assert.False(result.Ok);
    }

    // --- host helpers -----------------------------------------------------

    private static ProcessRequest EchoRequest() => OperatingSystem.IsWindows()
        ? new ProcessRequest("cmd.exe", new[] { "/c", "echo 3ds2apple-process-test" })
        : new ProcessRequest("/bin/sh", new[] { "-c", "echo 3ds2apple-process-test" });

    private static ProcessRequest SleeperRequest() => OperatingSystem.IsWindows()
        ? new ProcessRequest("cmd.exe", new[] { "/c", "ping -n 120 127.0.0.1 > nul" })
        : new ProcessRequest("/bin/sh", new[] { "-c", "sleep 120" });

    /// <summary>A tool-shaped process that starts one long-lived child and waits for it.</summary>
    private static ProcessRequest ChildTreeRequest(string pidFile)
    {
        if (OperatingSystem.IsWindows())
        {
            var script = "$p = Start-Process -FilePath 'ping' -ArgumentList '-n','120','127.0.0.1' -WindowStyle Hidden -PassThru; "
                         + "Set-Content -LiteralPath '" + pidFile.Replace("'", "''") + "' -Value $p.Id; Wait-Process -Id $p.Id";
            return new ProcessRequest("powershell.exe", new[] { "-NoProfile", "-NonInteractive", "-Command", script });
        }
        return new ProcessRequest("/bin/sh", new[] { "-c", "sleep 120 & echo $! > '" + pidFile + "'; wait" });
    }

    private static async Task<int> ReadPidAsync(string path, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                if (File.Exists(path))
                {
                    var text = (await File.ReadAllTextAsync(path)).Trim();
                    if (int.TryParse(text, out var processId))
                    {
                        return processId;
                    }
                }
            }
            catch (IOException)
            {
                // The child is still writing the file; retry.
            }
            await Task.Delay(100);
        }
        throw new TimeoutException("the child process id file was not written: " + path);
    }

    private static async Task WaitUntilTrackedAsync(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (LauncherProcessRegistry.Count > 0)
            {
                return;
            }
            await Task.Delay(50);
        }
        Assert.Fail("no tool process was tracked by the launcher process registry");
    }

    private static async Task AssertProcessIsGoneAsync(int processId, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                using var process = Process.GetProcessById(processId);
                if (process.HasExited)
                {
                    return;
                }
            }
            catch (ArgumentException)
            {
                return;
            }
            await Task.Delay(100);
        }
        Assert.Fail("process " + processId + " is still running; the process tree was not terminated");
    }

    private sealed class FakeKiller : IProcessTreeKiller
    {
        public List<int> ProcessIds { get; } = new();

        public void Kill(int processId) => ProcessIds.Add(processId);
    }

    private sealed class RecordingTreeKiller : IProcessTreeKiller
    {
        private readonly ProcessTreeKiller _inner = new();

        public List<int> ProcessIds { get; } = new();

        public void Kill(int processId)
        {
            lock (ProcessIds)
            {
                ProcessIds.Add(processId);
            }
            _inner.Kill(processId);
        }
    }
}
