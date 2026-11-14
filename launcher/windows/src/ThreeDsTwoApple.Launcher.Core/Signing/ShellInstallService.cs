using System.Text.Json.Serialization;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>
/// <c>Shell/manifest.json</c>: identity + pinned hash of the ROM-free shell
/// template IPA (empty catalogue, no packs, no ROMs) shipped with the launcher.
/// The installable app is composed from it (see BuildPipeline/IpaComposer.cs) and the
/// composed IPA is what plumesign signs and installs.
/// </summary>
public sealed record ShellManifest(
    [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
    [property: JsonPropertyName("fileName")] string FileName,
    [property: JsonPropertyName("version")] string Version,
    [property: JsonPropertyName("bundleId")] string BundleId,
    [property: JsonPropertyName("sha256")] string Sha256,
    [property: JsonPropertyName("bytes")] long Bytes,
    [property: JsonPropertyName("build")] int Build = 0,
    [property: JsonPropertyName("minIosVersion")] string? MinIosVersion = null)
{
    public const string ManifestFileName = "manifest.json";
    public const string DefaultIpaFileName = "3ds2apple-shell.ipa";

    public static string ManifestPath(string shellDirectory) => Path.Combine(shellDirectory, ManifestFileName);

    public static async Task<ShellManifest?> ReadAsync(string shellDirectory, CancellationToken cancellationToken = default)
    {
        var path = ManifestPath(shellDirectory);
        if (!File.Exists(path))
        {
            return null;
        }
        try
        {
            var json = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
            var manifest = System.Text.Json.JsonSerializer.Deserialize<ShellManifest>(json, Json.ReadOptions);
            if (manifest is null || manifest.SchemaVersion != 1 || string.IsNullOrWhiteSpace(manifest.FileName) || string.IsNullOrWhiteSpace(manifest.BundleId))
            {
                return null;
            }
            return manifest;
        }
        catch (System.Text.Json.JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    /// <summary>Verify a template/composed IPA exists and (for the pinned template) the size/SHA-256.</summary>
    public ShellVerification Verify(string shellDirectory)
    {
        var ipaPath = Path.Combine(shellDirectory, FileName);
        if (!File.Exists(ipaPath))
        {
            return new ShellVerification(false, ipaPath, null, "The shell template IPA is not bundled (Shell/" + FileName + ").", "Run launcher/windows/tools/prepare-dist.ps1 with a shell template IPA built on macOS.");
        }
        var (sha256, bytes) = HashIpa(ipaPath);
        if (!string.IsNullOrWhiteSpace(Sha256) && !string.Equals(Sha256, sha256, StringComparison.OrdinalIgnoreCase))
        {
            return new ShellVerification(false, ipaPath, bytes,
                "Shell template IPA SHA-256 mismatch (manifest " + Sha256 + ", file " + sha256 + ").",
                "The bundled template was modified or is the wrong build; rebuild/repack the distribution.");
        }
        if (Bytes > 0 && Bytes != bytes)
        {
            return new ShellVerification(false, ipaPath, bytes,
                "Shell template IPA size mismatch (manifest " + Bytes.ToString() + ", file " + bytes.ToString() + ").",
                "The bundled template is truncated or the wrong build; rebuild/repack the distribution.");
        }
        return new ShellVerification(true, ipaPath, bytes, null, null);
    }

    private static (string Sha256, long Bytes) HashIpa(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = System.Security.Cryptography.SHA256.Create();
        return (Convert.ToHexStringLower(sha.ComputeHash(stream)), stream.Length);
    }
}

/// <summary>Result of verifying the bundled shell template IPA.</summary>
public sealed record ShellVerification(bool Ok, string IpaPath, long? ActualBytes, string? Error, string? Fix);

/// <summary>Outcome of installing the app.</summary>
public sealed record ShellInstallOutcome(
    bool Installed,
    string BundleId,
    string? SignedIpaPath,
    SigningError? Error,
    string? LogPath);

/// <summary>
/// Signs and installs the composed app IPA with the bundled official Impactor's
/// plumesign CLI. The whole IPA is signed by plumesign, which covers the nested
/// Frameworks/GamePack-&lt;TITLEID&gt;.dylib files (that is why packs are inside the
/// app bundle instead of being pushed into Documents).
/// </summary>
/// <remarks>
/// The Apple ID is entered in Impactor by the user; the launcher never handles
/// credentials. A stale "device already registered" reply falls back to sign-only
/// + device install, the retry S2Arm documents.
/// </remarks>
public sealed class ShellInstallService
{
    private readonly ImpactorBundle _bundle;
    private readonly UsbMuxClient _mux;
    private readonly PlumeSignRunner _signer;
    private readonly string _workDirectory;

    public ShellInstallService(ImpactorBundle bundle, UsbMuxClient mux, PlumeSignRunner signer, string workDirectory)
    {
        _bundle = bundle;
        _mux = mux;
        _signer = signer;
        _workDirectory = workDirectory;
    }

    /// <summary>
    /// Sign + install one IPA (the composed app, or the bare template as a
    /// fallback) after checking the pinned shell template is still intact.
    /// </summary>
    public async Task<ShellInstallOutcome> InstallAsync(
        ShellManifest shell,
        string shellDirectory,
        string ipaPath,
        string? bundleIdOverride,
        string? deviceUdid,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        var templateVerification = shell.Verify(shellDirectory);
        if (!templateVerification.Ok)
        {
            throw new LauncherToolException("shell_invalid", templateVerification.Error ?? "The shell template IPA is not usable.", templateVerification.Fix);
        }
        if (!File.Exists(ipaPath))
        {
            throw new LauncherToolException("shell_invalid", "The IPA to install does not exist: " + ipaPath, "Compose/install again; this is a launcher bug if it repeats.");
        }

        var compatibility = ShellTemplateRules.ValidateManifest(shell);
        if (!compatibility.Ok)
        {
            throw new LauncherToolException("shell_template_incompatible", compatibility.Error!, compatibility.Fix);
        }
        var templateInspection = IpaTemplateInspector.Inspect(templateVerification.IpaPath, requireEmptyCatalog: true);
        if (!templateInspection.Ok)
        {
            throw new LauncherToolException("shell_template_incompatible", templateInspection.Error!, templateInspection.Fix);
        }
        log?.Invoke("Template identity: " + (templateInspection.Identity?.Version ?? "?") + " (build " + (templateInspection.Identity?.Build?.ToString() ?? "?") + "), catalogue schema " + (templateInspection.Identity?.CatalogSchemaVersion.ToString() ?? "?") + ", games " + (templateInspection.Identity?.GameCount.ToString() ?? "?") + ".");
        if (!string.Equals(Path.GetFullPath(ipaPath), Path.GetFullPath(templateVerification.IpaPath), StringComparison.OrdinalIgnoreCase))
        {
            var composedInspection = IpaTemplateInspector.Inspect(ipaPath, requireEmptyCatalog: false);
            if (!composedInspection.Ok)
            {
                throw new LauncherToolException("shell_template_incompatible", composedInspection.Error!, composedInspection.Fix);
            }
            log?.Invoke("Composed app identity: " + (composedInspection.Identity?.Version ?? "?") + " (build " + (composedInspection.Identity?.Build?.ToString() ?? "?") + "), games " + (composedInspection.Identity?.GameCount.ToString() ?? "?") + ".");
        }

        var bundleStatus = _bundle.Verify();
        if (!bundleStatus.Ready)
        {
            var error = AppleErrorCatalog.Lookup("impactor_missing")! with { Detail = bundleStatus.Summary };
            return new ShellInstallOutcome(false, bundleIdOverride ?? shell.BundleId, null, error, null);
        }

        var bundleId = string.IsNullOrWhiteSpace(bundleIdOverride) ? shell.BundleId : bundleIdOverride.Trim();
        if (!IsPlausibleBundleId(bundleId))
        {
            throw new LauncherToolException("shell_bundle_id", "'" + bundleId + "' is not a valid bundle identifier.",
                "Use reverse-DNS letters/digits/dots/hyphens, e.g. com.yourname.3ds2apple.shell.");
        }

        MuxDevice? device;
        try
        {
            device = await _mux.FindAsync(deviceUdid, cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (LauncherToolException error)
        {
            return new ShellInstallOutcome(false, bundleId, null, AppleErrorCatalog.Lookup("device_not_found")! with { Detail = error.Message }, null);
        }
        if (device is null)
        {
            return new ShellInstallOutcome(false, bundleId, null, AppleErrorCatalog.Lookup("device_not_found")!, null);
        }
        log?.Invoke("Device: " + Privacy.RedactUdid(device.Udid) + " (usbmux id " + device.DeviceId.ToString() + ", " + device.ConnectionType + ")");
        log?.Invoke("Signing the whole IPA with the official plumesign (Apple ID from Impactor); nested Frameworks dylibs are covered by this signature…");

        var signedDirectory = Path.Combine(_workDirectory, "signed");
        Directory.CreateDirectory(signedDirectory);
        var signedIpa = Path.Combine(signedDirectory, "app-" + bundleId.Replace('.', '-') + "-" + DateTimeOffset.UtcNow.ToString("yyyyMMdd-HHmmss") + ".ipa");
        var request = new PlumeSignRequest(ipaPath, signedIpa, bundleId, "3ds2apple", device.DeviceId.ToString(), RegisterAndInstall: true);
        var result = await _signer.RunAsync(request, log, cancellationToken).ConfigureAwait(false);
        if (result.Success)
        {
            log?.Invoke("Installed. Keep the phone unlocked; the next step pushes ROM data into the app container.");
            return new ShellInstallOutcome(true, bundleId, signedIpa, null, result.LogPath);
        }

        if (result.Error?.Code == "device_already_registered")
        {
            log?.Invoke("Device is already registered: retrying as sign-only + device install (S2Arm-documented fallback).");
            var signOnly = await _signer.RunAsync(request with { RegisterAndInstall = false }, log, cancellationToken).ConfigureAwait(false);
            if (!signOnly.Success)
            {
                return new ShellInstallOutcome(false, bundleId, null, signOnly.Error, signOnly.LogPath);
            }
            var install = await _signer.InstallSignedAppAsync(signedIpa, device.DeviceId.ToString(), log, cancellationToken).ConfigureAwait(false);
            return new ShellInstallOutcome(install.Success, bundleId, signedIpa, install.Error, install.LogPath);
        }
        return new ShellInstallOutcome(false, bundleId, null, result.Error, result.LogPath);
    }

    private static bool IsPlausibleBundleId(string bundleId) =>
        !string.IsNullOrWhiteSpace(bundleId)
        && bundleId.Length <= 155
        && bundleId.Contains('.', StringComparison.Ordinal)
        && bundleId.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-');
}
