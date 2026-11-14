using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Models;

/// <summary>One decrypted ROM detected by <c>3ds2apple-pack rom inspect --json</c>.</summary>
public sealed record RomInfo(
    string Path,
    string Container,
    string TitleID,
    string? ProductCode,
    string DisplayName,
    long Bytes,
    long? ContentBytes,
    int? TitleVersion);

/// <summary>A built <c>GamePack.dylib</c> record from a package manifest.</summary>
public sealed record PackRecord(string Sha256, long Bytes, string Format)
{
    public bool IsPlaceholder => string.Equals(Format, "placeholder", StringComparison.OrdinalIgnoreCase)
                                 || string.Equals(Format, "fake", StringComparison.OrdinalIgnoreCase);
}

/// <summary>One package as reported by <c>packages list --json</c>.</summary>
public sealed record PackageInfo(
    string TitleID,
    string DisplayName,
    string ProductCode,
    int AotVersion,
    string State,
    PackRecord? Pack,
    IReadOnlyList<string> Issues)
{
    public bool HasPack => Pack is { } pack && !pack.IsPlaceholder;

    public bool IsQueued => string.Equals(State, "queued", StringComparison.OrdinalIgnoreCase);

    public bool IsBuilt => string.Equals(State, "built", StringComparison.OrdinalIgnoreCase);
}

/// <summary>A shell/library row the launcher keeps in its own state file.</summary>
public sealed class LibraryEntry
{
    public string TitleID { get; set; } = string.Empty;
    public string DisplayName { get; set; } = string.Empty;
    public string? ProductCode { get; set; }
    public string RomPath { get; set; } = string.Empty;
    public string DisplayNameOverride { get; set; } = string.Empty;
    public string? PackageDir { get; set; }
    public string? PackPath { get; set; }
    public PackRecord? Pack { get; set; }
    public string State { get; set; } = "imported";
    public string? LastError { get; set; }
    public string? LastBuildName { get; set; }
    public string? BuildHost { get; set; }
    public DateTimeOffset ImportedAt { get; set; } = DateTimeOffset.UtcNow;
    public DateTimeOffset? BuiltAt { get; set; }
    public DateTimeOffset? PushedAt { get; set; }
    public List<string> PushedFiles { get; set; } = new();
}

/// <summary>A phone listed by the device bridge (<c>devpush devices --json</c>).</summary>
public sealed record DeviceInfo(
    string Udid,
    string? Name,
    string? Model,
    string? IosVersion,
    string Connection,
    bool Paired)
{
    public bool IsUsb => string.Equals(Connection, "usb", StringComparison.OrdinalIgnoreCase);

    public string Display => $"{Name ?? Model ?? "iPhone/iPad"} ({IosVersion ?? "?"}) · {Privacy.RedactUdid(Udid)} · {Connection}{(Paired ? string.Empty : " · not paired")}";
}

/// <summary>Result of <c>devpush app-attr --bundle-id ... --json</c>.</summary>
public sealed record AppAttributes(
    bool Installed,
    string? DataContainer,
    string? AppBundleVersion,
    bool? FileSharingEnabled);

/// <summary>One remote file/directory entry from <c>devpush ls</c> / <c>devpush stat</c>.</summary>
public sealed record RemoteEntry(string Name, bool IsDir, long Size, long? MtimeUnix);

/// <summary>Progress of one file transfer (contract: devpush/1 NDJSON).</summary>
public sealed record TransferProgress(string? File, long BytesSent, long BytesTotal)
{
    public double Percent => BytesTotal <= 0 ? 0 : Math.Clamp(100.0 * BytesSent / BytesTotal, 0, 100);
}

/// <summary>Structured failure reported by a tool CLI (devpush error event, plumesign error mapping).</summary>
public sealed class LauncherToolException : Exception
{
    public LauncherToolException(string code, string message, string? hint = null, int? exitCode = null)
        : base(message)
    {
        Code = code;
        Hint = hint;
        ExitCode = exitCode;
    }

    /// <summary>Stable machine code (e.g. <c>device_not_found</c>, <c>free_appid_limit</c>).</summary>
    public string Code { get; }

    /// <summary>Actionable next step shown in the UI; never a command to copy blindly.</summary>
    public string? Hint { get; }

    public int? ExitCode { get; }
}

/// <summary>A file the launcher has written to the local staging directory and will push.</summary>
public sealed record StagedFile(string LocalPath, string RemoteName, string Sha256, long Bytes);
