using System.Security.Cryptography;
using System.Text;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>Static compatibility provider shared by the build-cache/deploy tests.</summary>
internal sealed class StaticBuildCompatibilityProvider : IBuildCompatibilityProvider
{
    public StaticBuildCompatibilityProvider(string clangVersion = "21.1.8", string ld64Version = "21.1.8", string recompilerVersion = "1.0.0")
    {
        Compatibility = BuildCompatibility.Create(recompilerVersion, clangVersion, ld64Version);
    }

    public BuildCompatibility Compatibility { get; set; }

    public int Calls { get; private set; }

    public Task<BuildCompatibility> ResolveAsync(CancellationToken cancellationToken = default)
    {
        Calls++;
        return Task.FromResult(Compatibility);
    }
}

internal static class TestHash
{
    public static string Sha256Hex(string path) =>
        Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(path)));
}

public sealed class BuildCompatibilityTests
{
    [Fact]
    public void MarkerRecordsEveryCompatibilityComponent()
    {
        var compatibility = BuildCompatibility.Create("1.2.3", "21.1.8", "21.1.8");
        var marker = compatibility.BuildCompatVersion;
        Assert.Contains("build=" + BuildCompatibility.CurrentFormatVersion, marker);
        Assert.Contains("recomp=" + BuildCompatibility.CurrentRecompilerAbi, marker);
        Assert.Contains("gamepack=" + LauncherInfo.GamePackAbiVersion, marker);
        Assert.Contains("shim=" + BuildCompatibility.CurrentShimAbi, marker);
        Assert.Contains("catalog=" + BuildCompatibility.CurrentCatalogSchemaVersion, marker);
        Assert.Contains("gameinfo=" + LauncherInfo.GameInfoSchemaVersion, marker);
        Assert.Contains("recompiler=1.2.3", marker);
        Assert.Contains("clang=21.1.8", marker);
        Assert.Contains("ld64=21.1.8", marker);
        Assert.Equal(BuildCompatibility.Create("1.2.3", "21.1.8", "21.1.8").BuildCompatVersion, marker);
    }

    [Fact]
    public void MissingToolVersionsAreStableUnknownMarkers()
    {
        var first = BuildCompatibility.Create();
        var second = BuildCompatibility.Create(null, "  ", "");
        Assert.Contains("clang=" + BuildCompatibility.UnknownVersion, first.BuildCompatVersion);
        Assert.Equal(first.BuildCompatVersion, second.BuildCompatVersion);
    }

    [Fact]
    public void DifferentToolchainVersionsInvalidateTheMarker()
    {
        var llvm218 = BuildCompatibility.Create("1.0.0", "21.1.8", "21.1.8").BuildCompatVersion;
        var llvm220 = BuildCompatibility.Create("1.0.0", "22.0.0", "22.0.0").BuildCompatVersion;
        Assert.NotEqual(llvm218, llvm220);
    }

    [Fact]
    public void MarkerExcludesLauncherAndShellVersions()
    {
        // A launcher/shell update with an unchanged local build recipe must keep the marker,
        // otherwise every installed GamePack would be needlessly recompiled after an update.
        var marker = BuildCompatibility.Create("1.0.0", "21.1.8", "21.1.8").BuildCompatVersion;
        Assert.DoesNotContain(LauncherInfo.Version, marker, StringComparison.Ordinal);
        Assert.DoesNotContain("shell", marker, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("launcher", marker, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ShortLabelIsStableAndShort()
    {
        var compatibility = BuildCompatibility.Create("1.0.0", "21.1.8", "21.1.8");
        Assert.Equal(compatibility.ShortVersion, compatibility.ShortVersion);
        Assert.StartsWith("b", compatibility.ShortVersion, StringComparison.Ordinal);
        Assert.Equal(9, compatibility.ShortVersion.Length);
        Assert.NotEqual(compatibility.ShortVersion, BuildCompatibility.Create("1.0.0", "22.0.0", "21.1.8").ShortVersion);
        Assert.Equal("?", BuildCompatibility.ShortLabel(""));
    }
}

public sealed class BuildCachePolicyTests
{
    private const string Compat = "build=1;recomp=1;gamepack=1;shim=1;catalog=2;gameinfo=1;recompiler=1.0.0;clang=21.1.8;ld64=21.1.8";
    private const string RomSha = "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";

    private static BuildArtifact Artifact(string compat = Compat, string romSha = RomSha) => new()
    {
        BuildCompatVersion = compat,
        BuildCompatShort = BuildCompatibility.ShortLabel(compat),
        RomSha256 = romSha,
        RomBytes = 1024,
        PackSha256 = new string('b', 64),
        PackBytes = 2048,
        LauncherVersion = "0.1.1",
        BuiltAt = DateTimeOffset.UtcNow,
    };

    private static Func<string, bool> PackExists => _ => true;

    [Fact]
    public void ReusesOnlyWhenCompatibilityRomShaAndPackAllMatch()
    {
        var decision = BuildCachePolicy.Evaluate(Artifact(), Compat, RomSha, "/tmp/pack.dylib", PackExists);
        Assert.True(decision.Reuse);
        Assert.Equal(BuildReuseStatus.Reusable, decision.Status);
    }

    [Fact]
    public void NoRecordedBuildForcesARebuild()
    {
        Assert.Equal(BuildReuseStatus.NoRecordedBuild, BuildCachePolicy.Evaluate(null, Compat, RomSha, "/tmp/pack.dylib", PackExists).Status);
        Assert.Equal(BuildReuseStatus.NoRecordedBuild, BuildCachePolicy.Evaluate(new BuildArtifact(), Compat, RomSha, "/tmp/pack.dylib", PackExists).Status);
    }

    [Fact]
    public void ChangedBuildMethodForcesARebuild()
    {
        var changed = Compat.Replace("clang=21.1.8", "clang=22.0.0");
        var decision = BuildCachePolicy.Evaluate(Artifact(), changed, RomSha, "/tmp/pack.dylib", PackExists);
        Assert.False(decision.Reuse);
        Assert.Equal(BuildReuseStatus.BuildMethodChanged, decision.Status);
        Assert.Contains("recipe changed", decision.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void UnresolvedCurrentRecipeForcesARebuild()
    {
        Assert.Equal(BuildReuseStatus.BuildMethodChanged, BuildCachePolicy.Evaluate(Artifact(), null, RomSha, "/tmp/pack.dylib", PackExists).Status);
        Assert.Equal(BuildReuseStatus.BuildMethodChanged, BuildCachePolicy.Evaluate(Artifact(), "  ", RomSha, "/tmp/pack.dylib", PackExists).Status);
    }

    [Theory]
    [InlineData("ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100")]
    [InlineData("")]
    [InlineData(null)]
    public void ChangedRomForcesARebuild(string? currentRomSha)
    {
        var decision = BuildCachePolicy.Evaluate(Artifact(), Compat, currentRomSha, "/tmp/pack.dylib", PackExists);
        Assert.False(decision.Reuse);
        Assert.Equal(BuildReuseStatus.RomChanged, decision.Status);
    }

    [Fact]
    public void MissingPackFileForcesARebuild()
    {
        Assert.Equal(BuildReuseStatus.PackMissing, BuildCachePolicy.Evaluate(Artifact(), Compat, RomSha, null, PackExists).Status);
        Assert.Equal(BuildReuseStatus.PackMissing, BuildCachePolicy.Evaluate(Artifact(), Compat, RomSha, "/tmp/pack.dylib", _ => false).Status);
    }

    [Fact]
    public void LauncherVersionChangeAloneKeepsTheCache()
    {
        var artifact = Artifact();
        artifact.LauncherVersion = "0.1.0";
        var decision = BuildCachePolicy.Evaluate(artifact, Compat, RomSha, "/tmp/pack.dylib", PackExists);
        Assert.True(decision.Reuse);
    }
}

public sealed class BuildFingerprintTests
{
    [Fact]
    public void MatchesWhenSizeAndWriteTimeStillMatch()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("game.cci", new byte[] { 1, 2, 3, 4 });
        var artifact = new BuildArtifact
        {
            RomSha256 = TestHash.Sha256Hex(rom),
            RomBytes = new FileInfo(rom).Length,
            RomLastWriteUtc = File.GetLastWriteTimeUtc(rom),
        };
        Assert.True(BuildFingerprint.MatchesUnchangedRom(artifact, rom));
    }

    [Fact]
    public void SizeChangeIsDetected()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("game.cci", new byte[] { 1, 2, 3, 4 });
        var artifact = new BuildArtifact { RomSha256 = "abc", RomBytes = 3 };
        Assert.False(BuildFingerprint.MatchesUnchangedRom(artifact, rom));
    }

    [Fact]
    public void WriteTimeChangeIsDetected()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("game.cci", new byte[] { 1, 2, 3, 4 });
        var artifact = new BuildArtifact
        {
            RomSha256 = "abc",
            RomBytes = new FileInfo(rom).Length,
            RomLastWriteUtc = File.GetLastWriteTimeUtc(rom).AddMinutes(-5),
        };
        Assert.False(BuildFingerprint.MatchesUnchangedRom(artifact, rom));
    }

    [Fact]
    public void MissingArtifactOrRomDoesNotMatch()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("game.cci", new byte[] { 1 });
        Assert.False(BuildFingerprint.MatchesUnchangedRom(null, rom));
        Assert.False(BuildFingerprint.MatchesUnchangedRom(new BuildArtifact { RomSha256 = "abc" }, null));
        Assert.False(BuildFingerprint.MatchesUnchangedRom(new BuildArtifact { RomSha256 = "abc" }, Path.Combine(temp.Path, "gone.cci")));
    }
}

public sealed class ToolchainBuildCompatibilityProviderTests
{
    private static string ToolFile(TempDir temp, string name)
    {
        var path = Path.Combine(temp.Path, name);
        File.WriteAllText(path, "binary");
        return path;
    }

    [Fact]
    public async Task ParsesClangAndLd64VersionsAndCachesTheProbe()
    {
        using var temp = new TempDir();
        var recompiler = ToolFile(temp, "3dsrecomp");
        var clang = ToolFile(temp, "clang");
        var ld64 = ToolFile(temp, "ld64.lld");
        var toolchain = new LocalToolchain(recompiler, temp.Path, null, null, null, null, null);
        var runner = new FakeProcessRunner(request =>
        {
            var name = Path.GetFileName(request.FileName);
            return name switch
            {
                "3dsrecomp" => new ProcessResult(0, "3dsrecomp 1.4.0", string.Empty, false, true),
                "clang" => new ProcessResult(0, "clang version 21.1.8", string.Empty, false, true),
                "ld64.lld" => new ProcessResult(0, "LLD 21.1.8 (compatible with GNU linkers)", string.Empty, false, true),
                _ => new ProcessResult(1, string.Empty, "unexpected " + name, false, true),
            };
        });
        var provider = new ToolchainBuildCompatibilityProvider(runner, toolchain);

        var first = await provider.ResolveAsync();
        var second = await provider.ResolveAsync();

        Assert.Same(first, second);
        Assert.Contains("recompiler=1.4.0", first.BuildCompatVersion);
        Assert.Contains("clang=21.1.8", first.BuildCompatVersion);
        Assert.Contains("ld64=21.1.8", first.BuildCompatVersion);
        Assert.Equal(3, runner.Requests.Count);
        Assert.Equal(LocalToolchain.ToolFileName("clang"), Path.GetFileName(runner.Requests[1].FileName));
    }

    [Fact]
    public async Task MissingToolchainYieldsUnknownVersionsWithoutProbing()
    {
        var runner = new FakeProcessRunner(_ => throw new InvalidOperationException("no probe may run"));
        var provider = new ToolchainBuildCompatibilityProvider(runner, null);
        var compatibility = await provider.ResolveAsync();
        Assert.Equal(BuildCompatibility.UnknownVersion, compatibility.ClangVersion);
        Assert.Equal(BuildCompatibility.UnknownVersion, compatibility.Ld64Version);
        Assert.Empty(runner.Requests);
    }
}

public sealed class LibraryBuildServiceTests
{
    private const string TitleId = "0004000000055E00";

    private static LibraryEntry Entry(TempDir temp) => new()
    {
        TitleID = TitleId,
        DisplayName = "Demo Game",
        ProductCode = "CTR-P-TEST",
        RomPath = temp.Bytes("demo.cci", new byte[] { 1, 2, 3, 4, 5, 6, 7 }),
        State = "imported",
    };

    private static string DisplayName(LibraryEntry entry) => entry.DisplayName;

    [Fact]
    public async Task BuildNowCompilesAndPersistsTheCompatibilityMarker()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var entry = Entry(temp);
        workspace.Upsert(entry);
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);

        var report = await service.BuildAsync(new[] { entry }, DisplayName);

        Assert.True(report.Success);
        Assert.Equal(1, report.BuiltCount);
        Assert.Equal(0, report.ReusedCount);
        Assert.Single(provider.Requests);
        Assert.NotNull(entry.Build);
        Assert.Equal(compatibility.Compatibility.BuildCompatVersion, entry.Build!.BuildCompatVersion);
        Assert.Equal(TestHash.Sha256Hex(entry.RomPath), entry.Build.RomSha256);
        Assert.Equal("built", entry.State);

        // The marker must survive a launcher restart (state.json, not a log).
        var reopened = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var persisted = reopened.Find(TitleId);
        Assert.NotNull(persisted?.Build);
        Assert.Equal(entry.Build!.BuildCompatVersion, persisted!.Build!.BuildCompatVersion);
        Assert.Equal(entry.Build.RomSha256, persisted.Build.RomSha256);
    }

    [Fact]
    public async Task BuildNowReusesTheCacheWithoutCallingTheToolchainAgain()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var entry = Entry(temp);
        workspace.Upsert(entry);
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);

        await service.BuildAsync(new[] { entry }, DisplayName);
        var second = await service.BuildAsync(new[] { entry }, DisplayName);

        Assert.True(second.Success);
        Assert.Equal(0, second.BuiltCount);
        Assert.Equal(1, second.ReusedCount);
        Assert.Single(provider.Requests);
    }

    [Fact]
    public async Task ChangedBuildRecipeForcesABuildOnTheNextRun()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var entry = Entry(temp);
        workspace.Upsert(entry);
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);
        await service.BuildAsync(new[] { entry }, DisplayName);

        compatibility.Compatibility = BuildCompatibility.Create("1.0.0", "22.0.0", "22.0.0");
        provider.Compatibility = compatibility.Compatibility;
        var second = await service.BuildAsync(new[] { entry }, DisplayName);

        Assert.Equal(1, second.BuiltCount);
        Assert.Equal(2, provider.Requests.Count);
        Assert.Contains("clang=22.0.0", entry.Build!.BuildCompatVersion);
    }

    [Fact]
    public async Task ChangedRomForcesABuildOnTheNextRun()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var entry = Entry(temp);
        workspace.Upsert(entry);
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);
        await service.BuildAsync(new[] { entry }, DisplayName);
        var firstSha = entry.Build!.RomSha256;

        File.WriteAllBytes(entry.RomPath, new byte[] { 9, 9, 9, 9, 9, 9, 9, 8 });
        var second = await service.BuildAsync(new[] { entry }, DisplayName);

        Assert.Equal(1, second.BuiltCount);
        Assert.Equal(2, provider.Requests.Count);
        Assert.NotEqual(firstSha, entry.Build!.RomSha256);
        Assert.Equal(TestHash.Sha256Hex(entry.RomPath), entry.Build.RomSha256);
    }

    [Fact]
    public async Task MissingRomIsReportedPerGameWithoutCallingTheProvider()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var entry = Entry(temp);
        entry.RomPath = Path.Combine(temp.Path, "gone.cci");
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);

        var report = await service.BuildAsync(new[] { entry }, DisplayName);

        Assert.False(report.Success);
        Assert.Equal(1, report.FailedCount);
        Assert.Equal(LibraryBuildService.RomMissingCode, report.Items[0].ErrorCode);
        Assert.Empty(provider.Requests);
        Assert.Equal("build_failed", entry.State);
    }

    [Fact]
    public async Task BuildAllProcessesEveryGameInOrder()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var first = Entry(temp);
        var second = Entry(temp);
        second.TitleID = "0004000000055D00";
        second.DisplayName = "Second Game";
        workspace.Upsert(first);
        workspace.Upsert(second);
        var compatibility = new StaticBuildCompatibilityProvider();
        var provider = new RecordingBuildProvider { Compatibility = compatibility.Compatibility };
        var service = new LibraryBuildService(workspace, provider, compatibility);

        var report = await service.BuildAsync(new[] { first, second }, DisplayName);

        Assert.True(report.Success);
        Assert.Equal(2, report.BuiltCount);
        Assert.Equal(new[] { first.TitleID, second.TitleID }, provider.Requests.Select(request => request.TitleID));
    }

    /// <summary>Fake local build: writes a pack file and reports the provided compatibility marker.</summary>
    private sealed class RecordingBuildProvider : IPackBuildProvider
    {
        public List<PackBuildRequest> Requests { get; } = new();

        public BuildCompatibility? Compatibility { get; set; }

        public string Name => "fake local build";

        public bool Installable => true;

        public Task<PackBuildOutcome> BuildAsync(
            PackBuildRequest request,
            IProgress<BuildProgress>? progress,
            Action<string>? log,
            CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            var packPath = Path.Combine(request.WorkDirectory, "fake-" + request.TitleID + ".dylib");
            Directory.CreateDirectory(Path.GetDirectoryName(packPath)!);
            File.WriteAllBytes(packPath, new byte[] { 0xCF, 0xFA, 0xED, 0xFE });
            progress?.Report(new BuildProgress("done", 100, "fake pack built"));
            return Task.FromResult(new PackBuildOutcome(
                true,
                true,
                packPath,
                new PackRecord(new string('b', 64), new FileInfo(packPath).Length, "gamepack-macho"),
                null,
                null,
                "fake-" + request.TitleID,
                Compatibility,
                TestHash.Sha256Hex(request.RomPath),
                new FileInfo(request.RomPath).Length));
        }
    }
}
