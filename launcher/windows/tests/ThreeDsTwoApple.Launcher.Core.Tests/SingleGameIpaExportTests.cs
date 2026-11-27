using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using SkiaSharp;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>
/// Single-game IPA export (Library "Export IPA"): template + one GamePack +
/// autoLaunch catalogue + the game's ROM embedded as Roms/&lt;TITLEID&gt;.&lt;ext&gt; +
/// the SMDH cover replacing the template AppIcon*.png set. The composition reuses
/// IpaComposer, so these tests cover the exporter layer (embedded game data), the
/// icon generator and the structure gate only (no signing, no device).
/// </summary>
public sealed class SingleGameIpaExportTests
{
    private const string TitleId = "0004000000055E00";
    private static readonly byte[] MachOMagic = { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 };
    private static readonly byte[] FakeRom = { 0x4E, 0x43, 0x53, 0x44, 0x01, 0x02, 0x03, 0x04, 0x05 };

    /// <summary>Template AppIcon sizes the real shell ships (iOS 20/29/40/60/76/83.5 pt + @2x/@3x + 1024).</summary>
    private static readonly (string Name, int Pixel)[] TemplateIcons =
    {
        ("AppIcon20x20.png", 20),
        ("AppIcon20x20@2x.png", 40),
        ("AppIcon20x20@3x.png", 60),
        ("AppIcon29x29.png", 29),
        ("AppIcon29x29@2x.png", 58),
        ("AppIcon29x29@3x.png", 87),
        ("AppIcon40x40.png", 40),
        ("AppIcon40x40@2x.png", 80),
        ("AppIcon40x40@3x.png", 120),
        ("AppIcon60x60@2x.png", 120),
        ("AppIcon60x60@3x.png", 180),
        ("AppIcon76x76.png", 76),
        ("AppIcon76x76@2x.png", 152),
        ("AppIcon83.5x83.5@2x.png", 167),
        ("AppIcon1024x1024.png", 1024),
    };

    private static byte[] RenderPng(int width, int height, SKColor color)
    {
        var info = new SKImageInfo(width, height, SKColorType.Rgba8888, SKAlphaType.Premul);
        using var bitmap = new SKBitmap(info);
        using (var canvas = new SKCanvas(bitmap))
        {
            canvas.Clear(color);
        }
        using var image = SKImage.FromBitmap(bitmap);
        using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
        return encoded.ToArray();
    }

    private static void AddBytes(ZipArchive archive, string name, byte[] content, int mode)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        entry.ExternalAttributes = mode << 16;
        using var stream = entry.Open();
        stream.Write(content);
    }

    private static void AddText(ZipArchive archive, string name, string content, int mode)
    {
        var entry = archive.CreateEntry(name, CompressionLevel.Optimal);
        entry.ExternalAttributes = mode << 16;
        using var writer = new StreamWriter(entry.Open(), new System.Text.UTF8Encoding(false));
        writer.Write(content);
    }

    private static string BuildTemplate(TempDir temp)
    {
        var ipaPath = Path.Combine(temp.Path, "template.ipa");
        using var archive = ZipFile.Open(ipaPath, ZipArchiveMode.Create);
        AddText(archive, "Payload/demo.app/Info.plist", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>0.2.2</string><key>CFBundleVersion</key><string>1</string></dict></plist>", 0x81A4);
        AddText(archive, "Payload/demo.app/GameCatalog.json", "{\"schemaVersion\":2,\"games\":[]}", 0x81A4);
        AddBytes(archive, "Payload/demo.app/demo", new byte[] { 0xCF, 0xFA, 0xED, 0xFE }, 0x81ED);
        foreach (var (name, pixel) in TemplateIcons)
        {
            AddBytes(archive, "Payload/demo.app/" + name, RenderPng(pixel, pixel, new SKColor(20, 20, 20)), 0x81A4);
        }
        return ipaPath;
    }

    private static FakeProcessRunner CatalogRunner(string catalogJson, bool fail = false)
    {
        return new FakeProcessRunner(request =>
        {
            var catalogOut = request.Arguments.SkipWhile(a => a != "--catalog-out").Skip(1).FirstOrDefault();
            if (catalogOut is not null && !fail)
            {
                File.WriteAllText(catalogOut, catalogJson);
            }
            return fail
                ? new ProcessResult(1, string.Empty, "catalog failed", false, true)
                : new ProcessResult(0, string.Empty, string.Empty, false, true);
        });
    }

    private static string CatalogJson()
    {
        var game = new
        {
            titleID = TitleId,
            displayName = "Demo",
            productCode = "CTR-P-DEMO",
            aot = true,
            aotVersion = 1,
            packFile = "Frameworks/GamePack-" + TitleId + ".dylib",
            packABIVersion = 1,
        };
        return JsonSerializer.Serialize(new { schemaVersion = 2, games = new[] { game } });
    }

    private static string FakeRomFile(TempDir temp, string name = "Example Game.cci") =>
        temp.Bytes(name, FakeRom);

    /// <summary>Rewrite an IPA with entry-level mutation (structure-gate tests).</summary>
    private static string RewriteIpa(string source, string destination, Action<List<(string Name, byte[] Bytes)>> mutate)
    {
        var entries = new List<(string Name, byte[] Bytes)>();
        using (var archive = ZipFile.OpenRead(source))
        {
            foreach (var entry in archive.Entries)
            {
                using var stream = entry.Open();
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                entries.Add((entry.FullName, memory.ToArray()));
            }
        }
        mutate(entries);
        using var output = ZipFile.Open(destination, ZipArchiveMode.Create);
        foreach (var (name, bytes) in entries)
        {
            var entry = output.CreateEntry(name, CompressionLevel.Optimal);
            using var stream = entry.Open();
            stream.Write(bytes);
        }
        return destination;
    }

    [Fact]
    public void AppIconGeneratorRendersEveryTemplateSizeFromTheCover()
    {
        using var temp = new TempDir();
        var cover = temp.Bytes("cover.png", RenderPng(48, 48, new SKColor(200, 40, 40)));
        var template = new List<AppIconGenerator.TemplateIcon>
        {
            new("a.png", 20, 20),
            new("b.png", 120, 120),
            new("c.png", 1024, 1024),
        };

        var rendered = AppIconGenerator.Render(cover, template);

        Assert.NotNull(rendered);
        Assert.Equal(3, rendered!.Count);
        Assert.Equal((20, 20), AppIconGenerator.PngSize(rendered["a.png"]));
        Assert.Equal((120, 120), AppIconGenerator.PngSize(rendered["b.png"]));
        Assert.Equal((1024, 1024), AppIconGenerator.PngSize(rendered["c.png"]));
        Assert.Null(AppIconGenerator.Render(null, template));
        Assert.Null(AppIconGenerator.Render(temp.Path + "/missing.png", template));
    }

    [Fact]
    public async Task ExportsUnsignedSingleGameIpaWithEmbeddedRomAutoLaunchAndGameIcons()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var cover = temp.Bytes("cover.png", RenderPng(48, 48, new SKColor(10, 200, 10)));
        var rom = FakeRomFile(temp);
        var runner = CatalogRunner(CatalogJson());
        var exporter = new SingleGameIpaExporter(new PackCli(runner, "pack", Path.Combine(temp.Path, "out")));
        var outputDir = Path.Combine(temp.Path, "exports");

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", "CTR-P-DEMO", 1, packPath),
            cover,
            rom,
            "0.2.2",
            outputDir);

        Assert.True(result.Ok, result.Error);
        Assert.NotNull(result.IpaPath);
        Assert.True(File.Exists(result.IpaPath));
        Assert.Equal(Path.Combine(outputDir, TitleId + "-Demo.ipa"), result.IpaPath);
        var displayName = ReadPlistValue(result.IpaPath!, "CFBundleDisplayName");
        Assert.Equal("Demo", displayName);
        Assert.Equal("Demo", ReadPlistValue(result.IpaPath!, "CFBundleName"));
        Assert.Equal(15, result.ReplacedIconCount);
        Assert.Equal(1, result.GameCount);
        Assert.True(result.Bytes > 0);
        Assert.Equal(FakeRom.Length, result.RomBytes);
        Assert.Equal("Roms/" + TitleId + ".cci", result.RomRelativePath);
        Assert.Contains(result.Warnings, warning => warning.Contains("game data", StringComparison.OrdinalIgnoreCase));
        var sha = Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(result.IpaPath!)));
        Assert.Equal(sha, result.Sha256);
        Assert.Contains(runner.Requests, request => request.Arguments.Contains("--auto-launch"));
        Assert.Contains(runner.Requests, request => request.Arguments.Contains("--catalog-out"));

        var verification = SingleGameIpaExporter.VerifyStructure(result.IpaPath!, TitleId);
        Assert.True(verification.Ok, verification.Error);

        using var archive = ZipFile.OpenRead(result.IpaPath!);
        var catalogEntry = archive.GetEntry("Payload/demo.app/GameCatalog.json");
        Assert.NotNull(catalogEntry);
        using (var reader = new StreamReader(catalogEntry!.Open()))
        using (var catalog = JsonDocument.Parse(reader.ReadToEnd()))
        {
            Assert.True(catalog.RootElement.GetProperty("autoLaunch").GetBoolean());
            Assert.Equal(1, catalog.RootElement.GetProperty("games").GetArrayLength());
            var game = catalog.RootElement.GetProperty("games")[0];
            Assert.Equal(TitleId, game.GetProperty("titleID").GetString());
            Assert.Equal("Roms/" + TitleId + ".cci", game.GetProperty("romFile").GetString());
        }
        Assert.NotNull(archive.GetEntry("Payload/demo.app/Frameworks/GamePack-" + TitleId + ".dylib"));
        var romEntry = archive.GetEntry("Payload/demo.app/Roms/" + TitleId + ".cci");
        Assert.NotNull(romEntry);
        using (var stream = romEntry!.Open())
        using (var memory = new MemoryStream())
        {
            stream.CopyTo(memory);
            Assert.Equal(FakeRom, memory.ToArray());
        }
        var romEntries = archive.Entries
            .Where(entry => entry.FullName.Contains("/Roms/", StringComparison.OrdinalIgnoreCase))
            .ToList();
        Assert.Single(romEntries);

        // Every template icon was replaced by the cover at the template's pixel size.
        foreach (var (name, pixel) in TemplateIcons)
        {
            var entry = archive.GetEntry("Payload/demo.app/" + name);
            Assert.NotNull(entry);
            using var stream = entry!.Open();
            using var memory = new MemoryStream();
            stream.CopyTo(memory);
            Assert.Equal((pixel, pixel), AppIconGenerator.PngSize(memory.ToArray()));
        }
    }

    [Fact]
    public async Task HonoursACustomOutputFileName()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = FakeRomFile(temp);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));
        var outputDir = Path.Combine(temp.Path, "exports");

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            outputDir,
            outputFileName: "my-game-unsigned.ipa");

        Assert.True(result.Ok, result.Error);
        Assert.Equal(Path.Combine(outputDir, "my-game-unsigned.ipa"), result.IpaPath);
        Assert.True(File.Exists(result.IpaPath));
        Assert.True(SingleGameIpaExporter.VerifyStructure(result.IpaPath!, TitleId).Ok);
    }

    [Fact]
    public async Task MissingRomFailsWithAnActionableError()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var noRom = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            romPath: null,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(noRom.Ok);
        Assert.Contains("ROM", noRom.Error);
        Assert.Contains("embeds", noRom.Error, StringComparison.OrdinalIgnoreCase);

        var missingFile = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            Path.Combine(temp.Path, "gone.cci"),
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(missingFile.Ok);
        Assert.Contains("ROM", missingFile.Error);
    }

    [Fact]
    public async Task UnsupportedRomExtensionIsRefused()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = temp.Bytes("game.cia", FakeRom);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));

        Assert.False(result.Ok);
        Assert.Contains(".cci", result.Error);
        Assert.Contains("ROM", result.Error);
    }

    [Fact]
    public async Task RomExtensionIsNormalisedToLowerCaseInTheBundle()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = temp.Bytes("Example Game.3DS", FakeRom);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));

        Assert.True(result.Ok, result.Error);
        Assert.Equal("Roms/" + TitleId + ".3ds", result.RomRelativePath);
        using var archive = ZipFile.OpenRead(result.IpaPath!);
        Assert.NotNull(archive.GetEntry("Payload/demo.app/Roms/" + TitleId + ".3ds"));
        Assert.True(SingleGameIpaExporter.VerifyStructure(result.IpaPath!, TitleId).Ok);
    }

    [Fact]
    public async Task StructureGateRequiresExactlyOneMatchingRomsEntry()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = FakeRomFile(temp);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.True(result.Ok, result.Error);

        // An extra (unlisted) Roms/ entry is refused.
        var extra = RewriteIpa(result.IpaPath!, Path.Combine(temp.Path, "extra.ipa"), entries =>
        {
            entries.Add(("Payload/demo.app/Roms/extra.cci", new byte[] { 1, 2, 3 }));
        });
        var extraVerification = SingleGameIpaExporter.VerifyStructure(extra, TitleId);
        Assert.False(extraVerification.Ok);
        Assert.Contains("exactly one", extraVerification.Error);

        // A catalogue without romFile is refused.
        var missingCatalogRom = RewriteIpa(result.IpaPath!, Path.Combine(temp.Path, "missing-romfile.ipa"), entries =>
        {
            for (var index = 0; index < entries.Count; index++)
            {
                if (!entries[index].Name.EndsWith("GameCatalog.json", StringComparison.Ordinal))
                {
                    continue;
                }
                using var document = JsonDocument.Parse(entries[index].Bytes);
                var game = new Dictionary<string, object?>();
                foreach (var property in document.RootElement.GetProperty("games")[0].EnumerateObject())
                {
                    if (property.Name == "romFile")
                    {
                        continue;
                    }
                    game[property.Name] = property.Value.Clone();
                }
                var catalog = new Dictionary<string, object?>
                {
                    ["schemaVersion"] = 2,
                    ["autoLaunch"] = true,
                    ["games"] = new[] { game },
                };
                entries[index] = (entries[index].Name, JsonSerializer.SerializeToUtf8Bytes(catalog));
            }
        });
        var catalogVerification = SingleGameIpaExporter.VerifyStructure(missingCatalogRom, TitleId);
        Assert.False(catalogVerification.Ok);
        Assert.Contains("romFile", catalogVerification.Error);
    }

    [Fact]
    public async Task MissingCoverKeepsTemplateIconsAndWarns()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = FakeRomFile(temp);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            coverPath: null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));

        Assert.True(result.Ok, result.Error);
        Assert.Equal(0, result.ReplacedIconCount);
        Assert.Contains(result.Warnings, warning => warning.Contains("cover", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task RejectsInvalidTemplatePackAndCatalogFailures()
    {
        using var temp = new TempDir();
        var rom = FakeRomFile(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var noTemplate = await exporter.ExportAsync(
            Path.Combine(temp.Path, "missing-template.ipa"),
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(noTemplate.Ok);
        Assert.Contains("template", noTemplate.Error, StringComparison.OrdinalIgnoreCase);

        var template = BuildTemplate(temp);
        var noPack = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, Path.Combine(temp.Path, "missing.dylib")),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(noPack.Ok);
        Assert.Contains("GamePack", noPack.Error);

        var failing = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson(), fail: true), "pack", Path.Combine(temp.Path, "out")));
        var catalogFailed = await failing.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            rom,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(catalogFailed.Ok);
        Assert.Contains("catalog", catalogFailed.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void OutputFileNameMatchesTheBuildPackageBaseName()
    {
        var name = SingleGameIpaExporter.OutputFileName("Demo Game", TitleId);
        Assert.Equal(TitleId + "-Demo Game.ipa", name);
        Assert.DoesNotContain("unsigned", name, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("0.2.2", name, StringComparison.Ordinal);

        // Illegal file-name characters become '_' (same sanitizer as the .32a name).
        Assert.Equal(TitleId + "-Demo_Game_ X_.ipa", SingleGameIpaExporter.OutputFileName("Demo/Game: X?", TitleId));
        Assert.Equal(TitleId + "-game.ipa", SingleGameIpaExporter.OutputFileName("   ", TitleId));
        Assert.Equal("0004000000055E00-示例游戏.ipa", SingleGameIpaExporter.OutputFileName("示例游戏", "0004000000055e00"));
        Assert.Equal(TitleId + "-Demo Game.32a", ExportNaming.BuildPackageFileName("Demo Game", TitleId));
    }

    [Fact]
    public async Task AppDisplayNameIsLocalizedFromGameInfoDisplayNames()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var rom = FakeRomFile(temp);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));
        var outputDir = Path.Combine(temp.Path, "exports");

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", "CTR-P-DEMO", 1, packPath),
            null,
            rom,
            "0.2.2",
            outputDir,
            displayNames: new Dictionary<string, string> { ["en"] = "Demo", ["zh-Hans"] = "演示游戏" });

        Assert.True(result.Ok, result.Error);
        using var archive = ZipFile.OpenRead(result.IpaPath!);
        Assert.Equal("Demo", ReadPlistValue(archive, "Payload/demo.app/Info.plist", "CFBundleDisplayName"));
        var chinese = ReadEntryText(archive, "Payload/demo.app/zh-Hans.lproj/InfoPlist.strings");
        Assert.Contains("演示游戏", chinese, StringComparison.Ordinal);
        Assert.Contains("CFBundleDisplayName", chinese, StringComparison.Ordinal);
        var english = ReadEntryText(archive, "Payload/demo.app/en.lproj/InfoPlist.strings");
        Assert.Contains("Demo", english, StringComparison.Ordinal);
        // Bundle id is untouched by the display-name rewrite.
        Assert.Null(archive.GetEntry("Payload/demo.app/Info.plist.bak"));
    }

    private static string ReadPlistValue(string ipaPath, string key)
    {
        using var archive = ZipFile.OpenRead(ipaPath);
        return ReadPlistValue(archive, "Payload/demo.app/Info.plist", key);
    }

    private static string ReadPlistValue(ZipArchive archive, string entryName, string key)
    {
        var entry = archive.GetEntry(entryName) ?? throw new InvalidOperationException("missing " + entryName);
        using var stream = entry.Open();
        using var reader = new StreamReader(stream);
        var document = System.Xml.Linq.XDocument.Parse(reader.ReadToEnd());
        var values = document.Root?.Elements().FirstOrDefault()?.Elements().ToList() ?? new List<System.Xml.Linq.XElement>();
        for (var index = 0; index + 1 < values.Count; index += 2)
        {
            if (values[index].Value == key)
            {
                return values[index + 1].Value;
            }
        }
        throw new InvalidOperationException("missing plist key " + key);
    }

    private static string ReadEntryText(ZipArchive archive, string entryName)
    {
        var entry = archive.GetEntry(entryName) ?? throw new InvalidOperationException("missing " + entryName);
        using var stream = entry.Open();
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }
}
