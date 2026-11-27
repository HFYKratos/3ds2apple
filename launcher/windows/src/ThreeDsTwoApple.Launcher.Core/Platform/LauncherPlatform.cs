namespace ThreeDsTwoApple.Launcher.Core.Platform;

/// <summary>
/// Small cross-platform baseline for the shared Avalonia launcher (0.2.3 P0).
/// Windows keeps its existing names and paths; Linux uses ELF tool names and the
/// official Linux plumesign CLI. Everything that depends on the OS should ask
/// this class instead of hard-coding ".exe" or "windows".
/// </summary>
public static class LauncherPlatform
{
    public static bool IsWindows => OperatingSystem.IsWindows();

    public static bool IsLinux => OperatingSystem.IsLinux();

    public static bool IsMacOS => OperatingSystem.IsMacOS();

    /// <summary>Lower-case platform tag recorded in manifests/tool probes.</summary>
    public static string PlatformTag => IsWindows ? "windows" : IsLinux ? "linux" : IsMacOS ? "macos" : "unknown";

    /// <summary>Human-readable OS label for the About/Diagnostics pages.</summary>
    public static string OsDisplayName => IsWindows ? "Windows" : IsLinux ? "Linux" : IsMacOS ? "macOS" : "Unknown";

    /// <summary>".exe" on Windows, empty elsewhere.</summary>
    public static string ExecutableSuffix => IsWindows ? ".exe" : string.Empty;

    /// <summary>Append the host executable suffix unless the name already carries it.</summary>
    public static string WithExecutableSuffix(string baseName)
    {
        if (string.IsNullOrWhiteSpace(baseName))
        {
            return baseName;
        }
        return baseName.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || ExecutableSuffix.Length == 0
            ? baseName
            : baseName + ExecutableSuffix;
    }

    /// <summary>Bundled ROM/queue CLI (builder/pack).</summary>
    public static string PackCliFileName => WithExecutableSuffix("3ds2apple-pack");

    /// <summary>Device bridge CLI.</summary>
    public static string DevPushFileName => WithExecutableSuffix("devpush");

    /// <summary>Local AOT recompiler (Windows-only in the current release).</summary>
    public static string RecompilerFileName => WithExecutableSuffix("3dsrecomp");

    /// <summary>
    /// Official plumesign CLI of Impactor v2.7.3. Windows uses the bundled PE;
    /// Linux uses the official plumesign-linux-x86_64 build (verified by
    /// launcher/linux/vendor/PINS.json). macOS keeps the existing placeholder
    /// name; its signing path is the Xcode toolchain.
    /// </summary>
    public static string PlumeSignFileName => IsWindows
        ? "plumesign-windows-x86_64.exe"
        : IsLinux ? "plumesign-linux-x86_64" : "plumesign-macos-universal";

    /// <summary>Full Impactor app (Windows GUI helper). Linux only needs plumesign.</summary>
    public static string ImpactorFileName => IsWindows
        ? "Impactor-windows-x86_64-portable.exe"
        : IsLinux ? string.Empty : "Impactor-macos-universal";

    /// <summary>Portable data root directory name used beside the executable.</summary>
    public const string PortableDataDirectoryName = "3ds2apple-data";
}
