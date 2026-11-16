using ThreeDsTwoApple.Launcher.Core.Hardware;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>Hardware detection/formatting for the Deploy compile line.</summary>
public sealed class HardwareProfileTests
{
    [Fact]
    public void ParsesUniquePhysicalCoresFromProcCpuinfo()
    {
        const string cpuInfo = """
            processor	: 0
            physical id	: 0
            core id		: 0

            processor	: 1
            physical id	: 0
            core id		: 1

            processor	: 2
            physical id	: 0
            core id		: 0

            processor	: 3
            physical id	: 0
            core id		: 1
            """;

        Assert.Equal(2, HardwareProbe.ParsePhysicalCoresLinux(cpuInfo));
    }

    [Fact]
    public void FallsBackToLogicalCountWhenCoreIdsAreMissing()
    {
        const string cpuInfo = """
            processor	: 0
            model name	: Synthetic CPU

            processor	: 1
            model name	: Synthetic CPU
            """;

        Assert.Equal(2, HardwareProbe.ParsePhysicalCoresLinux(cpuInfo));
        Assert.Null(HardwareProbe.ParsePhysicalCoresLinux(string.Empty));
    }

    [Fact]
    public void ParsesMemoryTotalsAndAvailable()
    {
        const string memInfo = """
            MemTotal:       33554432 kB
            MemFree:         2097152 kB
            MemAvailable:    8388608 kB
            """;

        var memory = HardwareProbe.ParseMemoryLinux(memInfo);
        Assert.NotNull(memory);
        Assert.Equal(32UL * 1024 * 1024 * 1024, memory!.Value.Total);
        Assert.Equal(8UL * 1024 * 1024 * 1024, memory.Value.Available);
        Assert.Null(HardwareProbe.ParseMemoryLinux("no numbers here"));
    }

    [Fact]
    public void DescribeMentionsCoresMemoryAndAutoParallelism()
    {
        var profile = new HardwareProfile(16, 8, 34359738368UL, 17179869184UL);
        var line = profile.Describe();
        Assert.Contains("16 logical / 8 physical cores", line);
        Assert.Contains("32 GB RAM", line);
        Assert.Contains("16 GB free", line);
        Assert.Contains("3dsrecomp auto-parallelizes", line);
        Assert.Contains("16 jobs", line);
        Assert.Equal(16, profile.CompileJobs);
    }

    [Fact]
    public void GigabyteFormattingIsInvariant()
    {
        Assert.Equal("1.5", HardwareProfile.FormatGb(1610612736UL));
        Assert.Equal("0", HardwareProfile.FormatGb(0UL));
        Assert.Equal("32", HardwareProfile.FormatGb(34359738368UL));
    }

    [Fact]
    public void DetectionReturnsPlausibleValuesOnThisHost()
    {
        var profile = HardwareProbe.Detect();
        Assert.True(profile.LogicalCores >= 1);
        Assert.True(profile.PhysicalCores >= 1);
        Assert.True(profile.PhysicalCores <= profile.LogicalCores);
        Assert.True(profile.TotalMemoryBytes > 0);
        Assert.True(profile.AvailableMemoryBytes <= profile.TotalMemoryBytes);
    }
}
