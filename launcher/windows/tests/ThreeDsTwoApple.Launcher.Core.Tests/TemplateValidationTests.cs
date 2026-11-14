using System.IO.Compression;
using System.Text;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Util;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

public sealed class ShellTemplateRulesTests
{
    [Theory]
    [InlineData("0.2.0-beta1", true)]
    [InlineData("0.2.0-beta2", true)]
    [InlineData("0.2.0-rc1", true)]
    [InlineData("0.2.0", true)]
    [InlineData("0.2.1", true)]
    [InlineData("0.10.0", true)]
    [InlineData("0.2.0-alpha1", false)]
    [InlineData("0.1.9", false)]
    [InlineData("1.0.0-beta1", true)]
    [InlineData("garbage", false)]
    [InlineData("", false)]
    public void VersionComparisonMatchesMinimum(string version, bool expected)
    {
        Assert.Equal(expected, ShellTemplateRules.VersionAtLeast(version, ShellTemplateRules.MinimumVersion));
    }

    [Fact]
    public void AcceptsCurrentTemplateIdentity()
    {
        var ok = ShellTemplateRules.Validate("0.2.0-beta1", 9, "manifest");
        Assert.True(ok.Ok);
        Assert.True(ShellTemplateRules.Validate("0.2.0", 12, "Info.plist").Ok);
    }

    [Fact]
    public void RejectsOldOrMissingIdentity()
    {
        Assert.False(ShellTemplateRules.Validate("0.1.9", 9, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate("0.2.0-beta1", 8, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate(null, 9, "manifest").Ok);
        Assert.False(ShellTemplateRules.Validate("0.2.0", 0, "manifest").Ok);
    }

    [Fact]
    public void ManifestValidationUsesBuildField()
    {
        var good = new ShellManifest(1, "3ds2apple-shell.ipa", "0.2.0", "com.example.shell", new string('a', 64), 1, Build: 9);
        Assert.True(ShellTemplateRules.ValidateManifest(good).Ok);
        var bad = good with { Build = 8 };
        Assert.False(ShellTemplateRules.ValidateManifest(bad).Ok);
    }
}

public sealed class IpaTemplateInspectorTests
{
    private const string ValidXmlPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.kratos.3ds2apple</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>12</string>
</dict></plist>
""";

    private static readonly string OldXmlPlist = ValidXmlPlist
        .Replace("<string>0.2.0</string>", "<string>0.1.9</string>")
        .Replace("<string>12</string>", "<string>7</string>");

    private const string EmptyCatalog = """{"schemaVersion":2,"games":[]}""";
    private const string LoadedCatalog = """{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Demo","packFile":"Frameworks/GamePack-0004000000055E00.dylib"}]}""";
    private const string BinaryPlistBase64 = "YnBsaXN0MDDTAQIDBAUGXxASQ0ZCdW5kbGVJZGVudGlmaWVyXxAaQ0ZCdW5kbGVTaG9ydFZlcnNpb25TdHJpbmdfEA9DRkJ1bmRsZVZlcnNpb25fEBRjb20ua3JhdG9zLjNkczJhcHBsZVUwLjIuMFIxMggPJEFTanAAAAAAAAABAQAAAAAAAAAHAAAAAAAAAAAAAAAAAAAAcw==";

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
        Assert.Equal("0.2.0", result.Identity!.Version);
        Assert.Equal(12, result.Identity.Build);
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
        Assert.Equal("0.2.0", result.Identity!.Version);
        Assert.Equal(12, result.Identity.Build);
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
    [Fact]
    public void RedactsLongUdid()
    {
        const string udid = "00008030-001A2B3C4D5E6F70";
        var redacted = Privacy.RedactUdid(udid);
        Assert.StartsWith("00008030", redacted);
        Assert.EndsWith("6F70", redacted);
        Assert.DoesNotContain("001A2B3C4D5E", redacted);
        Assert.NotEqual(udid, redacted);
    }

    [Fact]
    public void HandlesShortAndEmpty()
    {
        Assert.Equal("?", Privacy.RedactUdid(null));
        Assert.Equal("?", Privacy.RedactUdid(""));
        Assert.DoesNotContain("123456789012", Privacy.RedactUdid("123456789012"));
        Assert.Contains(" · usb", Privacy.RedactDevice("00008030-001A2B3C4D5E6F70", "usb"));
    }
}
