using System.IO.Compression;
using System.Text;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Contract tests for the v2 one-click batch Deploy pipeline. All dependencies are
/// fakes, so these run without a phone, a Mac, an Apple ID or any real toolchain.
/// The tests lock down the fix for the reported failure chain:
///   * a deploy request must never sign/install a bare shell (no real packs);
///   * the composed IPA is verified before signing (packs + non-empty schema-2 catalogue);
///   * push uses Workspace.State.InstalledBundleId, never only the template manifest id;
///   * build/compose/install/push/verify are chained in one action with the exact failed step.
/// </summary>
public sealed class DeployFlowTests
{
    private const string TitleA = "0004000000055E00";
    private const string TitleB = "0004000000055D00";
    private static readonly string TemplateBundleId = "com.template.shell";
    private static readonly string InstalledBundleId = "com.example.actual-installed";

    private static byte[] Arm64MachODylib()
    {
        var bytes = new byte[64];
        BitConverter.GetBytes(0xFEEDFACFu).CopyTo(bytes, 0);
        BitConverter.GetBytes(0x0100000C).CopyTo(bytes, 4);
        BitConverter.GetBytes(6u).CopyTo(bytes, 12);
        return bytes;
    }

    private static LibraryEntry Entry(string titleId, string name, TempDir temp, bool withRealPack)
    {
        var rom = temp.Bytes("rom-" + titleId + ".cci", new byte[] { 1, 2, 3, 4, 5, 6, 7 });
        var entry = new LibraryEntry
        {
            TitleID = titleId,
            DisplayName = name,
            ProductCode = "CTR-P-TEST",
            RomPath = rom,
            State = withRealPack ? "built" : "imported",
        };
        if (withRealPack)
        {
            var packPath = temp.Bytes("pack-" + titleId + ".dylib", Arm64MachODylib());
            entry.Pack = new PackRecord(new string('a', 64), new FileInfo(packPath).Length, "gamepack-macho");
            entry.PackPath = packPath;
            entry.BuiltAt = DateTimeOffset.UtcNow;
        }
        return entry;
    }

    private static string TemplateIpa(TempDir temp)
    {
        var path = Path.Combine(temp.Path, "template.ipa");
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        AddZipEntry(archive, "Payload/demo.app/Info.plist", Encoding.UTF8.GetBytes("<plist/>"));
        AddZipEntry(archive, "Payload/demo.app/GameCatalog.json", Encoding.UTF8.GetBytes("{\"schemaVersion\":2,\"games\":[]}"));
        return path;
    }

    private static void AddZipEntry(ZipArchive archive, string name, byte[] bytes)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        using var stream = entry.Open();
        stream.Write(bytes);
    }

    private static ShellManifest Shell() =>
        new(1, "3ds2apple-shell.ipa", "0.1.0", TemplateBundleId, new string('0', 64), 0, Build: 1);

    private sealed record Pipeline(
        DeployOrchestrator Orchestrator,
        LauncherWorkspace Workspace,
        TempDir Temp,
        FakeBuildProvider Build,
        FakeComposer Composer,
        FakeInstaller Installer,
        FakePusher Pusher,
        string TemplatePath)
    {
        public CollectingProgress Progress { get; } = new();
    }

    private static Pipeline CreatePipeline(TempDir temp, params LibraryEntry[] entries) =>
        CreatePipelineCore(temp, null, entries);

    private static Pipeline CreatePipelineWithCompatibility(
        TempDir temp,
        IBuildCompatibilityProvider compatibility,
        params LibraryEntry[] entries) =>
        CreatePipelineCore(temp, compatibility, entries);

    private static Pipeline CreatePipelineCore(
        TempDir temp,
        IBuildCompatibilityProvider? compatibility,
        params LibraryEntry[] entries)
    {
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        foreach (var entry in entries)
        {
            workspace.Upsert(entry);
        }
        workspace.SaveState();
        var build = new FakeBuildProvider();
        var composer = new FakeComposer();
        var installer = new FakeInstaller { BundleId = InstalledBundleId };
        var pusher = new FakePusher();
        var orchestrator = new DeployOrchestrator(workspace, Shell(), temp.Path, build, composer, installer, pusher, compatibility);
        return new Pipeline(orchestrator, workspace, temp, build, composer, installer, pusher, TemplateIpa(temp));
    }

    /// <summary>Build record exactly matching the current ROM, used by the cache-reuse tests.</summary>
    private static BuildArtifact Artifact(LibraryEntry entry, BuildCompatibility compatibility) => new()
    {
        BuildCompatVersion = compatibility.BuildCompatVersion,
        BuildCompatShort = compatibility.ShortVersion,
        RomSha256 = TestHash.Sha256Hex(entry.RomPath),
        RomBytes = new FileInfo(entry.RomPath).Length,
        RomLastWriteUtc = File.GetLastWriteTimeUtc(entry.RomPath),
        PackSha256 = entry.Pack?.Sha256 ?? string.Empty,
        PackBytes = entry.Pack?.Bytes ?? 0,
        LauncherVersion = "0.1.0",
        BuiltAt = DateTimeOffset.UtcNow,
    };

    private static DeployRequest Request(Pipeline pipeline, params string[] titleIds) =>
        new(titleIds, pipeline.TemplatePath, BundleIdOverride: null, DeviceUdid: null);

    [Fact]
    public async Task DeployBuildsMissingPacksChainsEveryStepAndPushesUsingInstalledBundleId()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Built game", temp, withRealPack: true), Entry(TitleB, "New game", temp, withRealPack: false));

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA, TitleB), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Null(outcome.FailedStep);
        Assert.NotNull(outcome.ComposedIpaPath);
        // Only the game without a real pack is compiled; the existing pack is reused.
        var request = Assert.Single(pipeline.Build.Requests);
        Assert.Equal(TitleB, request.TitleID);
        // One composed IPA contains both real packs, and it passed the hard gate.
        var composedPacks = Assert.Single(pipeline.Composer.Calls);
        Assert.Equal(new[] { TitleA, TitleB }, composedPacks.Select(pack => pack.TitleID));
        Assert.Single(pipeline.Installer.InstalledIpas);
        // Push uses the ACTUAL installed bundle id, not the shell template manifest value.
        Assert.Equal(2, pipeline.Pusher.PushBundleIds.Count);
        Assert.All(pipeline.Pusher.PushBundleIds, id => Assert.Equal(InstalledBundleId, id));
        Assert.DoesNotContain(TemplateBundleId, pipeline.Pusher.PushBundleIds);
        // Workspace state is persisted and every selected game ends verified.
        Assert.Equal(InstalledBundleId, pipeline.Workspace.State.InstalledBundleId);
        Assert.Equal(2, pipeline.Workspace.State.InstalledGameCount);
        Assert.All(outcome.Games, game => Assert.True(game.Built && game.Pushed && game.Verified, game.ErrorMessage));
        Assert.NotNull(pipeline.Workspace.Find(TitleA)!.PushedAt);
        Assert.NotNull(pipeline.Workspace.Find(TitleB)!.PushedAt);
        // All five steps reported success, in order.
        var succeeded = pipeline.Progress.Events.Where(e => e.Status == DeployStepStatus.Succeeded).Select(e => e.Step).ToList();
        Assert.Equal(new[]
        {
            DeployStepKind.Build, DeployStepKind.Compose, DeployStepKind.Install, DeployStepKind.Push, DeployStepKind.Verify,
        }, succeeded);
    }

    [Fact]
    public async Task DeployNeverSignsBareShellWhenTheToolchainIsMissing()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: false));
        pipeline.Build.FailCode = LocalWinbuildPackProvider.MissingToolsCode;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Build, outcome.FailedStep);
        Assert.Equal(LocalWinbuildPackProvider.MissingToolsCode, outcome.ErrorCode);
        Assert.Contains("3dsrecomp", outcome.ErrorMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.InstalledIpas);
        Assert.Empty(pipeline.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task DeployRejectsComposedBareShellBeforeSigning()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: false));
        // A buggy/spoofed composer returns an IPA without the real pack and an empty catalogue.
        pipeline.Composer.IncludePacks = false;
        pipeline.Composer.CatalogGames = 0;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Compose, outcome.FailedStep);
        Assert.StartsWith("composed_ipa_", outcome.ErrorCode ?? string.Empty, StringComparison.Ordinal);
        Assert.Empty(pipeline.Installer.InstalledIpas);
        Assert.Empty(pipeline.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task DeployFailureAtInstallStopsBeforePushAndSurfacesTheActionableFix()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: true));
        pipeline.Installer.Succeed = false;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Install, outcome.FailedStep);
        Assert.False(string.IsNullOrWhiteSpace(outcome.ErrorMessage));
        Assert.False(string.IsNullOrWhiteSpace(outcome.ErrorFix));
        Assert.True(outcome.Retryable);
        Assert.Empty(pipeline.Pusher.PushBundleIds);
        Assert.Null(pipeline.Workspace.State.InstalledBundleId);
    }

    [Fact]
    public async Task PushFailureNamesThePushStepPerGame()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: true), Entry(TitleB, "Game B", temp, withRealPack: true));
        pipeline.Pusher.FailPushFor = TitleB;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA, TitleB), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Push, outcome.FailedStep);
        Assert.Equal("device_not_found", outcome.ErrorCode);
        Assert.Contains("Game B", outcome.ErrorMessage, StringComparison.Ordinal);
        Assert.True(outcome.Games[0].Pushed);
        Assert.False(outcome.Games[1].Pushed);
    }

    [Fact]
    public async Task VerifyFailureIsReportedAsTheVerifyStep()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: true));
        pipeline.Pusher.FailVerify = true;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Verify, outcome.FailedStep);
        Assert.Equal("push_verify_failed", outcome.ErrorCode);
        Assert.Null(pipeline.Workspace.Find(TitleA)!.PushedAt);
    }

    [Fact]
    public async Task DeployWithNoSelectionFailsBeforeAnyWork()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(TitleA, "Game A", temp, withRealPack: true));

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline), pipeline.Progress);

        Assert.False(outcome.Success);
        Assert.Equal(DeployStepKind.Build, outcome.FailedStep);
        Assert.Equal("no_games_selected", outcome.ErrorCode);
        Assert.False(outcome.Retryable);
        Assert.Empty(pipeline.Build.Requests);
        Assert.Empty(pipeline.Installer.InstalledIpas);
    }

    [Fact]
    public async Task DeployReusesTheCacheOnlyWhenCompatAndRomShaMatch()
    {
        using var temp = new TempDir();
        var compatibility = new StaticBuildCompatibilityProvider();
        var entry = Entry(TitleA, "Cached game", temp, withRealPack: true);
        entry.Build = Artifact(entry, compatibility.Compatibility);
        var pipeline = CreatePipelineWithCompatibility(temp, compatibility, entry);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Empty(pipeline.Build.Requests);
    }

    [Fact]
    public async Task DeployRebuildsWhenTheRomShaChanged()
    {
        using var temp = new TempDir();
        var compatibility = new StaticBuildCompatibilityProvider();
        var entry = Entry(TitleA, "Changed ROM", temp, withRealPack: true);
        // The build record matches the original ROM; the user then replaces the ROM file
        // (different content/size), so the recorded SHA-256 can no longer be trusted.
        entry.Build = Artifact(entry, compatibility.Compatibility);
        File.WriteAllBytes(entry.RomPath, new byte[] { 9, 9, 9 });
        var pipeline = CreatePipelineWithCompatibility(temp, compatibility, entry);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Build.Requests);
        Assert.Equal(TestHash.Sha256Hex(entry.RomPath), pipeline.Workspace.Find(TitleA)!.Build!.RomSha256);
    }

    [Fact]
    public async Task DeployRebuildsWhenTheBuildRecipeChanged()
    {
        using var temp = new TempDir();
        var compatibility = new StaticBuildCompatibilityProvider(clangVersion: "22.0.0");
        var entry = Entry(TitleA, "Old recipe", temp, withRealPack: true);
        entry.Build = Artifact(entry, BuildCompatibility.Create("1.0.0", "21.1.8", "21.1.8"));
        var pipeline = CreatePipelineWithCompatibility(temp, compatibility, entry);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Build.Requests);
    }

    [Fact]
    public async Task DeployRebuildsALegacyPackWithoutACompatibilityMarker()
    {
        using var temp = new TempDir();
        var compatibility = new StaticBuildCompatibilityProvider();
        var entry = Entry(TitleA, "Legacy pack", temp, withRealPack: true);
        var pipeline = CreatePipelineWithCompatibility(temp, compatibility, entry);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Build.Requests);
    }

    [Fact]
    public async Task DeployRecordsTheBuildMarkerAndRomShaAfterCompiling()
    {
        using var temp = new TempDir();
        var compatibility = new StaticBuildCompatibilityProvider();
        var entry = Entry(TitleA, "New game", temp, withRealPack: false);
        var pipeline = CreatePipelineWithCompatibility(temp, compatibility, entry);
        pipeline.Build.Compatibility = compatibility.Compatibility;

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        var built = pipeline.Workspace.Find(TitleA)!;
        Assert.NotNull(built.Build);
        Assert.Equal(compatibility.Compatibility.BuildCompatVersion, built.Build!.BuildCompatVersion);
        Assert.Equal(TestHash.Sha256Hex(entry.RomPath), built.Build.RomSha256);
        Assert.Equal(LauncherInfo.Version, built.Build.LauncherVersion);
        Assert.True(built.Build.PackBytes > 0);
    }

    // --- fakes ----------------------------------------------------------

    internal sealed class CollectingProgress : IProgress<DeployProgress>
    {
        public List<DeployProgress> Events { get; } = new();

        public void Report(DeployProgress value) => Events.Add(value);
    }

    private sealed class FakeBuildProvider : IPackBuildProvider
    {
        public List<PackBuildRequest> Requests { get; } = new();
        public string? FailCode { get; set; }
        public bool Installable { get; set; } = true;
        public BuildCompatibility? Compatibility { get; set; }

        public string Name => "fake local build";

        public bool InstallableProvider => Installable;

        public Task<PackBuildOutcome> BuildAsync(PackBuildRequest request, IProgress<BuildProgress>? progress, Action<string>? log, CancellationToken cancellationToken = default)
        {
            Requests.Add(request);
            if (FailCode is { } code)
            {
                return Task.FromResult(PackBuildOutcome.Failure(code, "missing local toolchain: 3dsrecomp.exe / clang.exe"));
            }
            var packPath = Path.Combine(request.WorkDirectory, "fake-" + request.TitleID + ".dylib");
            Directory.CreateDirectory(Path.GetDirectoryName(packPath)!);
            File.WriteAllBytes(packPath, Arm64MachODylib());
            progress?.Report(new BuildProgress("link", 100, "fake pack built"));
            return Task.FromResult(new PackBuildOutcome(
                true,
                Installable,
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

    private sealed class FakeComposer : IComposedIpaComposer
    {
        public List<IReadOnlyList<ComposedPack>> Calls { get; } = new();
        public bool IncludePacks { get; set; } = true;
        public int CatalogGames { get; set; } = -1;

        public Task<ComposedAppIpa> ComposeAsync(string shellTemplateIpaPath, IReadOnlyList<ComposedPack> packs, string outputDirectory, Action<string>? log, CancellationToken cancellationToken)
        {
            Calls.Add(packs);
            Directory.CreateDirectory(outputDirectory);
            var ipaPath = Path.Combine(outputDirectory, "composed-" + Guid.NewGuid().ToString("N")[..8] + ".ipa");
            using (var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Create))
            {
                AddZipEntry(archive, "Payload/demo.app/Info.plist", Encoding.UTF8.GetBytes("<plist/>"));
                var gameCount = CatalogGames < 0 ? packs.Count : Math.Min(CatalogGames, packs.Count);
                var gamesJson = string.Join(",", packs.Take(gameCount).Select(pack =>
                    "{\"titleID\":\"" + pack.TitleID + "\",\"packFile\":\"Frameworks/GamePack-" + pack.TitleID + ".dylib\"}"));
                AddZipEntry(archive, "Payload/demo.app/GameCatalog.json",
                    Encoding.UTF8.GetBytes("{\"schemaVersion\":2,\"games\":[" + gamesJson + "]}"));
                if (IncludePacks)
                {
                    foreach (var pack in packs)
                    {
                        AddZipEntry(archive, "Payload/demo.app/Frameworks/GamePack-" + pack.TitleID + ".dylib", Arm64MachODylib());
                    }
                }
            }
            var bytes = new FileInfo(ipaPath).Length;
            return Task.FromResult(new ComposedAppIpa(
                ipaPath,
                Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(ipaPath))),
                bytes,
                packs.Count,
                packs.Select(pack => pack.TitleID).ToList(),
                "Payload/demo.app/"));
        }
    }

    private sealed class FakeInstaller : IAppIpaInstaller
    {
        public List<string> InstalledIpas { get; } = new();
        public string BundleId { get; set; } = InstalledBundleId;
        public bool Succeed { get; set; } = true;

        public Task<ShellInstallOutcome> InstallAsync(ShellManifest shell, string shellDirectory, string ipaPath, string? bundleIdOverride, string? deviceUdid, Action<string>? log, CancellationToken cancellationToken)
        {
            InstalledIpas.Add(ipaPath);
            if (!Succeed)
            {
                var error = AppleErrorCatalog.Lookup("generic_signing_failure")! with { Detail = "plumesign failed: simulated" };
                return Task.FromResult(new ShellInstallOutcome(false, bundleIdOverride ?? shell.BundleId, null, error, null));
            }
            return Task.FromResult(new ShellInstallOutcome(true, BundleId, ipaPath + ".signed", null, null));
        }
    }

    private sealed class FakePusher : IGameDataPusher
    {
        public List<string> PushBundleIds { get; } = new();
        public List<GamePushPlan> Plans { get; } = new();
        public string? FailPushFor { get; set; }
        public bool FailVerify { get; set; }

        public Task<GamePushPlan> CreatePlanAsync(LibraryEntry entry, string stagingDirectory, Action<string>? log, CancellationToken cancellationToken) =>
            GamePushPlan.CreateAsync(
                stagingDirectory,
                entry.TitleID,
                string.IsNullOrWhiteSpace(entry.DisplayNameOverride) ? entry.DisplayName : entry.DisplayNameOverride,
                entry.ProductCode,
                1,
                entry.PackPath,
                entry.RomPath,
                entry.DisplayNames,
                entry.Publisher,
                entry.Region,
                entry.CoverPath,
                log,
                cancellationToken);

        public Task<PushOutcome> PushAsync(GamePushPlan plan, string bundleId, string? deviceUdid, bool resume, IProgress<PushProgress>? progress, Action<string>? log, CancellationToken cancellationToken)
        {
            PushBundleIds.Add(bundleId);
            Plans.Add(plan);
            if (FailPushFor is { } failed && string.Equals(plan.TitleId, failed, StringComparison.OrdinalIgnoreCase))
            {
                return Task.FromResult(new PushOutcome(false, plan.RemoteDirectory, Array.Empty<string>(), Array.Empty<string>(),
                    "device_not_found", "the phone is not connected"));
            }
            return Task.FromResult(new PushOutcome(true, plan.RemoteDirectory,
                plan.Files.Select(file => file.RemoteName).ToList(), Array.Empty<string>(), null, null));
        }

        public Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? deviceUdid, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<string>>(FailVerify
                ? new[] { "GameRom.cci: wrong size on the phone" }
                : Array.Empty<string>());
    }
}

/// <summary>Unit tests for the hard gate between composition and signing.</summary>
public sealed class ComposedIpaVerifierTests
{
    private const string TitleId = "0004000000055E00";

    private static (string IpaPath, ComposedPack Pack) Fixture(TempDir temp, string? catalogJson = null, bool includePack = true)
    {
        var packPath = temp.Bytes("GamePack.dylib", new byte[] { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 });
        var ipaPath = Path.Combine(temp.Path, "composed.ipa");
        using var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Create);
        AddZipEntry(archive, "Payload/demo.app/GameCatalog.json", Encoding.UTF8.GetBytes(catalogJson
            ?? "{\"schemaVersion\":2,\"games\":[{\"titleID\":\"" + TitleId + "\",\"packFile\":\"Frameworks/GamePack-" + TitleId + ".dylib\"}]}"));
        if (includePack)
        {
            AddZipEntry(archive, "Payload/demo.app/Frameworks/GamePack-" + TitleId + ".dylib", new byte[] { 0xCF, 0xFA, 0xED, 0xFE });
        }
        return (ipaPath, new ComposedPack(TitleId, "Demo", null, 1, packPath));
    }

    private static void AddZipEntry(ZipArchive archive, string name, byte[] bytes)
    {
        var entry = archive.CreateEntry(name);
        using var stream = entry.Open();
        stream.Write(bytes);
    }

    [Fact]
    public void AcceptsARealPackAndNonEmptySchema2Catalogue()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp);
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack });
        Assert.True(result.Ok, result.Describe());
        Assert.Equal(1, result.GameCount);
        Assert.Equal(TitleId, Assert.Single(result.TitleIDs));
    }

    [Fact]
    public void RejectsZeroPacks()
    {
        using var temp = new TempDir();
        var (ipaPath, _) = Fixture(temp);
        var result = ComposedIpaVerifier.Verify(ipaPath, Array.Empty<ComposedPack>());
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_no_packs", result.ErrorCode);
    }

    [Fact]
    public void RejectsMissingPackEntry()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp, includePack: false);
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack });
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_pack_missing", result.ErrorCode);
    }

    [Fact]
    public void RejectsEmptyCatalogue()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp, catalogJson: "{\"schemaVersion\":2,\"games\":[]}");
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack });
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_catalog_empty", result.ErrorCode);
    }

    [Fact]
    public void RejectsWrongCatalogueSchema()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp,
            catalogJson: "{\"schemaVersion\":1,\"games\":[{\"titleID\":\"" + TitleId + "\",\"packFile\":\"Frameworks/GamePack-" + TitleId + ".dylib\"}]}");
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack });
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_catalog_invalid", result.ErrorCode);
    }

    [Fact]
    public void RejectsCatalogueGameCountMismatch()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp, catalogJson: "{\"schemaVersion\":2,\"games\":[]}");
        var second = new ComposedPack("0004000000055D00", "Demo 2", null, 1, pack.PackPath);
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack, second });
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_catalog_empty", result.ErrorCode);
    }

    [Fact]
    public void RejectsGameDataInsideTheIpa()
    {
        using var temp = new TempDir();
        var (ipaPath, pack) = Fixture(temp);
        using (var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Update))
        {
            AddZipEntry(archive, "Payload/demo.app/Roms/" + TitleId + ".cci", new byte[] { 1, 2, 3 });
        }
        var result = ComposedIpaVerifier.Verify(ipaPath, new[] { pack });
        Assert.False(result.Ok);
        Assert.Equal("composed_ipa_contains_rom", result.ErrorCode);
    }
}
