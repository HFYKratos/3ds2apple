using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.Platform;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>0.2.3 P0: the shared Avalonia launcher must name tools per host OS.</summary>
public sealed class PlatformAbstractionTests
{
    [Fact]
    public void PlatformTagAndSuffixMatchTheHost()
    {
        Assert.Contains(LauncherPlatform.PlatformTag, new[] { "windows", "linux", "macos" });
        if (LauncherPlatform.IsWindows)
        {
            Assert.Equal(".exe", LauncherPlatform.ExecutableSuffix);
            Assert.Equal("3ds2apple-pack.exe", LauncherPlatform.PackCliFileName);
            Assert.Equal("devpush.exe", LauncherPlatform.DevPushFileName);
            Assert.Equal("plumesign-windows-x86_64.exe", LauncherPlatform.PlumeSignFileName);
        }
        else
        {
            Assert.Equal(string.Empty, LauncherPlatform.ExecutableSuffix);
            Assert.Equal("3ds2apple-pack", LauncherPlatform.PackCliFileName);
            Assert.Equal("devpush", LauncherPlatform.DevPushFileName);
            Assert.Equal("plumesign-linux-x86_64", LauncherPlatform.PlumeSignFileName);
        }
        Assert.Equal(LauncherPlatform.PackCliFileName, LauncherPlatform.WithExecutableSuffix(LauncherPlatform.PackCliFileName));
        Assert.Contains(LauncherPlatform.PlatformTag, new[] { "windows", "linux", "macos" });
    }

    [Fact]
    public void ToolLocatorFindsTheHostNamedPackCli()
    {
        using var temp = new TempDir();
        var bin = Path.Combine(temp.Path, "Bin");
        Directory.CreateDirectory(bin);
        var tool = Path.Combine(bin, LauncherPlatform.PackCliFileName);
        File.WriteAllText(tool, "stub");

        var locator = new ToolLocator(temp.Path);

        Assert.Equal(tool, locator.FindPackCli());
    }

    [Fact]
    public void LinuxPayloadPathsAreSafeAndContainTheSigningCli()
    {
        var expected = DistributionLayout.LinuxExpectedRelativePaths;
        Assert.Equal(expected.Count, expected.Distinct(StringComparer.Ordinal).Count());
        Assert.All(expected, path => Assert.True(DistributionLayout.IsSafeRelativePath(path), "unsafe Linux payload path: " + path));
        Assert.Contains("ThirdParty/Impactor/plumesign-linux-x86_64", expected);
        Assert.Contains("Bin/3ds2apple-pack", expected);
    }

    [Fact]
    public void LinuxPackCliMarksADistributionRoot()
    {
        using var temp = new TempDir();
        var bin = Path.Combine(temp.Path, "Bin");
        Directory.CreateDirectory(bin);
        File.WriteAllText(Path.Combine(bin, "3ds2apple-pack"), "stub");
        Assert.True(DistributionLayout.IsDistributionRoot(temp.Path));
    }
}
