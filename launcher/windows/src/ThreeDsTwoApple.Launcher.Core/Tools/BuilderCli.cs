using System.Text.Json;
using System.Text.RegularExpressions;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Tools;

/// <summary>Probe result for the existing builder-windows / zkb CLI.</summary>
public sealed record BuilderProbe(bool Ready, string? Path, string? Version, string? Error);

/// <summary>One build on the user's macOS host (existing builder-windows command).</summary>
public sealed record BuildAgentBuildRequest(
    string Host,
    string RomPath,
    string BuildName,
    string DisplayName,
    string OutputDirectory);

/// <summary>Result of one macOS Build Agent build.</summary>
public sealed record BuildAgentResult(
    bool Success,
    int ExitCode,
    string? IpaPath,
    string? Sha256,
    string Log,
    string? ErrorCode,
    string? ErrorMessage);

/// <summary>A progress event from the Build Agent CLI (JSON mode).</summary>
public sealed record AgentProgress(string Stage, double? Percent, string Message);

/// <summary>
/// Thin wrapper around the existing <c>builder-windows</c> CLI (builder/windows),
/// which drives the project's macOS Build Agent over SSH. The launcher does not
/// re-implement SSH, the Agent protocol or the AOT pipeline: it runs the same
/// command the CLI-first frontend uses and streams its JSON events.
/// </summary>
public sealed class BuilderCli
{
    public const string ToolName = "builder";
    private readonly IProcessRunner _runner;

    public BuilderCli(IProcessRunner runner, string executablePath) => (_runner, ExecutablePath) = (runner, executablePath);

    public string ExecutablePath { get; }

    public static BuilderCli? Create(IProcessRunner runner, ToolLocator locator)
    {
        var path = locator.FindBuilderCli();
        return path is null ? null : new BuilderCli(runner, path);
    }

    public async Task<BuilderProbe> ProbeAsync(CancellationToken cancellationToken = default)
    {
        var result = await _runner.RunAsync(new ProcessRequest(ExecutablePath, new[] { "--version" }, Timeout: TimeSpan.FromSeconds(20)), cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!result.Started || !result.Ok)
        {
            return new BuilderProbe(false, ExecutablePath, null, result.Combined.Trim());
        }
        return new BuilderProbe(true, ExecutablePath, ToolLocator.FirstVersionLikeToken(result.Combined), null);
    }

    /// <summary>
    /// Build one game through the macOS host and download the unsigned IPA.
    /// Exit codes match zkb: 0 ok, 1 build failed, 2 usage/config, 3 transport,
    /// 4 canceled, 5 local I/O.
    /// </summary>
    public async Task<BuildAgentResult> BuildIpaAsync(
        BuildAgentBuildRequest request,
        Action<string>? onLogLine,
        Action<AgentProgress>? onProgress,
        CancellationToken cancellationToken = default)
    {
        var arguments = new List<string>
        {
            "build",
            "--host", request.Host,
            "--rom", request.RomPath,
            "--name", request.BuildName,
            "--display-name", request.DisplayName,
            "--out", request.OutputDirectory,
            "--json",
        };
        var log = new System.Text.StringBuilder();
        var ipaFromEvents = new List<string>();
        void OnLine(string line)
        {
            log.AppendLine(line);
            onLogLine?.Invoke(line);
            var trimmed = line.Trim();
            if (trimmed.Length == 0)
            {
                return;
            }
            if (trimmed[0] == '{')
            {
                try
                {
                    using var document = Json.TryParse(trimmed);
                    if (document is not null)
                    {
                        var root = document.RootElement;
                        var stage = Json.String(root, "stage", "step", "phase") ?? Json.String(root, "type") ?? "agent";
                        var percent = (double?)(Json.Long(root, "percent", "progress", "pct"));
                        var message = Json.String(root, "message", "hint", "detail") ?? Json.String(root, "event") ?? stage;
                        onProgress?.Invoke(new AgentProgress(stage, percent, message));
                        CollectIpaPaths(root, ipaFromEvents);
                        return;
                    }
                }
                catch (JsonException)
                {
                    // fall through to plain logging
                }
            }
            onProgress?.Invoke(new AgentProgress("agent", null, trimmed));
        }

        var process = await _runner.RunAsync(
            new ProcessRequest(ExecutablePath, arguments, Timeout: TimeSpan.FromHours(4)),
            onStdOutLine: OnLine,
            onStdErrLine: OnLine,
            cancellationToken: cancellationToken).ConfigureAwait(false);

        var text = log.ToString();
        if (!process.Started)
        {
            return new BuildAgentResult(false, -1, null, null, text, "build_agent_missing", $"Could not start {ExecutablePath}.");
        }
        if (process.TimedOut)
        {
            return new BuildAgentResult(false, process.ExitCode, null, null, text, "build_agent_timeout", "The Build Agent did not finish within 4 hours.");
        }
        if (process.ExitCode != 0)
        {
            var code = process.ExitCode switch
            {
                1 => "agent_build_failed",
                2 => "agent_usage",
                3 => "agent_transport",
                4 => "agent_canceled",
                5 => "agent_local_io",
                _ => "agent_failed",
            };
            return new BuildAgentResult(false, process.ExitCode, null, null, text, code, LastLines(process));
        }

        var ipaPath = FindIpa(request.OutputDirectory, ipaFromEvents);
        if (ipaPath is null)
        {
            return new BuildAgentResult(false, process.ExitCode, null, null, text, "agent_no_ipa",
                "The Agent finished successfully but no .ipa was found in its output directory. Check the host build log.");
        }
        var sha256 = Signing.ImpactorBundle.Sha256File(ipaPath);
        return new BuildAgentResult(true, process.ExitCode, ipaPath, sha256, text, null, null);
    }

    private static void CollectIpaPaths(JsonElement element, List<string> paths)
    {
        switch (element.ValueKind)
        {
            case JsonValueKind.String:
            {
                var value = element.GetString();
                if (!string.IsNullOrWhiteSpace(value) && value.EndsWith(".ipa", StringComparison.OrdinalIgnoreCase))
                {
                    paths.Add(value);
                }
                break;
            }
            case JsonValueKind.Object:
                foreach (var property in element.EnumerateObject())
                {
                    CollectIpaPaths(property.Value, paths);
                }
                break;
            case JsonValueKind.Array:
                foreach (var item in element.EnumerateArray())
                {
                    CollectIpaPaths(item, paths);
                }
                break;
        }
    }

    private static string? FindIpa(string outputDirectory, IReadOnlyList<string> fromEvents)
    {
        foreach (var path in fromEvents)
        {
            if (File.Exists(path))
            {
                return path;
            }
        }
        if (!Directory.Exists(outputDirectory))
        {
            return null;
        }
        return Directory.EnumerateFiles(outputDirectory, "*.ipa", SearchOption.AllDirectories)
            .Select(path => new FileInfo(path))
            .OrderByDescending(info => info.LastWriteTimeUtc)
            .Select(info => info.FullName)
            .FirstOrDefault();
    }

    private static string LastLines(ProcessResult process)
    {
        var lines = process.StdOutLines.Concat(process.StdErrLines).TakeLast(8).ToList();
        var text = string.Join("\n", lines);
        return text.Length > 1500 ? text[^1500..] : text;
    }
}
