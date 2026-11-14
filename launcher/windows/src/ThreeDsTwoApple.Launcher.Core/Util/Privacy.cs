namespace ThreeDsTwoApple.Launcher.Core.Util;

/// <summary>
/// Privacy helpers for launcher logs and UI. A device UDID is a personal
/// identifier: the launcher only ever displays/logs a redacted form; the full
/// value is passed internally to devpush/plumesign commands and stored nowhere.
/// </summary>
public static class Privacy
{
    /// <summary>first 8 + ellipsis + last 4 (or a short mask for tiny inputs).</summary>
    public static string RedactUdid(string? udid)
    {
        if (string.IsNullOrWhiteSpace(udid))
        {
            return "?";
        }
        var value = udid.Trim();
        if (value.Length <= 12)
        {
            return value[..Math.Min(4, value.Length)] + "…";
        }
        return value[..8] + "…" + value[^4..];
    }

    /// <summary>Redacted UDID + connection type for UI/log device rows.</summary>
    public static string RedactDevice(string? udid, string? connection = null) =>
        string.IsNullOrWhiteSpace(connection) ? RedactUdid(udid) : RedactUdid(udid) + " · " + connection;
}
