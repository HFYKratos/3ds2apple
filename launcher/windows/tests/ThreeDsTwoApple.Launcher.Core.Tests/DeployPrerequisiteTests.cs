using ThreeDsTwoApple.Launcher.Core.Deploy;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Contract tests for the Deploy prerequisites (the green/red status lights). The
/// evaluator is pure, so these lock the deploy-blocking rules without a phone, Windows,
/// LLVM or the bundled Impactor.
/// </summary>
public sealed class DeployPrerequisiteTests
{
    private static DeployPrerequisiteInputs Ready(
        bool signingPinned = true,
        bool localResolved = true,
        IReadOnlyList<string>? missingLocalTools = null,
        bool bridgeFound = true,
        bool bridgeEnumerates = true,
        IReadOnlyList<string>? devices = null,
        bool shellManifest = true,
        bool shellVerified = true) => new(
        SigningToolsPinned: signingPinned,
        SigningDetail: "Impactor v2.7.3 + plumesign",
        LocalToolchainResolved: localResolved,
        MissingLocalTools: missingLocalTools ?? Array.Empty<string>(),
        LocalToolchainDetail: "3dsrecomp · LLVM clang/llvm-ar/ld64.lld",
        DeviceBridgeFound: bridgeFound,
        DeviceBridgeEnumerates: bridgeEnumerates,
        DeviceBridgeVersion: "1.0.0",
        DeviceSummaries: devices ?? new[] { "USB · 0000…" },
        ShellManifestPresent: shellManifest,
        ShellVerified: shellVerified,
        ShellDetail: "v0.1.1 build 1");

    [Fact]
    public void AllReadyReportHasFiveGreenRowsInDisplayOrder()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(Ready());

        Assert.True(report.AllReady);
        Assert.Equal(5, report.ReadyCount);
        Assert.Equal(5, report.TotalCount);
        Assert.Empty(report.Blocked);
        Assert.Equal(
            new[]
            {
                DeployPrerequisiteKind.DeviceConnected,
                DeployPrerequisiteKind.SigningTools,
                DeployPrerequisiteKind.LocalToolchain,
                DeployPrerequisiteKind.DeviceBridge,
                DeployPrerequisiteKind.ShellTemplate,
            },
            report.Prerequisites.Select(item => item.Kind));
        Assert.All(report.Prerequisites, item => Assert.False(string.IsNullOrWhiteSpace(item.Detail)));
        Assert.Equal("devpush 1.0.0", report.Find(DeployPrerequisiteKind.DeviceBridge)!.Detail);
    }

    [Fact]
    public void NoDeviceTurnsOnlyTheDeviceLightRed()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(Ready(devices: Array.Empty<string>()));

        Assert.False(report.AllReady);
        var device = report.Find(DeployPrerequisiteKind.DeviceConnected)!;
        Assert.False(device.Ready);
        Assert.Equal(string.Empty, device.Detail);
        var blocked = Assert.Single(report.Blocked);
        Assert.Equal(DeployPrerequisiteKind.DeviceConnected, blocked.Kind);
        Assert.Equal(4, report.ReadyCount);
    }

    [Fact]
    public void DeviceCanBeDetectedThroughUsbMuxdEvenWhenTheBridgeIsMissing()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(Ready(bridgeFound: false));

        Assert.True(report.Find(DeployPrerequisiteKind.DeviceConnected)!.Ready);
        Assert.False(report.Find(DeployPrerequisiteKind.DeviceBridge)!.Ready);
        Assert.Equal(DeployPrerequisiteKind.DeviceBridge, Assert.Single(report.Blocked).Kind);
    }

    [Fact]
    public void BridgeThatCannotEnumerateDevicesIsRed()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(Ready(bridgeEnumerates: false));

        var bridge = report.Find(DeployPrerequisiteKind.DeviceBridge)!;
        Assert.False(bridge.Ready);
        Assert.Equal(string.Empty, bridge.Detail);
    }

    [Fact]
    public void TamperedSigningToolsAreRedEvenWhenTheFilesExist()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(Ready(signingPinned: false));

        var signing = report.Find(DeployPrerequisiteKind.SigningTools)!;
        Assert.False(signing.Ready);
        Assert.Equal(string.Empty, signing.Detail);
    }

    [Fact]
    public void MissingLocalToolchainListsTheMissingParts()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(
            Ready(localResolved: false, missingLocalTools: new[] { "3dsrecomp.exe", "clang.exe" }));

        var local = report.Find(DeployPrerequisiteKind.LocalToolchain)!;
        Assert.False(local.Ready);
        Assert.Contains("3dsrecomp.exe", local.Detail);
        Assert.Contains("clang.exe", local.Detail);
    }

    [Fact]
    public void ResolvedToolchainWithOneMissingPartIsStillRed()
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(
            Ready(missingLocalTools: new[] { "ld64.lld.exe" }));

        var local = report.Find(DeployPrerequisiteKind.LocalToolchain)!;
        Assert.False(local.Ready);
        Assert.Equal("ld64.lld.exe", local.Detail);
    }

    [Theory]
    [InlineData(true, false)]
    [InlineData(false, true)]
    [InlineData(false, false)]
    public void ShellTemplateNeedsBothTheManifestAndTheVerification(bool manifest, bool verified)
    {
        var report = DeployPrerequisiteEvaluator.Evaluate(
            Ready(shellManifest: manifest, shellVerified: verified));

        Assert.False(report.Find(DeployPrerequisiteKind.ShellTemplate)!.Ready);
    }
}
