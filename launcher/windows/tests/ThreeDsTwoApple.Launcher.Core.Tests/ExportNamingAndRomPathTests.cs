using System.IO.Compression;
using System.Text;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Localization;
using ThreeDsTwoApple.Launcher.Core.Models;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// 0.2.2-beta4: the export success state shows only "Exported: &lt;path&gt;" (no byte
/// count / unsigned / game-data warnings); the dialog warnings are unchanged.
/// </summary>
public sealed class ExportCopyTests
{
    [Fact]
    public void SuccessMessagesOnlyCarryThePath()
    {
        var path = "/tmp/exports/0004000000055E00-Example Game.ipa";
        Assert.Equal("Exported: " + path, LanguageCatalog.Format("en", "library.ipaExported", path));
        Assert.Equal("已导出：" + path, LanguageCatalog.Format("zh-Hans", "library.ipaExported", path));
        Assert.Equal("Exported: " + path, LanguageCatalog.Format("en", "library.buildPackage.exported", path));
        Assert.Equal("已导出：" + path, LanguageCatalog.Format("zh-Hans", "library.buildPackage.exported", path));

        // The removed suffix hints must not come back as success-state text.
        Assert.False(LanguageCatalog.English.ContainsKey("library.ipaUnsignedHint"));
        Assert.False(LanguageCatalog.ChineseSimplified.ContainsKey("library.ipaUnsignedHint"));
        Assert.DoesNotContain("{1}", LanguageCatalog.English["library.ipaExported"], StringComparison.Ordinal);
        Assert.DoesNotContain("{1}", LanguageCatalog.ChineseSimplified["library.buildPackage.exported"], StringComparison.Ordinal);
    }
}

/// <summary>
/// A .32a-imported game records the package in RomPath; the IPA export / deploy
/// resolve the embedded GameRom copy (package directory first, then the archive).
/// </summary>
public sealed class GameRomResolverTests
{
    private const string TitleId = "0004000000055E00";

    private static LibraryEntry Entry(string romPath, string? packageDir = null) => new()
    {
        TitleID = TitleId,
        DisplayName = "Example Game",
        RomPath = romPath,
        PackageDir = packageDir,
    };

    [Fact]
    public void ResolvesAPlainRomPathUnchanged()
    {
        using var temp = new TempDir();
        var rom = temp.Bytes("Example Game.cci", new byte[] { 1, 2, 3, 4 });

        var resolved = GameRomResolver.Resolve(Entry(rom), Path.Combine(temp.Path, "cache"), out var error);

        Assert.Null(error);
        Assert.NotNull(resolved);
        Assert.Equal(Path.GetFullPath(rom), resolved!.Path);
        Assert.Equal("cci", resolved.Extension);
        Assert.Equal(4, resolved.Bytes);
    }

    [Fact]
    public void PrefersTheImportedPackageGameRomCopy()
    {
        using var temp = new TempDir();
        var packageDir = Directory.CreateDirectory(Path.Combine(temp.Path, "packages", TitleId)).FullName;
        var packageRom = Path.Combine(packageDir, "GameRom.3ds");
        File.WriteAllBytes(packageRom, new byte[] { 9, 8, 7 });
        var package = temp.Bytes(TitleId + "-Example Game.32a", new byte[] { 5, 5, 5 });

        var resolved = GameRomResolver.Resolve(Entry(package, packageDir), Path.Combine(temp.Path, "cache"), out var error);

        Assert.Null(error);
        Assert.Equal(packageRom, resolved!.Path);
        Assert.Equal("3ds", resolved.Extension);
    }

    [Fact]
    public void ExtractsGameRomFromTheBuildPackageArchive()
    {
        using var temp = new TempDir();
        var package = Path.Combine(temp.Path, TitleId + "-Example Game.32a");
        using (var archive = ZipFile.Open(package, ZipArchiveMode.Create))
        {
            WriteEntry(archive, "GameInfo.json", "{\"schemaVersion\":1}");
            WriteEntry(archive, "GameRom.cci", "rom-bytes");
            WriteEntry(archive, "BuildManifest.json", "{}");
        }
        var cache = Path.Combine(temp.Path, "cache");

        var resolved = GameRomResolver.Resolve(Entry(package), cache, out var error);

        Assert.Null(error);
        Assert.NotNull(resolved);
        Assert.True(File.Exists(resolved!.Path));
        Assert.Equal("rom-bytes", File.ReadAllText(resolved.Path));
        Assert.StartsWith(Path.GetFullPath(cache), Path.GetFullPath(resolved.Path), StringComparison.Ordinal);
    }

    [Fact]
    public void MissingGameDataGivesAReadableError()
    {
        using var temp = new TempDir();
        var package = Path.Combine(temp.Path, TitleId + "-Example Game.32a");
        using (var archive = ZipFile.Open(package, ZipArchiveMode.Create))
        {
            WriteEntry(archive, "GameInfo.json", "{}");
        }

        var resolved = GameRomResolver.Resolve(Entry(package), Path.Combine(temp.Path, "cache"), out var error);

        Assert.Null(resolved);
        Assert.NotNull(error);
        Assert.Contains("game data", error, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("re-import", error, StringComparison.OrdinalIgnoreCase);
    }

    private static void WriteEntry(ZipArchive archive, string name, string text)
    {
        var entry = archive.CreateEntry(name);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(text);
    }
}
