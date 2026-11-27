using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>Outcome of one "Refresh signing" action (re-sign/install the last IPA in place).</summary>
public sealed record SigningRefreshOutcome(
    bool Installed,
    string? IpaPath,
    ShellInstallOutcome? Install,
    string? Error)
{
    public static SigningRefreshOutcome NoIpa(string message) => new(false, null, null, message);
}

/// <summary>
/// Free Apple IDs expire after 7 days (0.2.2-beta5). The launcher remembers the last
/// composed/exported installable IPA and can re-sign + overwrite-install exactly that
/// IPA with the existing plumesign/Impactor path, without rebuilding packs, composing
/// a new app or deleting the app (Documents and saves survive an overwrite install).
/// This is NOT a new deploy: it cannot add games or update GamePacks.
/// </summary>
public sealed class SigningRefreshService
{
    public const string NoIpaMessage =
        "No installable IPA yet. Press Deploy once (or export a ready-to-sign package) and retry.";

    private readonly LauncherWorkspace _workspace;

    public SigningRefreshService(LauncherWorkspace workspace) => _workspace = workspace;

    /// <summary>Recorded path (may be stale/deleted); used for diagnostics.</summary>
    public string? LastIpaPath => _workspace.State.LastInstallableIpaPath;

    /// <summary>Recorded path only when the file still exists.</summary>
    public string? LastUsableIpaPath
    {
        get
        {
            var path = LastIpaPath;
            return !string.IsNullOrWhiteSpace(path) && File.Exists(path) ? path : null;
        }
    }

    /// <summary>True when a previously composed/exported IPA can be re-signed.</summary>
    public bool CanRefresh => LastUsableIpaPath is not null;

    /// <summary>Remember the last composed (Deploy) or exported (single-game IPA) file.</summary>
    public static void RecordInstallableIpa(LauncherWorkspace workspace, string? ipaPath)
    {
        if (string.IsNullOrWhiteSpace(ipaPath))
        {
            return;
        }
        var fullPath = Path.GetFullPath(ipaPath);
        if (!File.Exists(fullPath))
        {
            return;
        }
        workspace.State.LastInstallableIpaPath = fullPath;
        workspace.State.LastInstallableIpaAt = DateTimeOffset.UtcNow;
        workspace.SaveState();
    }

    /// <summary>
    /// Re-sign + overwrite-install the recorded IPA. <paramref name="bundleIdOverride"/>
    /// must be the installed bundle id so the existing app is updated in place; when
    /// none is recorded the shell's bundle id is used.
    /// </summary>
    public async Task<SigningRefreshOutcome> RefreshAsync(
        IAppIpaInstaller installer,
        ShellManifest shell,
        string shellDirectory,
        string? deviceUdid,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        var ipaPath = LastUsableIpaPath;
        if (ipaPath is null)
        {
            return SigningRefreshOutcome.NoIpa(NoIpaMessage);
        }
        var bundleId = string.IsNullOrWhiteSpace(_workspace.State.InstalledBundleId)
            ? null
            : _workspace.State.InstalledBundleId;
        try
        {
            var install = await installer.InstallAsync(
                shell,
                shellDirectory,
                ipaPath,
                bundleId,
                deviceUdid,
                log,
                cancellationToken).ConfigureAwait(false);
            if (!install.Installed)
            {
                var error = install.Error;
                return new SigningRefreshOutcome(false, ipaPath, install,
                    error is null
                        ? "Signing/installing the saved IPA failed."
                        : error.Title + (string.IsNullOrWhiteSpace(error.Detail) ? string.Empty : " — " + error.Detail));
            }
            _workspace.State.InstalledBundleId = install.BundleId;
            _workspace.State.InstalledAt = DateTimeOffset.UtcNow;
            _workspace.SaveState();
            log?.Invoke("refresh signing: re-signed and installed " + ipaPath + " as " + install.BundleId + " (app data kept)");
            return new SigningRefreshOutcome(true, ipaPath, install, null);
        }
        catch (LauncherToolException exception)
        {
            return new SigningRefreshOutcome(false, ipaPath, null, exception.Message);
        }
    }
}
