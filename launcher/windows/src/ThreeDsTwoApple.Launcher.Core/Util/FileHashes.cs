using System.Security.Cryptography;

namespace ThreeDsTwoApple.Launcher.Core.Util;

/// <summary>Streaming SHA-256 helpers (a ROM can be multi-GB; never read it into memory).</summary>
public static class FileHashes
{
    public static async Task<string> Sha256Async(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return Convert.ToHexStringLower(hash);
    }

    public static async Task<(string Sha256, long Bytes)> Sha256WithSizeAsync(string path, CancellationToken cancellationToken = default)
    {
        await using var stream = File.OpenRead(path);
        var bytes = stream.Length;
        var hash = await SHA256.HashDataAsync(stream, cancellationToken).ConfigureAwait(false);
        return (Convert.ToHexStringLower(hash), bytes);
    }
}
