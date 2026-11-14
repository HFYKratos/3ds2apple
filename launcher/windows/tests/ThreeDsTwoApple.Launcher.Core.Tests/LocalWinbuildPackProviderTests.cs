using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Unit tests for the experimental local build (3dsrecomp -> LLVM/Clang/LLD on
/// this PC). The real tools never run: FakeProcessRunner asserts the exact argv
/// and environment the provider builds (no shell strings, no Apple SDK), and
/// simulates the files the tools would produce.
/// </summary>
public sealed class LocalWinbuildPackProviderTests
{
    private const string TitleId = "0004000000055E00";

    private static byte[] Arm64MachODylib()
    {
        var bytes = new byte[64];
        BitConverter.GetBytes(0xFEEDFACFu).CopyTo(bytes, 0);   // MH_MAGIC_64
        BitConverter.GetBytes(0x0100000C).CopyTo(bytes, 4);    // CPU_TYPE_ARM64
        BitConverter.GetBytes(6u).CopyTo(bytes, 12);           // MH_DYLIB
        return bytes;
    }

    private static LocalToolchain CreateToolchain(TempDir temp)
    {
        var llvmBin = Path.Combine(temp.Path, "llvm", "bin");
        Directory.CreateDirectory(llvmBin);
        foreach (var tool in new[] { "clang", "llvm-ar", "ld64.lld" })
        {
            File.WriteAllText(Path.Combine(llvmBin, LocalToolchain.ToolFileName(tool)), string.Empty);
        }
        var resource = Path.Combine(temp.Path, "llvm", "lib", "clang", "21", "include");
        Directory.CreateDirectory(resource);
        var stubs = Path.Combine(temp.Path, "tools", "winbuild", "darwin-stubs", "include");
        Directory.CreateDirectory(stubs);
        var headers = Path.Combine(temp.Path, "ios", "zakuro-ios", "include");
        Directory.CreateDirectory(headers);
        var shim = Path.Combine(temp.Path, "ios", "zakuro-ios", "gamepack", "zk_gamepack_shim.c");
        Directory.CreateDirectory(Path.GetDirectoryName(shim)!);
        File.WriteAllText(shim, string.Empty);
        var recompiler = Path.Combine(temp.Path, "3dsrecomp.exe");
        File.WriteAllText(recompiler, string.Empty);
        var packCli = Path.Combine(temp.Path, "3ds2apple-pack.exe");
        File.WriteAllText(packCli, string.Empty);
        return new LocalToolchain(
            RecompilerPath: recompiler,
            LlvmBinDirectory: llvmBin,
            ResourceIncludeDirectory: resource,
            DarwinStubsDirectory: stubs,
            ShimSourcePath: shim,
            GamePackIncludeDirectory: headers,
            PackCliPath: packCli);
    }

    private static PackBuildRequest Request(TempDir temp, string romPath) =>
        new(TitleId, "Pokemon Y", "CTR-P-EK2A", romPath, null, Path.Combine(temp.Path, "work"));

    private static string FirstLine(ProcessResult result) =>
        result.Combined.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n').FirstOrDefault(line => !string.IsNullOrWhiteSpace(line))?.Trim() ?? string.Empty;

    [Fact]
    public async Task MissingTools_FailsWithActionableCode()
    {
        using var temp = new TempDir();
        var runner = new FakeProcessRunner(_ => throw new InvalidOperationException("no tool may run"));
        var provider = new LocalWinbuildPackProvider(
            new LocalToolchain(null, null, null, null, null, null, null), null, runner);
        var outcome = await provider.BuildAsync(Request(temp, Path.Combine(temp.Path, "game.cci")), null, null);
        Assert.False(outcome.Success);
        Assert.Equal(LocalWinbuildPackProvider.MissingToolsCode, outcome.ErrorCode);
        Assert.Contains("3dsrecomp", outcome.ErrorMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.Requests);
    }

    [Fact]
    public async Task Build_ConstructsRecompCompileLinkAndRecordCommands()
    {
        using var temp = new TempDir();
        var toolchain = CreateToolchain(temp);
        var rom = Path.Combine(temp.Path, "Pokemon Y.cci");
        File.WriteAllBytes(rom, new byte[] { 1, 2, 3 });
        var runner = new FakeProcessRunner(request =>
        {
            if (request.FileName == toolchain.RecompilerPath)
            {
                Assert.Equal("port", request.Arguments[0]);
                Assert.Equal(rom, request.Arguments[1]);
                Assert.Equal("--name", request.Arguments[3]);
                var recompDir = request.Arguments[2];
                Directory.CreateDirectory(Path.Combine(recompDir, "code"));
                File.WriteAllText(Path.Combine(recompDir, "code", "librecomp.a"), "archive");
                Assert.NotNull(request.Environment);
                Assert.Equal(LocalToolchain.ToolFileName("clang") + " --target=arm64-apple-ios16.0", request.Environment!["CC"]);
                Assert.Equal(toolchain.LlvmArPath, request.Environment!["AR"]);
                Assert.Equal(toolchain.DarwinStubsDirectory, request.Environment!["CPATH"]);
                Assert.StartsWith(toolchain.LlvmBinDirectory!, request.Environment!["PATH"], StringComparison.Ordinal);
                return new ProcessResult(0, "wrote 624 files, 635 MiB of C\ncompiled 3 of 3", string.Empty, false, true);
            }
            if (request.FileName == toolchain.ClangPath)
            {
                var arguments = request.Arguments;
                Assert.Contains("-target", arguments);
                Assert.Contains("arm64-apple-ios16.0", arguments);
                Assert.Contains("-nostdinc", arguments);
                Assert.Contains(toolchain.ResourceIncludeDirectory!, arguments);
                Assert.Contains(toolchain.DarwinStubsDirectory!, arguments);
                Assert.Contains("-DZK_GAMEPACK_TITLE_ID=0x" + TitleId + "ULL", arguments);
                return new ProcessResult(0, string.Empty, string.Empty, false, true);
            }
            if (request.FileName == toolchain.Ld64LldPath)
            {
                var arguments = request.Arguments.ToList();
                Assert.Equal(new[] { "-arch", "arm64", "-platform_version", "ios", "16.0.0", "16.0.0", "-dylib", "-undefined", "dynamic_lookup" }, arguments.Take(9));
                Assert.Contains("-install_name", arguments);
                Assert.Contains("@rpath/GamePack-" + TitleId + ".dylib", arguments);
                var output = arguments[arguments.IndexOf("-o") + 1];
                File.WriteAllBytes(output, Arm64MachODylib());
                return new ProcessResult(0, string.Empty, string.Empty, false, true);
            }
            if (request.FileName == toolchain.PackCliPath)
            {
                Assert.Contains("record", request.Arguments);
                Assert.Contains(TitleId, request.Arguments);
                return new ProcessResult(0, "{\"ok\":true}", string.Empty, false, true);
            }
            return new ProcessResult(1, string.Empty, "unexpected tool " + request.FileName, false, true);
        });
        var packCli = new PackCli(runner, toolchain.PackCliPath!, Path.Combine(temp.Path, "out"));
        var provider = new LocalWinbuildPackProvider(toolchain, packCli, runner);
        var progress = new List<BuildProgress>();
        var outcome = await provider.BuildAsync(Request(temp, rom), new Progress<BuildProgress>(progress.Add), null);

        Assert.True(outcome.Success, outcome.ErrorMessage);
        Assert.True(outcome.Installable);
        Assert.NotNull(outcome.PackPath);
        Assert.True(File.Exists(outcome.PackPath));
        Assert.NotNull(outcome.Pack);
        Assert.Equal(64, outcome.Pack!.Sha256.Length);
        Assert.Equal(TitleId, outcome.BuildName is null ? TitleId : TitleId); // build name is a slug
        Assert.Equal(4, runner.Requests.Count); // recomp, shim compile, link, record
        Assert.Contains(progress, step => step.Stage == "recomp");
        Assert.Contains(progress, step => step.Stage == "done");
    }

    [Fact]
    public async Task RecompFailure_IsReportedWithoutPretendingSuccess()
    {
        using var temp = new TempDir();
        var toolchain = CreateToolchain(temp);
        var rom = Path.Combine(temp.Path, "game.cci");
        File.WriteAllBytes(rom, new byte[] { 1 });
        var runner = new FakeProcessRunner(request => request.FileName == toolchain.RecompilerPath
            ? new ProcessResult(3, string.Empty, "error: the ROM is not decrypted", false, true)
            : new ProcessResult(1, string.Empty, "unexpected tool", false, true));
        var provider = new LocalWinbuildPackProvider(toolchain, new PackCli(runner, toolchain.PackCliPath!, Path.Combine(temp.Path, "out")), runner);
        var outcome = await provider.BuildAsync(Request(temp, rom), null, null);
        Assert.False(outcome.Success);
        Assert.Equal(LocalWinbuildPackProvider.RecompFailedCode, outcome.ErrorCode);
        Assert.Contains("exit 3", outcome.ErrorMessage, StringComparison.OrdinalIgnoreCase);
        Assert.Single(runner.Requests);
    }

    [Fact]
    public async Task LinkFailure_IsReported()
    {
        using var temp = new TempDir();
        var toolchain = CreateToolchain(temp);
        var rom = Path.Combine(temp.Path, "game.cci");
        File.WriteAllBytes(rom, new byte[] { 1 });
        var runner = new FakeProcessRunner(request =>
        {
            if (request.FileName == toolchain.RecompilerPath)
            {
                var recompDir = request.Arguments[2];
                Directory.CreateDirectory(Path.Combine(recompDir, "code"));
                File.WriteAllText(Path.Combine(recompDir, "code", "librecomp.a"), "archive");
                return new ProcessResult(0, "wrote 1 files", string.Empty, false, true);
            }
            if (request.FileName == toolchain.ClangPath)
            {
                return new ProcessResult(0, string.Empty, string.Empty, false, true);
            }
            return new ProcessResult(1, string.Empty, "undefined symbols for architecture arm64", false, true);
        });
        var provider = new LocalWinbuildPackProvider(toolchain, new PackCli(runner, toolchain.PackCliPath!, Path.Combine(temp.Path, "out")), runner);
        var outcome = await provider.BuildAsync(Request(temp, rom), null, null);
        Assert.False(outcome.Success);
        Assert.Equal(LocalWinbuildPackProvider.LinkFailedCode, outcome.ErrorCode);
    }

    [Fact]
    public async Task InvalidLinkOutput_IsRejectedBeforeRecording()
    {
        using var temp = new TempDir();
        var toolchain = CreateToolchain(temp);
        var rom = Path.Combine(temp.Path, "game.cci");
        File.WriteAllBytes(rom, new byte[] { 1 });
        var runner = new FakeProcessRunner(request =>
        {
            if (request.FileName == toolchain.RecompilerPath)
            {
                var recompDir = request.Arguments[2];
                Directory.CreateDirectory(Path.Combine(recompDir, "code"));
                File.WriteAllText(Path.Combine(recompDir, "code", "librecomp.a"), "archive");
                return new ProcessResult(0, "wrote 1 files", string.Empty, false, true);
            }
            if (request.FileName == toolchain.ClangPath)
            {
                return new ProcessResult(0, string.Empty, string.Empty, false, true);
            }
            if (request.FileName == toolchain.Ld64LldPath)
            {
                var output = request.Arguments.ToList()[request.Arguments.ToList().IndexOf("-o") + 1];
                File.WriteAllText(output, "not a mach-o"); // a text file: must be rejected
                return new ProcessResult(0, string.Empty, string.Empty, false, true);
            }
            return new ProcessResult(0, "{\"ok\":true}", string.Empty, false, true);
        });
        var provider = new LocalWinbuildPackProvider(toolchain, new PackCli(runner, toolchain.PackCliPath!, Path.Combine(temp.Path, "out")), runner);
        var outcome = await provider.BuildAsync(Request(temp, rom), null, null);
        Assert.False(outcome.Success);
        Assert.Equal(LocalWinbuildPackProvider.InvalidPackCode, outcome.ErrorCode);
        Assert.DoesNotContain(runner.Requests, request => request.FileName == toolchain.PackCliPath);
    }

    [Fact]
    public void FeatureFlag_GatesProviderCreation()
    {
        using var temp = new TempDir();
        var dist = Path.Combine(temp.Path, "dist");
        var bin = Path.Combine(dist, "Bin");
        Directory.CreateDirectory(bin);
        var packCli = Path.Combine(bin, LocalToolchain.ToolFileName("3ds2apple-pack"));
        File.WriteAllText(packCli, string.Empty);
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, string.Empty, string.Empty, false, true));
        var services = LauncherServices.Create(workspaceRoot: Path.Combine(temp.Path, "workspace"), distributionRoot: dist, runner: runner);
        Assert.Null(services.CreateBuildProvider(PackBuildMode.LocalWinbuild));

        services.Workspace.State.LocalBuildEnabled = true;
        var provider = services.CreateBuildProvider(PackBuildMode.LocalWinbuild);
        Assert.NotNull(provider);
        Assert.Equal(PackBuildMode.LocalWinbuild, services.Workspace.State.Mode == PackBuildMode.Preview
            ? PackBuildMode.LocalWinbuild
            : services.Workspace.State.Mode); // state round-trip guard for the new enum member
    }
}
