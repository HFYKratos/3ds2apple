using System.Text;

namespace ThreeDsTwoApple.Launcher.Core.Tools;

/// <summary>A resolved tool binary plus what probing found (never a guessed success).</summary>
public sealed record ToolProbe(string Name, string? Path, string? Version, string? Error, string Source)
{
    public bool Found => Path is not null;
    public bool Ready => Found && Version is not null;

    public string Describe() => Found
        ? $"{Name}: {Path} ({Version ?? "version unknown"})"
        : $"{Name}: not found — {Error ?? "set the path in Settings or put it into Bin/" }";
}

/// <summary>
/// Finds the bundled / configured tool binaries. Resolution order is the same for
/// every tool: explicit environment override, a path saved in launcher settings,
/// the distribution layout (next to the launcher executable), then PATH.
/// </summary>
public sealed class ToolLocator
{
    private readonly string _distributionRoot;
    private readonly Dictionary<string, string?> _overrides = new(StringComparer.OrdinalIgnoreCase);

    public ToolLocator(string? distributionRoot = null)
    {
        _distributionRoot = string.IsNullOrWhiteSpace(distributionRoot) ? AppContext.BaseDirectory : distributionRoot;
    }

    public string DistributionRoot => _distributionRoot;

    /// <summary>Remember a path from the launcher Settings page (empty string clears it).</summary>
    public void Override(string toolName, string? path) =>
        _overrides[toolName] = string.IsNullOrWhiteSpace(path) ? null : path;

    public string? OverrideFor(string toolName) => _overrides.TryGetValue(toolName, out var path) ? path : null;

    public const string PackCliTool = "pack";
    public const string DevPushTool = "devpush";
    public const string BuilderTool = "builder";
    public const string ImpactorTool = "impactor";
    public const string PlumeSignTool = "plumesign";
    public const string RecompTool = "recomp";
    public const string LlvmTool = "llvm";

    /// <summary>3ds2apple-pack (ROM detection / package queue / GameInfo writer).</summary>
    public string? FindPackCli() => Find(PackCliTool, "THREEDS2APPLE_PACK", "3ds2apple-pack", "Bin");

    /// <summary>devpush (device bridge CLI from task-16).</summary>
    public string? FindDevPush() => Find(DevPushTool, "DEVPUSH_EXE", "devpush", "Bin");

    /// <summary>builder-windows / zkb (drives the macOS Build Agent).</summary>
    public string? FindBuilderCli() => Find(BuilderTool, "THREEDS2APPLE_BUILDER", "builder-windows", "Bin");

    /// <summary>3dsrecomp.exe (ROM -> generated C) for the experimental local build.</summary>
    public string? FindRecompiler() => Find(RecompTool, "THREEDS2APPLE_RECOMP", "3dsrecomp", "Bin");

    /// <summary>
    /// Official LLVM bin directory (clang.exe, llvm-ar.exe, ld64.lld.exe) for the
    /// experimental local build: Settings override, WINBUILD_LLVM_DIR, the bundled
    /// Bin/llvm layout, the default Windows install path, then clang on PATH.
    /// </summary>
    public string? FindLlvmBinDirectory()
    {
        var configured = OverrideFor(LlvmTool);
        if (!string.IsNullOrWhiteSpace(configured) && Directory.Exists(configured))
        {
            return configured;
        }
        var fromEnvironment = Environment.GetEnvironmentVariable("WINBUILD_LLVM_DIR");
        if (!string.IsNullOrWhiteSpace(fromEnvironment) && Directory.Exists(fromEnvironment))
        {
            return fromEnvironment;
        }
        foreach (var candidate in new[]
                 {
                     Path.Combine(_distributionRoot, "Bin", "llvm"),
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LLVM", "bin"),
                 })
        {
            if (Directory.Exists(candidate))
            {
                return candidate;
            }
        }
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = directory.Trim();
            if (File.Exists(Path.Combine(trimmed, "clang.exe")) || File.Exists(Path.Combine(trimmed, "clang")))
            {
                return trimmed;
            }
        }
        return null;
    }

    /// <summary>Official Impactor v2.7.2 portable executable, bundled unmodified.</summary>
    public string? FindImpactor() => Find(
        ImpactorTool,
        "THREEDS2APPLE_IMPACTOR",
        Signing.ImpactorPins.ImpactorFileName,
        Path.Combine("ThirdParty", "Impactor"));

    /// <summary>Official plumesign CLI of the same Impactor release.</summary>
    public string? FindPlumeSign() => Find(
        PlumeSignTool,
        "THREEDS2APPLE_PLUMESIGN",
        Signing.ImpactorPins.PlumeSignFileName,
        Path.Combine("ThirdParty", "Impactor"));

    public string ImpactorDirectory => Path.Combine(_distributionRoot, "ThirdParty", "Impactor");

    public string ShellDirectory => Path.Combine(_distributionRoot, "Shell");

    public string BinDirectory => Path.Combine(_distributionRoot, "Bin");

    /// <summary>All candidate paths for diagnostics (the UI shows where it looked).</summary>
    public IReadOnlyList<string> Candidates(string baseName, string subdirectory) =>
        new[]
        {
            Path.Combine(_distributionRoot, subdirectory, baseName),
            Path.Combine(_distributionRoot, subdirectory, baseName + ".exe"),
            Path.Combine(_distributionRoot, baseName),
            Path.Combine(_distributionRoot, baseName + ".exe"),
        };

    private string? Find(string toolName, string environmentVariable, string baseName, string subdirectory)
    {
        var configured = _overrides.TryGetValue(toolName, out var saved) ? saved : null;
        if (IsFile(configured))
        {
            return configured;
        }
        var fromEnvironment = Environment.GetEnvironmentVariable(environmentVariable);
        if (IsFile(fromEnvironment))
        {
            return fromEnvironment;
        }
        foreach (var candidate in Candidates(baseName, subdirectory))
        {
            if (IsFile(candidate))
            {
                return candidate;
            }
        }
        // Last resort: PATH (development machines with cargo/dotnet on PATH).
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var name in new[] { baseName, baseName + ".exe", baseName + ".cmd", baseName + ".bat" })
            {
                var candidate = Path.Combine(directory.Trim(), name);
                if (IsFile(candidate))
                {
                    return candidate;
                }
            }
        }
        return null;
    }

    private static bool IsFile(string? path) =>
        !string.IsNullOrWhiteSpace(path) && File.Exists(path);

    /// <summary>Probe a CLI's version output without failing when it is absent.</summary>
    public static async Task<ToolProbe> ProbeAsync(
        string name,
        string? path,
        IProcessRunner runner,
        string[] versionArguments,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return new ToolProbe(name, null, null, "not found", "missing");
        }
        var result = await runner.RunAsync(
            new ProcessRequest(path, versionArguments, Timeout: TimeSpan.FromSeconds(20)),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!result.Started)
        {
            return new ToolProbe(name, path, null, result.Combined.Trim(), "unusable");
        }
        var text = result.Combined.Trim();
        var version = FirstVersionLikeToken(text) ?? (result.Ok ? text.Split('\n').FirstOrDefault() : null);
        return result.Ok
            ? new ToolProbe(name, path, version, null, "ok")
            : new ToolProbe(name, path, version, text.Length > 300 ? text[..300] : text, "failed");
    }

    /// <summary>Extract the first <c>x.y.z</c> token so tool banners stay compatible.</summary>
    public static string? FirstVersionLikeToken(string? text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return null;
        }
        foreach (var token in text.Split(new[] { ' ', '\t', '\r', '\n', '(', ')', ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            var trimmed = token.TrimStart('v', 'V');
            var digits = 0;
            var dots = 0;
            var valid = true;
            foreach (var c in trimmed)
            {
                if (char.IsDigit(c)) { digits++; }
                else if (c == '.' && digits > 0) { dots++; }
                else { valid = false; break; }
            }
            if (valid && dots >= 1 && digits > 0)
            {
                return trimmed;
            }
        }
        return null;
    }
}
