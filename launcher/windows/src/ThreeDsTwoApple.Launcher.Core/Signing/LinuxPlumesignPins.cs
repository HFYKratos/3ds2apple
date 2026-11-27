using ThreeDsTwoApple.Launcher.Core.Signing;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>
/// Pins for the official Impactor v2.7.3 plumesign-linux-x86_64 binary used by the
/// Linux launcher (launcher/linux/vendor/PINS.json). Same release/licence as the
/// Windows pair; only the Linux CLI is required (no Impactor GUI, no usbmuxd
/// dependency of plumesign itself).
/// </summary>
public static class LinuxPlumesignPins
{
    public const string TestedVersion = "2.7.3";
    public const string ReleasePageUrl = "https://github.com/claration/impactor/releases/tag/v2.7.3";
    public const string BinaryFileName = "plumesign-linux-x86_64";
    public const string BundleRelativeDirectory = "ThirdParty/Impactor";

    public static readonly PinnedBinary PlumeSign = new(
        BinaryFileName,
        "d7d631d04fd80bf134fef9a7c71f704e9ae92f3d8f7e4895f10de4236acdc177",
        12_694_648);

    public static PinnedFileStatus Verify(string path) => ImpactorBundle.VerifyPinned(PlumeSign, path);
}
