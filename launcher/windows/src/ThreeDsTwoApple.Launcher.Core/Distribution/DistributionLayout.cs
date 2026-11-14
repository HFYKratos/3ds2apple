using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ThreeDsTwoApple.Launcher.Core.Distribution;

/// <summary>One file embedded into the launcher executable.</summary>
public sealed record EmbeddedFile(string ResourceName, string RelativePath, long Bytes);

/// <summary>One file written under the extraction root.</summary>
public sealed record ExtractedFile(string RelativePath, long Bytes, string Sha256);

/// <summary>Marker written into the extraction root (also the cache key for re-extraction).</summary>
public sealed class PayloadManifestDocument
{
    public int SchemaVersion { get; set; } = 1;

    public string? LauncherVersion { get; set; }

    public DateTimeOffset ExtractedAt { get; set; }

    public List<ExtractedFile> Files { get; set; } = new();
}

/// <summary>Result of preparing the distribution directory (developer layout or first-run extraction).</summary>
public sealed record DistributionPrepareResult(
    string Root,
    bool Extracted,
    bool HasEmbeddedPayload,
    string? Warning,
    IReadOnlyList<EmbeddedFile> Payload)
{
    public string Describe() => Extracted
        ? "extracted the bundled payload to " + Root
        : HasEmbeddedPayload ? "using the extracted payload at " + Root : "using the developer layout at " + Root;
}

/// <summary>
/// Single-file distribution support. The published one-exe package embeds the ROM-free shell
/// template, the pinned official Impactor/plumesign, the tool CLIs and the licence/notice texts
/// as resources. <see cref="Prepare"/> either uses a multi-file developer layout (Bin/, Shell/,
/// ThirdParty/) next to the executable, an explicit <c>THREEDS2APPLE_DIST</c> directory, or
/// extracts the embedded payload once into %LOCALAPPDATA%\3ds2apple\distribution\&lt;version&gt;.
/// </summary>
public static class DistributionLayout
{
    public const string PayloadResourcePrefix = "Payload/";

    public const string OverrideEnvironmentVariable = "THREEDS2APPLE_DIST";

    public const string LauncherDataDirectoryName = "3ds2apple";

    public const string ExtractionDirectoryName = "distribution";

    public const string MarkerFileName = "payload-manifest.json";

    private static readonly object Gate = new();

    private static DistributionPrepareResult? _cached;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNameCaseInsensitive = true,
    };

    /// <summary>Relative paths a release package must provide; checked by --self-test.</summary>
    public static IReadOnlyList<string> ExpectedRelativePaths { get; } = new[]
    {
        "Shell/manifest.json",
        "Shell/3ds2apple-shell.ipa",
        "ThirdParty/Impactor/Impactor-windows-x86_64-portable.exe",
        "ThirdParty/Impactor/plumesign-windows-x86_64.exe",
        "ThirdParty/Impactor/LICENSE-Impactor-MIT.txt",
        "ThirdParty/Impactor/LICENSE-apple-codesign-MPL-2.0.txt",
        "ThirdParty/Impactor/README-source-and-licenses.txt",
        "ThirdParty/Impactor/PINS.json",
        "Bin/3ds2apple-pack.exe",
        "Bin/builder-windows.exe",
        "Bin/devpush.exe",
        "licenses/LICENSE",
        "licenses/NOTICE",
        "licenses/THIRD_PARTY.md",
    };

    /// <summary>Resolve (and on first run extract) the distribution root. Cached per process.</summary>
    public static DistributionPrepareResult Prepare()
    {
        lock (Gate)
        {
            return _cached ??= PrepareCore();
        }
    }

    public static string Resolve() => Prepare().Root;

    /// <summary>Test hook: forget the cached result.</summary>
    public static void ResetForTests()
    {
        lock (Gate)
        {
            _cached = null;
        }
    }

    /// <summary>Default extraction root: %LOCALAPPDATA%\3ds2apple\distribution\&lt;launcher version&gt;.</summary>
    public static string DefaultExtractionRoot() => Path.Combine(
        LauncherDataRoot(),
        ExtractionDirectoryName,
        LauncherInfo.Version);

    /// <summary>%LOCALAPPDATA%\3ds2apple (falls back to ~/.local/share on non-Windows hosts).</summary>
    public static string LauncherDataRoot()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            localAppData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "share");
        }
        return Path.Combine(localAppData, LauncherDataDirectoryName);
    }

    /// <summary>True when a directory looks like a multi-file launcher distribution.</summary>
    public static bool IsDistributionRoot(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
        {
            return false;
        }
        return File.Exists(Path.Combine(directory, "Bin", "3ds2apple-pack.exe"))
            || File.Exists(Path.Combine(directory, "ThirdParty", "Impactor", "PINS.json"))
            || File.Exists(Path.Combine(directory, "Shell", "manifest.json"));
    }

    /// <summary>All embedded payload files of the launcher assembly.</summary>
    public static IReadOnlyList<EmbeddedFile> PayloadInventory(Assembly? assembly = null)
    {
        assembly ??= typeof(DistributionLayout).Assembly;
        var files = new List<EmbeddedFile>();
        foreach (var resource in assembly.GetManifestResourceNames())
        {
            if (!resource.StartsWith(PayloadResourcePrefix, StringComparison.Ordinal))
            {
                continue;
            }
            var relative = ToSafeRelativePath(resource);
            if (relative.Length == 0)
            {
                continue;
            }
            long bytes = 0;
            try
            {
                using var stream = assembly.GetManifestResourceStream(resource);
                bytes = stream?.Length ?? 0;
            }
            catch (IOException)
            {
                bytes = 0;
            }
            files.Add(new EmbeddedFile(resource, relative, bytes));
        }
        return files.OrderBy(file => file.RelativePath, StringComparer.Ordinal).ToList();
    }

    /// <summary>Map an embedded resource name to a safe relative path ("" when unsafe).</summary>
    public static string ToSafeRelativePath(string resourceName)
    {
        if (string.IsNullOrWhiteSpace(resourceName) || !resourceName.StartsWith(PayloadResourcePrefix, StringComparison.Ordinal))
        {
            return string.Empty;
        }
        var relative = resourceName.Substring(PayloadResourcePrefix.Length).Replace('\\', '/');
        return IsSafeRelativePath(relative) ? relative : string.Empty;
    }

    /// <summary>Reject absolute paths, drive letters and any ".." segment.</summary>
    public static bool IsSafeRelativePath(string? relative)
    {
        if (string.IsNullOrWhiteSpace(relative) || Path.IsPathRooted(relative))
        {
            return false;
        }
        var normalized = relative.Replace('\\', '/');
        if (normalized.Contains(':', StringComparison.Ordinal) || normalized.StartsWith("/", StringComparison.Ordinal))
        {
            return false;
        }
        foreach (var segment in normalized.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (segment is "." or "..")
            {
                return false;
            }
        }
        return true;
    }

    /// <summary>True when the extraction root is missing, incomplete or stale.</summary>
    public static bool NeedsExtraction(string root, IReadOnlyList<EmbeddedFile> payload)
    {
        if (payload.Count == 0 || !Directory.Exists(root))
        {
            return true;
        }
        var marker = Path.Combine(root, MarkerFileName);
        if (!File.Exists(marker))
        {
            return true;
        }
        foreach (var file in payload)
        {
            var path = Path.Combine(root, file.RelativePath.Replace('/', Path.DirectorySeparatorChar));
            var info = new FileInfo(path);
            if (!info.Exists || info.Length != file.Bytes)
            {
                return true;
            }
        }
        return false;
    }

    /// <summary>Extract every embedded file under <paramref name="root"/> and write the marker.</summary>
    public static string Extract(IReadOnlyList<EmbeddedFile> payload, string root, Assembly? assembly = null)
    {
        assembly ??= typeof(DistributionLayout).Assembly;
        Directory.CreateDirectory(root);
        var extracted = new List<ExtractedFile>();
        foreach (var file in payload)
        {
            using var stream = assembly.GetManifestResourceStream(file.ResourceName)
                ?? throw new InvalidOperationException("embedded resource is missing: " + file.ResourceName);
            var destination = Path.Combine(root, file.RelativePath.Replace('/', Path.DirectorySeparatorChar));
            var directory = Path.GetDirectoryName(destination);
            if (!string.IsNullOrEmpty(directory))
            {
                Directory.CreateDirectory(directory);
            }
            var temporary = destination + ".tmp";
            using (var output = File.Create(temporary))
            {
                stream.CopyTo(output);
            }
            if (File.Exists(destination))
            {
                File.Delete(destination);
            }
            File.Move(temporary, destination);
            extracted.Add(new ExtractedFile(file.RelativePath, new FileInfo(destination).Length, Sha256File(destination)));
        }
        var document = new PayloadManifestDocument
        {
            LauncherVersion = LauncherInfo.Version,
            ExtractedAt = DateTimeOffset.UtcNow,
            Files = extracted,
        };
        var markerPath = Path.Combine(root, MarkerFileName);
        var json = JsonSerializer.Serialize(document, JsonOptions);
        var markerTemporary = markerPath + ".tmp";
        File.WriteAllText(markerTemporary, json, Encoding.UTF8);
        if (File.Exists(markerPath))
        {
            File.Delete(markerPath);
        }
        File.Move(markerTemporary, markerPath);
        return markerPath;
    }

    /// <summary>Read the marker file of an extraction root; null when absent or unreadable.</summary>
    public static PayloadManifestDocument? ReadManifest(string root)
    {
        try
        {
            var path = Path.Combine(root, MarkerFileName);
            return File.Exists(path)
                ? JsonSerializer.Deserialize<PayloadManifestDocument>(File.ReadAllText(path), JsonOptions)
                : null;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static DistributionPrepareResult PrepareCore()
    {
        var payload = PayloadInventory();
        var overridden = Environment.GetEnvironmentVariable(OverrideEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(overridden) && Directory.Exists(overridden))
        {
            return new DistributionPrepareResult(Path.GetFullPath(overridden), Extracted: false, HasEmbeddedPayload: payload.Count > 0, Warning: null, payload);
        }
        var baseDirectory = AppContext.BaseDirectory;
        if (IsDistributionRoot(baseDirectory))
        {
            return new DistributionPrepareResult(baseDirectory, Extracted: false, HasEmbeddedPayload: payload.Count > 0, Warning: null, payload);
        }
        if (payload.Count == 0)
        {
            return new DistributionPrepareResult(
                baseDirectory,
                Extracted: false,
                HasEmbeddedPayload: false,
                Warning: "this developer build has no embedded distribution payload; bundle the shell template, Impactor, Bin tools and licences before shipping",
                payload);
        }
        var root = DefaultExtractionRoot();
        string? warning = null;
        var extractedNow = false;
        if (NeedsExtraction(root, payload))
        {
            try
            {
                Extract(payload, root);
                extractedNow = true;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                warning = "could not extract the bundled payload to " + root + ": " + exception.Message;
            }
        }
        return new DistributionPrepareResult(root, extractedNow, HasEmbeddedPayload: true, warning, payload);
    }

    /// <summary>Lower-case SHA-256 of a file (shared with the Impactor verifier).</summary>
    public static string Sha256File(string path)
    {
        using var stream = File.OpenRead(path);
        using var sha = SHA256.Create();
        return Convert.ToHexStringLower(sha.ComputeHash(stream));
    }
}