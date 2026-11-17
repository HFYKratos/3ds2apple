using System.Text.RegularExpressions;

namespace ThreeDsTwoApple.Launcher.Core.Util;

/// <summary>
/// Privacy helpers for launcher logs, diagnostics and device rows. A device UDID,
/// usbmux id, serial number or ECID identifies a user's phone, so the launcher never
/// writes or displays one: log/UI text uses a non-identifying description such as
/// "iPhone/iPad (USB)", and the full values stay internal arguments of
/// devpush/plumesign only. <see cref="SanitizeLogLine"/> is the last line of defence
/// for text copied from third-party tool output.
/// </summary>
public static class Privacy
{
    /// <summary>Replacement written where a device identifier would have been.</summary>
    public const string DevicePlaceholder = "<device>";

    /// <summary>Non-identifying fallback device name.</summary>
    public const string GenericDeviceName = "iPhone/iPad";

    // Apple UDIDs: 24 hex chars split by a dash on A12+ devices, 40 hex on older ones.
    private static readonly Regex ModernUdid = new(
        @"(?<![0-9A-Fa-f])[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}(?![0-9A-Fa-f])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static readonly Regex LegacyUdid = new(
        @"(?<![0-9A-Fa-f])[0-9A-Fa-f]{40}(?![0-9A-Fa-f])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // The pre-0.1.2 launcher logged "first8…last4"; scrub that shape as well.
    private static readonly Regex MaskedUdid = new(
        @"(?<![0-9A-Za-z])[0-9A-Fa-f]{6,12}(?:…|\.{2,3})[0-9A-Fa-f]{3,8}(?![0-9A-Za-z])",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    // "udid: ...", "serial=F2LZ...", "ECID 123...": keep the field name, drop the value.
    private static readonly Regex NamedIdentifier = new(
        @"(?<![0-9A-Za-z])((?:udid|serial(?:\s*number)?|ecid)\b\s*[:=#]?\s*)[A-Za-z0-9][A-Za-z0-9-]{5,}",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private static readonly Regex UsbMuxId = new(
        @"(?<![0-9A-Za-z])usbmuxd?(?:\s*id)?\b\s*[:=#]?\s*\d+",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    /// <summary>"usb" -> "USB", "network"/"wifi" -> "Wi-Fi"; never an identifier.</summary>
    public static string ConnectionLabel(string? connection)
    {
        if (string.IsNullOrWhiteSpace(connection))
        {
            return "USB";
        }
        var normalized = connection.Trim();
        if (string.Equals(normalized, "usb", StringComparison.OrdinalIgnoreCase))
        {
            return "USB";
        }
        if (string.Equals(normalized, "network", StringComparison.OrdinalIgnoreCase)
            || string.Equals(normalized, "wifi", StringComparison.OrdinalIgnoreCase)
            || string.Equals(normalized, "wi-fi", StringComparison.OrdinalIgnoreCase))
        {
            return "Wi-Fi";
        }
        return normalized.Length <= 8 ? normalized : "USB";
    }

    /// <summary>
    /// Non-identifying device description for logs/UI: the model name and the
    /// connection type. The UDID, serial number and the user's device name are never
    /// part of this string (the full values remain internal command arguments).
    /// </summary>
    public static string DescribeDevice(string? model, string? connection, string? iosVersion = null)
    {
        var label = string.IsNullOrWhiteSpace(model) ? GenericDeviceName : model.Trim();
        var text = label + " (" + ConnectionLabel(connection);
        if (!string.IsNullOrWhiteSpace(iosVersion))
        {
            text += ", iOS " + iosVersion.Trim();
        }
        return text + ")";
    }

    /// <summary>
    /// Remove every device identifier that may appear in a log line or in text copied
    /// from a tool's stdout/stderr. Title IDs and SHA-256 digests are not device
    /// identifiers and are left untouched.
    /// </summary>
    public static string SanitizeLogLine(string? line)
    {
        if (string.IsNullOrEmpty(line))
        {
            return string.Empty;
        }
        var sanitized = ModernUdid.Replace(line, DevicePlaceholder);
        sanitized = LegacyUdid.Replace(sanitized, DevicePlaceholder);
        sanitized = MaskedUdid.Replace(sanitized, DevicePlaceholder);
        sanitized = UsbMuxId.Replace(sanitized, "usbmuxd " + DevicePlaceholder);
        sanitized = NamedIdentifier.Replace(sanitized, match => match.Groups[1].Value + DevicePlaceholder);
        return sanitized;
    }
}
