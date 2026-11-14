using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Device;

/// <summary>Feature flags reported by <c>devpush capabilities --json</c>.</summary>
public sealed record DevPushCapabilities(string Version, string Schema, IReadOnlyList<string> Commands, IReadOnlyDictionary<string, bool> Features)
{
    public bool Has(string command) => Commands.Contains(command, StringComparer.OrdinalIgnoreCase);
}

/// <summary>One <c>devpush --json</c> NDJSON event, already validated to schema devpush/1.</summary>
public sealed record DevPushEvent(DevPushEventType Type, string? Command, JsonElement Payload);

public enum DevPushEventType
{
    Begin,
    Progress,
    Warn,
    Done,
    Error,
    Unknown,
}

/// <summary>Result of <c>put/get/put-tar</c>.</summary>
public sealed record TransferResult(string? Path, long Bytes, string? Sha256);

/// <summary>
/// Typed client for the device bridge CLI (task-16 <c>tools/devpush</c>, contract
/// <c>devpush/1</c>, documented in docs/device-bridge.md and
/// docs/windows-launcher.md).
/// </summary>
/// <remarks>
/// The launcher does not talk to usbmuxd/AFC itself: every device operation goes
/// through this CLI so there is exactly one implementation of house_arrest/AFC,
/// the 90-second stall watchdog and the JSON contract. Progress lines are
/// forwarded as they arrive; a structured error event becomes a
/// <see cref="LauncherToolException"/> with the CLI's stable code/hint.
/// </remarks>
public sealed class DevPushClient
{
    public const string Schema = "devpush/1";

    private readonly IProcessRunner _runner;
    private readonly string? _mockDirectory;
    private readonly TimeSpan _defaultTimeout;

    public DevPushClient(IProcessRunner runner, string executablePath, string? mockDirectory = null, TimeSpan? defaultTimeout = null)
    {
        _runner = runner;
        ExecutablePath = executablePath;
        _mockDirectory = string.IsNullOrWhiteSpace(mockDirectory) ? null : mockDirectory;
        _defaultTimeout = defaultTimeout ?? TimeSpan.FromMinutes(30);
    }

    public string ExecutablePath { get; }

    public static DevPushClient? Create(IProcessRunner runner, Tools.ToolLocator locator)
    {
        var path = locator.FindDevPush();
        var mock = Environment.GetEnvironmentVariable("DEVPUSH_MOCK_DIR");
        return path is null ? null : new DevPushClient(runner, path, mock);
    }

    public async Task<DevPushCapabilities> CapabilitiesAsync(CancellationToken cancellationToken = default)
    {
        var run = await RunAsync(new[] { "capabilities" }, "capabilities", null, cancellationToken).ConfigureAwait(false);
        var done = run.Done;
        var features = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        if (Json.Obj(done, "features") is { } featureElement)
        {
            foreach (var property in featureElement.EnumerateObject())
            {
                features[property.Name] = property.Value.ValueKind == JsonValueKind.True;
            }
        }
        return new DevPushCapabilities(
            Json.String(done, "version") ?? "unknown",
            Json.String(done, "schema") ?? Schema,
            Json.Array(done, "commands").Select(c => c.GetString() ?? string.Empty).Where(c => c.Length > 0).ToList(),
            features);
    }

    public async Task<IReadOnlyList<DeviceInfo>> DevicesAsync(CancellationToken cancellationToken = default)
    {
        var run = await RunAsync(new[] { "devices" }, "devices", null, cancellationToken).ConfigureAwait(false);
        var devices = new List<DeviceInfo>();
        foreach (var element in Json.Array(run.Done, "devices"))
        {
            var udid = Json.String(element, "udid");
            if (string.IsNullOrWhiteSpace(udid))
            {
                continue;
            }
            devices.Add(new DeviceInfo(
                udid,
                Json.String(element, "name"),
                Json.String(element, "model"),
                Json.String(element, "iosVersion"),
                Json.String(element, "connection") ?? "usb",
                Json.Bool(element, "paired") ?? false));
        }
        return devices;
    }

    /// <summary>App attributes incl. the data container used for AFC pushes.</summary>
    /// <exception cref="LauncherToolException">code <c>app_missing</c> when the app is not installed.</exception>
    public async Task<AppAttributes> AppAttrAsync(string bundleId, string? udid = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "app-attr", "--bundle-id", bundleId };
        AddUdid(arguments, udid);
        try
        {
            var run = await RunAsync(arguments, "app-attr", null, cancellationToken).ConfigureAwait(false);
            return new AppAttributes(
                Json.Bool(run.Done, "installed") ?? true,
                Json.String(run.Done, "dataContainer"),
                Json.String(run.Done, "appBundleVersion"),
                Json.Bool(run.Done, "fileSharingEnabled"));
        }
        catch (LauncherToolException error) when (error.Code == "app_missing")
        {
            return new AppAttributes(false, null, null, null);
        }
    }

    public async Task<IReadOnlyList<RemoteEntry>> ListAsync(
        string bundleId,
        string remotePath,
        string container = "app",
        string? udid = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "ls", "--bundle-id", bundleId, "--path", remotePath, "--container", container };
        AddUdid(arguments, udid);
        var run = await RunAsync(arguments, "ls", null, cancellationToken).ConfigureAwait(false);
        return ParseEntries(Json.Array(run.Done, "entries"));
    }

    /// <summary>Stat one remote path; null when it does not exist (path_not_found).</summary>
    public async Task<RemoteEntry?> StatAsync(
        string bundleId,
        string remotePath,
        string container = "app",
        string? udid = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "stat", "--bundle-id", bundleId, "--path", remotePath, "--container", container };
        AddUdid(arguments, udid);
        try
        {
            var run = await RunAsync(arguments, "stat", null, cancellationToken).ConfigureAwait(false);
            return new RemoteEntry(
                Path.GetFileName(remotePath),
                Json.Bool(run.Done, "isDir") ?? false,
                Json.Long(run.Done, "size") ?? 0,
                Json.Long(run.Done, "mtime"));
        }
        catch (LauncherToolException error) when (error.Code is "path_not_found")
        {
            return null;
        }
    }

    /// <summary>Copy one local file into the installed app's container (AFC).</summary>
    public async Task<TransferResult> PutAsync(
        string bundleId,
        string localPath,
        string remotePath,
        string container = "app",
        string? udid = null,
        IProgress<TransferProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "put", "--bundle-id", bundleId, "--local", localPath, "--remote", remotePath, "--container", container };
        AddUdid(arguments, udid);
        var run = await RunAsync(arguments, "put", progress, cancellationToken).ConfigureAwait(false);
        return new TransferResult(
            Json.String(run.Done, "remotePath") ?? remotePath,
            Json.Long(run.Done, "bytes") ?? 0,
            Json.String(run.Done, "sha256"));
    }

    /// <summary>Stream a local tar to the device and unpack it under <paramref name="destination"/>.</summary>
    public async Task<TransferResult> PutTarAsync(
        string bundleId,
        string tarPath,
        string destination,
        string container = "app",
        string? udid = null,
        IProgress<TransferProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "put-tar", "--bundle-id", bundleId, "--tar", tarPath, "--dest", destination, "--container", container };
        AddUdid(arguments, udid);
        var run = await RunAsync(arguments, "put-tar", progress, cancellationToken).ConfigureAwait(false);
        return new TransferResult(Json.String(run.Done, "dest") ?? destination, Json.Long(run.Done, "bytes") ?? 0, null);
    }

    public async Task GetAsync(
        string bundleId,
        string remotePath,
        string localPath,
        string container = "app",
        string? udid = null,
        IProgress<TransferProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "get", "--bundle-id", bundleId, "--remote", remotePath, "--local", localPath, "--container", container };
        AddUdid(arguments, udid);
        await RunAsync(arguments, "get", progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task MakeDirectoryAsync(string bundleId, string remotePath, string container = "app", string? udid = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "mkdir", "--bundle-id", bundleId, "--path", remotePath, "--container", container };
        AddUdid(arguments, udid);
        await RunAsync(arguments, "mkdir", null, cancellationToken).ConfigureAwait(false);
    }

    public async Task RemoveAsync(string bundleId, string remotePath, string container = "app", string? udid = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "rm", "--bundle-id", bundleId, "--path", remotePath, "--container", container };
        AddUdid(arguments, udid);
        await RunAsync(arguments, "rm", null, cancellationToken).ConfigureAwait(false);
    }

    public async Task<long> FreeBytesAsync(string bundleId, string container = "app", string? udid = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "free", "--bundle-id", bundleId, "--container", container };
        AddUdid(arguments, udid);
        var run = await RunAsync(arguments, "free", null, cancellationToken).ConfigureAwait(false);
        return Json.Long(run.Done, "freeBytes") ?? 0;
    }

    public async Task InstallAsync(string ipaPath, string? bundleId = null, string? udid = null, IProgress<TransferProgress>? progress = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "install", "--ipa", ipaPath };
        if (!string.IsNullOrWhiteSpace(bundleId))
        {
            arguments.Add("--bundle-id");
            arguments.Add(bundleId);
        }
        AddUdid(arguments, udid);
        await RunAsync(arguments, "install", progress, cancellationToken).ConfigureAwait(false);
    }

    public async Task UninstallAsync(string bundleId, string? udid = null, CancellationToken cancellationToken = default)
    {
        var arguments = new List<string> { "uninstall", "--bundle-id", bundleId };
        AddUdid(arguments, udid);
        await RunAsync(arguments, "uninstall", null, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>Probe the binary and its contract version; used by Settings and --self-test.</summary>
    public async Task<Tools.ToolProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            var capabilities = await CapabilitiesAsync(cancellationToken).ConfigureAwait(false);
            return new Tools.ToolProbe("devpush", ExecutablePath, capabilities.Version, null, "ok");
        }
        catch (LauncherToolException error)
        {
            return new Tools.ToolProbe("devpush", ExecutablePath, null, error.Message, "failed");
        }
    }

    // --- internals ---------------------------------------------------------

    private static void AddUdid(List<string> arguments, string? udid)
    {
        if (!string.IsNullOrWhiteSpace(udid))
        {
            arguments.Add("--udid");
            arguments.Add(udid);
        }
    }

    private static IReadOnlyList<RemoteEntry> ParseEntries(IReadOnlyList<JsonElement> elements)
    {
        var entries = new List<RemoteEntry>();
        foreach (var element in elements)
        {
            var name = Json.String(element, "name");
            if (name is null)
            {
                continue;
            }
            entries.Add(new RemoteEntry(name, Json.Bool(element, "isDir") ?? false, Json.Long(element, "size") ?? 0, Json.Long(element, "mtime")));
        }
        return entries;
    }

    private async Task<DevPushRun> RunAsync(
        IReadOnlyList<string> commandArguments,
        string expectedCommand,
        IProgress<TransferProgress>? progress,
        CancellationToken cancellationToken)
    {
        var arguments = new List<string>();
        if (_mockDirectory is not null)
        {
            arguments.Add("--mock-dir");
            arguments.Add(_mockDirectory);
        }
        arguments.Add("--json");
        arguments.AddRange(commandArguments);

        DevPushRunState state = new();
        var process = await _runner.RunAsync(
            new ProcessRequest(ExecutablePath, arguments, Timeout: _defaultTimeout),
            line => OnLine(line, expectedCommand, state, progress),
            cancellationToken: cancellationToken).ConfigureAwait(false);

        if (state.Error is not null)
        {
            throw state.Error;
        }
        if (!process.Started)
        {
            throw new LauncherToolException(
                "devpush_unavailable",
                $"Could not start the device bridge ({ExecutablePath}).",
                "Make sure Bin/devpush.exe is next to the launcher, or set its path in Settings.");
        }
        if (!process.Ok)
        {
            throw new LauncherToolException(
                CodeForExit(process.ExitCode),
                DescribeFailure(process),
                HintFor(CodeForExit(process.ExitCode)),
                process.ExitCode);
        }
        if (state.Done is null)
        {
            throw new LauncherToolException(
                "devpush_protocol",
                $"The device bridge exited successfully but sent no done event for '{expectedCommand}'.",
                "Update Bin/devpush.exe to the version bundled with this launcher.");
        }
        return new DevPushRun(state.Done.Value, state.Warnings.ToList());
    }

    /// <summary>Parse one devpush/1 NDJSON line; null when the line is not a launcher event.</summary>
    public static DevPushEvent? ParseEventLine(string line)
    {
        var trimmed = line.Trim();
        if (trimmed.Length == 0 || trimmed[0] != '{')
        {
            return null;
        }
        using var document = Json.TryParse(trimmed);
        if (document is null)
        {
            return null;
        }
        var root = document.RootElement;
        var schema = Json.String(root, "schema");
        if (schema is not null && schema != Schema)
        {
            return null;
        }
        var type = (Json.String(root, "type") ?? string.Empty).ToLowerInvariant() switch
        {
            "begin" => DevPushEventType.Begin,
            "progress" => DevPushEventType.Progress,
            "warn" => DevPushEventType.Warn,
            "done" => DevPushEventType.Done,
            "error" => DevPushEventType.Error,
            _ => DevPushEventType.Unknown,
        };
        return new DevPushEvent(type, Json.String(root, "command"), root.Clone());
    }

    private static void OnLine(string line, string expectedCommand, DevPushRunState state, IProgress<TransferProgress>? progress)
    {
        var parsed = ParseEventLine(line);
        if (parsed is null)
        {
            return;
        }
        var root = parsed.Payload;
        switch (parsed.Type)
        {
            case DevPushEventType.Progress:
            {
                progress?.Report(new TransferProgress(
                    Json.String(root, "file"),
                    Json.Long(root, "bytesSent") ?? 0,
                    Json.Long(root, "bytesTotal") ?? 0));
                break;
            }
            case DevPushEventType.Warn:
            {
                var message = Json.String(root, "message") ?? root.GetRawText();
                lock (state.Warnings)
                {
                    state.Warnings.Add(message);
                }
                break;
            }
            case DevPushEventType.Done:
            {
                lock (state)
                {
                    state.Done = root;
                }
                break;
            }
            case DevPushEventType.Error:
            {
                var error = Json.Obj(root, "error");
                var code = error is { } e ? Json.String(e, "code") ?? "devpush_error" : "devpush_error";
                var message = error is { } e2 ? Json.String(e2, "message") ?? "device bridge reported an error" : "device bridge reported an error";
                var hint = error is { } e3 ? Json.String(e3, "hint") : null;
                var exitCode = (int?)Json.Long(root, "exitCode") ?? (error is { } e4 ? (int?)Json.Long(e4, "exitCode") : null);
                lock (state)
                {
                    state.Error = new LauncherToolException(code, $"{parsed.Command ?? expectedCommand}: {message}", hint, exitCode);
                }
                break;
            }
            default:
                break;
        }
    }

    private static string DescribeFailure(ProcessResult process)
    {
        var line = Tools.PackCli.FirstMeaningfulLine(process);
        return line.Length > 500 ? line[..500] : line;
    }

    private static string CodeForExit(int exitCode) => exitCode switch
    {
        2 => "devpush_usage",
        3 => "device_unavailable",
        4 => "pairing_required",
        5 => "app_missing",
        6 => "stall_timeout",
        7 => "afc_error",
        8 => "install_failed",
        9 => "unsupported",
        _ => "devpush_failed",
    };

    private static string? HintFor(string code) => code switch
    {
        "device_unavailable" => "Connect the iPhone/iPad by USB, unlock it, and make sure it shows up in Finder / Apple Devices.",
        "pairing_required" => "Unlock the phone and tap Trust on the 'Trust This Computer?' prompt, then refresh devices.",
        "app_missing" => "Install the base shell app first (Device tab -> Install base shell).",
        "stall_timeout" => "The transfer stalled for 90 s. Keep the phone unlocked and on the same cable, then retry; already-pushed files are skipped.",
        "afc_error" => "The app container could not be opened. Update the base shell app and make sure the phone is unlocked.",
        "unsupported" => "This devpush build does not support the command. Update Bin/devpush.exe.",
        "devpush_usage" => "Internal launcher/devpush argument mismatch; this is a launcher bug, please report it.",
        _ => "See the launcher log for the device bridge output.",
    };

    private sealed class DevPushRunState
    {
        public JsonElement? Done;
        public LauncherToolException? Error;
        public List<string> Warnings { get; } = new();
    }

    private sealed record DevPushRun(JsonElement Done, IReadOnlyList<string> Warnings);
}
