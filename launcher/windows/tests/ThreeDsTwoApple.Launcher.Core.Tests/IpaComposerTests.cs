using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

public sealed class IpaComposerTests
{
    private const string TitleId = "0004000000055E00";
    private static readonly byte[] MachOMagic = { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 };

    private static void AddEntry(ZipArchive archive, string name, string content, int mode)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        entry.ExternalAttributes = mode << 16;
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(content);
    }

    private static void AddBytes(ZipArchive archive, string name, byte[] content, int mode)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        entry.ExternalAttributes = mode << 16;
        using var stream = entry.Open();
        stream.Write(content);
    }

    private static string BuildTemplate(TempDir temp, bool withRoms = false)
    {
        var ipaPath = Path.Combine(temp.Path, "template.ipa");
        using var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Create);
        AddEntry(archive, "Payload/demo.app/Info.plist", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>1</string></dict></plist>", 0x81A4);
        AddEntry(archive, "Payload/demo.app/GameCatalog.json", """{"schemaVersion":2,"games":[]}""", 0x81A4);
        AddBytes(archive, "Payload/demo.app/demo", new byte[] { 0xCF, 0xFA, 0xED, 0xFE }, 0x81ED);
        if (withRoms)
        {
            AddBytes(archive, "Payload/demo.app/Roms/" + TitleId + ".cci", new byte[] { 1, 2, 3 }, 0x81A4);
        }
        return ipaPath;
    }

    /// <summary>
    /// Fake pack CLI: writes the catalogue the real Rust CLI would write. With
    /// <paramref name="bundledRomFields"/> it also emits the legacy
    /// romFile/romSha256/romBytes that a package imported from a .32a with its
    /// GameRom carries in GameInfo.json.
    /// </summary>
    private static FakeProcessRunner CatalogRunner(List<string>? seenTitleIds = null, bool bundledRomFields = false)
    {
        return new FakeProcessRunner(request =>
        {
            var catalogOut = request.Arguments.SkipWhile(a => a != "--catalog-out").Skip(1).FirstOrDefault();
            var meta = request.Arguments.SkipWhile(a => a != "--metadata-out").Skip(1).FirstOrDefault(); // unused
            var titleIds = new List<string>();
            for (var i = 0; i < request.Arguments.Count - 1; i++)
            {
                if (request.Arguments[i] == "--title-id")
                {
                    titleIds.Add(request.Arguments[i + 1]);
                }
            }
            seenTitleIds?.AddRange(titleIds);
            if (catalogOut is not null)
            {
                var games = string.Join(",", titleIds.Select(id =>
                {
                    var romFields = bundledRomFields
                        ? ",\"romFile\":\"Roms/" + id + ".cci\",\"romSha256\":\"" + new string('a', 64) + "\",\"romBytes\":16900"
                        : string.Empty;
                    return "{\"titleID\":\"" + id + "\",\"displayName\":\"Demo\",\"productCode\":\"CTR-P-DEMO\",\"aot\":true,\"aotVersion\":1,\"packFile\":\"Frameworks/GamePack-" + id + ".dylib\",\"packABIVersion\":1" + romFields + "}";
                }));
                File.WriteAllText(catalogOut, "{\"schemaVersion\":2,\"games\":[" + games + "]}");
            }
            return new ProcessResult(0, string.Empty, string.Empty, false, true);
        });
    }

    [Fact]
    public async Task ComposesPackAndCatalogIntoRomFreeIpa()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var runner = CatalogRunner();
        var composer = new IpaComposer(new PackCli(runner, "pack", Path.Combine(temp.Path, "out")));
        var outputDirectory = Path.Combine(temp.Path, "composed");
        var composed = await composer.ComposeAsync(template, new[]
        {
            new ComposedPack(TitleId, "Demo", "CTR-P-DEMO", 1, packPath),
        }, outputDirectory);

        Assert.Equal(1, composed.GameCount);
        Assert.Equal(TitleId, Assert.Single(composed.TitleIDs));
        Assert.True(File.Exists(composed.IpaPath));
        Assert.NotEqual(0, composed.Bytes);
        Assert.Equal(composed.Sha256, ThreeDsTwoApple.Launcher.Core.Signing.ImpactorBundle.Sha256File(composed.IpaPath));

        using var output = ZipFile.OpenRead(composed.IpaPath);
        Assert.NotNull(output.GetEntry("Payload/demo.app/Info.plist"));
        var packEntry = output.GetEntry("Payload/demo.app/Frameworks/GamePack-" + TitleId + ".dylib");
        Assert.NotNull(packEntry);
        using (var stream = packEntry!.Open())
        using (var memory = new MemoryStream())
        {
            stream.CopyTo(memory);
            Assert.Equal(MachOMagic, memory.ToArray());
        }
        Assert.DoesNotContain(output.Entries, entry => entry.FullName.Contains("/Roms/", StringComparison.OrdinalIgnoreCase));
        var catalogEntry = output.GetEntry("Payload/demo.app/GameCatalog.json");
        Assert.NotNull(catalogEntry);
        string catalogJson;
        using (var reader = new StreamReader(catalogEntry!.Open()))
        {
            catalogJson = reader.ReadToEnd();
        }
        using var catalog = JsonDocument.Parse(catalogJson);
        var game = catalog.RootElement.GetProperty("games")[0];
        Assert.Equal(TitleId, game.GetProperty("titleID").GetString());
        Assert.Equal("Frameworks/GamePack-" + TitleId + ".dylib", game.GetProperty("packFile").GetString());
        Assert.Equal("zk_gamepack_register", game.GetProperty("registrationSymbol").GetString());
        Assert.Equal(1, game.GetProperty("packABIVersion").GetInt32());
    }

    /// <summary>
    /// Regression for the .32a-import defect: a package whose GameInfo.json records
    /// romFile (because the build package embedded its GameRom) makes the pack CLI
    /// emit a catalogue romFile. The launcher-first shell is ROM-free (the data is
    /// pushed to Documents/Games), so the composed catalogue must drop it - iOS
    /// AOTPackageLoader treats a catalogue romFile as a required bundled
    /// Roms/&lt;TITLEID&gt;.&lt;ext&gt; and otherwise refuses to launch the game.
    /// </summary>
    [Fact]
    public async Task ComposedCatalogDropsBundledRomFieldsFromImportedPackages()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var composer = new IpaComposer(new PackCli(
            CatalogRunner(bundledRomFields: true),
            "pack",
            Path.Combine(temp.Path, "out")));
        var composed = await composer.ComposeAsync(template, new[]
        {
            new ComposedPack(TitleId, "Demo", "CTR-P-DEMO", 1, packPath),
        }, Path.Combine(temp.Path, "composed"));

        using var output = ZipFile.OpenRead(composed.IpaPath);
        var catalogEntry = output.GetEntry("Payload/demo.app/GameCatalog.json");
        Assert.NotNull(catalogEntry);
        string catalogJson;
        using (var reader = new StreamReader(catalogEntry!.Open()))
        {
            catalogJson = reader.ReadToEnd();
        }
        Assert.DoesNotContain("romFile", catalogJson, StringComparison.Ordinal);
        Assert.DoesNotContain("romSha256", catalogJson, StringComparison.Ordinal);
        Assert.DoesNotContain("romBytes", catalogJson, StringComparison.Ordinal);
        Assert.DoesNotContain("Roms/", catalogJson, StringComparison.Ordinal);
        using var catalog = JsonDocument.Parse(catalogJson);
        var game = catalog.RootElement.GetProperty("games")[0];
        Assert.Equal(TitleId, game.GetProperty("titleID").GetString());
        Assert.Equal("Frameworks/GamePack-" + TitleId + ".dylib", game.GetProperty("packFile").GetString());
        Assert.True(game.GetProperty("aot").GetBoolean());
        Assert.Equal(1, game.GetProperty("packABIVersion").GetInt32());
    }

    [Fact]
    public void NormalizeCatalogDropsBundledRomFieldsAndKeepsTheRest()
    {
        var catalog = "{\"schemaVersion\":2,\"games\":[{\"titleID\":\"" + TitleId
            + "\",\"displayName\":\"Demo\",\"productCode\":\"CTR-P-DEMO\",\"aot\":true,"
            + "\"aotVersion\":1,\"packFile\":\"Frameworks/GamePack-" + TitleId + ".dylib\","
            + "\"romFile\":\"Roms/" + TitleId + ".cci\",\"romSha256\":\"" + new string('a', 64)
            + "\",\"romBytes\":16900,\"packABIVersion\":1,\"notes\":\"kept\"}]}";

        var normalized = IpaComposer.NormalizeCatalog(catalog, new[] { TitleId });
        Assert.DoesNotContain("romFile", normalized, StringComparison.Ordinal);
        Assert.DoesNotContain("romSha256", normalized, StringComparison.Ordinal);
        Assert.DoesNotContain("romBytes", normalized, StringComparison.Ordinal);
        Assert.DoesNotContain("Roms/", normalized, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(normalized);
        var game = document.RootElement.GetProperty("games")[0];
        Assert.Equal(TitleId, game.GetProperty("titleID").GetString());
        Assert.Equal("Demo", game.GetProperty("displayName").GetString());
        Assert.Equal("CTR-P-DEMO", game.GetProperty("productCode").GetString());
        Assert.Equal("kept", game.GetProperty("notes").GetString());
        Assert.Equal("zk_gamepack_register", game.GetProperty("registrationSymbol").GetString());
    }

    [Fact]
    public async Task RejectsTemplateThatContainsRoms()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp, withRoms: true);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var composer = new IpaComposer(new PackCli(CatalogRunner(), "pack", Path.Combine(temp.Path, "out")));
        var exception = await Assert.ThrowsAsync<LauncherToolException>(() => composer.ComposeAsync(template, new[]
        {
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
        }, Path.Combine(temp.Path, "composed")));
        Assert.Equal("shell_template_incompatible", exception.Code);
    }

    [Fact]
    public void CatalogValidationRequiresFrameworksPackFile()
    {
        const string badCatalog = """{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Demo","aot":true,"aotVersion":1,"packFile":"GamePack.dylib","packABIVersion":1}]}""";
        var exception = Assert.Throws<LauncherToolException>(() => IpaComposer.NormalizeCatalog(badCatalog, new[] { TitleId }));
        Assert.Equal("catalog_failed", exception.Code);

        const string goodCatalog = """{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Demo","aot":true,"aotVersion":1,"packFile":"Frameworks/GamePack-0004000000055E00.dylib","packABIVersion":1}]}""";
        var normalized = IpaComposer.NormalizeCatalog(goodCatalog, new[] { TitleId });
        Assert.Contains("registrationSymbol", normalized, StringComparison.Ordinal);
        Assert.Contains("Frameworks/GamePack-0004000000055E00.dylib", normalized, StringComparison.Ordinal);
    }
}
