using ThreeDsTwoApple.Launcher.Core.Portable;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>Portable data root policy: beside the exe when writable, LocalAppData fallback, migration.</summary>
public sealed class PortableLayoutTests
{
    [Fact]
    public void PortableDataRootSitsBesideTheExecutable()
    {
        using var temporary = new TempDir();
        var exeDirectory = Path.Combine(temporary.Path, "launcher-folder");
        var decision = PortableLayout.Resolve(
            exeDirectory: exeDirectory,
            localAppDataRoot: Path.Combine(temporary.Path, "localappdata"),
            isWritable: _ => true);

        Assert.Equal(DataRootKind.Portable, decision.Kind);
        Assert.Equal(Path.Combine(exeDirectory, "3ds2apple-data"), decision.DataRoot);
        Assert.Equal(Path.Combine(exeDirectory, "3ds2apple-data", "workspace"), decision.WorkspaceRoot);
        Assert.Equal(Path.Combine(exeDirectory, "3ds2apple-data", "distribution"), decision.DistributionBase);
        Assert.True(decision.IsPortable);
    }

    [Fact]
    public void ReadOnlyLauncherFolderFallsBackToLocalAppData()
    {
        using var temporary = new TempDir();
        var localAppData = Path.Combine(temporary.Path, "localappdata");
        var decision = PortableLayout.Resolve(
            exeDirectory: Path.Combine(temporary.Path, "read-only"),
            localAppDataRoot: localAppData,
            isWritable: path => path.StartsWith(localAppData, StringComparison.OrdinalIgnoreCase));

        Assert.Equal(DataRootKind.LocalAppData, decision.Kind);
        Assert.Equal(Path.Combine(localAppData, "3ds2apple", "launcher"), decision.WorkspaceRoot);
        Assert.Equal(Path.Combine(localAppData, "3ds2apple", "distribution"), decision.DistributionBase);
        Assert.False(decision.IsPortable);
    }

    [Fact]
    public void ExplicitOverrideWins()
    {
        using var temporary = new TempDir();
        var custom = Path.Combine(temporary.Path, "custom-data");
        var decision = PortableLayout.Resolve(
            exeDirectory: Path.Combine(temporary.Path, "exe"),
            localAppDataRoot: Path.Combine(temporary.Path, "localappdata"),
            isWritable: _ => true,
            dataRootOverride: custom);

        Assert.Equal(DataRootKind.Explicit, decision.Kind);
        Assert.Equal(Path.Combine(custom, "workspace"), decision.WorkspaceRoot);
        Assert.Equal(Path.Combine(custom, "distribution"), decision.DistributionBase);
    }

    [Fact]
    public void NothingWritableUsesTemporaryFallback()
    {
        using var temporary = new TempDir();
        var decision = PortableLayout.Resolve(
            exeDirectory: Path.Combine(temporary.Path, "exe"),
            localAppDataRoot: Path.Combine(temporary.Path, "localappdata"),
            isWritable: _ => false);

        Assert.Equal(DataRootKind.TempFallback, decision.Kind);
        Assert.Contains("launcher-data", decision.WorkspaceRoot);
    }

    [Fact]
    public void ProbeWritableReportsWritableAndMissingFolders()
    {
        using var temporary = new TempDir();
        var directory = Path.Combine(temporary.Path, "new-folder");
        Assert.True(PortableLayout.ProbeWritable(directory));
        Assert.True(Directory.Exists(directory));
        if (!OperatingSystem.IsWindows())
        {
            var file = Path.Combine(temporary.Path, "a-file");
            File.WriteAllText(file, "x");
            Assert.False(PortableLayout.ProbeWritable(Path.Combine(file, "child")));
        }
    }

    [Fact]
    public void MigrationCopiesStatePackagesAndKeepsLegacy()
    {
        using var temporary = new TempDir();
        var legacy = Path.Combine(temporary.Path, "legacy");
        Directory.CreateDirectory(Path.Combine(legacy, "out", "packages", "0004000000AAAA00"));
        Directory.CreateDirectory(Path.Combine(legacy, "work"));
        File.WriteAllText(Path.Combine(legacy, "state.json"), "{\"schemaVersion\":1,\"games\":[]}");
        File.WriteAllText(Path.Combine(legacy, "out", "packages", "0004000000AAAA00", "GameInfo.json"), "{}");
        File.WriteAllBytes(Path.Combine(legacy, "out", "packages", "0004000000AAAA00", "GamePack.dylib"), new byte[] { 1, 2, 3 });
        File.WriteAllText(Path.Combine(legacy, "work", "junk.bin"), "regenerable");

        var portable = Path.Combine(temporary.Path, "portable");
        var result = PortableLayout.MigrateLegacyWorkspace(portable, legacy);

        Assert.True(result.Migrated);
        Assert.True(result.StateCopied);
        Assert.True(File.Exists(Path.Combine(portable, "state.json")));
        Assert.True(File.Exists(Path.Combine(portable, "out", "packages", "0004000000AAAA00", "GameInfo.json")));
        Assert.True(File.Exists(Path.Combine(portable, "out", "packages", "0004000000AAAA00", "GamePack.dylib")));
        Assert.False(File.Exists(Path.Combine(portable, "work", "junk.bin")));
        Assert.True(File.Exists(result.MarkerPath));
        // The old workspace is never deleted, so a failed migration cannot lose the library.
        Assert.True(File.Exists(Path.Combine(legacy, "state.json")));
        Assert.True(File.Exists(Path.Combine(legacy, "out", "packages", "0004000000AAAA00", "GamePack.dylib")));
    }

    [Fact]
    public void MigrationIsSkippedWhenTheNewWorkspaceAlreadyHasState()
    {
        using var temporary = new TempDir();
        var legacy = Path.Combine(temporary.Path, "legacy");
        var portable = Path.Combine(temporary.Path, "portable");
        Directory.CreateDirectory(legacy);
        Directory.CreateDirectory(portable);
        File.WriteAllText(Path.Combine(legacy, "state.json"), "{}");
        File.WriteAllText(Path.Combine(portable, "state.json"), "{}");

        var result = PortableLayout.MigrateIfNeeded(portable, legacy);

        Assert.False(result.Attempted);
    }

    [Fact]
    public void FailedStateCopyKeepsTheLegacyWorkspaceUsable()
    {
        using var temporary = new TempDir();
        var legacy = Path.Combine(temporary.Path, "legacy");
        var portable = Path.Combine(temporary.Path, "portable");
        Directory.CreateDirectory(legacy);
        File.WriteAllText(Path.Combine(legacy, "state.json"), "{}");

        var result = PortableLayout.MigrateLegacyWorkspace(portable, legacy, copyFile: (_, _) => throw new IOException("disk full"));

        Assert.True(result.Attempted);
        Assert.False(result.StateCopied);
        Assert.Contains("disk full", result.Warning);
        Assert.True(File.Exists(Path.Combine(legacy, "state.json")));
    }

    [Fact]
    public void MigrateIfNeededDoesNothingWithoutALegacyWorkspace()
    {
        using var temporary = new TempDir();
        var result = PortableLayout.MigrateIfNeeded(Path.Combine(temporary.Path, "portable"), Path.Combine(temporary.Path, "legacy"));
        Assert.False(result.Attempted);
        Assert.Null(result.Warning);
    }
}
