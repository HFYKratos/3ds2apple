using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// One Library "Import" picker now accepts decrypted ROMs and .32a build packages;
/// the classifier is the tested dispatch layer (ROM import vs build-package import).
/// </summary>
public sealed class LibraryImportPlannerTests
{
    [Fact]
    public void SplitsRomsAndBuildPackagesAndReportsRejectedFiles()
    {
        using var temp = new TempDir();
        var rom1 = temp.Bytes("Example Game.cci", new byte[] { 1 });
        var rom2 = temp.Bytes("Second Example.3DS", new byte[] { 2 });
        var package = temp.Bytes("example-game-00055e00.32a", new byte[] { 3 });
        var text = temp.Bytes("notes.txt", new byte[] { 4 });
        var missing = Path.Combine(temp.Path, "gone.cci");

        var selection = LibraryImportPlanner.Classify(new[] { rom1, package, rom2, text, missing, rom1 });

        Assert.Equal(new[] { rom1, rom2 }, selection.RomPaths);
        Assert.Equal(new[] { package }, selection.BuildPackagePaths);
        Assert.Equal(2, selection.Errors.Count);
        Assert.Contains(selection.Errors, error => error.Contains("Unsupported file", StringComparison.Ordinal));
        Assert.Contains(selection.Errors, error => error.Contains("File not found", StringComparison.Ordinal));
        Assert.True(selection.HasWork);
        Assert.Contains("2 ROM(s), 1 build package(s), 2 rejected", LibraryImportPlanner.Describe(selection));
    }

    [Fact]
    public void EmptyOrUnsupportedSelectionHasNoWork()
    {
        using var temp = new TempDir();
        var text = temp.Bytes("save.dat", new byte[] { 1 });

        Assert.False(LibraryImportPlanner.Classify(Array.Empty<string>()).HasWork);
        var selection = LibraryImportPlanner.Classify(new[] { text });
        Assert.False(selection.HasWork);
        Assert.Single(selection.Errors);
    }

    [Fact]
    public void ExtensionsAreCaseInsensitiveAndPathsAreTrimmed()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("Example Game.CCI", new byte[] { 1 });
        var package = temp.Bytes("Example.32A", new byte[] { 2 });

        var selection = LibraryImportPlanner.Classify(new[] { " " + rom + " ", package });

        Assert.Equal(new[] { rom }, selection.RomPaths);
        Assert.Equal(new[] { package }, selection.BuildPackagePaths);
        Assert.Empty(selection.Errors);
        Assert.True(LibraryImportPlanner.IsRom(rom));
        Assert.True(LibraryImportPlanner.IsBuildPackage(package));
        Assert.False(LibraryImportPlanner.IsRom(package));
    }
}

/// <summary>
/// Capability gate for the bundled 3ds2apple-pack CLI: the 0.2.2-beta2 package
/// contained a 0.2.0 CLI without builds / catalog --auto-launch, so both exports
/// were rejected by clap. The launcher must refuse such a binary with an
/// actionable rebuild hint, and the self-test probes it statically.
/// </summary>
public sealed class PackCliCapabilityTests
{
    private static string CurrentBinary(TempDir temp) =>
        temp.Bytes("current-pack.exe", System.Text.Encoding.ASCII.GetBytes(
            "3ds2apple-pack 0.2.2\nCommands: rom packages build catalog pack builds\n--auto-launch"));

    private static string StaleBinary(TempDir temp) =>
        temp.Bytes("stale-pack.exe", System.Text.Encoding.ASCII.GetBytes("3ds2apple-pack 0.2.0\nCommands: rom packages build catalog pack"));

    [Fact]
    public void StaticScanDistinguishesCurrentAndStaleCli()
    {
        using var temp = new TempDir();
        var current = PackCli.InspectBinaryCapabilities(CurrentBinary(temp));
        Assert.True(current.Ok, current.Describe());
        Assert.True(current.HasBuildsCommand);
        Assert.True(current.HasCatalogAutoLaunch);

        var stale = PackCli.InspectBinaryCapabilities(StaleBinary(temp));
        Assert.False(stale.Ok);
        Assert.Contains("out of date", stale.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Null(PackCli.CapabilityError(CurrentBinary(temp)));
        Assert.NotNull(PackCli.CapabilityError(StaleBinary(temp)));

        var missing = PackCli.InspectBinaryCapabilities(Path.Combine(temp.Path, "missing.exe"));
        Assert.False(missing.Ok);
        Assert.Contains("does not exist", missing.Error, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ExportRefusesAStaleCliBeforeRunningIt()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(Path.Combine(temp.Path, "workspace"));
        var runner = new FakeProcessRunner(_ => throw new InvalidOperationException("a stale CLI must not be executed"));
        var packCli = new PackCli(runner, StaleBinary(temp), Path.Combine(temp.Path, "out"));
        var service = new BuildPackageService(workspace, packCli);

        var outcome = await service.ExportAsync(new[] { "0004000000055E00" }, compatibility: null);

        Assert.False(outcome.Ok);
        Assert.Contains("out of date", outcome.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(runner.Requests);
    }

    [Fact]
    public void ActionableFailureMapsClapRejectionToARebuildHint()
    {
        var clap = new ProcessResult(2, string.Empty,
            "error: unexpected argument 'builds' found\n\nUsage: 3ds2apple-pack [OPTIONS] <COMMAND>\n\nFor more information, try '--help'.",
            false, true);
        var message = PackCli.ActionableFailure(clap);
        Assert.Contains("out of date", message, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("THREEDS2APPLE_PACK", message, StringComparison.Ordinal);

        var plain = new ProcessResult(1, string.Empty, "error: the ROM is not decrypted", false, true);
        Assert.Equal("error: the ROM is not decrypted", PackCli.ActionableFailure(plain));
    }
}
