using System.IO.Compression;
using System.Text;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Device-aware incremental deploy: the pure decision table, the marker file and the
/// orchestrator behaviour for every rule from .internal/round-016-beta2.md section 5.
/// All fakes are local to this file: no phone, no pack CLI, no Impactor.
/// </summary>
public sealed class DeviceDeployPlannerTests
{
    private const string TitleA = "0004000000055D00";
    private const string TitleB = "0004000000055E00";
    private const string TitleC = "0004000000055F00";
    private const string Expected = "0.1.6-beta2";

    private static BuildCompatibility Compatibility() => new StaticBuildCompatibilityProvider().Compatibility;

    private static byte[] Arm64MachODylib()
    {
        var bytes = new byte[64];
        BitConverter.GetBytes(0xFEEDFACFu).CopyTo(bytes, 0);
        BitConverter.GetBytes(0x0100000C).CopyTo(bytes, 4);
        BitConverter.GetBytes(6u).CopyTo(bytes, 12);
        return bytes;
    }

    private static LibraryEntry Entry(TempDir temp, string titleId, string name, bool built = true)
    {
        var compatibility = Compatibility();
        var rom = temp.Bytes("rom-" + titleId + ".cci", new byte[] { 1, 2, 3, 4, 5, 6, 7 });
        var entry = new LibraryEntry
        {
            TitleID = titleId,
            DisplayName = name,
            ProductCode = "CTR-P-TEST",
            RomPath = rom,
            State = built ? "built" : "imported",
        };
        if (built)
        {
            var packPath = temp.Bytes("pack-" + titleId + ".dylib", Arm64MachODylib());
            entry.Pack = new PackRecord(new string('a', 64), new FileInfo(packPath).Length, "gamepack-macho");
            entry.PackPath = packPath;
            entry.BuiltAt = DateTimeOffset.UtcNow;
            entry.Build = new BuildArtifact
            {
                BuildCompatVersion = compatibility.BuildCompatVersion,
                BuildCompatShort = compatibility.ShortVersion,
                RomSha256 = TestHash.Sha256Hex(rom),
                RomBytes = new FileInfo(rom).Length,
                RomLastWriteUtc = File.GetLastWriteTimeUtc(rom),
                PackSha256 = TestHash.Sha256Hex(packPath),
                PackBytes = new FileInfo(packPath).Length,
                LauncherVersion = Expected,
                BuiltAt = DateTimeOffset.UtcNow,
            };
        }
        return entry;
    }

    private static DeviceDeployMarker Marker(string appPackageVersion, params LibraryEntry[] entries) =>
        DeviceDeployMarker.Create(Expected, appPackageVersion, "0.1.6", 1, entries, null);

    private static DeviceDeploySnapshot Snapshot(
        DeviceAppIdentity app,
        DeviceDeployMarker? marker,
        params (LibraryEntry Game, long? RomBytes, long? InfoBytes)[] installed)
    {
        var ids = new List<string>();
        var data = new Dictionary<string, DeviceGameData>(StringComparer.OrdinalIgnoreCase);
        foreach (var (game, romBytes, infoBytes) in installed)
        {
            ids.Add(game.TitleID);
            data[game.TitleID] = new DeviceGameData(game.TitleID, romBytes, infoBytes);
        }
        return new DeviceDeploySnapshot(app, ids, data, marker);
    }

    private static long RomBytes(LibraryEntry entry) => new FileInfo(entry.RomPath).Length;

    private static DeviceDeployDecision Decide(TempDir temp, DeviceDeploySnapshot snapshot, IReadOnlyList<LibraryEntry> selected, IReadOnlyList<LibraryEntry> library)
    {
        return DeviceDeployPlanner.Decide(
            snapshot,
            Expected,
            selected,
            library,
            titleId =>
            {
                var entry = library.FirstOrDefault(item => string.Equals(item.TitleID, titleId, StringComparison.OrdinalIgnoreCase));
                return entry is null ? (long?)null : RomBytes(entry);
            });
    }

    [Fact]
    public void NotInstalledMeansFullInstall()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var snapshot = Snapshot(DeviceAppIdentity.NotInstalled, null);
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.FullInstall, decision.Mode);
        Assert.Single(decision.IpaGames);
        Assert.Single(decision.PushGames);
    }

    [Fact]
    public void AppVersionMismatchReinstallsTheUnionAndPushesOnlyMissingData()
    {
        using var temp = new TempDir();
        var installed = Entry(temp, TitleA, "Installed game");
        var selected = Entry(temp, TitleB, "New game");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", "0.1.6-beta1"), Marker("0.1.6-beta1", installed),
            (installed, RomBytes(installed), 64L),
            (selected, null, null));
        var decision = Decide(temp, snapshot, new[] { selected }, new[] { installed, selected });
        Assert.Equal(DeviceDeployMode.Reinstall, decision.Mode);
        Assert.Equal(new[] { TitleB, TitleA }, decision.IpaGames.Select(item => item.TitleID));
        Assert.Equal(new[] { TitleB }, decision.PushGames.Select(item => item.TitleID));
    }

    [Fact]
    public void CurrentAppWithCurrentDataAndBuildsIsNoOp()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), Marker(Expected, game),
            (game, RomBytes(game), 64L));
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.UpToDate, decision.Mode);
        Assert.Empty(decision.IpaGames);
        Assert.Empty(decision.PushGames);
    }

    [Fact]
    public void CurrentAppWithMissingDataPushesOnly()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), Marker(Expected, game),
            (game, null, null));
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.PushOnly, decision.Mode);
        Assert.Empty(decision.IpaGames);
        Assert.Single(decision.PushGames);
    }

    [Fact]
    public void CurrentAppButChangedGamePackReinstalls()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var marker = Marker(Expected, game) with
        {
            Games = new[] { DeviceDeployMarker.BuildRecord(game)! with { BuildCompatVersion = "build=old" } },
        };
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker,
            (game, RomBytes(game), 64L));
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.Reinstall, decision.Mode);
        Assert.Contains(decision.Notes, note => note.Contains("build identity is outdated", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void MissingMarkerOnAnExistingInstallUpdatesOnceWithEveryBuiltGame()
    {
        using var temp = new TempDir();
        var installed = Entry(temp, TitleA, "Installed game");
        var otherBuilt = Entry(temp, TitleC, "Other built game");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), null);
        var decision = Decide(temp, snapshot, new[] { installed }, new[] { installed, otherBuilt });
        Assert.Equal(DeviceDeployMode.Reinstall, decision.Mode);
        Assert.Equal(new[] { TitleA, TitleC }, decision.IpaGames.Select(item => item.TitleID));
    }

    [Fact]
    public void UnknownPackageVersionUpdatesOnce()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", null), Marker(Expected, game),
            (game, RomBytes(game), 64L));
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.Reinstall, decision.Mode);
    }

    [Fact]
    public void DataIsCurrentRequiresCompleteMatchingFilesAndMarker()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var marker = Marker(Expected, game);
        var complete = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker, (game, RomBytes(game), 64L));
        Assert.True(DeviceDeployPlanner.IsDataCurrent(complete, game, RomBytes(game)));
        var wrongSize = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker, (game, RomBytes(game) + 1, 64L));
        Assert.False(DeviceDeployPlanner.IsDataCurrent(wrongSize, game, RomBytes(game)));
        var noInfo = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker, (game, RomBytes(game), null));
        Assert.False(DeviceDeployPlanner.IsDataCurrent(noInfo, game, RomBytes(game)));
    }

    [Fact]
    public void FindOrphanedInstalledGamesReportsPhoneOnlyData()
    {
        using var temp = new TempDir();
        var known = Entry(temp, TitleA, "Known game");
        var missingRom = Entry(temp, TitleB, "Missing ROM game");
        missingRom.RomPath = Path.Combine(temp.Path, "deleted.cci");
        var phoneOnly = new LibraryEntry { TitleID = TitleC, RomPath = string.Empty };
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), Marker(Expected, known),
            (known, RomBytes(known), 64L),
            (missingRom, 4096L, 64L),
            (phoneOnly, 4096L, 64L));
        var library = new[] { known, missingRom };
        bool HasLocalRom(string titleId) =>
            library.FirstOrDefault(item => string.Equals(item.TitleID, titleId, StringComparison.OrdinalIgnoreCase))
                is { RomPath.Length: > 0 } entry && File.Exists(entry.RomPath);

        var orphans = DeviceDeployPlanner.FindOrphanedInstalledGames(snapshot, library, HasLocalRom);

        Assert.Equal(2, orphans.Count);
        Assert.Contains(orphans, orphan => orphan.TitleID == TitleC && orphan.DisplayName is null);
        Assert.Contains(orphans, orphan => orphan.TitleID == TitleB && orphan.DisplayName == "Missing ROM game");
        Assert.DoesNotContain(orphans, orphan => orphan.TitleID == TitleA);
    }

    [Fact]
    public void DecisionCarriesOrphansWithoutChangingTheMode()
    {
        using var temp = new TempDir();
        var game = Entry(temp, TitleA, "Game A");
        var phoneOnly = new LibraryEntry { TitleID = TitleC, RomPath = string.Empty };
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), Marker(Expected, game),
            (game, RomBytes(game), 64L), (phoneOnly, 4096L, 64L));
        var decision = Decide(temp, snapshot, new[] { game }, new[] { game });
        Assert.Equal(DeviceDeployMode.UpToDate, decision.Mode);
        var orphan = Assert.Single(decision.OrphanedGames);
        Assert.Equal(TitleC, orphan.TitleID);
        Assert.True(decision.HasOrphanedGames);
    }
}

/// <summary>Marker file (Documents/.3ds2apple-deploy.json) round-trip and compatibility.</summary>
public sealed class DeviceDeployMarkerTests
{
    private const string TitleA = "0004000000055D00";

    private static LibraryEntry BuiltEntry(TempDir temp)
    {
        var compatibility = new StaticBuildCompatibilityProvider().Compatibility;
        var rom = temp.Bytes("rom.cci", new byte[] { 1, 2, 3 });
        var pack = temp.Bytes("pack.dylib", new byte[] { 4, 5, 6 });
        return new LibraryEntry
        {
            TitleID = TitleA,
            DisplayName = "Game",
            RomPath = rom,
            PackPath = pack,
            Pack = new PackRecord(new string('a', 64), 3, "gamepack-macho"),
            Build = new BuildArtifact
            {
                BuildCompatVersion = compatibility.BuildCompatVersion,
                BuildCompatShort = compatibility.ShortVersion,
                RomSha256 = TestHash.Sha256Hex(rom),
                RomBytes = 3,
                PackSha256 = TestHash.Sha256Hex(pack),
                PackBytes = 3,
                LauncherVersion = "0.1.6-beta2",
                BuiltAt = DateTimeOffset.UtcNow,
            },
        };
    }

    [Fact]
    public void MarkerSerializesAndParsesRoundTrip()
    {
        using var temp = new TempDir();
        var entry = BuiltEntry(temp);
        var marker = DeviceDeployMarker.Create("0.1.6-beta2", "0.1.6-beta2", "0.1.6", 1, new[] { entry }, null);
        var parsed = DeviceDeployMarker.Parse(marker.ToJson());
        Assert.NotNull(parsed);
        Assert.Equal(1, parsed!.SchemaVersion);
        Assert.Equal("0.1.6-beta2", parsed.AppPackageVersion);
        var record = parsed.Find(TitleA);
        Assert.NotNull(record);
        Assert.Equal(entry.Build!.BuildCompatVersion, record!.BuildCompatVersion);
        Assert.Equal(entry.Build.RomSha256, record.RomSha256);
    }

    [Fact]
    public void MarkerRejectsForeignOrCorruptContent()
    {
        Assert.Null(DeviceDeployMarker.Parse(null));
        Assert.Null(DeviceDeployMarker.Parse(""));
        Assert.Null(DeviceDeployMarker.Parse("not json"));
        Assert.Null(DeviceDeployMarker.Parse("{\"schemaVersion\":99}"));
    }

    [Fact]
    public void MarkerCreationPreservesRecordsFromPreviousRuns()
    {
        using var temp = new TempDir();
        var entry = BuiltEntry(temp);
        var first = DeviceDeployMarker.Create("0.1.6-beta2", "0.1.6-beta1", "0.1.6", 1, new[] { entry }, null);
        var removed = first.Games[0] with { TitleID = "00040000000AAAAA" };
        var previous = first with { Games = new[] { removed } };
        var created = DeviceDeployMarker.Create("0.1.6-beta2", "0.1.6-beta2", "0.1.6", 1, Array.Empty<LibraryEntry>(), previous);
        var record = Assert.Single(created.Games);
        Assert.Equal("00040000000AAAAA", record.TitleID);
    }

    [Fact]
    public void MarkerRecordsPhoneOnlyGamesAsDataOnly()
    {
        using var temp = new TempDir();
        var entry = BuiltEntry(temp);
        var orphans = new[] { new DeviceOrphanedGame("00040000000AAAAA", "Phone game", 4096, 64) };
        var marker = DeviceDeployMarker.Create("0.1.6-beta2", "0.1.6-beta2", "0.1.6", 1, new[] { entry }, null, orphans);
        var orphan = marker.Find("00040000000AAAAA");
        Assert.NotNull(orphan);
        Assert.True(orphan!.DataOnly);
        Assert.Equal(4096, orphan.RomBytes);
        Assert.False(marker.Find(TitleA)!.DataOnly);
        var parsed = DeviceDeployMarker.Parse(marker.ToJson());
        Assert.NotNull(parsed);
        Assert.True(parsed!.Find("00040000000AAAAA")!.DataOnly);
    }
}

/// <summary>End-to-end orchestrator behaviour with a fake device inspector and fake tools.</summary>
public sealed class DeviceDeployOrchestratorTests
{
    private const string TitleA = "0004000000055D00";
    private const string TitleB = "0004000000055E00";
    private const string TitleC = "0004000000055F00";
    private const string Expected = "0.1.6-beta2";
    private const string TemplateBundleId = "com.template.shell";
    private const string InstalledBundleId = "com.example.actual-installed";

    [Fact]
    public async Task NotInstalledRunsTheFullFlowAndWritesTheMarker()
    {
        using var temp = new TempDir();
        var game = NewEntry(temp, TitleA, "Game A");
        var pipeline = CreatePipeline(temp, new DeviceDeploySnapshot(DeviceAppIdentity.NotInstalled, Array.Empty<string>(),
            new Dictionary<string, DeviceGameData>(), null), game);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Composer.Calls);
        Assert.Single(pipeline.Installer.Calls);
        Assert.Single(pipeline.Pusher.Plans);
        var marker = Assert.Single(pipeline.Inspector.WrittenMarkers);
        Assert.NotNull(marker.Find(TitleA));
        Assert.Equal(Expected, marker.AppPackageVersion);
        Assert.Equal(DeviceDeployMode.FullInstall, outcome.DeviceSummary!.Mode);
    }

    [Fact]
    public async Task AppVersionMismatchReinstallsTheUnionAndPushesOnlyTheNewGame()
    {
        using var temp = new TempDir();
        var installed = NewEntry(temp, TitleA, "Installed game");
        var selected = NewEntry(temp, TitleB, "New game");
        var marker = DeviceDeployMarker.Create(Expected, "0.1.6-beta1", "0.1.6", 1, new[] { installed }, null);
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", "0.1.6-beta1"), marker,
            (installed, ((long?)null, (long?)null)), (selected, ((long?)null, (long?)null)));
        var pipeline = CreatePipeline(temp, snapshot, installed, selected);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleB), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        var composed = Assert.Single(pipeline.Composer.Calls);
        Assert.Equal(new[] { TitleB, TitleA }, composed.Select(pack => pack.TitleID));
        Assert.Single(pipeline.Installer.Calls);
        var pushed = Assert.Single(pipeline.Pusher.Plans);
        Assert.Equal(TitleB, pushed.TitleId);
        var written = Assert.Single(pipeline.Inspector.WrittenMarkers);
        Assert.NotNull(written.Find(TitleA));
        Assert.NotNull(written.Find(TitleB));
        Assert.Equal(DeviceDeployMode.Reinstall, outcome.DeviceSummary!.Mode);
    }

    [Fact]
    public async Task UpToDateSkipsInstallAndPush()
    {
        using var temp = new TempDir();
        var game = NewEntry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected),
            DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { game }, null),
            (game, CompleteData(game)));
        var pipeline = CreatePipeline(temp, snapshot, game);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.Calls);
        Assert.Empty(pipeline.Pusher.Plans);
        Assert.Empty(pipeline.Inspector.WrittenMarkers);
        Assert.True(outcome.Games[0].Pushed);
        Assert.True(outcome.Games[0].Verified);
        Assert.Equal(DeviceDeployMode.UpToDate, outcome.DeviceSummary!.Mode);
        Assert.Contains(pipeline.Progress.Events, e => e.Step == DeployStepKind.Install && e.Status == DeployStepStatus.Skipped);
    }

    [Fact]
    public async Task MissingDataPushesOnlyWithoutReinstalling()
    {
        using var temp = new TempDir();
        var game = NewEntry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected),
            DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { game }, null),
            (game, ((long?)null, (long?)null)));
        var pipeline = CreatePipeline(temp, snapshot, game);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.Calls);
        Assert.Single(pipeline.Pusher.Plans);
        Assert.Single(pipeline.Inspector.WrittenMarkers);
        Assert.Equal(DeviceDeployMode.PushOnly, outcome.DeviceSummary!.Mode);
    }

    [Fact]
    public async Task ChangedGamePackBuildReinstallsEvenWhenDataIsCurrent()
    {
        using var temp = new TempDir();
        var game = NewEntry(temp, TitleA, "Game A");
        var marker = DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { game }, null) with
        {
            Games = new[] { DeviceDeployMarker.BuildRecord(game)! with { BuildCompatVersion = "build=old" } },
        };
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker, (game, CompleteData(game)));
        var pipeline = CreatePipeline(temp, snapshot, game);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Composer.Calls);
        Assert.Single(pipeline.Installer.Calls);
        Assert.Empty(pipeline.Pusher.Plans);
        Assert.Equal(DeviceDeployMode.Reinstall, outcome.DeviceSummary!.Mode);
    }

    [Fact]
    public async Task MissingMarkerUpdatesOnceAndKeepsEveryBuiltGame()
    {
        using var temp = new TempDir();
        var installed = NewEntry(temp, TitleA, "Installed game");
        var otherBuilt = NewEntry(temp, TitleC, "Other built game");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), null, (installed, CompleteData(installed)));
        var pipeline = CreatePipeline(temp, snapshot, installed, otherBuilt);
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);
        Assert.True(outcome.Success, outcome.ErrorMessage);
        var composed = Assert.Single(pipeline.Composer.Calls);
        Assert.Equal(new[] { TitleA, TitleC }, composed.Select(pack => pack.TitleID));
        Assert.Single(pipeline.Installer.Calls);
        Assert.Single(pipeline.Inspector.WrittenMarkers);
    }

    [Fact]
    public async Task MarkerWriteFailureStillLeavesTheDeploySuccessful()
    {
        using var temp = new TempDir();
        var game = NewEntry(temp, TitleA, "Game A");
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected),
            DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { game }, null),
            (game, ((long?)null, (long?)null)));
        var pipeline = CreatePipeline(temp, snapshot, game);
        pipeline.Inspector.MarkerWriteError = new LauncherToolException("afc_error", "marker write failed (simulated)");
        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress, line => pipeline.Logs.Add(line));
        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Empty(pipeline.Inspector.WrittenMarkers);
        Assert.Contains(pipeline.Logs, line => line.Contains("deploy marker could not be written", StringComparison.Ordinal));
    }

    [Fact]
    public async Task OverwriteInstallIsBlockedWhenPhoneGamesAreMissingFromTheLibrary()
    {
        using var temp = new TempDir();
        var selected = NewEntry(temp, TitleA, "Selected game");
        var phoneOnly = PhoneOnlyEntry(TitleC);
        var marker = DeviceDeployMarker.Create(Expected, "0.1.6-beta1", "0.1.6", 1, new[] { selected }, null);
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", "0.1.6-beta1"), marker,
            (selected, CompleteData(selected)), (phoneOnly, ((long?)4096, (long?)64)));
        var pipeline = CreatePipeline(temp, snapshot, selected);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress, line => pipeline.Logs.Add(line));

        Assert.False(outcome.Success);
        Assert.Equal("orphaned_games_need_confirmation", outcome.ErrorCode);
        Assert.Equal(DeployStepKind.Install, outcome.FailedStep);
        var orphan = Assert.Single(outcome.OrphanedGames!);
        Assert.Equal(TitleC, orphan.TitleID);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.Calls);
        Assert.Empty(pipeline.Pusher.Plans);
        Assert.Empty(pipeline.Inspector.WrittenMarkers);
        Assert.Contains(pipeline.Logs, line => line.Contains("orphaned_games_need_confirmation", StringComparison.Ordinal));
    }

    [Fact]
    public async Task ConfirmedOverwriteProceedsAndRecordsThePhoneOnlyGameAsDataOnly()
    {
        using var temp = new TempDir();
        var selected = NewEntry(temp, TitleA, "Selected game");
        var phoneOnly = PhoneOnlyEntry(TitleC);
        var marker = DeviceDeployMarker.Create(Expected, "0.1.6-beta1", "0.1.6", 1, new[] { selected }, null);
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", "0.1.6-beta1"), marker,
            (selected, CompleteData(selected)), (phoneOnly, ((long?)4096, (long?)64)));
        var pipeline = CreatePipeline(temp, snapshot, selected);

        var outcome = await pipeline.Orchestrator.RunAsync(RequestAcceptingOrphans(pipeline, TitleA), pipeline.Progress, line => pipeline.Logs.Add(line));

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Composer.Calls);
        Assert.Single(pipeline.Installer.Calls);
        var written = Assert.Single(pipeline.Inspector.WrittenMarkers);
        Assert.True(written.Find(TitleC)!.DataOnly);
        Assert.NotNull(written.Find(TitleA));
        Assert.Contains(pipeline.Logs, line => line.Contains("confirmed update", StringComparison.Ordinal));
    }

    [Fact]
    public async Task DataOnlyUpdateKeepsPhoneOnlyGamesUntouched()
    {
        using var temp = new TempDir();
        var selected = NewEntry(temp, TitleA, "Selected game");
        var phoneOnly = PhoneOnlyEntry(TitleC);
        var marker = DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { selected }, null);
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker,
            (selected, ((long?)null, (long?)null)), (phoneOnly, ((long?)4096, (long?)64)));
        var pipeline = CreatePipeline(temp, snapshot, selected);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress, line => pipeline.Logs.Add(line));

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.Calls);
        Assert.Single(pipeline.Pusher.Plans);
        var written = Assert.Single(pipeline.Inspector.WrittenMarkers);
        Assert.True(written.Find(TitleC)!.DataOnly);
        Assert.Contains(pipeline.Logs, line => line.Contains("untouched", StringComparison.Ordinal));
    }

    [Fact]
    public async Task UpToDateWithPhoneOnlyGamesStaysANoOp()
    {
        using var temp = new TempDir();
        var selected = NewEntry(temp, TitleA, "Selected game");
        var phoneOnly = PhoneOnlyEntry(TitleC);
        var marker = DeviceDeployMarker.Create(Expected, Expected, "0.1.6", 1, new[] { selected }, null);
        var snapshot = Snapshot(new DeviceAppIdentity(true, "0.1.6", "1", Expected), marker,
            (selected, CompleteData(selected)), (phoneOnly, ((long?)4096, (long?)64)));
        var pipeline = CreatePipeline(temp, snapshot, selected);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress, line => pipeline.Logs.Add(line));

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Equal(DeviceDeployMode.UpToDate, outcome.DeviceSummary!.Mode);
        Assert.Empty(pipeline.Composer.Calls);
        Assert.Empty(pipeline.Installer.Calls);
        Assert.Empty(pipeline.Pusher.Plans);
        Assert.Empty(pipeline.Inspector.WrittenMarkers);
        Assert.Single(outcome.OrphanedGames!);
        Assert.Contains(pipeline.Logs, line => line.Contains("untouched", StringComparison.Ordinal));
    }

    [Fact]
    public async Task FreshInstallDoesNotBlockOnPreExistingPhoneData()
    {
        using var temp = new TempDir();
        var selected = NewEntry(temp, TitleA, "Selected game");
        var phoneOnly = PhoneOnlyEntry(TitleC);
        var snapshot = Snapshot(DeviceAppIdentity.NotInstalled, null, (phoneOnly, ((long?)4096, (long?)64)));
        var pipeline = CreatePipeline(temp, snapshot, selected);

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline, TitleA), pipeline.Progress);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Single(pipeline.Installer.Calls);
    }

    // --- fixtures -------------------------------------------------------

    private static DeviceDeploySnapshot Snapshot(DeviceAppIdentity app, DeviceDeployMarker? marker, params (LibraryEntry Game, (long? RomBytes, long? InfoBytes) Data)[] installed)
    {
        var ids = new List<string>();
        var data = new Dictionary<string, DeviceGameData>(StringComparer.OrdinalIgnoreCase);
        foreach (var (game, sizes) in installed)
        {
            ids.Add(game.TitleID);
            data[game.TitleID] = new DeviceGameData(game.TitleID, sizes.RomBytes, sizes.InfoBytes);
        }
        return new DeviceDeploySnapshot(app, ids, data, marker);
    }

    private static (long? RomBytes, long? InfoBytes) CompleteData(LibraryEntry game) =>
        (new FileInfo(game.RomPath).Length, 64L);

    private sealed record Pipeline(
        DeployOrchestrator Orchestrator,
        LauncherWorkspace Workspace,
        RecordingComposer Composer,
        RecordingInstaller Installer,
        RecordingPusher Pusher,
        FakeDeviceInspector Inspector,
        string TemplatePath)
    {
        public CollectingProgress Progress { get; } = new();
        public List<string> Logs { get; } = new();
    }

    private static Pipeline CreatePipeline(TempDir temp, DeviceDeploySnapshot snapshot, params LibraryEntry[] entries)
    {
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        foreach (var entry in entries)
        {
            workspace.Upsert(entry);
        }
        workspace.SaveState();
        var compatibility = new StaticBuildCompatibilityProvider();
        var composer = new RecordingComposer();
        var installer = new RecordingInstaller();
        var pusher = new RecordingPusher();
        var inspector = new FakeDeviceInspector { Snapshot = snapshot };
        var template = TemplateIpa(temp);
        var orchestrator = new DeployOrchestrator(
            workspace,
            Shell(),
            temp.Path,
            new FakeBuildProvider { Compatibility = compatibility.Compatibility },
            composer,
            installer,
            pusher,
            compatibility,
            inspector,
            Expected);
        var pipeline = new Pipeline(orchestrator, workspace, composer, installer, pusher, inspector, template);
        return pipeline;
    }

    private static DeployRequest Request(Pipeline pipeline, params string[] titleIds) =>
        new(titleIds, pipeline.TemplatePath, BundleIdOverride: null, DeviceUdid: null);

    private static DeployRequest RequestAcceptingOrphans(Pipeline pipeline, params string[] titleIds) =>
        new(titleIds, pipeline.TemplatePath, BundleIdOverride: null, DeviceUdid: null, AcceptOrphanedGames: true);

    /// <summary>A game object the phone reports but the launcher workspace/library does not have.</summary>
    private static LibraryEntry PhoneOnlyEntry(string titleId) =>
        new() { TitleID = titleId, DisplayName = "Phone-only game", RomPath = string.Empty };

    private static LibraryEntry NewEntry(TempDir temp, string titleId, string name)
    {
        var compatibility = new StaticBuildCompatibilityProvider().Compatibility;
        var rom = temp.Bytes("rom-" + titleId + ".cci", new byte[] { 1, 2, 3, 4, 5, 6, 7 });
        var packPath = temp.Bytes("pack-" + titleId + ".dylib", Arm64MachODylib());
        return new LibraryEntry
        {
            TitleID = titleId,
            DisplayName = name,
            ProductCode = "CTR-P-TEST",
            RomPath = rom,
            State = "built",
            Pack = new PackRecord(TestHash.Sha256Hex(packPath), new FileInfo(packPath).Length, "gamepack-macho"),
            PackPath = packPath,
            BuiltAt = DateTimeOffset.UtcNow,
            Build = new BuildArtifact
            {
                BuildCompatVersion = compatibility.BuildCompatVersion,
                BuildCompatShort = compatibility.ShortVersion,
                RomSha256 = TestHash.Sha256Hex(rom),
                RomBytes = new FileInfo(rom).Length,
                RomLastWriteUtc = File.GetLastWriteTimeUtc(rom),
                PackSha256 = TestHash.Sha256Hex(packPath),
                PackBytes = new FileInfo(packPath).Length,
                LauncherVersion = Expected,
                BuiltAt = DateTimeOffset.UtcNow,
            },
        };
    }

    private static ShellManifest Shell() => new(1, "3ds2apple-shell.ipa", "0.1.6", TemplateBundleId, new string('0', 64), 0, Build: 1);

    private static byte[] Arm64MachODylib()
    {
        var bytes = new byte[64];
        BitConverter.GetBytes(0xFEEDFACFu).CopyTo(bytes, 0);
        BitConverter.GetBytes(0x0100000C).CopyTo(bytes, 4);
        BitConverter.GetBytes(6u).CopyTo(bytes, 12);
        return bytes;
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

    private sealed class CollectingProgress : IProgress<DeployProgress>
    {
        public List<DeployProgress> Events { get; } = new();
        public void Report(DeployProgress value) => Events.Add(value);
    }

    private sealed class FakeDeviceInspector : IDeviceDeployInspector
    {
        public DeviceDeploySnapshot Snapshot { get; set; } = new(DeviceAppIdentity.NotInstalled, Array.Empty<string>(),
            new Dictionary<string, DeviceGameData>(), null);
        public List<DeviceDeployMarker> WrittenMarkers { get; } = new();
        public LauncherToolException? MarkerWriteError { get; set; }

        public Task<DeviceDeploySnapshot> InspectAsync(DeviceDeployInspectRequest request, Action<string>? log, CancellationToken cancellationToken = default) =>
            Task.FromResult(Snapshot);

        public Task WriteMarkerAsync(DeviceDeployMarkerWriteRequest request, Action<string>? log, CancellationToken cancellationToken = default)
        {
            if (MarkerWriteError is not null)
            {
                throw MarkerWriteError;
            }
            WrittenMarkers.Add(request.Marker);
            return Task.CompletedTask;
        }
    }

    private sealed class FakeBuildProvider : IPackBuildProvider
    {
        public BuildCompatibility? Compatibility { get; set; }
        public string Name => "fake local build";
        public bool Installable => true;
        public bool InstallableProvider => true;

        public Task<PackBuildOutcome> BuildAsync(PackBuildRequest request, IProgress<BuildProgress>? progress, Action<string>? log, CancellationToken cancellationToken = default)
        {
            var packPath = Path.Combine(request.WorkDirectory, "fake-" + request.TitleID + ".dylib");
            Directory.CreateDirectory(Path.GetDirectoryName(packPath)!);
            File.WriteAllBytes(packPath, Arm64MachODylib());
            return Task.FromResult(new PackBuildOutcome(
                true, true, packPath,
                new PackRecord(new string('b', 64), new FileInfo(packPath).Length, "gamepack-macho"),
                null, null, "fake-" + request.TitleID, Compatibility,
                TestHash.Sha256Hex(request.RomPath), new FileInfo(request.RomPath).Length));
        }
    }

    private sealed class RecordingComposer : IComposedIpaComposer
    {
        public List<IReadOnlyList<ComposedPack>> Calls { get; } = new();

        public Task<ComposedAppIpa> ComposeAsync(string shellTemplateIpaPath, IReadOnlyList<ComposedPack> packs, string outputDirectory, Action<string>? log, CancellationToken cancellationToken)
        {
            Calls.Add(packs);
            Directory.CreateDirectory(outputDirectory);
            var ipaPath = Path.Combine(outputDirectory, "composed-" + Guid.NewGuid().ToString("N")[..8] + ".ipa");
            using (var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Create))
            {
                AddZipEntry(archive, "Payload/demo.app/Info.plist", Encoding.UTF8.GetBytes("<plist/>"));
                var gamesJson = string.Join(",", packs.Select(pack =>
                    "{\"titleID\":\"" + pack.TitleID + "\",\"packFile\":\"Frameworks/GamePack-" + pack.TitleID + ".dylib\"}"));
                AddZipEntry(archive, "Payload/demo.app/GameCatalog.json",
                    Encoding.UTF8.GetBytes("{\"schemaVersion\":2,\"games\":[" + gamesJson + "]}"));
                foreach (var pack in packs)
                {
                    AddZipEntry(archive, "Payload/demo.app/Frameworks/GamePack-" + pack.TitleID + ".dylib", Arm64MachODylib());
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

    private sealed class RecordingInstaller : IAppIpaInstaller
    {
        public List<string> Calls { get; } = new();

        public Task<ShellInstallOutcome> InstallAsync(ShellManifest shell, string shellDirectory, string ipaPath, string? bundleIdOverride, string? deviceUdid, Action<string>? log, CancellationToken cancellationToken)
        {
            Calls.Add(ipaPath);
            return Task.FromResult(new ShellInstallOutcome(true, InstalledBundleId, ipaPath + ".signed", null, null));
        }
    }

    private sealed class RecordingPusher : IGameDataPusher
    {
        public List<GamePushPlan> Plans { get; } = new();

        public Task<GamePushPlan> CreatePlanAsync(LibraryEntry entry, string stagingDirectory, Action<string>? log, CancellationToken cancellationToken) =>
            GamePushPlan.CreateAsync(
                stagingDirectory, entry.TitleID, entry.DisplayName, entry.ProductCode,
                LauncherInfo.GamePackAbiVersion, entry.PackPath, entry.RomPath,
                entry.DisplayNames, entry.Publisher, entry.Region, entry.CoverPath, log, cancellationToken);

        public Task<PushOutcome> PushAsync(GamePushPlan plan, string bundleId, string? deviceUdid, bool resume, IProgress<PushProgress>? progress, Action<string>? log, CancellationToken cancellationToken)
        {
            Plans.Add(plan);
            return Task.FromResult(new PushOutcome(true, plan.RemoteDirectory,
                plan.Files.Select(file => file.RemoteName).ToList(), Array.Empty<string>(), null, null));
        }

        public Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? deviceUdid, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
    }
}

/// <summary>
/// devpush/1 app-attr parsing: the launcher reads the three identity keys out of the
/// JSON keys map (the mock backend and a real installation_proxy both report them).
/// </summary>
public sealed class DevPushClientAppAttrTests
{
    private const string DoneLine = "{\"schema\":\"devpush/1\",\"type\":\"done\",\"command\":\"app-attr\",\"installed\":true,\"dataContainer\":\"/container\",\"fileSharingEnabled\":true,\"keys\":{\"CFBundleShortVersionString\":\"0.1.6\",\"CFBundleVersion\":\"7\",\"ThreeDS2ApplePackageVersion\":\"0.1.6-beta2\",\"Other\":\"value\"}}";

    [Fact]
    public async Task ParsesTheThreeIdentityKeysFromTheKeysMap()
    {
        var runner = new ScriptedRunner(DoneLine);
        var client = new ThreeDsTwoApple.Launcher.Core.Device.DevPushClient(runner, "devpush.exe");
        var attributes = await client.AppAttrAsync("com.kratos.3ds2apple");
        Assert.True(attributes.Installed);
        Assert.Equal("0.1.6", attributes.ShortVersion);
        Assert.Equal("7", attributes.BuildVersion);
        Assert.Equal("0.1.6-beta2", attributes.PackageVersion);
        Assert.NotNull(attributes.Attributes);
        Assert.Equal("0.1.6-beta2", attributes.Attributes!["ThreeDS2ApplePackageVersion"]);
        Assert.Equal("value", attributes.Attributes["Other"]);
        Assert.Equal(1, runner.Calls);
    }

    [Fact]
    public async Task AppMissingErrorIsReportedAsNotInstalled()
    {
        var runner = new ScriptedRunner("{\"schema\":\"devpush/1\",\"type\":\"error\",\"command\":\"app-attr\",\"error\":{\"code\":\"app_missing\",\"message\":\"missing\",\"exitCode\":5}}");
        var client = new ThreeDsTwoApple.Launcher.Core.Device.DevPushClient(runner, "devpush.exe");
        var attributes = await client.AppAttrAsync("com.kratos.3ds2apple");
        Assert.False(attributes.Installed);
        Assert.Null(attributes.PackageVersion);
    }

    private sealed class ScriptedRunner : IProcessRunner
    {
        private readonly string _stdout;

        public ScriptedRunner(string stdout) => _stdout = stdout;

        public int Calls { get; private set; }

        public Task<ProcessResult> RunAsync(ProcessRequest request, Action<string>? onStdOutLine = null, Action<string>? onStdErrLine = null, CancellationToken cancellationToken = default)
        {
            Calls++;
            foreach (var line in _stdout.Split('\n'))
            {
                onStdOutLine?.Invoke(line);
            }
            return Task.FromResult(new ProcessResult(0, _stdout, string.Empty, false, true));
        }
    }
}
