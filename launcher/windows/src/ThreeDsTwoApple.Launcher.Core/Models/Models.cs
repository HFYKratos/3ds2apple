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
    int? TitleVersion,
    string? Region = null);

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
    IReadOnlyList<string> Issues,
    IReadOnlyDictionary<string, string>? DisplayNames = null,
    string? Publisher = null,
    string? CoverPath = null,
    string? Region = null)
{
    public bool HasPack => Pack is { } pack && !pack.IsPlaceholder;

    public bool IsQueued => string.Equals(State, "queued", StringComparison.OrdinalIgnoreCase);

    public bool IsBuilt => string.Equals(State, "built", StringComparison.OrdinalIgnoreCase);
}

/// <summary>A shell/library row the launcher keeps in its own state file.</summary>
public sealed class LibraryEntry
{
    public string TitleID { get; set; } = string.Empty;

    /// <summary>English/default display name written by the pack CLI (never user input).</summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>Localized short titles from the ROM SMDH icon metadata (BCP-47 keys).</summary>
    public Dictionary<string, string> DisplayNames { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Publisher from the ROM SMDH (empty when unknown).</summary>
    public string Publisher { get; set; } = string.Empty;

    /// <summary>Region codes from the ROM SMDH region lockout (e.g. "EU", "US",
    /// "EU+AU", "region-free"; empty when unknown). Pushed in GameInfo.json.</summary>
    public string Region { get; set; } = string.Empty;

    /// <summary>Absolute path of the package's cover.png (ROM icon), null when the ROM has no icon.</summary>
    public string? CoverPath { get; set; }

    public string? ProductCode { get; set; }
    public string RomPath { get; set; } = string.Empty;

    /// <summary>Legacy editable-name field; kept only so old state.json files still deserialize (never read for display).</summary>
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

    /// <summary>
    /// Recorded identity of the last successful local build: the
    /// <c>buildCompatVersion</c> marker and the ROM SHA-256. Deploy/"Build now" reuse
    /// the GamePack only when both still match. This lives in state.json (user data),
    /// never in the launcher log.
    /// </summary>
    public BuildArtifact? Build { get; set; }
}

/// <summary>Recorded build identity for one GamePack (see <see cref="LibraryEntry.Build"/>).</summary>
public sealed class BuildArtifact
{
    /// <summary>Canonical local-build recipe marker (recomp/shim/pack ABI + toolchain versions).</summary>
    public string BuildCompatVersion { get; set; } = string.Empty;

    /// <summary>Short label derived from <see cref="BuildCompatVersion"/> for the UI.</summary>
    public string BuildCompatShort { get; set; } = string.Empty;

    /// <summary>SHA-256 of the ROM the GamePack was built from.</summary>
    public string RomSha256 { get; set; } = string.Empty;

    public long RomBytes { get; set; }

    /// <summary>ROM last-write time when the build ran; used as a cheap change hint.</summary>
    public DateTimeOffset? RomLastWriteUtc { get; set; }

    public string PackSha256 { get; set; } = string.Empty;

    public long PackBytes { get; set; }

    public string? BuildName { get; set; }

    /// <summary>Launcher version that produced the pack (informational only, not compatibility).</summary>
    public string LauncherVersion { get; set; } = string.Empty;

    public DateTimeOffset BuiltAt { get; set; }
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

    /// <summary>
    /// Non-identifying description for logs/UI ("iPhone 15 Pro (USB)"). The UDID and
    /// the user's device name stay internal; only the internal device operations use them.
    /// </summary>
    public string Display => Privacy.DescribeDevice(Model, Connection, IosVersion);
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
