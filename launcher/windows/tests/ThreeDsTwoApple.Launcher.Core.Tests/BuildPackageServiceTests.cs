using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
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

        var packageFile = temp.Bytes("example-game-00055e00.32a", new byte[] { 1, 2, 3 });
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

        var packageFile = temp.Bytes("example-game-00055e00.32a", new byte[] { 1, 2, 3 });
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

        var packageFile = temp.Bytes("example-game-00055e00.32a", new byte[] { 1, 2, 3 });
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
}
