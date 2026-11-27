using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>0.2.3 P1: Linux plumesign account state and pins must be safe/explicit.</summary>
public sealed class LinuxPlumesignTests
{
    private const string Binary = "/opt/3ds2apple/plumesign-linux-x86_64";

    private static PlumesignAccountService Service(TempDir temp, Func<ProcessRequest, ProcessResult> handler) =>
        new(new FakeProcessRunner(handler), temp.Bytes("plumesign-linux-x86_64", new byte[] { 1, 2, 3 }));

    [Fact]
    public async Task NoAccountsFoundMeansSignedOut()
    {
        using var temp = new TempDir();
        var service = Service(temp, _ => new ProcessResult(0,
            "[2026-11-27T07:33:57Z INFO  plumesign::commands::account] No accounts found. Use 'account login' to add an account.",
            string.Empty, false, true));

        var status = await service.StatusAsync();

        Assert.False(status.SignedIn);
        Assert.Contains("Not signed in", status.Summary);
    }

    [Fact]
    public async Task SavedAccountMeansSignedInWithoutExposingTheAppleId()
    {
        using var temp = new TempDir();
        var service = Service(temp, _ => new ProcessResult(0,
            "[INFO] Account: example@example.com (Team: TEAMID1234)\n[INFO] Certificate: Apple Development",
            string.Empty, false, true));

        var status = await service.StatusAsync();

        Assert.True(status.SignedIn);
        Assert.DoesNotContain("example@example.com", status.Summary, StringComparison.Ordinal);
    }

    [Fact]
    public async Task AccountListFailureIsReadableAndNotSignedIn()
    {
        using var temp = new TempDir();
        var service = Service(temp, _ => new ProcessResult(1, string.Empty, "keychain unavailable", false, true));

        var status = await service.StatusAsync();

        Assert.False(status.SignedIn);
        Assert.False(string.IsNullOrWhiteSpace(status.Summary));
    }

    [Fact]
    public void PinsMatchTheOfficialLinuxRelease()
    {
        Assert.Equal("2.7.3", LinuxPlumesignPins.TestedVersion);
        Assert.Equal("plumesign-linux-x86_64", LinuxPlumesignPins.PlumeSign.FileName);
        Assert.Equal(12_694_648, LinuxPlumesignPins.PlumeSign.Bytes);
        Assert.Equal("d7d631d04fd80bf134fef9a7c71f704e9ae92f3d8f7e4895f10de4236acdc177", LinuxPlumesignPins.PlumeSign.Sha256);
        Assert.Contains("github.com/claration/impactor", LinuxPlumesignPins.ReleasePageUrl);
    }

    [Fact]
    public void MissingOrMismatchedBinaryIsNotPinnedReady()
    {
        using var temp = new TempDir();
        var missing = LinuxPlumesignPins.Verify(Path.Combine(temp.Path, "missing-plumesign"));
        Assert.False(missing.Ok);

        var fake = temp.Bytes("plumesign-linux-x86_64", new byte[] { 1, 2, 3 });
        Assert.False(LinuxPlumesignPins.Verify(fake).Ok);
    }

    [Fact]
    public void MissingPlumesignCannotOpenALoginTerminal()
    {
        using var temp = new TempDir();
        var service = new PlumesignAccountService(new FakeProcessRunner(_ => throw new InvalidOperationException("no process may run")), Path.Combine(temp.Path, "missing"));

        var launch = service.OpenLoginTerminal();

        Assert.False(launch.Launched);
        Assert.False(string.IsNullOrWhiteSpace(launch.Error));
        Assert.Empty(launch.Command);
    }
}
