using System.Diagnostics;
using System.Security.Cryptography;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>One binary of the official Impactor release we ship unmodified.</summary>
public sealed record PinnedBinary(string FileName, string Sha256, long Bytes);

/// <summary>
/// The pinned official Impactor release (v2.7.2) and its CLI <c>plumesign</c>.
/// </summary>
/// <remarks>
/// This is the only signing path on Windows. The two executables are copied
/// byte-for-byte from the official GitHub release, never rebuilt, re-signed or
/// patched; their SHA-256 is verified before every launch and by
/// <c>tools/fetch-impactor.ps1</c>. Impactor is MIT; it embeds
/// apple-codesign, which is MPL-2.0. Licence texts and source links live in
/// <c>vendor/impactor/</c> and are copied next to the binaries by the
/// bundling script. Pins match the official release asset digests (checked
/// against the GitHub API; see docs/windows-build.md).
/// </remarks>
public static class ImpactorPins
{
    public const string TestedVersion = "2.7.2";
    public const string ReleasePageUrl = "https://github.com/claration/impactor/releases/tag/v2.7.2";
    public const string DownloadBaseUrl = "https://github.com/claration/impactor/releases/download/v2.7.2/";
    public const string BundleRelativeDirectory = "ThirdParty/Impactor";
    public const string ImpactorFileName = "Impactor-windows-x86_64-portable.exe";
    public const string PlumeSignFileName = "plumesign-windows-x86_64.exe";
    public const string ImpactorLicenseFile = "LICENSE-Impactor-MIT.txt";
    public const string AppleCodesignLicenseFile = "LICENSE-apple-codesign-MPL-2.0.txt";
    public const string SourceNoteFile = "README-source-and-licenses.txt";

    public static readonly PinnedBinary Impactor = new(
        ImpactorFileName,
        "f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef",
        18_213_888);

    public static readonly PinnedBinary PlumeSign = new(
        PlumeSignFileName,
        "b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0",
        10_718_720);

    public static IReadOnlyList<PinnedBinary> All { get; } = new[] { Impactor, PlumeSign };

    public static IReadOnlyList<string> RequiredLicenseFiles { get; } = new[]
    {
        ImpactorLicenseFile,
        AppleCodesignLicenseFile,
        SourceNoteFile,
    };
}

/// <summary>Verification of one pinned binary on disk.</summary>
public sealed record PinnedFileStatus(PinnedBinary Pin, string Path, bool Present, long? ActualBytes, string? ActualSha256)
{
    public bool Ok => Present && ActualSha256 is not null && string.Equals(ActualSha256, Pin.Sha256, StringComparison.OrdinalIgnoreCase) && ActualBytes == Pin.Bytes;

    public string Describe() => !Present
        ? $"{Pin.FileName}: missing"
        : Ok
            ? $"{Pin.FileName}: ok (SHA-256 {Pin.Sha256[..16]}…)"
            : $"{Pin.FileName}: MISMATCH (expected SHA-256 {Pin.Sha256}, got {ActualSha256 ?? "?"}, {ActualBytes} bytes)";
}

/// <summary>Readiness of the bundled Impactor + plumesign + licence files.</summary>
public sealed record ImpactorBundleStatus(
    string Directory,
    bool BinariesOk,
    bool LicensesOk,
    IReadOnlyList<PinnedFileStatus> Binaries,
    IReadOnlyList<string> MissingLicenseFiles,
    string? ImpactorPath,
    string? PlumeSignPath)
{
    public bool Ready => BinariesOk && LicensesOk;

    public string Summary
    {
        get
        {
            if (Ready)
            {
                return $"Official Impactor v{ImpactorPins.TestedVersion} + plumesign ready (SHA-256 pinned, unmodified).";
            }
            if (!BinariesOk)
            {
                return "Impactor bundle is missing or modified: " + string.Join("; ", Binaries.Where(b => !b.Ok).Select(b => b.Describe()));
            }
            return "Impactor licences are missing from the bundle: " + string.Join(", ", MissingLicenseFiles);
        }
    }
}

/// <summary>Verifies and launches the bundled official Impactor.</summary>
public sealed class ImpactorBundle
{
    private readonly string _directory;

    public ImpactorBundle(string directory) => _directory = directory;

    public string Directory => _directory;

    public string ImpactorPath => Path.Combine(_directory, ImpactorPins.ImpactorFileName);

    public string PlumeSignPath => Path.Combine(_directory, ImpactorPins.PlumeSignFileName);

    public static ImpactorBundle Locate(string distributionRoot, string? overrideDirectory = null) =>
        new(string.IsNullOrWhiteSpace(overrideDirectory) ? Path.Combine(distributionRoot, "ThirdParty", "Impactor") : overrideDirectory);

    public static PinnedFileStatus VerifyPinned(PinnedBinary pin, string path)
    {
        if (!File.Exists(path))
        {
            return new PinnedFileStatus(pin, path, false, null, null);
        }
        var info = new FileInfo(path);
        return new PinnedFileStatus(pin, path, true, info.Length, Sha256File(path));
    }

    public ImpactorBundleStatus Verify()
    {
        var statuses = ImpactorPins.All
            .Select(pin => VerifyPinned(pin, Path.Combine(_directory, pin.FileName)))
            .ToList();
        var missingLicenses = ImpactorPins.RequiredLicenseFiles
            .Where(file => !File.Exists(Path.Combine(_directory, file)))
            .ToList();
        var impactorPath = statuses.FirstOrDefault(s => s.Pin.FileName == ImpactorPins.ImpactorFileName && s.Ok)?.Path;
        var plumeSignPath = statuses.FirstOrDefault(s => s.Pin.FileName == ImpactorPins.PlumeSignFileName && s.Ok)?.Path;
        return new ImpactorBundleStatus(
            _directory,
            statuses.All(s => s.Ok),
            missingLicenses.Count == 0,
            statuses,
            missingLicenses,
            impactorPath,
            plumeSignPath);
    }

    /// <summary>
    /// Start the official Impactor so the user can sign in with their own Apple ID.
    /// The launcher never sees the Apple ID or password; the account is stored by
    /// Impactor and reused by plumesign for signing.
    /// </summary>
    public Process StartImpactor()
    {
        var status = Verify();
        if (!status.BinariesOk || status.ImpactorPath is null)
        {
            throw new Models.LauncherToolException("impactor_missing", status.Summary, "Run launcher/windows/tools/fetch-impactor.ps1 on a machine that can reach GitHub, or reinstall the launcher package.");
        }
        return Process.Start(new ProcessStartInfo(status.ImpactorPath) { UseShellExecute = true })
               ?? throw new Models.LauncherToolException("impactor_launch_failed", "Windows did not start Impactor.", "Try starting it from ThirdParty/Impactor manually.");
    }

    /// <summary>SHA-256 of a file, lower-case hex; the one hashing helper used everywhere.</summary>
    public static string Sha256File(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        var hash = sha.ComputeHash(stream);
        return Convert.ToHexStringLower(hash);
    }
}
