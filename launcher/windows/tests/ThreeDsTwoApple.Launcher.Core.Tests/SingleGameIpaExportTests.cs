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
/// autoLaunch catalogue + the SMDH cover replacing the template AppIcon*.png set.
/// The composition reuses IpaComposer, so these tests cover the exporter layer,
/// the icon generator and the structure gate only (no signing, no device).
/// </summary>
public sealed class SingleGameIpaExportTests
{
    private const string TitleId = "0004000000055E00";
    private static readonly byte[] MachOMagic = { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0 };

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
    public async Task ExportsUnsignedSingleGameIpaWithAutoLaunchAndGameIcons()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var cover = temp.Bytes("cover.png", RenderPng(48, 48, new SKColor(10, 200, 10)));
        var runner = CatalogRunner(CatalogJson());
        var exporter = new SingleGameIpaExporter(new PackCli(runner, "pack", Path.Combine(temp.Path, "out")));
        var outputDir = Path.Combine(temp.Path, "exports");

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", "CTR-P-DEMO", 1, packPath),
            cover,
            "0.2.2",
            outputDir);

        Assert.True(result.Ok, result.Error);
        Assert.NotNull(result.IpaPath);
        Assert.True(File.Exists(result.IpaPath));
        Assert.EndsWith("-unsigned.ipa", result.IpaPath);
        Assert.Contains("0.2.2", Path.GetFileName(result.IpaPath));
        Assert.Equal(15, result.ReplacedIconCount);
        Assert.Empty(result.Warnings);
        Assert.Equal(1, result.GameCount);
        Assert.True(result.Bytes > 0);
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
            Assert.Equal(TitleId, catalog.RootElement.GetProperty("games")[0].GetProperty("titleID").GetString());
        }
        Assert.NotNull(archive.GetEntry("Payload/demo.app/Frameworks/GamePack-" + TitleId + ".dylib"));
        Assert.DoesNotContain(archive.Entries, entry => entry.FullName.Contains("/Roms/", StringComparison.OrdinalIgnoreCase));

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
    public async Task MissingCoverKeepsTemplateIconsAndWarns()
    {
        using var temp = new TempDir();
        var template = BuildTemplate(temp);
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var result = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            coverPath: null,
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
        var packPath = temp.Bytes("GamePack.dylib", MachOMagic);
        var exporter = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson()), "pack", Path.Combine(temp.Path, "out")));

        var noTemplate = await exporter.ExportAsync(
            Path.Combine(temp.Path, "missing-template.ipa"),
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(noTemplate.Ok);
        Assert.Contains("template", noTemplate.Error, StringComparison.OrdinalIgnoreCase);

        var template = BuildTemplate(temp);
        var noPack = await exporter.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, Path.Combine(temp.Path, "missing.dylib")),
            null,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(noPack.Ok);
        Assert.Contains("GamePack", noPack.Error);

        var failing = new SingleGameIpaExporter(new PackCli(CatalogRunner(CatalogJson(), fail: true), "pack", Path.Combine(temp.Path, "out")));
        var catalogFailed = await failing.ExportAsync(
            template,
            new ComposedPack(TitleId, "Demo", null, 1, packPath),
            null,
            "0.2.2",
            Path.Combine(temp.Path, "exports"));
        Assert.False(catalogFailed.Ok);
        Assert.Contains("catalog", catalogFailed.Error, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void OutputFileNameIsUnsignedAndCarriesTheSlug()
    {
        var name = SingleGameIpaExporter.OutputFileName("Demo Game", TitleId, "0.2.2");
        Assert.EndsWith("-0.2.2-unsigned.ipa", name);
        Assert.Contains("00055e00", name);
        Assert.DoesNotContain(" ", name);
    }
}
