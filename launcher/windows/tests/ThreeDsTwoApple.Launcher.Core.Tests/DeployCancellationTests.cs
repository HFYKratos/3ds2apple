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
/// Contract tests for the user Stop action: the Deploy pipeline must react to the
/// cancellation token in every stage, report a Cancelled outcome (not a failure) that
/// names the interrupted step, and never report later steps as failed/succeeded.
/// The tool-process tree kill itself is covered by ProcessRunnerTests.
/// </summary>
public sealed class DeployCancellationTests
{
    private const string TitleId = "0004000000055E00";
    private static readonly string TemplateBundleId = "com.template.shell";

    private static byte[] Arm64MachODylib()
    {
        var bytes = new byte[64];
        BitConverter.GetBytes(0xFEEDFACFu).CopyTo(bytes, 0);
        BitConverter.GetBytes(0x0100000C).CopyTo(bytes, 4);
        BitConverter.GetBytes(6u).CopyTo(bytes, 12);
        return bytes;
    }

    private static LibraryEntry Entry(TempDir temp, bool withRealPack)
    {
        var rom = temp.Bytes("rom-" + TitleId + ".cci", new byte[] { 1, 2, 3, 4, 5, 6, 7 });
        var entry = new LibraryEntry
        {
            TitleID = TitleId,
            DisplayName = "Cancellable game",
            ProductCode = "CTR-P-TEST",
            RomPath = rom,
            State = withRealPack ? "built" : "imported",
        };
        if (withRealPack)
        {
            var packPath = temp.Bytes("pack-" + TitleId + ".dylib", Arm64MachODylib());
            entry.Pack = new PackRecord(new string('a', 64), new FileInfo(packPath).Length, "gamepack-macho");
            entry.PackPath = packPath;
            entry.BuiltAt = DateTimeOffset.UtcNow;
        }
        return entry;
    }

    private sealed record Pipeline(
        DeployOrchestrator Orchestrator,
        Fakes Fakes,
        CollectingProgress Progress,
        string TemplatePath);

    private static Pipeline CreatePipeline(TempDir temp, LibraryEntry entry)
    {
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        workspace.Upsert(entry);
        workspace.SaveState();
        var fakes = new Fakes();
        var shell = new ShellManifest(1, "3ds2apple-shell.ipa", "0.1.0", TemplateBundleId, new string('0', 64), 0, Build: 1);
        var orchestrator = new DeployOrchestrator(workspace, shell, temp.Path, fakes.Build, fakes.Composer, fakes.Installer, fakes.Pusher);
        var templatePath = Path.Combine(temp.Path, "template.ipa");
        using (var archive = ZipFile.Open(templatePath, ZipArchiveMode.Create))
        {
            AddZipEntry(archive, "Payload/demo.app/Info.plist", Encoding.UTF8.GetBytes("<plist/>"));
            AddZipEntry(archive, "Payload/demo.app/GameCatalog.json", Encoding.UTF8.GetBytes("{\"schemaVersion\":2,\"games\":[]}"));
        }
        return new Pipeline(orchestrator, fakes, new CollectingProgress(), templatePath);
    }

    private static DeployRequest Request(Pipeline pipeline) =>
        new(new[] { TitleId }, pipeline.TemplatePath, BundleIdOverride: null, DeviceUdid: null);

    private static async Task<DeployOutcome> RunAndStopAsync(Pipeline pipeline, Task started, CancellationTokenSource cancellation)
    {
        var run = pipeline.Orchestrator.RunAsync(Request(pipeline), pipeline.Progress, null, cancellation.Token);
        await started.WaitAsync(TimeSpan.FromSeconds(10));
        cancellation.Cancel();
        return await run.WaitAsync(TimeSpan.FromSeconds(15));
    }

    private static void AssertCancelledAt(DeployOutcome outcome, CollectingProgress progress, DeployStepKind step)
    {
        Assert.True(outcome.Cancelled);
        Assert.False(outcome.Success);
        Assert.Equal(step, outcome.FailedStep);
        Assert.Equal("deploy_cancelled", outcome.ErrorCode);
        Assert.True(outcome.Retryable);
        Assert.Contains(progress.Events, e => e.Step == step && e.Status == DeployStepStatus.Cancelled);
    }

    [Fact]
    public async Task StopDuringBuildReportsCancelledInsteadOfAFailedBuild()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: false));
        pipeline.Fakes.Build.Block = true;
        using var cancellation = new CancellationTokenSource();

        var outcome = await RunAndStopAsync(pipeline, pipeline.Fakes.Build.Started.Task, cancellation);

        AssertCancelledAt(outcome, pipeline.Progress, DeployStepKind.Build);
        Assert.Empty(pipeline.Fakes.Composer.Calls);
        Assert.Empty(pipeline.Fakes.Installer.InstalledIpas);
        Assert.Empty(pipeline.Fakes.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task StopDuringComposeReportsCancelledAtTheComposeStep()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: true));
        pipeline.Fakes.Composer.Block = true;
        using var cancellation = new CancellationTokenSource();

        var outcome = await RunAndStopAsync(pipeline, pipeline.Fakes.Composer.Started.Task, cancellation);

        AssertCancelledAt(outcome, pipeline.Progress, DeployStepKind.Compose);
        Assert.Empty(pipeline.Fakes.Installer.InstalledIpas);
        Assert.Empty(pipeline.Fakes.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task StopDuringInstallReportsCancelledBeforePush()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: true));
        pipeline.Fakes.Installer.Block = true;
        using var cancellation = new CancellationTokenSource();

        var outcome = await RunAndStopAsync(pipeline, pipeline.Fakes.Installer.Started.Task, cancellation);

        AssertCancelledAt(outcome, pipeline.Progress, DeployStepKind.Install);
        Assert.Empty(pipeline.Fakes.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task StopDuringPushReportsCancelledAndLeavesTheGameUnverified()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: true));
        pipeline.Fakes.Pusher.Block = true;
        using var cancellation = new CancellationTokenSource();

        var outcome = await RunAndStopAsync(pipeline, pipeline.Fakes.Pusher.Started.Task, cancellation);

        AssertCancelledAt(outcome, pipeline.Progress, DeployStepKind.Push);
        Assert.All(outcome.Games, game => Assert.False(game.Verified));
    }

    [Fact]
    public async Task AnAlreadyCancelledTokenStopsTheDeployBeforeAnyToolRuns()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: true));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline), pipeline.Progress, null, cancellation.Token);

        AssertCancelledAt(outcome, pipeline.Progress, DeployStepKind.Build);
        Assert.Empty(pipeline.Fakes.Composer.Calls);
        Assert.Empty(pipeline.Fakes.Installer.InstalledIpas);
        Assert.Empty(pipeline.Fakes.Pusher.PushBundleIds);
    }

    [Fact]
    public async Task TheSameCancellationTokenReachesCompileComposeInstallAndPush()
    {
        using var temp = new TempDir();
        var pipeline = CreatePipeline(temp, Entry(temp, withRealPack: false));
        using var cancellation = new CancellationTokenSource();

        var outcome = await pipeline.Orchestrator.RunAsync(Request(pipeline), pipeline.Progress, null, cancellation.Token);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.Equal(cancellation.Token, pipeline.Fakes.Build.Token);
        Assert.Equal(cancellation.Token, pipeline.Fakes.Composer.Token);
        Assert.Equal(cancellation.Token, pipeline.Fakes.Installer.Token);
        Assert.Equal(cancellation.Token, pipeline.Fakes.Pusher.PushToken);
        Assert.Equal(cancellation.Token, pipeline.Fakes.Pusher.VerifyToken);
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

    private sealed class Fakes
    {
        public RecordingBuildProvider Build { get; } = new();
        public RecordingComposer Composer { get; } = new();
        public RecordingInstaller Installer { get; } = new();
        public RecordingPusher Pusher { get; } = new();
    }

    private sealed class RecordingBuildProvider : IPackBuildProvider
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken Token { get; private set; }
        public bool Block { get; set; }

        public string Name => "recording fake build";

        public bool Installable => true;

        public async Task<PackBuildOutcome> BuildAsync(
            PackBuildRequest request,
            IProgress<BuildProgress>? progress,
            Action<string>? log,
            CancellationToken cancellationToken = default)
        {
            Token = cancellationToken;
            Started.TrySetResult();
            if (Block)
            {
                await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            }
            var packPath = Path.Combine(request.WorkDirectory, "fake-" + request.TitleID + ".dylib");
            Directory.CreateDirectory(Path.GetDirectoryName(packPath)!);
            File.WriteAllBytes(packPath, Arm64MachODylib());
            progress?.Report(new BuildProgress("link", 100, "fake pack built"));
            return new PackBuildOutcome(
                true,
                true,
                packPath,
                new PackRecord(new string('b', 64), new FileInfo(packPath).Length, "gamepack-macho"),
                null,
                null,
                "fake-" + request.TitleID);
        }
    }

    private sealed class RecordingComposer : IComposedIpaComposer
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken Token { get; private set; }
        public bool Block { get; set; }
        public List<IReadOnlyList<ComposedPack>> Calls { get; } = new();

        public async Task<ComposedAppIpa> ComposeAsync(
            string shellTemplateIpaPath,
            IReadOnlyList<ComposedPack> packs,
            string outputDirectory,
            Action<string>? log,
            CancellationToken cancellationToken)
        {
            Token = cancellationToken;
            Calls.Add(packs);
            Started.TrySetResult();
            if (Block)
            {
                await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            }
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
            return new ComposedAppIpa(
                ipaPath,
                Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(File.ReadAllBytes(ipaPath))),
                bytes,
                packs.Count,
                packs.Select(pack => pack.TitleID).ToList(),
                "Payload/demo.app/");
        }
    }

    private sealed class RecordingInstaller : IAppIpaInstaller
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken Token { get; private set; }
        public bool Block { get; set; }
        public List<string> InstalledIpas { get; } = new();

        public async Task<ShellInstallOutcome> InstallAsync(
            ShellManifest shell,
            string shellDirectory,
            string ipaPath,
            string? bundleIdOverride,
            string? deviceUdid,
            Action<string>? log,
            CancellationToken cancellationToken)
        {
            Token = cancellationToken;
            InstalledIpas.Add(ipaPath);
            Started.TrySetResult();
            if (Block)
            {
                await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            }
            return new ShellInstallOutcome(true, "com.example.installed", ipaPath + ".signed", null, null);
        }
    }

    private sealed class RecordingPusher : IGameDataPusher
    {
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationToken CreatePlanToken { get; private set; }
        public CancellationToken PushToken { get; private set; }
        public CancellationToken VerifyToken { get; private set; }
        public bool Block { get; set; }
        public List<string> PushBundleIds { get; } = new();

        public async Task<GamePushPlan> CreatePlanAsync(
            LibraryEntry entry,
            string stagingDirectory,
            Action<string>? log,
            CancellationToken cancellationToken)
        {
            CreatePlanToken = cancellationToken;
            return await GamePushPlan.CreateAsync(
                stagingDirectory,
                entry.TitleID,
                entry.DisplayName,
                entry.ProductCode,
                LauncherInfo.GamePackAbiVersion,
                entry.PackPath,
                entry.RomPath,
                entry.DisplayNames,
                entry.Publisher,
                entry.Region,
                entry.CoverPath,
                log,
                cancellationToken).ConfigureAwait(false);
        }

        public async Task<PushOutcome> PushAsync(
            GamePushPlan plan,
            string bundleId,
            string? deviceUdid,
            bool resume,
            IProgress<PushProgress>? progress,
            Action<string>? log,
            CancellationToken cancellationToken)
        {
            PushToken = cancellationToken;
            PushBundleIds.Add(bundleId);
            Started.TrySetResult();
            if (Block)
            {
                await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            }
            return new PushOutcome(true, plan.RemoteDirectory,
                plan.Files.Select(file => file.RemoteName).ToList(), Array.Empty<string>(), null, null);
        }

        public Task<IReadOnlyList<string>> VerifyAsync(GamePushPlan plan, string bundleId, string? deviceUdid, CancellationToken cancellationToken)
        {
            VerifyToken = cancellationToken;
            return Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>());
        }
    }
}
