using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>
/// Linux signing/install path: the composed (or single-game) IPA is signed by the
/// official plumesign-linux-x86_64 CLI and installed with its
/// --register-and-install flow (falling back to "sign, then device --install" when
/// the device is already registered). No compile, compose or Windows Impactor GUI
/// is involved; the existing <see cref="PlumeSignRunner"/> argv contract is reused.
/// </summary>
public sealed class LinuxShellInstallService : IAppIpaInstaller
{
    private readonly PlumeSignRunner _signer;
    private readonly DevPushClient? _bridge;
    private readonly UsbMuxClient? _mux;
    private readonly string _workDirectory;

    public LinuxShellInstallService(PlumeSignRunner signer, DevPushClient? bridge, UsbMuxClient? mux, string workDirectory)
    {
        _signer = signer;
        _bridge = bridge;
        _mux = mux;
        _workDirectory = workDirectory;
    }

    public async Task<ShellInstallOutcome> InstallAsync(
        ShellManifest shell,
        string shellDirectory,
        string ipaPath,
        string? bundleIdOverride,
        string? deviceUdid,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        var template = shell.Verify(shellDirectory);
        if (!template.Ok)
        {
            throw new LauncherToolException("shell_invalid", template.Error ?? "The shell template IPA is not usable.", template.Fix);
        }
        var compatibility = ShellTemplateRules.ValidateManifest(shell);
        if (!compatibility.Ok)
        {
            throw new LauncherToolException("shell_template_incompatible", compatibility.Error!, compatibility.Fix);
        }
        if (!File.Exists(ipaPath))
        {
            throw new LauncherToolException("shell_invalid", "The IPA to install does not exist: " + ipaPath + ". Compose/export it again.");
        }
        var composed = IpaTemplateInspector.Inspect(ipaPath, requireEmptyCatalog: false);
        if (!composed.Ok)
        {
            throw new LauncherToolException("shell_template_incompatible", composed.Error!, composed.Fix);
        }
        var pin = LinuxPlumesignPins.Verify(_signer.PlumeSignPath);
        if (!pin.Ok)
        {
            return new ShellInstallOutcome(false, bundleIdOverride ?? shell.BundleId,
                null, AppleErrorCatalog.Lookup("impactor_missing")! with { Detail = pin.Describe() }, null);
        }

        var bundleId = string.IsNullOrWhiteSpace(bundleIdOverride) ? shell.BundleId : bundleIdOverride.Trim();
        if (!IsPlausibleBundleId(bundleId))
        {
            throw new LauncherToolException("shell_bundle_id", "'" + bundleId + "' is not a valid bundle identifier.",
                "Use reverse-DNS letters/digits/dots/hyphens, e.g. com.yourname.3ds2apple.shell.");
        }

        string? targetUdid = deviceUdid;
        if (string.IsNullOrWhiteSpace(targetUdid))
        {
            if (_bridge is null)
            {
                return new ShellInstallOutcome(false, bundleId, null,
                    AppleErrorCatalog.Lookup("device_not_found")! with { Detail = "the devpush device bridge is missing on Linux" }, null);
            }
            var devices = await _bridge.DevicesAsync(cancellationToken).ConfigureAwait(false);
            var usb = devices.Where(device => device.IsUsb || string.Equals(device.Connection, "usb", StringComparison.OrdinalIgnoreCase)).ToList();
            targetUdid = (usb.Count == 1 ? usb[0] : devices.Count == 1 ? devices[0] : null)?.Udid;
            if (string.IsNullOrWhiteSpace(targetUdid))
            {
                return new ShellInstallOutcome(false, bundleId, null,
                    AppleErrorCatalog.Lookup("device_not_found")! with { Detail = "select the target iPhone/iPad in Deploy first" }, null);
            }
        }
        log?.Invoke("Device selected for signing/install (UDID not logged).");
        // plumesign's --udid matches the numeric usbmuxd DeviceID on the Windows
        // path; on Linux the devpush/UI device is identified by UDID, so translate it
        // through the read-only usbmuxd ListDevices client before signing.
        var plumeDevice = await ResolvePlumeSignDeviceAsync(targetUdid, log, cancellationToken).ConfigureAwait(false);
        log?.Invoke("Signing the IPA with the official plumesign-linux-x86_64 (Apple ID session from ~/.config/PlumeImpactor)…");

        var signedDirectory = Path.Combine(_workDirectory, "signed");
        Directory.CreateDirectory(signedDirectory);
        var signedIpa = Path.Combine(signedDirectory, "app-" + bundleId.Replace('.', '-') + "-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + ".ipa");
        var request = new PlumeSignRequest(ipaPath, signedIpa, bundleId, "3ds2apple", plumeDevice, RegisterAndInstall: true);
        var result = await _signer.RunAsync(request, log, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            log?.Invoke("Installed. Keep the phone unlocked; the next step pushes game data (devpush).");
            return new ShellInstallOutcome(true, bundleId, signedIpa, null, result.LogPath);
        }

        // A saved account can still hit "device already registered" or a marker change;
        // if signing produced the signed IPA, install that explicitly instead of failing.
        if (File.Exists(signedIpa))
        {
            log?.Invoke("Signing finished but register-and-install did not confirm; retrying device install with the signed IPA.");
            var install = await _signer.InstallSignedAppAsync(signedIpa, plumeDevice, log, cancellationToken).ConfigureAwait(false);
            return new ShellInstallOutcome(install.Success, bundleId, signedIpa, install.Error, install.LogPath);
        }
        return new ShellInstallOutcome(false, bundleId, null, result.Error, result.LogPath);
    }

    /// <summary>
    /// Translate a devpush UDID into the usbmuxd numeric device id that plumesign's
    /// --udid expects (same value the Windows Impactor path uses). Returns the input
    /// unchanged when usbmuxd is unavailable so the caller still gets plumesign's own
    /// actionable error instead of a guessed override.
    /// </summary>
    private async Task<string> ResolvePlumeSignDeviceAsync(string udid, Action<string>? log, CancellationToken cancellationToken)
    {
        if (_mux is null)
        {
            return udid;
        }
        try
        {
            var devices = await _mux.ListDevicesAsync(TimeSpan.FromSeconds(5), cancellationToken).ConfigureAwait(false);
            var match = devices.FirstOrDefault(device => string.Equals(device.Udid, udid, StringComparison.OrdinalIgnoreCase))
                        ?? devices.FirstOrDefault(device => device.IsUsb)
                        ?? devices.FirstOrDefault();
            if (match is null)
            {
                throw new LauncherToolException("device_not_found", "usbmuxd did not report the connected iPhone/iPad.",
                    "Connect the iPhone/iPad by USB, unlock it, tap Trust and make sure usbmuxd is running, then retry.");
            }
            log?.Invoke("Resolved the usbmux device number for plumesign (UDID not logged).");
            return match.DeviceId.ToString(System.Globalization.CultureInfo.InvariantCulture);
        }
        catch (LauncherToolException)
        {
            throw;
        }
        catch (Exception exception) when (exception is IOException or System.Net.Sockets.SocketException or OperationCanceledException or UnauthorizedAccessException)
        {
            log?.Invoke("usbmuxd device-number lookup failed; passing the UDID to plumesign instead: " + exception.Message);
            return udid;
        }
    }

    private static bool IsPlausibleBundleId(string bundleId) =>
        !string.IsNullOrWhiteSpace(bundleId)
        && bundleId.Length <= 155
        && bundleId.Contains('.', StringComparison.Ordinal)
        && bundleId.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');
}
