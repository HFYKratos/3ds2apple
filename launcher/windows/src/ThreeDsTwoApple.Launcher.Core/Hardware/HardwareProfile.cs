using System.Globalization;
using System.Runtime.InteropServices;

namespace ThreeDsTwoApple.Launcher.Core.Hardware;

/// <summary>
/// What the compile step can use on this PC. 3dsrecomp has no jobs flag: it derives
/// its worker count from the logical CPU count (std::thread::available_parallelism)
/// and throttles clang invocations by the free-memory budget. The launcher therefore
/// only reports the hardware and does not invent a compile-jobs setting.
/// </summary>
public sealed record HardwareProfile(int LogicalCores, int PhysicalCores, ulong TotalMemoryBytes, ulong AvailableMemoryBytes)
{
    /// <summary>Workers 3dsrecomp will spawn for a foreground build (one per logical core).</summary>
    public int CompileJobs => Math.Max(1, LogicalCores);

    /// <summary>Total physical memory in GiB (one decimal, invariant).</summary>
    public string TotalMemoryGb => FormatGb(TotalMemoryBytes);

    /// <summary>Currently available physical memory in GiB (one decimal, invariant).</summary>
    public string AvailableMemoryGb => FormatGb(AvailableMemoryBytes);

    /// <summary>Compact English line used in self-test output and diagnostics.</summary>
    public string Describe() =>
        $"{LogicalCores} logical / {PhysicalCores} physical cores · {TotalMemoryGb} GB RAM ({AvailableMemoryGb} GB free) · 3dsrecomp auto-parallelizes ({CompileJobs} jobs, memory-budgeted)";

    /// <summary>Compact numbers for the localized Deploy line.</summary>
    public static string FormatGb(ulong bytes) => (bytes / 1073741824d).ToString("0.#", CultureInfo.InvariantCulture);
}

/// <summary>Windows/Unix probe for logical cores, physical cores and physical memory.</summary>
public static class HardwareProbe
{
    private static readonly Lazy<HardwareProfile> Detected = new(DetectCore, isThreadSafe: true);

    /// <summary>Detected once per process; never throws (falls back to managed values).</summary>
    public static HardwareProfile Current => Detected.Value;

    /// <summary>Detect now (tests use the parsing helpers below instead of the host values).</summary>
    public static HardwareProfile Detect() => DetectCore();

    /// <summary>Count unique (physical id, core id) pairs in /proc/cpuinfo; null when unknown.</summary>
    public static int? ParsePhysicalCoresLinux(string cpuInfo)
    {
        if (string.IsNullOrWhiteSpace(cpuInfo))
        {
            return null;
        }
        var logical = 0;
        var pairs = new HashSet<(string Package, string Core)>();
        string? package = null;
        string? core = null;
        foreach (var line in cpuInfo.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (line.StartsWith("processor", StringComparison.Ordinal))
            {
                logical++;
                package = null;
                core = null;
                continue;
            }
            var colon = line.IndexOf(':');
            if (colon < 0)
            {
                continue;
            }
            var key = line[..colon].Trim();
            var value = line[(colon + 1)..].Trim();
            switch (key)
            {
                case "physical id":
                    package = value;
                    break;
                case "core id":
                    core = value;
                    break;
            }
            if (package is not null && core is not null && logical > pairs.Count)
            {
                pairs.Add((package, core));
            }
        }
        return pairs.Count > 0 ? pairs.Count : logical > 0 ? logical : null;
    }

    /// <summary>Parse Linux /proc/meminfo into (total, available) bytes; null when unreadable.</summary>
    public static (ulong Total, ulong Available)? ParseMemoryLinux(string memInfo)
    {
        ulong? total = null;
        ulong? available = null;
        foreach (var line in memInfo.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            var parts = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2)
            {
                continue;
            }
            if (!ulong.TryParse(parts[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var kilobytes))
            {
                continue;
            }
            if (parts[0] == "MemTotal:")
            {
                total = kilobytes * 1024UL;
            }
            else if (parts[0] == "MemAvailable:")
            {
                available = kilobytes * 1024UL;
            }
        }
        return total is { } totalBytes ? (totalBytes, available ?? totalBytes) : null;
    }

    private static HardwareProfile DetectCore()
    {
        var logical = Math.Max(1, Environment.ProcessorCount);
        int? physical = null;
        ulong total = 0;
        ulong available = 0;
        try
        {
            if (OperatingSystem.IsWindows())
            {
                physical = DetectPhysicalCoresWindows();
                var memory = ReadWindowsMemory();
                if (memory is { } windowsMemory)
                {
                    (total, available) = windowsMemory;
                }
            }
            else if (OperatingSystem.IsLinux())
            {
                try
                {
                    physical = ParsePhysicalCoresLinux(File.ReadAllText("/proc/cpuinfo"));
                }
                catch (IOException)
                {
                    physical = null;
                }
                catch (UnauthorizedAccessException)
                {
                    physical = null;
                }
                try
                {
                    if (ParseMemoryLinux(File.ReadAllText("/proc/meminfo")) is { } linuxMemory)
                    {
                        (total, available) = linuxMemory;
                    }
                }
                catch (IOException)
                {
                    // fall through to the managed value
                }
                catch (UnauthorizedAccessException)
                {
                    // fall through to the managed value
                }
            }
        }
        catch (Exception)
        {
            physical = null;
        }

        if (total == 0)
        {
            var gcMemory = GC.GetGCMemoryInfo();
            total = (ulong)Math.Max(0, gcMemory.TotalAvailableMemoryBytes);
            available = total;
        }
        var physicalCores = physical is > 0 ? Math.Min(physical.Value, logical) : logical;
        return new HardwareProfile(logical, Math.Max(1, physicalCores), total, available);
    }

    private static (ulong Total, ulong Available)? ReadWindowsMemory()
    {
        try
        {
            var status = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
            if (GlobalMemoryStatusEx(ref status))
            {
                return (status.TotalPhys, status.AvailPhys);
            }
        }
        catch (Exception)
        {
            // fall back to the managed value
        }
        return null;
    }

    private static int? DetectPhysicalCoresWindows()
    {
        try
        {
            var length = 0;
            GetLogicalProcessorInformation(IntPtr.Zero, ref length);
            if (length <= 0)
            {
                return null;
            }
            var buffer = Marshal.AllocHGlobal(length);
            try
            {
                if (!GetLogicalProcessorInformation(buffer, ref length))
                {
                    return null;
                }
                var size = Marshal.SizeOf<ProcessorRelation>();
                if (size <= 0)
                {
                    return null;
                }
                var count = length / size;
                var cores = 0;
                for (var index = 0; index < count; index++)
                {
                    var relation = Marshal.PtrToStructure<ProcessorRelation>(buffer + index * size);
                    if (relation.Relationship == RelationProcessorCore)
                    {
                        cores++;
                    }
                }
                return cores > 0 ? cores : null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
        catch (Exception)
        {
            return null;
        }
    }

    private const int RelationProcessorCore = 0;

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessorRelation
    {
        public UIntPtr ProcessorMask;
        public int Relationship;
        public ulong Union0;
        public ulong Union1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhys;
        public ulong AvailPhys;
        public ulong TotalPageFile;
        public ulong AvailPageFile;
        public ulong TotalVirtual;
        public ulong AvailVirtual;
        public ulong AvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx status);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetLogicalProcessorInformation(IntPtr buffer, ref int returnedLength);
}
