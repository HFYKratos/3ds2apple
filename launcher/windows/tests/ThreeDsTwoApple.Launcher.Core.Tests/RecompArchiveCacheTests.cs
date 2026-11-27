using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Unit tests for the generated-C archive retry cache. The cache is a strict
/// identity match: ROM SHA-256 + title id, build-compat marker, 3dsrecomp binary
/// identity/flags, exact archive path and the archive's own SHA-256.
/// </summary>
public sealed class RecompArchiveCacheTests
{
    private const string TitleId = "0004000000055E00";

    private static RecompArchiveKey Key(
        string titleId = TitleId,
        string romSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        long romBytes = 123,
        string compat = "build=1;recomp=1;gamepack=1;shim=1;catalog=2;gameinfo=1;recompiler=1.0.0;clang=21.1.8;ld64=21.1.8;opts=opt=O2;lto=0;fastmath=0",
        string recompilerSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        long recompilerBytes = 456,
        string options = "opt=O2;lto=0;fastmath=0")
        => new(titleId, romSha, romBytes, compat, "1.0.0", recompilerSha, recompilerBytes, options,
            Path.Combine("recomp", "code", "librecomp.a"));

    private static string WriteArchive(string root, byte[]? bytes = null)
    {
        var directory = Path.Combine(root, "recomp", "code");
        Directory.CreateDirectory(directory);
        var archive = Path.Combine(directory, "librecomp.a");
        File.WriteAllBytes(archive, bytes ?? new byte[] { 1, 2, 3, 4 });
        return archive;
    }

    [Fact]
    public async Task SaveThenReuseReturnsTheArchiveAndLeavesNoTemporaryMarker()
    {
        using var temp = new TempDir();
        var archive = WriteArchive(temp.Path);
        Assert.True(await RecompArchiveCache.SaveAsync(temp.Path, Key(), archive));

        Assert.True(File.Exists(RecompArchiveCache.MarkerPath(temp.Path)));
        Assert.Empty(Directory.GetFiles(temp.Path, "recomp-cache.json.tmp-*"));

        var reuse = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.True(reuse.Reused, reuse.Detail);
        Assert.Equal(Path.GetFullPath(archive), reuse.ArchivePath);
    }

    [Fact]
    public async Task MissingMarkerAndMissingArchiveAreCacheMisses()
    {
        using var temp = new TempDir();
        var miss = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.False(miss.Reused);
        Assert.Contains("marker", miss.Detail, StringComparison.OrdinalIgnoreCase);

        var archive = WriteArchive(temp.Path);
        Assert.True(await RecompArchiveCache.SaveAsync(temp.Path, Key(), archive));
        File.Delete(archive);
        var missingArchive = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.False(missingArchive.Reused);
        Assert.Contains("archive", missingArchive.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CorruptArchiveIsRejected()
    {
        using var temp = new TempDir();
        var archive = WriteArchive(temp.Path);
        Assert.True(await RecompArchiveCache.SaveAsync(temp.Path, Key(), archive));

        File.WriteAllBytes(archive, new byte[] { 9, 9, 9, 9 });
        var reuse = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.False(reuse.Reused);
        Assert.Contains("SHA-256", reuse.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Theory]
    [MemberData(nameof(MismatchedKeys))]
    public async Task AnyIdentityMismatchIsCacheMiss(RecompArchiveKey mismatched)
    {
        using var temp = new TempDir();
        var archive = WriteArchive(temp.Path);
        Assert.True(await RecompArchiveCache.SaveAsync(temp.Path, Key(), archive));

        var reuse = await RecompArchiveCache.TryReuseAsync(temp.Path, mismatched);
        Assert.False(reuse.Reused);
    }

    public static IEnumerable<object[]> MismatchedKeys()
    {
        yield return new object[] { Key(titleId: "0004000000000000") };
        yield return new object[] { Key(romSha: new string('c', 64)) };
        yield return new object[] { Key(romBytes: 124) };
        yield return new object[] { Key(compat: "changed-compat") };
        yield return new object[] { Key(recompilerSha: new string('d', 64)) };
        yield return new object[] { Key(recompilerBytes: 457) };
        yield return new object[] { Key(options: "opt=O3;lto=1;fastmath=0") };
    }

    [Fact]
    public async Task MarkerWithPathOutsideTheBuildRootIsRejected()
    {
        using var temp = new TempDir();
        var archive = WriteArchive(temp.Path);
        Assert.True(await RecompArchiveCache.SaveAsync(temp.Path, Key(), archive));
        var json = File.ReadAllText(RecompArchiveCache.MarkerPath(temp.Path))
            .Replace("recomp/code/librecomp.a", "../outside.a", StringComparison.Ordinal);
        File.WriteAllText(RecompArchiveCache.MarkerPath(temp.Path), json);

        var reuse = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.False(reuse.Reused);
        Assert.Contains("path", reuse.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task InvalidMarkerJsonIsCacheMiss()
    {
        using var temp = new TempDir();
        Directory.CreateDirectory(temp.Path);
        File.WriteAllText(RecompArchiveCache.MarkerPath(temp.Path), "{ not json");
        var reuse = await RecompArchiveCache.TryReuseAsync(temp.Path, Key());
        Assert.False(reuse.Reused);
        Assert.Contains("unreadable", reuse.Detail, StringComparison.OrdinalIgnoreCase);
    }
}
