using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Deploy -> "Advanced settings": AOT codegen options are persisted, included in
/// the build-cache key, and turn into a compiler wrapper on the local build. The
/// defaults must keep the 0.2.1 behaviour and its build command unchanged.
/// </summary>
public sealed class AdvancedBuildSettingsTests
{
    [Fact]
    public void DefaultsKeepTheDocumentedBehaviour()
    {
        var options = AdvancedBuildOptions.Default;
        Assert.Equal("O2", options.OptLevel);
        Assert.False(options.Lto);
        Assert.False(options.FastMath);
        Assert.True(options.IsDefault);
        Assert.True(options.Validate());
        Assert.Equal("opt=O2;lto=0;fastmath=0", options.CacheMarker);
        Assert.Equal(string.Empty, options.CompilerArgumentSuffix());
    }

    [Fact]
    public void CustomOptionsValidateAndDescribeThemselves()
    {
        var options = new AdvancedBuildOptions("O3", Lto: true, FastMath: true);
        Assert.True(options.Validate());
        Assert.False(options.IsDefault);
        Assert.Equal("opt=O3;lto=1;fastmath=1", options.CacheMarker);
        Assert.Equal("-O3 -flto -ffast-math", options.CompilerArgumentSuffix());
        Assert.Contains("O3", options.Describe());

        var invalid = new AdvancedBuildOptions("O9");
        Assert.False(invalid.Validate());
        Assert.Equal("O2", invalid.Normalized().OptLevel);
        Assert.Equal("O2", new AdvancedBuildOptions("nonsense").Normalized().OptLevel);
    }

    [Fact]
    public void BuildCompatibilityMarkerIncludesTheOptions()
    {
        var defaults = BuildCompatibility.Create("rev", "23.1.6", "23.1.6", AdvancedBuildOptions.Default.CacheMarker);
        var custom = BuildCompatibility.Create("rev", "23.1.6", "23.1.6", new AdvancedBuildOptions("O3", true, false).CacheMarker);
        Assert.Contains("opts=opt=O2;lto=0;fastmath=0", defaults.BuildCompatVersion, StringComparison.Ordinal);
        Assert.Contains("opts=opt=O3;lto=1;fastmath=0", custom.BuildCompatVersion, StringComparison.Ordinal);
        Assert.NotEqual(defaults.BuildCompatVersion, custom.BuildCompatVersion);
        Assert.NotEqual(defaults.ShortVersion, custom.ShortVersion);

        var artifact = new BuildArtifact
        {
            BuildCompatVersion = defaults.BuildCompatVersion,
            BuildCompatShort = defaults.ShortVersion,
            RomSha256 = new string('a', 64),
            PackSha256 = new string('b', 64),
            PackBytes = 10,
        };
        var reuse = BuildCachePolicy.Evaluate(artifact, defaults.BuildCompatVersion, artifact.RomSha256, "pack", _ => true);
        Assert.True(reuse.Reuse);
        var rebuild = BuildCachePolicy.Evaluate(artifact, custom.BuildCompatVersion, artifact.RomSha256, "pack", _ => true);
        Assert.False(rebuild.Reuse);
        Assert.Equal(BuildReuseStatus.BuildMethodChanged, rebuild.Status);
        Assert.Contains("recipe changed", rebuild.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void WorkspacePersistsAndNormalizesTheOptions()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        Assert.Equal(AdvancedBuildOptions.Default, workspace.BuildOptions);

        workspace.SetBuildOptions(new AdvancedBuildOptions("O3", Lto: true, FastMath: true));
        Assert.Equal("O3", workspace.BuildOptions.OptLevel);
        Assert.True(workspace.BuildOptions.Lto);
        Assert.True(workspace.BuildOptions.FastMath);

        var reloaded = LauncherWorkspace.Open(temp.Path);
        Assert.Equal("O3", reloaded.BuildOptions.OptLevel);
        Assert.True(reloaded.BuildOptions.Lto);
        Assert.True(reloaded.BuildOptions.FastMath);

        reloaded.SetBuildOptions(new AdvancedBuildOptions("bogus"));
        Assert.Equal("O2", LauncherWorkspace.Open(temp.Path).BuildOptions.OptLevel);
    }

    [Fact]
    public void CompilerWrapperAppendsTheFlagsAfterTheFixedOnes()
    {
        using var temp = new TempDir();
        var llvmBin = Path.Combine(temp.Path, "llvm", "bin");
        Directory.CreateDirectory(llvmBin);
        var clang = Path.Combine(llvmBin, "clang");
        File.WriteAllText(clang, string.Empty);
        var tools = new LocalToolchain(null, llvmBin, null, null, null, null, null);
        var workDirectory = Path.Combine(temp.Path, "work");
        Directory.CreateDirectory(workDirectory);
        var root = Path.Combine(workDirectory, "local-build", "demo-00055e00");

        var cc = LocalWinbuildPackProvider.WriteCompilerWrapper(
            tools,
            new AdvancedBuildOptions("O3", Lto: true, FastMath: true),
            root,
            workDirectory);

        var wrapper = OperatingSystem.IsWindows()
            ? Path.Combine(workDirectory, "local-build", "demo-00055e00", "codegen", "clang-wrapper.cmd")
            : Path.Combine(root, "codegen", "clang-wrapper.sh");
        Assert.True(File.Exists(wrapper), wrapper);
        var content = File.ReadAllText(wrapper);
        Assert.Contains("-O3 -flto -ffast-math", content, StringComparison.Ordinal);
        Assert.Contains("--target=arm64-apple-ios16.0", content, StringComparison.Ordinal);
        Assert.Contains(clang, content, StringComparison.Ordinal);
        if (OperatingSystem.IsWindows())
        {
            Assert.StartsWith("cmd.exe /c local-build/demo-00055e00/codegen/clang-wrapper.cmd", cc, StringComparison.Ordinal);
        }
        else
        {
            Assert.Equal(wrapper, cc);
        }
    }
}
