using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>ROM metadata (SMDH displayNames/publisher/cover.png) from the pack CLI JSON and helpers.</summary>
public sealed class RomMetadataParsingTests
{
    private const string PackagesListJson = """
        {
          "errors": [],
          "packages": [
            {
              "titleID": "0004000000055E00",
              "displayName": "Pokemon Y",
              "productCode": "CTR-P-EK2A",
              "aotVersion": 1,
              "state": "queued",
              "displayNames": { "en": "Pokemon Y", "zh-Hans": "宝可梦 Y", "ja": "ポケットモンスターY" },
              "publisher": "Nintendo",
              "coverPath": "/out/packages/0004000000055E00/cover.png"
            }
          ]
        }
        """;

    private const string PackagesAddJson = """
        {
          "errors": [],
          "packages": [
            {
              "titleID": "0004000000055E00",
              "displayName": "Pokemon Y",
              "productCode": "CTR-P-EK2A",
              "packageDir": "/out/packages/0004000000055E00",
              "romPath": "/ROM/Pokemon Y.cci",
              "status": "imported",
              "displayNames": { "en": "Pokemon Y", "zh-Hans": "宝可梦 Y" },
              "publisher": "Nintendo",
              "coverPath": "/out/packages/0004000000055E00/cover.png"
            }
          ]
        }
        """;

    [Fact]
    public async Task PackagesListParsesSmdhMetadata()
    {
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, PackagesListJson, string.Empty, false, true));
        var cli = new PackCli(runner, "3ds2apple-pack.exe", "/out");

        var result = await cli.ListAsync();

        var package = Assert.Single(result.Packages);
        Assert.Equal("Pokemon Y", package.DisplayName);
        Assert.NotNull(package.DisplayNames);
        Assert.Equal("宝可梦 Y", package.DisplayNames!["zh-Hans"]);
        Assert.Equal("Nintendo", package.Publisher);
        Assert.EndsWith("cover.png", package.CoverPath);
    }

    [Fact]
    public async Task PackagesAddParsesSmdhMetadata()
    {
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, PackagesAddJson, string.Empty, false, true));
        var cli = new PackCli(runner, "3ds2apple-pack.exe", "/out");

        var result = await cli.AddAsync(new[] { "/ROM/Pokemon Y.cci" }, null);

        var package = Assert.Single(result.Packages);
        Assert.Equal("/out/packages/0004000000055E00", package.PackageDir);
        Assert.NotNull(package.DisplayNames);
        Assert.Equal("Pokemon Y", package.DisplayNames!["en"]);
        Assert.Equal("Nintendo", package.Publisher);
        Assert.EndsWith("cover.png", package.CoverPath);
    }

    [Fact]
    public async Task AddAsyncPassesForceOnlyForReimports()
    {
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, PackagesAddJson, string.Empty, false, true));
        var cli = new PackCli(runner, "3ds2apple-pack.exe", "/out");

        await cli.AddAsync(new[] { "/ROM/Pokemon Y.cci" }, null);
        await cli.AddAsync(new[] { "/ROM/Pokemon Y.cci" }, null, force: true);

        Assert.DoesNotContain("--force", runner.Requests[0].Arguments);
        Assert.Contains("--force", runner.Requests[1].Arguments);
    }

    [Fact]
    public async Task OldCliJsonWithoutMetadataStillParses()
    {
        const string legacyJson = """
            {
              "errors": [],
              "packages": [
                {
                  "titleID": "0004000000055E00",
                  "displayName": "Pokemon Y",
                  "productCode": "CTR-P-EK2A",
                  "aotVersion": 1,
                  "state": "queued"
                }
              ]
            }
            """;
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, legacyJson, string.Empty, false, true));
        var cli = new PackCli(runner, "3ds2apple-pack.exe", "/out");

        var result = await cli.ListAsync();

        var package = Assert.Single(result.Packages);
        Assert.Null(package.DisplayNames);
        Assert.Null(package.Publisher);
        Assert.Null(package.CoverPath);
    }

    [Fact]
    public void NameSelectionPrefersTheUiLanguage()
    {
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["en"] = "Pokemon Y",
            ["zh-Hans"] = "宝可梦 Y",
            ["ja"] = "ポケットモンスターY",
        };

        Assert.Equal("宝可梦 Y", GameNames.Resolve(names, "Pokemon Y", "zh-Hans"));
        Assert.Equal("宝可梦 Y", GameNames.Resolve(names, "Pokemon Y", "zh-CN"));
        Assert.Equal("Pokemon Y", GameNames.Resolve(names, "Pokemon Y", "en"));
        Assert.Equal("Pokemon Y", GameNames.Resolve(names, "Pokemon Y", "de-DE"));
        Assert.Equal("Pokemon Y", GameNames.Resolve(names, "Pokemon Y", "zh-Hant"));
    }

    [Fact]
    public void NameSelectionFallsBackWithoutMapOrEnglishKey()
    {
        var onlyJapanese = new Dictionary<string, string> { ["ja"] = "テスト" };
        Assert.Equal("Default Name", GameNames.Resolve(null, "Default Name", "zh-Hans"));
        Assert.Equal("Default Name", GameNames.Resolve(onlyJapanese, "Default Name", "en"));
        Assert.Equal("テスト", GameNames.Resolve(onlyJapanese, string.Empty, "en"));
        Assert.Equal("Default Name", GameNames.Resolve(onlyJapanese, "Default Name", "zh-Hans"));
    }

    [Fact]
    public void PublisherAndCoverHelpers()
    {
        Assert.Equal("Nintendo", GameNames.ResolvePublisher("  Nintendo  "));
        Assert.Equal(string.Empty, GameNames.ResolvePublisher(null));

        using var temporary = new TempDir();
        var packageDir = Path.Combine(temporary.Path, "package");
        Directory.CreateDirectory(packageDir);
        var cover = Path.Combine(packageDir, "cover.png");
        File.WriteAllBytes(cover, new byte[] { 0x89, 0x50, 0x4E, 0x47 });

        Assert.Equal(Path.GetFullPath(cover), GameNames.ResolveCoverPath(packageDir, "cover.png"));
        Assert.Equal(Path.GetFullPath(cover), GameNames.ResolveCoverPath(packageDir, cover));
        Assert.Equal(Path.GetFullPath(cover), GameNames.ResolveCoverPath(packageDir, null));
        Assert.Null(GameNames.ResolveCoverPath(packageDir, "missing.png"));
        Assert.Null(GameNames.ResolveCoverPath(null, null));
    }
}
