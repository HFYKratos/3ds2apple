using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>Local plumesign account state; never contains the Apple ID or 2FA code.</summary>
public sealed record PlumesignAccountStatus(bool SignedIn, string Summary, string? Error)
{
    public static PlumesignAccountStatus SignedOut(string? detail = null) =>
        new(false, "Not signed in — use Sign in with plumesign and finish the Apple ID/2FA prompt in the terminal.", detail);
}

/// <summary>Result of trying to open a terminal window for the interactive login.</summary>
public sealed record PlumesignLoginLaunch(bool Launched, string Command, string? Error);

/// <summary>
/// Apple ID authentication for the Linux launcher. plumesign owns the account store
/// (~/.config/PlumeImpactor) and prompts for the Apple ID, password and 2FA code in
/// the terminal; the launcher only starts that terminal and later reads "is an
/// account saved?" from <c>plumesign account list</c>. Credentials are never passed
/// as arguments, persisted or written to a log.
/// </summary>
public sealed class PlumesignAccountService
{
    private readonly IProcessRunner _runner;
    private readonly string _plumeSignPath;

    public PlumesignAccountService(IProcessRunner runner, string plumeSignPath)
    {
        _runner = runner;
        _plumeSignPath = plumeSignPath;
    }

    public string PlumeSignPath => _plumeSignPath;

    /// <summary>True when an account entry is saved in plumesign's own store.</summary>
    public async Task<PlumesignAccountStatus> StatusAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_plumeSignPath))
        {
            return new PlumesignAccountStatus(false, "plumesign was not found — stage the official plumesign-linux-x86_64 binary (see launcher/linux/vendor/PINS.json).", "missing_binary");
        }
        try
        {
            var result = await _runner.RunAsync(
                new ProcessRequest(_plumeSignPath, new[] { "account", "list" },
                    Environment: new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["RUST_LOG"] = "info" },
                    Timeout: TimeSpan.FromSeconds(25)),
                cancellationToken: cancellationToken).ConfigureAwait(false);
            if (!result.Started)
            {
                return new PlumesignAccountStatus(false, "plumesign could not be started.", "not_started");
            }
            var output = result.Combined;
            // The CLI is the only place the saved Apple ID exists. Only classify the
            // state; never surface or log the raw account rows/lines.
            if (output.Contains("No accounts found", StringComparison.OrdinalIgnoreCase))
            {
                return PlumesignAccountStatus.SignedOut();
            }
            if (result.ExitCode != 0)
            {
                var line = Privacy.SanitizeLogLine(result.StdErrLines.LastOrDefault() ?? result.StdOutLines.LastOrDefault() ?? "account list failed");
                return new PlumesignAccountStatus(false, "Could not read the plumesign account state: " + line, "account_list_failed");
            }
            return new PlumesignAccountStatus(true, "Signed in — plumesign has a saved Apple ID account (session stays in ~/.config/PlumeImpactor).", null);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return new PlumesignAccountStatus(false, "Could not read the plumesign account state: " + exception.Message, exception.Message);
        }
    }

    /// <summary>
    /// Open an interactive terminal running <c>plumesign account login</c>. The user
    /// types the Apple ID/password/2FA there; nothing is passed through argv or logs.
    /// Returns Launched=false plus the exact command when no terminal emulator was found
    /// (the UI shows it so the user can run it manually).
    /// </summary>
    public PlumesignLoginLaunch OpenLoginTerminal()
    {
        if (!File.Exists(_plumeSignPath))
        {
            return new PlumesignLoginLaunch(false, string.Empty,
                "plumesign was not found; stage the official plumesign-linux-x86_64 binary first.");
        }
        var command = Quote(_plumeSignPath) + " account login";
        var overrideTerminal = Environment.GetEnvironmentVariable("THREEDS2APPLE_TERMINAL");
        var candidates = new List<(string Executable, IReadOnlyList<string> Arguments)>
        {
            ("x-terminal-emulator", new[] { "-e", "sh", "-c", "exec " + command }),
            ("gnome-terminal", new[] { "--", "sh", "-c", "exec " + command }),
            ("ptyxis", new[] { "--", "sh", "-c", "exec " + command }),
            ("konsole", new[] { "-e", "sh", "-c", "exec " + command }),
            ("xfce4-terminal", new[] { "-e", "sh -c 'exec " + command + "'" }),
            ("kitty", new[] { "-e", "sh", "-c", "exec " + command }),
            ("alacritty", new[] { "-e", "sh", "-c", "exec " + command }),
            ("xterm", new[] { "-e", "sh", "-c", "exec " + command }),
        };
        if (!string.IsNullOrWhiteSpace(overrideTerminal))
        {
            candidates.Insert(0, (overrideTerminal!, new[] { "-e", "sh", "-c", "exec " + command }));
        }
        foreach (var (executable, arguments) in candidates)
        {
            try
            {
                var startInfo = new System.Diagnostics.ProcessStartInfo(executable) { UseShellExecute = false };
                foreach (var argument in arguments)
                {
                    startInfo.ArgumentList.Add(argument);
                }
                using var process = System.Diagnostics.Process.Start(startInfo);
                if (process is not null)
                {
                    return new PlumesignLoginLaunch(true, command, null);
                }
            }
            catch (Exception exception) when (exception is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
            {
                // Try the next terminal emulator.
            }
        }
        return new PlumesignLoginLaunch(false, command,
            "No terminal emulator was found. Run the command above in a terminal window, finish the Apple ID/2FA prompt, then press Refresh account status.");
    }

    private static string Quote(string path) => path.Contains(' ', StringComparison.Ordinal) ? "'" + path.Replace("'", "'\\''") + "'" : path;
}
