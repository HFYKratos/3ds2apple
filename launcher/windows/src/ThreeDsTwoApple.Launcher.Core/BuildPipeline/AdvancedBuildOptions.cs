namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Deploy -> "Advanced settings": AOT codegen options applied to the NEXT build.
/// Defaults keep the 0.2.1 behaviour exactly (-O2, no LTO, no fast-math); the
/// values are persisted in the portable state.json and are part of the build
/// cache key, so changing one option forces the affected GamePacks to rebuild.
/// </summary>
public sealed record AdvancedBuildOptions(string OptLevel = "O2", bool Lto = false, bool FastMath = false)
{
    /// <summary>Optimization levels the AOT toolchain accepts (scripts/codegen flags).</summary>
    public static readonly IReadOnlyList<string> OptLevels = new[] { "O1", "O2", "O3", "Oz" };

    public static AdvancedBuildOptions Default { get; } = new();

    public bool IsDefault => OptLevel == "O2" && !Lto && !FastMath;

    /// <summary>Swap an unsupported level back to O2 instead of failing the build.</summary>
    public AdvancedBuildOptions Normalized() =>
        OptLevels.Contains(OptLevel) ? this : this with { OptLevel = "O2" };

    /// <summary>True only for one of O1/O2/O3/Oz.</summary>
    public bool Validate() => OptLevels.Contains(OptLevel);

    /// <summary>Canonical short marker used in the build-cache key (buildCompatVersion).</summary>
    public string CacheMarker =>
        "opt=" + OptLevel + ";lto=" + (Lto ? "1" : "0") + ";fastmath=" + (FastMath ? "1" : "0");

    /// <summary>
    /// Flags appended AFTER the fixed 3dsrecomp flags (-O2 ... ) by the compiler
    /// wrapper; empty for the defaults so the default build command is unchanged.
    /// </summary>
    public string CompilerArgumentSuffix()
    {
        var flags = new List<string>();
        if (OptLevel != "O2")
        {
            flags.Add("-" + OptLevel);
        }
        if (Lto)
        {
            flags.Add("-flto");
        }
        if (FastMath)
        {
            flags.Add("-ffast-math");
        }
        return string.Join(" ", flags);
    }

    /// <summary>Human one-line summary for the Deploy page.</summary>
    public string Describe() =>
        "opt=" + OptLevel + ", lto=" + (Lto ? "on" : "off") + ", fast-math=" + (FastMath ? "on" : "off");
}
