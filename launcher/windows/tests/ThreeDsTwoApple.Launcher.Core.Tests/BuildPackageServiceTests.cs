using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Platform;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Library .32a export/import orchestration: the pack CLI stays the single format
/// writer, so these tests assert the arguments the launcher passes, the JSON it
/// parses and the workspace state it keeps (no real binary and no ROM involved).
/// </summary>
public sealed class BuildPackageServiceTests
{
    private const string TitleID = "0004000000055E00";
    private const string PackSha = "9ef3c7109da31dad50d104341b19f3ad0cf19e566b6a360f7356e975b7d4a36b";
    private const string FileSha = "1111111111111111111111111111111111111111111111111111111111111111";

    private static string ExportJson(string outputDir, bool romIncluded = true, string warnings = "[]") => $$"""
        {
          "outputDir": "{{outputDir}}",
          "builds": [
            {
              "titleID": "{{TitleID}}",
              "displayName": "Example Game",
              "path": "{{outputDir}}/example-game-00055e00.32a",
              "bytes": 123456,
              "sha256": "{{FileSha}}",
              "romIncluded": {{(romIncluded ? "true" : "false")}},
              "packBytes": 4096,
              "packSha256": "{{PackSha}}",
              "warnings": {{warnings}}
            }
          ],
          "errors": []
        }
        """;

    private static string ImportJson(string packageDir) => $$"""
        {
          "imported": {
            "titleID": "{{TitleID}}",
            "displayName": "Example Game",
            "path": "/tmp/example-game-00055e00.32a",
            "packageDir": "{{packageDir}}",
            "packBytes": 4096,
            "packSha256": "{{PackSha}}",
            "romIncluded": true,
            "replaced": false,
            "warnings": ["the package includes game data"]
          }
        }
        """;

    private static string PackageListJson(string packageDir) => $$"""
        {
          "packages": [
            {
              "titleID": "{{TitleID}}",
              "displayName": "Example Game",
              "productCode": "CTR-T-EXMP",
              "aotVersion": 1,
              "state": "built",
              "pack": { "sha256": "{{PackSha}}", "bytes": 4096, "format": "macho" },
              "issues": [],
              "displayNames": { "en": "Example Game" },
              "publisher": "Example Publisher",
              "coverPath": "{{packageDir}}/cover.png",
              "region": "EU"
            }
          ],
          "errors": []
        }
        """;

    private static (LauncherWorkspace Workspace, PackCli Cli, FakeProcessRunner Runner) Create(
        TempDir temp,
        Func<ProcessRequest, ProcessResult> handler)
    {
        var workspace = LauncherWorkspace.Open(temp.Path);
        var runner = new FakeProcessRunner(handler);
        var cli = new PackCli(runner, "3ds2apple-pack", workspace.OutRoot);
        return (workspace, cli, runner);
    }

    [Fact]
    public async Task ExportWritesIntoWorkspaceBuildsAndParsesTheCliJson()
    {
        using var temp = new TempDir();
        var (workspace, cli, runner) = Create(temp, _ => new ProcessResult(0, ExportJson(Path.Combine(temp.Path, "builds")), string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);
        var compatibility = BuildCompatibility.Create("rev", "23.1.6", "23.1.6");

        var outcome = await service.ExportAsync(new[] { TitleID }, compatibility);

        Assert.True(outcome.Ok, outcome.Error);
        Assert.Equal(Path.Combine(workspace.Root, "builds"), outcome.OutputDirectory);
        Assert.True(Directory.Exists(service.BuildsDirectory));
        var package = Assert.Single(outcome.Packages);
        Assert.Equal(TitleID, package.TitleID);
        Assert.Equal("Example Game", package.DisplayName);
        Assert.True(package.RomIncluded);
        Assert.Equal(4096, package.PackBytes);
        Assert.Equal(PackSha, package.PackSha256);

        var request = Assert.Single(runner.Requests);
        Assert.Equal("3ds2apple-pack", request.FileName);
        var arguments = request.Arguments.ToList();
        Assert.Equal("--out", arguments[0]);
        Assert.Equal(workspace.OutRoot, arguments[1]);
        Assert.Contains("--json", arguments);
        Assert.Contains("builds", arguments);
        Assert.Contains("export", arguments);
        Assert.Contains("--title-id", arguments);
        Assert.Equal(TitleID, arguments[arguments.IndexOf("--title-id") + 1]);
        Assert.Equal(service.BuildsDirectory, arguments[arguments.IndexOf("--output-dir") + 1]);
        Assert.Equal(PackCli.PlatformTag(), arguments[arguments.IndexOf("--platform") + 1]);
        Assert.Equal("O2", arguments[arguments.IndexOf("--opt-level") + 1]);
        Assert.Contains("--app-version", arguments);
        Assert.Contains("--launcher-version", arguments);
        Assert.Contains("--toolchain-clang", arguments);
        Assert.Contains("23.1.6", arguments);
        Assert.DoesNotContain("--lto", arguments);
        Assert.DoesNotContain("--fast-math", arguments);
    }

    [Fact]
    public async Task ExportHonoursACustomOutputFolder()
    {
        using var temp = new TempDir();
        var custom = Path.Combine(temp.Path, "picked-folder");
        var (workspace, cli, runner) = Create(temp,
            _ => new ProcessResult(0, ExportJson(custom), string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);

        var outcome = await service.ExportAsync(new[] { TitleID }, compatibility: null, outputDirectory: custom);

        Assert.True(outcome.Ok, outcome.Error);
        Assert.True(Directory.Exists(custom));
        Assert.Equal(custom, outcome.OutputDirectory);
        var arguments = Assert.Single(runner.Requests).Arguments.ToList();
        Assert.Equal(custom, arguments[arguments.IndexOf("--output-dir") + 1]);
    }

    [Fact]
    public async Task ExportWithoutTitleIdsExportsEveryBuiltPackage()
    {
        using var temp = new TempDir();
        var (workspace, cli, runner) = Create(temp, _ => new ProcessResult(0, ExportJson(Path.Combine(temp.Path, "builds")), string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);

        var outcome = await service.ExportAsync(Array.Empty<string>(), compatibility: null);

        Assert.True(outcome.Ok, outcome.Error);
        var arguments = Assert.Single(runner.Requests).Arguments;
        Assert.Contains("--all", arguments);
        Assert.DoesNotContain("--title-id", arguments);
        Assert.DoesNotContain("--toolchain-clang", arguments);
        Assert.DoesNotContain("--toolchain-llvm", arguments);
    }

    [Fact]
    public async Task ExportWithoutRomKeepsTheCliWarning()
    {
        using var temp = new TempDir();
        var json = ExportJson(Path.Combine(temp.Path, "builds"), romIncluded: false,
            warnings: System.Text.Json.JsonSerializer.Serialize(new[] { "no game data was found for this title" }));
        var (workspace, cli, _) = Create(temp, _ => new ProcessResult(0, json, string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);

        var outcome = await service.ExportAsync(new[] { TitleID }, compatibility: null);

        Assert.True(outcome.Ok, outcome.Error);
        Assert.False(outcome.Packages[0].RomIncluded);
        Assert.Contains("no game data", Assert.Single(outcome.Packages[0].Warnings));
    }

    [Fact]
    public async Task ExportSurfacesCliErrors()
    {
        using var temp = new TempDir();
        const string json = """
            {
              "outputDir": "/tmp/builds",
              "builds": [],
              "errors": [ { "titleID": "0004000000055E00", "error": "the package has no GamePack yet" } ]
            }
            """;
        var (workspace, cli, _) = Create(temp, _ => new ProcessResult(1, json, string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);

        var outcome = await service.ExportAsync(new[] { TitleID }, compatibility: null);

        Assert.False(outcome.Ok);
        Assert.Empty(outcome.Packages);
        Assert.Contains("no GamePack", Assert.Single(outcome.Errors));
    }

    [Fact]
    public async Task ImportInstallsThePackageAndUpsertsTheLibraryEntry()
    {
        using var temp = new TempDir();
        var packageDir = Path.Combine(temp.Path, "packages", TitleID);
        var (workspace, cli, runner) = Create(temp, request =>
        {
            if (request.Arguments.Contains("import"))
            {
                return new ProcessResult(0, ImportJson(packageDir), string.Empty, false, true);
            }
            if (request.Arguments.Contains("list"))
            {
                return new ProcessResult(0, PackageListJson(packageDir), string.Empty, false, true);
            }
            return new ProcessResult(1, string.Empty, "unexpected command", false, true);
        });
        var service = new BuildPackageService(workspace, cli);

        var packageFile = temp.Bytes(TitleID + "-Example Game.32a", new byte[] { 1, 2, 3 });
        var outcome = await service.ImportAsync(packageFile, replace: false);

        Assert.True(outcome.Ok, outcome.Error);
        var package = outcome.Package!;
        Assert.Equal(TitleID, package.TitleID);
        Assert.True(package.RomIncluded);
        Assert.Contains("game data", Assert.Single(outcome.Warnings));

        var importRequest = runner.Requests.First(request => request.Arguments.Contains("import"));
        var importArguments = importRequest.Arguments.ToList();
        Assert.Contains("builds", importArguments);
        Assert.Contains("import", importArguments);
        Assert.DoesNotContain("--replace", importArguments);

        var entry = workspace.Find(TitleID);
        Assert.NotNull(entry);
        Assert.Equal("built", entry!.State);
        Assert.Equal(Path.Combine(workspace.OutRoot, "packages", TitleID, "GamePack.dylib"), entry.PackPath);
        Assert.Equal("Example Game", entry.DisplayName);
        // 0.2.2-beta4: the imported .32a is the entry's RomPath (persisted); the ROM
        // consumers resolve its embedded GameRom instead.
        Assert.Equal(Path.GetFullPath(packageFile), entry.RomPath);
        var reloaded = LauncherWorkspace.Open(temp.Path);
        Assert.NotNull(reloaded.Find(TitleID));
    }

    [Fact]
    public async Task ImportWithReplacePassesTheReplaceFlag()
    {
        using var temp = new TempDir();
        var packageDir = Path.Combine(temp.Path, "packages", TitleID);
        var (workspace, cli, runner) = Create(temp, request =>
            request.Arguments.Contains("import")
                ? new ProcessResult(0, ImportJson(packageDir), string.Empty, false, true)
                : new ProcessResult(0, PackageListJson(packageDir), string.Empty, false, true));
        var service = new BuildPackageService(workspace, cli);

        var packageFile = temp.Bytes(TitleID + "-Example Game.32a", new byte[] { 1, 2, 3 });
        var outcome = await service.ImportAsync(packageFile, replace: true);

        Assert.True(outcome.Ok, outcome.Error);
        var importRequest = runner.Requests.First(request => request.Arguments.Contains("import"));
        Assert.Contains("--replace", importRequest.Arguments);
    }

    [Fact]
    public async Task ImportConflictIsReportedForTheReplacePrompt()
    {
        using var temp = new TempDir();
        const string conflict = "a package for 0004000000055E00 already exists at /tmp/packages; pass --replace to overwrite its build files";
        var (workspace, cli, _) = Create(temp, _ => new ProcessResult(1, string.Empty, conflict, false, true));
        var service = new BuildPackageService(workspace, cli);

        var packageFile = temp.Bytes(TitleID + "-Example Game.32a", new byte[] { 1, 2, 3 });
        var outcome = await service.ImportAsync(packageFile, replace: false);

        Assert.False(outcome.Ok);
        Assert.Null(outcome.Package);
        Assert.Contains("--replace", outcome.Error);
        Assert.Null(workspace.Find(TitleID));
    }

    [Fact]
    public async Task MissingPackCliIsOneActionableError()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        var service = new BuildPackageService(workspace, packCli: null);

        var exported = await service.ExportAsync(new[] { TitleID }, compatibility: null);
        var imported = await service.ImportAsync("/tmp/example.32a", replace: false);

        Assert.False(exported.Ok);
        Assert.Contains("3ds2apple-pack", exported.Error);
        Assert.False(imported.Ok);
        Assert.Contains("3ds2apple-pack", imported.Error);
    }

    [Fact]
    public void PlatformTagIsPackedIntoTheManifest()
    {
        var tag = PackCli.PlatformTag();
        Assert.False(string.IsNullOrWhiteSpace(tag));
        Assert.Contains(tag, new[] { "windows", "macos", "linux" });
    }

    // --- 0.2.2-beta6: .32a build-cache restoration on import -----------------

    [Fact]
    public void LinuxImportRecordsForeignGamePackWithoutLocalToolchain()
    {
        using var temp = new TempDir();
        var packageFile = BuildPackageFile(temp);
        var currentWithoutLocalBuildTools = BuildCompatibility.Create();
        var created = BuildPackageManifestReader.TryCreateArtifact(
            packageFile, currentWithoutLocalBuildTools, out var artifact, out var status, out var detail);

        if (LauncherPlatform.IsLinux)
        {
            Assert.True(created, detail);
            Assert.NotNull(artifact);
            Assert.Equal(BuildCacheImportStatus.Recorded, status);
            Assert.Equal(currentWithoutLocalBuildTools.BuildCompatVersion, artifact!.BuildCompatVersion);
            Assert.Equal(ManifestRomSha, artifact.RomSha256);
            var decision = BuildCachePolicy.Evaluate(
                artifact, currentWithoutLocalBuildTools.BuildCompatVersion, artifact.RomSha256, "pack.dylib", _ => true);
            Assert.True(decision.Reuse, decision.Detail);
        }
        else
        {
            Assert.False(created);
            Assert.Equal(BuildCacheImportStatus.Mismatch, status);
        }
    }

    private const string ManifestClang = "clang version 23.1.6";
    private const string ManifestLlvm = "LLD 23.1.6";
    private const string ManifestGamePackSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    private const string ManifestRomSha = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc";
    private const string ManifestGameInfoSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    private static BuildCompatibility CurrentCompatibility(string clang = ManifestClang, string ld64 = ManifestLlvm, string options = "opt=O2;lto=0;fastmath=0") =>
        BuildCompatibility.Create(clangVersion: clang, ld64Version: ld64, buildOptions: options);

    /// <summary>Create a real .32a ZIP with the builder's manifest v1 layout.</summary>
    private static string BuildPackageFile(
        TempDir temp,
        bool includeRom = true,
        bool includeManifest = true,
        bool includeToolchain = true,
        string clang = ManifestClang,
        string llvm = ManifestLlvm,
        string optLevel = "O2",
        bool lto = false,
        bool fastMath = false)
    {
        var path = Path.Combine(temp.Path, TitleID + "-Example Game.32a");
        using var archive = ZipFile.Open(path, ZipArchiveMode.Create);
        if (includeManifest)
        {
            var manifest = new Dictionary<string, object?>
            {
                ["format"] = "3ds2apple-build",
                ["schemaVersion"] = 1,
                ["titleID"] = TitleID,
                ["displayName"] = "Example Game",
                ["productCode"] = "CTR-T-EXMP",
                ["aotVersion"] = 1,
                ["appVersion"] = "0.2.2",
                ["builtAt"] = "2026-01-31T12:34:56Z",
                ["platform"] = "windows",
                ["buildOptions"] = new Dictionary<string, object?>
                {
                    ["optLevel"] = optLevel,
                    ["lto"] = lto,
                    ["fastMath"] = fastMath,
                },
                ["pack"] = new Dictionary<string, object?>
                {
                    ["file"] = "GamePack-" + TitleID + ".dylib",
                    ["bytes"] = 4096,
                    ["sha256"] = ManifestGamePackSha,
                    ["format"] = "macho",
                    ["abiVersion"] = 1,
                },
                ["gameInfoSha256"] = ManifestGameInfoSha,
                ["rom"] = includeRom
                    ? new Dictionary<string, object?>
                    {
                        ["included"] = true,
                        ["file"] = "GameRom.cci",
                        ["bytes"] = 9,
                        ["sha256"] = ManifestRomSha,
                    }
                    : new Dictionary<string, object?> { ["included"] = false },
                ["sourceLauncher"] = new Dictionary<string, object?> { ["os"] = "windows", ["version"] = "0.2.2-beta5" },
            };
            if (includeToolchain)
            {
                manifest["toolchain"] = new Dictionary<string, object?> { ["clang"] = clang, ["llvm"] = llvm };
            }
            WriteEntry(archive, "manifest.json", JsonSerializer.Serialize(manifest));
        }
        WriteEntry(archive, "GamePack-" + TitleID + ".dylib", "fake-dylib");
        WriteEntry(archive, "GameInfo.json", "{}");
        if (includeRom)
        {
            WriteEntry(archive, "GameRom.cci", "rom-bytes");
        }
        return path;
    }

    private static void WriteEntry(ZipArchive archive, string name, string text)
    {
        var entry = archive.CreateEntry(name);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(text);
    }

    private static (LauncherWorkspace Workspace, PackCli Cli) CreateImportService(TempDir temp)
    {
        var packageDir = Path.Combine(temp.Path, "packages", TitleID);
        var (workspace, cli, _) = Create(temp, request =>
            request.Arguments.Contains("import")
                ? new ProcessResult(0, ImportJson(packageDir), string.Empty, false, true)
                : new ProcessResult(0, PackageListJson(packageDir), string.Empty, false, true));
        return (workspace, cli);
    }

    [Fact]
    public async Task ImportRecordsTheBuildCacheFromThePackageManifest()
    {
        using var temp = new TempDir();
        var (workspace, cli) = CreateImportService(temp);
        var service = new BuildPackageService(workspace, cli);
        var packageFile = BuildPackageFile(temp);
        var compatibility = CurrentCompatibility();

        var outcome = await service.ImportAsync(packageFile, replace: false, compatibility);

        Assert.True(outcome.Ok, outcome.Error);
        Assert.Equal(BuildCacheImportStatus.Recorded, outcome.BuildCacheStatus);
        var entry = workspace.Find(TitleID);
        Assert.NotNull(entry);
        Assert.NotNull(entry!.Build);
        Assert.Equal(compatibility.BuildCompatVersion, entry.Build!.BuildCompatVersion);
        Assert.Equal(ManifestGamePackSha, entry.Build.PackSha256);
        Assert.Equal(4096, entry.Build.PackBytes);
        Assert.Equal(ManifestRomSha, entry.Build.RomSha256);
        Assert.Equal(9, entry.Build.RomBytes);
        Assert.Equal("0.2.2-beta5", entry.Build.LauncherVersion);
        Assert.NotNull(entry.BuiltAt);

        // This is the actual Deploy decision: the imported GamePack is reusable.
        var decision = BuildCachePolicy.Evaluate(
            entry.Build, compatibility.BuildCompatVersion, entry.Build.RomSha256, "pack.dylib", _ => true);
        Assert.True(decision.Reuse, decision.Detail);

        // The record is persisted in state.json and survives a restart.
        var reopened = LauncherWorkspace.Open(temp.Path);
        Assert.NotNull(reopened.Find(TitleID)!.Build);
    }

    [Fact]
    public async Task ImportOfAnotherToolchainDoesNotFakeReuse()
    {
        using var temp = new TempDir();
        var (workspace, cli) = CreateImportService(temp);
        var service = new BuildPackageService(workspace, cli);
        var packageFile = BuildPackageFile(temp);

        var outcome = await service.ImportAsync(packageFile, replace: false, CurrentCompatibility(clang: "clang version 24.0.0"));

        Assert.True(outcome.Ok, outcome.Error);
        if (LauncherPlatform.IsLinux)
        {
            // Linux has no local AOT compiler: a real GamePack built with another
            // toolchain is the expected input and must stay deployable.
            Assert.Equal(BuildCacheImportStatus.Recorded, outcome.BuildCacheStatus);
            Assert.NotNull(workspace.Find(TitleID)!.Build);
        }
        else
        {
            Assert.Equal(BuildCacheImportStatus.Mismatch, outcome.BuildCacheStatus);
            Assert.Contains("toolchain", outcome.BuildCacheDetail, StringComparison.OrdinalIgnoreCase);
            Assert.Null(workspace.Find(TitleID)!.Build);
        }
    }

    [Fact]
    public async Task ImportOfPackageWithoutGameDataKeepsNoCacheRecord()
    {
        using var temp = new TempDir();
        var (workspace, cli) = CreateImportService(temp);
        var service = new BuildPackageService(workspace, cli);
        var packageFile = BuildPackageFile(temp, includeRom: false);

        var outcome = await service.ImportAsync(packageFile, replace: false, CurrentCompatibility());

        Assert.True(outcome.Ok, outcome.Error);
        Assert.Equal(BuildCacheImportStatus.NoGameData, outcome.BuildCacheStatus);
        Assert.Null(workspace.Find(TitleID)!.Build);
    }

    [Fact]
    public async Task ImportOfLegacyPackageWithoutManifestFallsBackSafely()
    {
        using var temp = new TempDir();
        var (workspace, cli) = CreateImportService(temp);
        var service = new BuildPackageService(workspace, cli);
        var packageFile = BuildPackageFile(temp, includeManifest: false);

        var outcome = await service.ImportAsync(packageFile, replace: false, CurrentCompatibility());

        Assert.True(outcome.Ok, outcome.Error);
        Assert.Equal(BuildCacheImportStatus.Missing, outcome.BuildCacheStatus);
        Assert.Null(workspace.Find(TitleID)!.Build);
    }
}
