using System.Reflection;

namespace ThreeDsTwoApple.Launcher.Core;

/// <summary>Identity of the launcher, used in logs, GameInfo.json and --version.</summary>
public static class LauncherInfo
{
    public const string ProductName = "3ds2apple-launcher-windows";

    /// <summary>Version recorded in pushed GameInfo.json (<c>launcherVersion</c>).</summary>
    public static string Version
    {
        get
        {
            var informational = typeof(LauncherInfo).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
            if (!string.IsNullOrWhiteSpace(informational))
            {
                var plus = informational.IndexOf('+');
                return plus >= 0 ? informational[..plus] : informational;
            }
            return typeof(LauncherInfo).Assembly.GetName().Version?.ToString(3) ?? "0.1.0";
        }
    }

    public static string VersionLine => $"{ProductName}/{Version}";

    public static string GameInfoLauncherVersion => VersionLine;

    /// <summary>Schema version of the pushed <c>GameInfo.json</c> the shell decodes.</summary>
    public const int GameInfoSchemaVersion = 1;

    /// <summary>GamePack host ABI version the shell expects (see docs/aot-first.md).</summary>
    public const int GamePackAbiVersion = 1;

    public const string RegistrationSymbol = "zk_gamepack_register";

    /// <summary>Directory name the shell scans inside the app's Documents container.</summary>
    public const string DocumentsGamesRelativePath = "Documents/Games";
}
