using ThreeDsTwoApple.Launcher.Core.Tools;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>One plumesign invocation.</summary>
/// <param name="IpaPath">Unsigned IPA to sign (the base shell).</param>
/// <param name="OutputIpaPath">Where the signed IPA is written.</param>
/// <param name="BundleIdentifier">Bundle id to use; always passed so the team suffix cannot surprise us.</param>
/// <param name="CustomName">Optional home-screen name.</param>
/// <param name="DeviceNumber">usbmux device number (not the UDID) used by --register-and-install.</param>
/// <param name="RegisterAndInstall">true = register device + sign + install in one step.</param>
public sealed record PlumeSignRequest(
    string IpaPath,
    string OutputIpaPath,
    string? BundleIdentifier = null,
    string? CustomName = null,
    string? DeviceNumber = null,
    bool RegisterAndInstall = true);

/// <summary>Outcome of one plumesign run.</summary>
public sealed record PlumeSignResult(
    bool Success,
    int ExitCode,
    string LogPath,
    string Log,
    SigningError? Error);

/// <summary>
/// Runs the official <c>plumesign</c> CLI (same release as Impactor v2.7.2,
/// SHA-256 pinned, unmodified). Account storage and Apple ID authentication stay
/// inside Impactor/plumesign; this class only builds argv and maps failures.
/// </summary>
public sealed class PlumeSignRunner
{
    public const string InstallationCompleteMarker = "Installation complete";

    private readonly IProcessRunner _runner;
    private readonly string _plumeSignPath;
    private readonly string _logDirectory;

    public PlumeSignRunner(IProcessRunner runner, string plumeSignPath, string logDirectory)
    {
        _runner = runner;
        _plumeSignPath = plumeSignPath;
        _logDirectory = logDirectory;
    }

    public string PlumeSignPath => _plumeSignPath;

    /// <summary>Build the exact argv for a signing run (public for tests and for the docs).</summary>
    public static IReadOnlyList<string> BuildSignArguments(PlumeSignRequest request)
    {
        var arguments = new List<string>
        {
            "sign",
            "--package", request.IpaPath,
            "--apple-id",
        };
        if (request.RegisterAndInstall)
        {
            arguments.Add("--register-and-install");
            if (!string.IsNullOrWhiteSpace(request.DeviceNumber))
            {
                arguments.Add("--udid");
                arguments.Add(request.DeviceNumber);
            }
        }
        arguments.Add("-o");
        arguments.Add(request.OutputIpaPath);
        if (!string.IsNullOrWhiteSpace(request.CustomName))
        {
            arguments.Add("--custom-name");
            arguments.Add(request.CustomName);
        }
        if (!string.IsNullOrWhiteSpace(request.BundleIdentifier))
        {
            arguments.Add("--custom-identifier");
            arguments.Add(request.BundleIdentifier);
        }
        return arguments;
    }

    /// <summary>Build the argv for installing an already-signed .app/IPA region.</summary>
    public static IReadOnlyList<string> BuildDeviceInstallArguments(string appPath, string deviceNumber) =>
        new[] { "device", "--udid", deviceNumber, "--install", appPath };

    public async Task<PlumeSignResult> RunAsync(
        PlumeSignRequest request,
        Action<string>? onLogLine = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_logDirectory);
        var logPath = Path.Combine(_logDirectory, $"plumesign-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}"[..52] + ".log");
        var output = new System.Text.StringBuilder();
        void Emit(string line)
        {
            output.AppendLine(line);
            onLogLine?.Invoke(line);
        }

        var arguments = BuildSignArguments(request);
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            // plumesign uses this level for the "Installation complete" marker; do
            // not inherit a user RUST_LOG that could hide it.
            ["RUST_LOG"] = "info",
        };
        var process = await _runner.RunAsync(
            new ProcessRequest(_plumeSignPath, arguments, Environment: environment, Timeout: TimeSpan.FromMinutes(10)),
            onStdOutLine: Emit,
            onStdErrLine: Emit,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        var log = output.ToString();
        await File.WriteAllTextAsync(logPath, log, cancellationToken).ConfigureAwait(false);

        var success = process.Started
                      && !process.TimedOut
                      && process.ExitCode == 0
                      && (!request.RegisterAndInstall || log.Contains(InstallationCompleteMarker, StringComparison.OrdinalIgnoreCase));
        if (success)
        {
            return new PlumeSignResult(true, process.ExitCode, logPath, log, null);
        }

        var error = AppleErrorCatalog.Explain(log.Length > 0 ? log : process.Combined);
        if (process.TimedOut)
        {
            error = new SigningError("signing_timeout", "Signing timed out.", "plumesign did not finish within 10 minutes.", "Retry; if it keeps timing out, remove the app from the phone and sign in to Impactor again.");
        }
        else if (!process.Started)
        {
            error = AppleErrorCatalog.Lookup("impactor_missing")!;
        }
        else if (process.ExitCode == 0)
        {
            error = new SigningError("install_incomplete", "The signer finished without confirming the install.",
                "plumesign exited 0 but never printed 'Installation complete'.",
                "Open Impactor and check whether the app appeared on the phone; if not, retry with the phone unlocked.");
        }
        return new PlumeSignResult(false, process.ExitCode, logPath, log, error);
    }

    /// <summary>Install an already-signed app (fallback when device registration is stale).</summary>
    public async Task<PlumeSignResult> InstallSignedAppAsync(
        string appPath,
        string deviceNumber,
        Action<string>? onLogLine = null,
        CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_logDirectory);
        var logPath = Path.Combine(_logDirectory, $"plumesign-device-{DateTimeOffset.UtcNow:yyyyMMdd-HHmmss}.log");
        var output = new System.Text.StringBuilder();
        void Emit(string line)
        {
            output.AppendLine(line);
            onLogLine?.Invoke(line);
        }
        var process = await _runner.RunAsync(
            new ProcessRequest(_plumeSignPath, BuildDeviceInstallArguments(appPath, deviceNumber), Timeout: TimeSpan.FromMinutes(5)),
            onStdOutLine: Emit,
            onStdErrLine: Emit,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var log = output.ToString();
        await File.WriteAllTextAsync(logPath, log, cancellationToken).ConfigureAwait(false);
        var success = process.Started && !process.TimedOut && process.ExitCode == 0;
        return new PlumeSignResult(success, process.ExitCode, logPath, log, success ? null : AppleErrorCatalog.Explain(log.Length > 0 ? log : process.Combined));
    }
}
