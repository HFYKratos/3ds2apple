using System.Globalization;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>
/// The five things the Deploy page checks before it can install games. Every row gets a
/// green or red status light in the UI; the rules live here (not in the view) so they are
/// unit-tested without a phone, Windows or any bundled binary.
/// </summary>
public enum DeployPrerequisiteKind
{
    /// <summary>A phone is visible over USB (through usbmuxd or the devpush bridge).</summary>
    DeviceConnected = 0,

    /// <summary>The bundled Impactor/plumesign binaries exist and match the pinned SHA-256.</summary>
    SigningTools = 1,

    /// <summary>The local build toolchain (3dsrecomp + LLVM clang/LLVM lld) is resolved and present.</summary>
    LocalToolchain = 2,

    /// <summary>The devpush device bridge is executable and can enumerate devices.</summary>
    DeviceBridge = 3,

    /// <summary>The ROM-free shell template IPA + manifest exist, are pinned and pass validation.</summary>
    ShellTemplate = 4,
}

/// <summary>Probe results fed into the evaluator; pure data so every readiness rule is testable.</summary>
public sealed record DeployPrerequisiteInputs(
    bool SigningToolsPinned,
    string? SigningDetail,
    bool LocalToolchainResolved,
    IReadOnlyList<string> MissingLocalTools,
    string? LocalToolchainDetail,
    bool DeviceBridgeFound,
    bool DeviceBridgeEnumerates,
    string? DeviceBridgeVersion,
    IReadOnlyList<string> DeviceSummaries,
    bool ShellManifestPresent,
    bool ShellVerified,
    string? ShellDetail);

/// <summary>One evaluated prerequisite row; Detail is display data (never a credential or raw UDID).</summary>
public sealed record DeployPrerequisite(DeployPrerequisiteKind Kind, bool Ready, string Detail);

/// <summary>The five Deploy prerequisites in the order the Deploy page shows them.</summary>
public sealed record DeployPrerequisiteReport(IReadOnlyList<DeployPrerequisite> Prerequisites)
{
    public bool AllReady => Prerequisites.Count > 0 && Prerequisites.All(item => item.Ready);

    public int ReadyCount => Prerequisites.Count(item => item.Ready);

    public int TotalCount => Prerequisites.Count;

    public IReadOnlyList<DeployPrerequisite> Blocked => Prerequisites.Where(item => !item.Ready).ToList();

    public DeployPrerequisite? Find(DeployPrerequisiteKind kind) =>
        Prerequisites.FirstOrDefault(item => item.Kind == kind);
}

/// <summary>
/// Pure aggregation for the Deploy status lights: green only when the probe really passed.
/// Signing is "pinned" only when the bundled files exist AND their SHA-256 matches the
/// launcher pins; the Apple-ID login cannot be detected programmatically and is a UI note.
/// </summary>
public static class DeployPrerequisiteEvaluator
{
    /// <summary>Rows in display order: device, signing tools, local toolchain, device bridge, shell template.</summary>
    public static DeployPrerequisiteReport Evaluate(DeployPrerequisiteInputs inputs)
    {
        var devices = inputs.DeviceSummaries ?? Array.Empty<string>();
        var missingTools = inputs.MissingLocalTools ?? Array.Empty<string>();
        var signingReady = inputs.SigningToolsPinned;
        var localReady = inputs.LocalToolchainResolved && missingTools.Count == 0;
        var bridgeReady = inputs.DeviceBridgeFound && inputs.DeviceBridgeEnumerates;
        var shellReady = inputs.ShellManifestPresent && inputs.ShellVerified;
        var prerequisites = new List<DeployPrerequisite>
        {
            new(DeployPrerequisiteKind.DeviceConnected, devices.Count > 0, DescribeDevices(devices)),
            new(DeployPrerequisiteKind.SigningTools, signingReady, signingReady ? inputs.SigningDetail ?? string.Empty : string.Empty),
            new(DeployPrerequisiteKind.LocalToolchain, localReady, localReady ? inputs.LocalToolchainDetail ?? string.Empty : string.Join(", ", missingTools)),
            new(DeployPrerequisiteKind.DeviceBridge, bridgeReady, bridgeReady ? DescribeBridge(inputs.DeviceBridgeVersion) : string.Empty),
            new(DeployPrerequisiteKind.ShellTemplate, shellReady, shellReady ? inputs.ShellDetail ?? string.Empty : string.Empty),
        };
        return new DeployPrerequisiteReport(prerequisites);
    }

    private static string DescribeDevices(IReadOnlyList<string> devices) => devices.Count switch
    {
        0 => string.Empty,
        1 => devices[0],
        _ => devices.Count.ToString(CultureInfo.InvariantCulture) + " devices · " + devices[0],
    };

    private static string DescribeBridge(string? version) =>
        string.IsNullOrWhiteSpace(version) ? "devpush" : "devpush " + version;
}
