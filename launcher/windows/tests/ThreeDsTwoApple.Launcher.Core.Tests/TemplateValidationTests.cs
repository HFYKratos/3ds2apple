using System.IO.Compression;
using System.Text;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using ThreeDsTwoApple.Launcher.Core.Util;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

public sealed class ShellTemplateRulesTests
{
    [Theory]
    [InlineData("0.1.0", true)]
    [InlineData("0.1.1", true)]
    [InlineData("0.2.0-beta1", true)]
    [InlineData("0.2.0", true)]
    [InlineData("0.10.0", true)]
    [InlineData("1.0.0-beta1", true)]
    [InlineData("0.1.0-beta1", false)]
    [InlineData("0.1.0-alpha1", false)]
    [InlineData("0.0.9", false)]
    [InlineData("garbage", false)]
    [InlineData("", false)]
    public void VersionComparisonMatchesMinimum(string version, bool expected)
    {
        Assert.Equal(expected, ShellTemplateRules.VersionAtLeast(version, ShellTemplateRules.MinimumVersion));
    }

    [Fact]
    public void AcceptsCurrentTemplateIdentity()
    {
        var ok = ShellTemplateRules.Validate("0.1.0", 1, "manifest");
        Assert.True(ok.Ok);
        Assert.True(ShellTemplateRules.Validate("0.1.0", 12, "Info.plist").Ok);
        Assert.True(ShellTemplateRules.Validate("0.2.0", 1, "Info.plist").Ok);
    }

    [Fact]
    public void RejectsOldOrMissingIdentity()
    {
        Assert.False(ShellTemplateRules.Validate("0.0.9", 1, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate("0.1.0", 0, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate(null, 1, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate("0.1.0", null, "manifest").Ok);
    }

    [Fact]
    public void ManifestValidationUsesBuildField()
    {
        var good = new ShellManifest(1, "3ds2apple-shell.ipa", "0.1.0", "com.example.shell", new string('a', 64), 1, Build: 1);
        Assert.True(ShellTemplateRules.ValidateManifest(good).Ok);
        var old = good with { Version = "0.0.9" };
        Assert.False(ShellTemplateRules.ValidateManifest(old).Ok);
        var noBuild = good with { Build = 0 };
        Assert.False(ShellTemplateRules.ValidateManifest(noBuild).Ok);
    }
}

public sealed class IpaTemplateInspectorTests
{
    private const string ValidXmlPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.kratos.3ds2apple</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
""";

    private static readonly string OldXmlPlist = ValidXmlPlist
        .Replace("<string>0.1.0</string>", "<string>0.0.9</string>");

    private const string EmptyCatalog = """{"schemaVersion":2,"games":[]}""";
    private const string LoadedCatalog = """{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Demo","packFile":"Frameworks/GamePack-0004000000055E00.dylib"}]}""";
    private const string BinaryPlistBase64 = "YnBsaXN0MDDTAQIDBAUGXxASQ0ZCdW5kbGVJZGVudGlmaWVyXxAaQ0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmdfEA9DRkJ1bmRsZVZlcnNpb25fEBRjb20ua3JhdG9zLjNkczJhcHBsZVUwLjEuMFExCA8kQVNqcAAAAAAAAAEBAAAAAAAAAAcAAAAAAAAAAAAAAAAAAABy";

    private static string BuildTemplate(TempDir temp, string plist, string catalog, bool withRoms = false, bool binaryPlist = false)
    {
        var ipa = Path.Combine(temp.Path, "template.ipa");
        using var archive = ZipFile.Open(ipa, ZipArchiveMode.Create);
        var info = archive.CreateEntry("Payload/demo.app/Info.plist");
        if (binaryPlist)
        {
            using var stream = info.Open();
            stream.Write(Convert.FromBase64String(BinaryPlistBase64));
        }
        else
        {
            using var writer = new StreamWriter(info.Open(), new UTF8Encoding(false));
            writer.Write(plist);
        }
        var catalogEntry = archive.CreateEntry("Payload/demo.app/GameCatalog.json");
        using (var writer = new StreamWriter(catalogEntry.Open(), new UTF8Encoding(false)))
        {
            writer.Write(catalog);
        }
        var exe = archive.CreateEntry("Payload/demo.app/demo");
        using (var stream = exe.Open()) stream.Write(new byte[] { 0xCF, 0xFA, 0xED, 0xFE });
        if (withRoms)
        {
            var rom = archive.CreateEntry("Payload/demo.app/Roms/0004000000055E00.cci");
            using var stream = rom.Open();
            stream.Write(new byte[] { 1, 2, 3 });
        }
        return ipa;
    }

    [Fact]
    public void AcceptsValidTemplate()
    {
        using var temp = new TempDir();
        var ipa = BuildTemplate(temp, ValidXmlPlist, EmptyCatalog);
        var result = IpaTemplateInspector.Inspect(ipa, requireEmptyCatalog: true);
        Assert.True(result.Ok, result.Error);
        Assert.Equal("0.1.0", result.Identity!.Version);
        Assert.Equal(1, result.Identity.Build);
        Assert.Equal(2, result.Identity.CatalogSchemaVersion);
        Assert.Equal(0, result.Identity.GameCount);
    }

    [Fact]
    public void ReadsBinaryInfoPlist()
    {
        using var temp = new TempDir();
        var ipa = BuildTemplate(temp, ValidXmlPlist, EmptyCatalog, binaryPlist: true);
        var result = IpaTemplateInspector.Inspect(ipa, requireEmptyCatalog: true);
        Assert.True(result.Ok, result.Error);
        Assert.Equal("0.1.0", result.Identity!.Version);
        Assert.Equal(1, result.Identity.Build);
    }

    [Fact]
    public void RejectsOldTemplateIdentity()
    {
        using var temp = new TempDir();
        var ipa = BuildTemplate(temp, OldXmlPlist, EmptyCatalog);
        var result = IpaTemplateInspector.Inspect(ipa, requireEmptyCatalog: true);
        Assert.False(result.Ok);
        Assert.Contains("older", result.Error!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void RejectsTemplateWithGamesOrWrongSchema()
    {
        using var temp = new TempDir();
        var loaded = IpaTemplateInspector.Inspect(BuildTemplate(temp, ValidXmlPlist, LoadedCatalog), requireEmptyCatalog: true);
        Assert.False(loaded.Ok);
        Assert.Contains("must be empty", loaded.Error!, StringComparison.OrdinalIgnoreCase);

        using var temp2 = new TempDir();
        var schema1 = IpaTemplateInspector.Inspect(BuildTemplate(temp2, ValidXmlPlist, """{"schemaVersion":1,"games":[]}"""), requireEmptyCatalog: true);
        Assert.False(schema1.Ok);
    }

    [Fact]
    public void RejectsTemplateWithRoms()
    {
        using var temp = new TempDir();
        var ipa = BuildTemplate(temp, ValidXmlPlist, EmptyCatalog, withRoms: true);
        var result = IpaTemplateInspector.Inspect(ipa, requireEmptyCatalog: true);
        Assert.False(result.Ok);
        Assert.Contains("Roms", result.Error!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ComposedAppAllowsGamesButNotRoms()
    {
        using var temp = new TempDir();
        var ipa = BuildTemplate(temp, ValidXmlPlist, LoadedCatalog);
        var result = IpaTemplateInspector.Inspect(ipa, requireEmptyCatalog: false);
        Assert.True(result.Ok, result.Error);
        Assert.Equal(1, result.Identity!.GameCount);
    }
}

public sealed class PrivacyTests
{
    private const string Udid = "00008030-001A2B3C4D5E6F70";

    [Fact]
    public void DeviceDescriptionIsNonIdentifying()
    {
        // The description helpers do not even accept an identifier; only the internal
        // DeviceInfo.Udid field (never logged) carries it.
        Assert.Equal("iPhone 15 Pro (USB)", Privacy.DescribeDevice("iPhone 15 Pro", "usb"));
        Assert.Equal("iPhone/iPad (USB)", Privacy.DescribeDevice(null, "usb"));
        Assert.Equal("iPhone 15 Pro (Wi-Fi)", Privacy.DescribeDevice("iPhone 15 Pro", "network"));
        Assert.Equal("iPhone 15 Pro (USB, iOS 18.2)", Privacy.DescribeDevice("iPhone 15 Pro", "usb", "18.2"));

        var device = new DeviceInfo(Udid, "Kratos iPhone", "iPhone 15 Pro", "18.2", "usb", Paired: true);
        var display = device.Display;
        Assert.Equal("iPhone 15 Pro (USB, iOS 18.2)", display);
        Assert.DoesNotContain(Udid, display, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("00008030", display, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("6F70", display, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("Kratos iPhone", display, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SanitizeLogLineRemovesEveryUdidShape()
    {
        var modern = Privacy.SanitizeLogLine("device " + Udid + " connected");
        Assert.Contains(Privacy.DevicePlaceholder, modern);
        Assert.DoesNotContain("00008030", modern, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("001A2B3C4D5E6F70", modern, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("6F70", modern, StringComparison.OrdinalIgnoreCase);

        const string legacyUdid = "0123456789ABCDEF0123456789ABCDEF01234567";
        var legacy = Privacy.SanitizeLogLine("legacy device " + legacyUdid);
        Assert.DoesNotContain(legacyUdid, legacy, StringComparison.OrdinalIgnoreCase);

        // The pre-0.1.2 launcher logged the "first8…last4" mask; it must not reappear either.
        var maskedInput = Udid[..8] + "…" + Udid[^4..];
        var masked = Privacy.SanitizeLogLine("udid " + maskedInput);
        Assert.DoesNotContain(Udid[..8], masked, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(Udid[^4..], masked, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(maskedInput, masked, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SanitizeLogLineRemovesUsbMuxIdEcidAndSerial()
    {
        const string text = "usbmux id 42 ecid: 1234567890123 serial=F2LZ12345678 UDID: " + Udid;
        var sanitized = Privacy.SanitizeLogLine(text);
        Assert.Contains(Privacy.DevicePlaceholder, sanitized);
        Assert.DoesNotContain("usbmux id 42", sanitized, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("1234567890123", sanitized, StringComparison.Ordinal);
        Assert.DoesNotContain("F2LZ12345678", sanitized, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("00008030", sanitized, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void SanitizeLogLineKeepsTitleIdsAndHashes()
    {
        // Title IDs and SHA-256 digests are not device identifiers and must stay readable
        // for support/verification work.
        const string line = "titleID 0004000000055E00 pack sha256 a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90";
        Assert.Equal(line, Privacy.SanitizeLogLine(line));
        Assert.Equal(string.Empty, Privacy.SanitizeLogLine(null));
    }
}

/// <summary>
/// Defence in depth: even if a third-party tool prints a device identifier, the two
/// launcher log sinks (the daily workspace log and each plumesign run log) scrub it.
/// </summary>
public sealed class PrivacyLogSinkTests
{
    private const string Udid = "00008030-001A2B3C4D5E6F70";

    [Fact]
    public void WorkspaceDailyLogSanitizesDeviceIdentifiers()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        workspace.AppendLog("device " + Udid + " usbmux id 7 ecid=1234567890123 serial=F2LZ12345678");

        var log = File.ReadAllText(workspace.CurrentLogPath);
        Assert.DoesNotContain(Udid, log, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("00008030", log, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("usbmux id 7", log, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("1234567890123", log, StringComparison.Ordinal);
        Assert.DoesNotContain("F2LZ12345678", log, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(Privacy.DevicePlaceholder, log);
        Assert.Contains("device", log, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task PlumeSignRunLogSanitizesDeviceIdentifiers()
    {
        using var temp = new TempDir();
        var runner = new FakeProcessRunner(_ => new ProcessResult(0,
            "Device " + Udid + " usbmux id 7 serial=F2LZ12345678\nInstallation complete", string.Empty, false, true));
        var signer = new PlumeSignRunner(runner, "/fake/plumesign", Path.Combine(temp.Path, "logs"));
        var result = await signer.RunAsync(new PlumeSignRequest(Path.Combine(temp.Path, "in.ipa"), Path.Combine(temp.Path, "out.ipa"), "com.example.app"));

        Assert.True(result.Success, result.Log);
        var log = await File.ReadAllTextAsync(result.LogPath);
        Assert.DoesNotContain(Udid, log, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("00008030", log, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("F2LZ12345678", log, StringComparison.OrdinalIgnoreCase);
        Assert.Contains(Privacy.DevicePlaceholder, log);
        Assert.DoesNotContain(Udid, result.Log, StringComparison.OrdinalIgnoreCase);
    }
}
