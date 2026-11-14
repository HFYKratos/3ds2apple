using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace ThreeDsTwoApple.Launcher.Core.Tools;

/// <summary>One process invocation; everything the launcher needs is explicit.</summary>
public sealed record ProcessRequest(
    string FileName,
    IReadOnlyList<string> Arguments,
    string? WorkingDirectory = null,
    IReadOnlyDictionary<string, string>? Environment = null,
    TimeSpan? Timeout = null,
    string? StandardInput = null)
{
    public string CommandLineDisplay => Arguments.Count == 0
        ? FileName
        : FileName + " " + string.Join(' ', Arguments.Select(Quote));

    private static string Quote(string argument) =>
        argument.Length > 0 && argument.All(c => !char.IsWhiteSpace(c) && c != '"') ? argument : '"' + argument.Replace("\"", "\\\"") + '"';
}

/// <summary>Result of one process invocation.</summary>
public sealed record ProcessResult(
    int ExitCode,
    string StdOut,
    string StdErr,
    bool TimedOut,
    bool Started)
{
    public bool Ok => Started && !TimedOut && ExitCode == 0;

    public string Combined => string.IsNullOrEmpty(StdErr) ? StdOut : StdOut + "\n" + StdErr;

    public IReadOnlyList<string> StdOutLines => SplitLines(StdOut);

    public IReadOnlyList<string> StdErrLines => SplitLines(StdErr);

    private static IReadOnlyList<string> SplitLines(string text) =>
        text.Length == 0
            ? Array.Empty<string>()
            : text.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n', StringSplitOptions.RemoveEmptyEntries);
}

/// <summary>Abstraction so unit tests can replace the process layer without a real binary.</summary>
public interface IProcessRunner
{
    Task<ProcessResult> RunAsync(
        ProcessRequest request,
        Action<string>? onStdOutLine = null,
        Action<string>? onStdErrLine = null,
        CancellationToken cancellationToken = default);
}

/// <summary>Launches tool CLIs and streams their output line by line.</summary>
/// <remarks>
/// The launcher only ever shells out to the project's own tools and to the
/// official Impactor/plumesign binaries. Arguments are passed as an argv array
/// (never through a shell string); stdout/stderr are read asynchronously so the
/// UI can show progress while a transfer or build is running.
/// </remarks>
public sealed class ProcessRunner : IProcessRunner
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromMinutes(30);

    public async Task<ProcessResult> RunAsync(
        ProcessRequest request,
        Action<string>? onStdOutLine = null,
        Action<string>? onStdErrLine = null,
        CancellationToken cancellationToken = default)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = request.FileName,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = request.StandardInput is not null,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var argument in request.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        if (!string.IsNullOrEmpty(request.WorkingDirectory))
        {
            startInfo.WorkingDirectory = request.WorkingDirectory;
        }
        if (request.Environment is not null)
        {
            foreach (var (key, value) in request.Environment)
            {
                startInfo.Environment[key] = value;
            }
        }

        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        var stdoutGate = new object();
        var stderrGate = new object();

        using var process = new Process { StartInfo = startInfo };
        process.OutputDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }
            lock (stdoutGate)
            {
                stdout.AppendLine(e.Data);
            }
            onStdOutLine?.Invoke(e.Data);
        };
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data is null)
            {
                return;
            }
            lock (stderrGate)
            {
                stderr.AppendLine(e.Data);
            }
            onStdErrLine?.Invoke(e.Data);
        };

        try
        {
            if (!process.Start())
            {
                return new ProcessResult(-1, string.Empty, $"could not start {request.FileName}", false, false);
            }
        }
        catch (Win32Exception error)
        {
            return new ProcessResult(-1, string.Empty, $"could not start {request.FileName}: {error.Message}", false, false);
        }

        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        if (request.StandardInput is not null)
        {
            await process.StandardInput.WriteAsync(request.StandardInput.AsMemory(), cancellationToken).ConfigureAwait(false);
            process.StandardInput.Close();
        }

        var timeout = request.Timeout ?? DefaultTimeout;
        using var timeoutSource = new CancellationTokenSource(timeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);
        var timedOut = false;
        try
        {
            await process.WaitForExitAsync(linkedSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            timedOut = !cancellationToken.IsCancellationRequested;
            try
            {
                process.Kill(entireProcessTree: true);
            }
            catch (InvalidOperationException)
            {
                // already exited
            }
            try
            {
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (InvalidOperationException)
            {
                // nothing to do
            }
        }

        // Drains the async output handlers so the captured text is complete.
        process.WaitForExit();
        string capturedStdout;
        string capturedStderr;
        lock (stdoutGate)
        {
            capturedStdout = stdout.ToString();
        }
        lock (stderrGate)
        {
            capturedStderr = stderr.ToString();
        }
        var exitCode = process.HasExited ? process.ExitCode : -1;
        return new ProcessResult(exitCode, capturedStdout, capturedStderr, timedOut, true);
    }
}
