using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>One file of Documents/Games/&lt;TITLEID&gt; to push.</summary>
public sealed record PushFile(string RemoteName, string LocalPath, string Sha256, long Bytes)
{
    public string RemotePath(string remoteDirectory) => remoteDirectory + "/" + RemoteName;
}

/// <summary>
/// Everything pushed for one game: the user's ROM and the informational
/// GameInfo.json, in that order. The GamePack.dylib is NOT pushed — it lives in
/// the signed app bundle (Frameworks/GamePack-&lt;TITLEID&gt;.dylib) and is loaded
/// through the bundle GameCatalog.json, because iOS cannot dlopen a loose unsigned
/// dylib from Documents. Pushed ROM data survives an overwrite install/update (a clean uninstall clears app data; verify on device)s/updates.
/// </summary>
public sealed class GamePushPlan
{
    private GamePushPlan(string titleId, string displayName, string? productCode, int aotVersion, IReadOnlyList<PushFile> files, string gameInfoPath)
    {
        TitleId = titleId;
        DisplayName = displayName;
        ProductCode = productCode;
        AotVersion = aotVersion;
        Files = files;
        GameInfoPath = gameInfoPath;
    }

    public string TitleId { get; }
    public string DisplayName { get; }
    public string? ProductCode { get; }
    public int AotVersion { get; }
    public IReadOnlyList<PushFile> Files { get; }
    public string GameInfoPath { get; }

    public string RemoteDirectory => LauncherInfo.DocumentsGamesRelativePath + "/" + TitleId;

    public long TotalBytes => Files.Sum(file => file.Bytes);

    /// <summary>
    /// Hash the user's ROM (read once), optionally record the already-installed
    /// pack metadata, write GameInfo.json into the workspace staging directory,
    /// and return the two-file push plan. No multi-GB copies are made.
    /// </summary>
    public static async Task<GamePushPlan> CreateAsync(
        string stagingDirectory,
        string titleId,
        string displayName,
        string? productCode,
        int aotVersion,
        string? packPath,
        string romPath,
        Action<string>? log = null,
        CancellationToken cancellationToken = default)
    {
        var normalizedTitle = GameInfoWriter.NormalizeTitleId(titleId);
        if (!File.Exists(romPath))
        {
            throw new LauncherToolException("rom_missing", "The imported ROM is no longer at " + romPath + ".",
                "Re-import the ROM, or restore the file at its original path.");
        }

        string? packSha256 = null;
        long? packBytes = null;
        if (!string.IsNullOrWhiteSpace(packPath) && File.Exists(packPath))
        {
            log?.Invoke("Hashing " + Path.GetFileName(packPath) + " (pack metadata only; the pack stays in the app bundle)…");
            var packHash = await HashFileAsync(packPath, cancellationToken).ConfigureAwait(false);
            packSha256 = packHash.Sha256;
            packBytes = packHash.Bytes;
        }
        log?.Invoke("Hashing " + Path.GetFileName(romPath) + " (this reads the whole ROM once)…");
        var romHash = await HashFileAsync(romPath, cancellationToken).ConfigureAwait(false);

        var document = GameInfoWriter.Build(
            normalizedTitle,
            displayName,
            productCode,
            aotVersion,
            packSha256,
            packBytes,
            romHash.Sha256,
            romHash.Bytes,
            DateTimeOffset.UtcNow);
        var stage = Path.Combine(stagingDirectory, normalizedTitle);
        Directory.CreateDirectory(stage);
        var gameInfoPath = Path.Combine(stage, GameInfoWriter.GameInfoFileName);
        await GameInfoWriter.WriteAsync(gameInfoPath, document, cancellationToken).ConfigureAwait(false);
        log?.Invoke("Wrote " + gameInfoPath);

        var gameInfoHash = await HashFileAsync(gameInfoPath, cancellationToken).ConfigureAwait(false);
        var files = new List<PushFile>
        {
            new(GameInfoWriter.GameRomFileName, romPath, romHash.Sha256, romHash.Bytes),
            new(GameInfoWriter.GameInfoFileName, gameInfoPath, gameInfoHash.Sha256, gameInfoHash.Bytes),
        };
        return new GamePushPlan(normalizedTitle, displayName, productCode, aotVersion, files, gameInfoPath);
    }

    public static async Task<(string Sha256, long Bytes)> HashFileAsync(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, useAsync: true);
        using var sha = System.Security.Cryptography.SHA256.Create();
        var hash = await sha.ComputeHashAsync(stream, cancellationToken).ConfigureAwait(false);
        var bytes = stream.Length;
        return (Convert.ToHexStringLower(hash), bytes);
    }
}

/// <summary>Progress for one pushed file.</summary>
public sealed record PushProgress(int FileIndex, int FileCount, string FileName, TransferProgress Transfer, string Message)
{
    public double OverallPercent
    {
        get
        {
            var perFile = 100d / Math.Max(1, FileCount);
            var inner = Math.Clamp(Transfer.Percent, 0, 100) * perFile / 100d;
            return Math.Clamp(FileIndex * perFile + inner, 0, 100);
        }
    }
}

/// <summary>Outcome of a push + verify pass.</summary>
public sealed record PushOutcome(
    bool Success,
    string RemoteDirectory,
    IReadOnlyList<string> Pushed,
    IReadOnlyList<string> Skipped,
    string? ErrorCode,
    string? ErrorMessage);

/// <summary>
/// Pushes the game data (ROM + GameInfo.json) into the installed app's Documents
/// container via the devpush CLI (house_arrest + AFC), with per-file progress,
/// resume-by-size and a read-back verification pass. GameInfo.json goes last so the
/// shell never sees a manifest before its ROM is present.
/// </summary>
public sealed class PushService
{
    private readonly DevPushClient _client;

    public PushService(DevPushClient client) => _client = client;

    public async Task<PushOutcome> PushAsync(
        GamePushPlan plan,
        string bundleId,
        string? udid,
        bool resume,
        IProgress<PushProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        var pushed = new List<string>();
        var skipped = new List<string>();
        log?.Invoke("Pushing ROM data for " + plan.DisplayName + " (" + plan.TitleId + ") to " + bundleId + " -> " + plan.RemoteDirectory);

        try
        {
            await _client.MakeDirectoryAsync(bundleId, plan.RemoteDirectory, udid: udid, cancellationToken: cancellationToken).ConfigureAwait(false);
        }
        catch (LauncherToolException error) when (error.Code is "afc_error" or "path_not_found" or "io_error")
        {
            log?.Invoke("note: creating " + plan.RemoteDirectory + " reported " + error.Code + "; continuing (" + error.Message + ")");
        }

        for (var index = 0; index < plan.Files.Count; index++)
        {
            var file = plan.Files[index];
            var remote = file.RemotePath(plan.RemoteDirectory);
            cancellationToken.ThrowIfCancellationRequested();

            if (resume && file.RemoteName != GameInfoWriter.GameInfoFileName)
            {
                var existing = await _client.StatAsync(bundleId, remote, udid: udid, cancellationToken: cancellationToken).ConfigureAwait(false);
                if (existing is { IsDir: false } && existing.Size == file.Bytes)
                {
                    skipped.Add(file.RemoteName);
                    log?.Invoke("skip " + file.RemoteName + ": already on the phone with the right size");
                    progress?.Report(new PushProgress(index, plan.Files.Count, file.RemoteName, new TransferProgress(file.RemoteName, file.Bytes, file.Bytes), "already on the phone"));
                    continue;
                }
            }

            var adapter = new TransferProgressAdapter(progress, index, plan.Files.Count, file.RemoteName);
            var result = await _client.PutAsync(bundleId, file.LocalPath, remote, udid: udid, progress: adapter, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (result.Bytes > 0 && result.Bytes != file.Bytes)
            {
                return new PushOutcome(false, plan.RemoteDirectory, pushed, skipped, "push_size_mismatch",
                    "devpush reported " + result.Bytes.ToString() + " bytes for " + file.RemoteName + ", expected " + file.Bytes.ToString() + ".");
            }
            pushed.Add(file.RemoteName);
            log?.Invoke("pushed " + file.RemoteName + " (" + FormatBytes(file.Bytes) + ")");
        }

        foreach (var file in plan.Files)
        {
            var remote = file.RemotePath(plan.RemoteDirectory);
            var entry = await _client.StatAsync(bundleId, remote, udid: udid, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (entry is null || entry.IsDir || entry.Size != file.Bytes)
            {
                return new PushOutcome(false, plan.RemoteDirectory, pushed, skipped, "push_verify_failed",
                    "After the push, " + file.RemoteName + " is missing or has the wrong size on the phone (expected " + file.Bytes.ToString() + ").");
            }
        }
        log?.Invoke("verified " + plan.Files.Count.ToString() + " file(s) in " + plan.RemoteDirectory);
        return new PushOutcome(true, plan.RemoteDirectory, pushed, skipped, null, null);
    }

    /// <summary>Read-back only: sizes of the expected files (no writes).</summary>
    public async Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? udid, CancellationToken cancellationToken = default)
    {
        var problems = new List<string>();
        foreach (var file in plan.Files)
        {
            var entry = await _client.StatAsync(bundleId, file.RemotePath(plan.RemoteDirectory), udid: udid, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (entry is null)
            {
                problems.Add(file.RemoteName + ": missing");
            }
            else if (entry.IsDir)
            {
                problems.Add(file.RemoteName + ": is a directory");
            }
            else if (entry.Size != file.Bytes)
            {
                problems.Add(file.RemoteName + ": " + entry.Size.ToString() + " bytes on phone, expected " + file.Bytes.ToString());
            }
        }
        return problems;
    }

    private static string FormatBytes(long bytes) => bytes switch
    {
        >= 1L << 30 => (bytes / (double)(1L << 30)).ToString("0.00") + " GiB",
        >= 1L << 20 => (bytes / (double)(1L << 20)).ToString("0.0") + " MiB",
        >= 1L << 10 => (bytes / (double)(1L << 10)).ToString("0.0") + " KiB",
        _ => bytes.ToString() + " B",
    };

    private sealed class TransferProgressAdapter : IProgress<TransferProgress>
    {
        private readonly IProgress<PushProgress>? _outer;
        private readonly int _index;
        private readonly int _count;
        private readonly string _fileName;

        public TransferProgressAdapter(IProgress<PushProgress>? outer, int index, int count, string fileName)
        {
            _outer = outer;
            _index = index;
            _count = count;
            _fileName = fileName;
        }

        public void Report(TransferProgress value) =>
            _outer?.Report(new PushProgress(_index, _count, _fileName, value, "transferring"));
    }
}
