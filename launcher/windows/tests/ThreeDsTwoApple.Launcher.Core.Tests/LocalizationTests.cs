using ThreeDsTwoApple.Launcher.Core.Distribution;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Localization;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

public sealed class LocalizationTests
{
    [Theory]
    [InlineData(null, "en")]
    [InlineData("", "en")]
    [InlineData("en-US", "en")]
    [InlineData("de-DE", "en")]
    [InlineData("zh", "zh-Hans")]
    [InlineData("zh-CN", "zh-Hans")]
    [InlineData("zh-Hans", "zh-Hans")]
    [InlineData("zh_CN", "zh-Hans")]
    [InlineData("zh-SG", "zh-Hans")]
    [InlineData("zh-TW", "en")]
    [InlineData("zh-Hant", "en")]
    [InlineData("zh-HK", "en")]
    public void DetectsOsLanguage(string? culture, string expected) =>
        Assert.Equal(expected, LanguageCatalog.Detect(culture));

    [Theory]
    [InlineData("system", UiLanguagePreference.System)]
    [InlineData(null, UiLanguagePreference.System)]
    [InlineData("en", UiLanguagePreference.English)]
    [InlineData("English", UiLanguagePreference.English)]
    [InlineData("zh-Hans", UiLanguagePreference.SimplifiedChinese)]
    [InlineData("zh-cn", UiLanguagePreference.SimplifiedChinese)]
    [InlineData("简体中文", UiLanguagePreference.SimplifiedChinese)]
    public void ParsesPersistedPreference(string? value, UiLanguagePreference expected) =>
        Assert.Equal(expected, LanguageCatalog.ParsePreference(value));

    [Theory]
    [InlineData(UiLanguagePreference.System, "zh-CN", "zh-Hans")]
    [InlineData(UiLanguagePreference.System, "en-US", "en")]
    [InlineData(UiLanguagePreference.English, "zh-CN", "en")]
    [InlineData(UiLanguagePreference.SimplifiedChinese, "en-US", "zh-Hans")]
    public void ResolvesPreference(UiLanguagePreference preference, string culture, string expected) =>
        Assert.Equal(expected, LanguageCatalog.Resolve(preference, culture));

    [Fact]
    public void EnglishAndChineseDefineExactlyTheSameKeys()
    {
        var english = LanguageCatalog.English.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
        var chinese = LanguageCatalog.ChineseSimplified.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
        Assert.Equal(english, chinese);
        Assert.Equal(english, LanguageCatalog.Keys.OrderBy(key => key, StringComparer.Ordinal).ToList());
    }

    [Fact]
    public void NoCatalogStringIsBlank()
    {
        foreach (var key in LanguageCatalog.Keys)
        {
            Assert.False(string.IsNullOrWhiteSpace(LanguageCatalog.Text(LanguageCatalog.EnglishTag, key)), "blank English string: " + key);
            Assert.False(string.IsNullOrWhiteSpace(LanguageCatalog.Text(LanguageCatalog.ChineseSimplifiedTag, key)), "blank zh-Hans string: " + key);
        }
    }

    [Fact]
    public void FormatPlaceholdersMatchBetweenLanguages()
    {
        foreach (var key in LanguageCatalog.Keys)
        {
            var english = LanguageCatalog.Placeholders(LanguageCatalog.English[key]);
            var chinese = LanguageCatalog.Placeholders(LanguageCatalog.ChineseSimplified[key]);
            Assert.Equal(english.OrderBy(token => token, StringComparer.Ordinal), chinese.OrderBy(token => token, StringComparer.Ordinal));
            Assert.True(LanguageCatalog.ChineseSimplified.ContainsKey(key), "zh-Hans is missing " + key);
            Assert.True(LanguageCatalog.English.ContainsKey(key), "English is missing " + key);
        }
    }

    [Fact]
    public void UnknownKeyFallsBackToTheKeyItself()
    {
        Assert.Equal("no.such.key", LanguageCatalog.Text(LanguageCatalog.EnglishTag, "no.such.key"));
        Assert.Equal("no.such.key", LanguageCatalog.Text(LanguageCatalog.ChineseSimplifiedTag, "no.such.key"));
    }

    [Fact]
    public void FormatsArgumentsInBothLanguages()
    {
        Assert.Equal("3 game(s)", LanguageCatalog.Format("en", "library.count", 3));
        Assert.Equal("3 个游戏", LanguageCatalog.Format("zh-Hans", "library.count", 3));
    }

    [Fact]
    public void LocAppliesPreferenceAndSwitchesLiveText()
    {
        try
        {
            Loc.ApplyPreference(UiLanguagePreference.SimplifiedChinese);
            Assert.Equal("zh-Hans", Loc.CurrentTag);
            Assert.Equal("游戏库", Loc.T("nav.library"));
            Assert.Equal("导入", Loc.T("nav.import"));

            Loc.ApplyPreference(UiLanguagePreference.English);
            Assert.Equal("en", Loc.CurrentTag);
            Assert.Equal("Library", Loc.T("nav.library"));

            Loc.ApplyPreference(UiLanguagePreference.System, "zh-CN");
            Assert.Equal("zh-Hans", Loc.CurrentTag);
            Assert.Equal("设置", Loc.T("settings.title"));

            Loc.ApplyPreference(UiLanguagePreference.System, "en-US");
            Assert.Equal("en", Loc.CurrentTag);
        }
        finally
        {
            Loc.ResetForTests();
        }
    }

    [Fact]
    public void LanguagePreferencePersistsInTheWorkspaceState()
    {
        using var temporary = new TempDir();
        var workspace = LauncherWorkspace.Open(temporary.Path);
        workspace.State.Language = LanguageCatalog.PreferenceKey(UiLanguagePreference.SimplifiedChinese);
        workspace.SaveState();

        var reopened = LauncherWorkspace.Open(temporary.Path);
        Assert.Equal("zh-Hans", reopened.State.Language);
        Assert.Equal(UiLanguagePreference.SimplifiedChinese, LanguageCatalog.ParsePreference(reopened.State.Language));
        Assert.Equal("system", new LauncherStateDocument().Language);
    }

    [Fact]
    public void NativeNamesAreSelfDescribing()
    {
        Assert.Equal("English", LanguageCatalog.NativeName(UiLanguagePreference.English));
        Assert.Equal("简体中文", LanguageCatalog.NativeName(UiLanguagePreference.SimplifiedChinese));
        Assert.Contains("English", LanguageCatalog.DisplayName(UiLanguagePreference.System, LanguageCatalog.EnglishTag));
        Assert.Contains("简体中文", LanguageCatalog.DisplayName(UiLanguagePreference.System, LanguageCatalog.ChineseSimplifiedTag));
    }
}

public sealed class DistributionLayoutTests
{
    [Theory]
    [InlineData("Payload/Shell/manifest.json", "Shell/manifest.json")]
    [InlineData("Payload/Bin/devpush.exe", "Bin/devpush.exe")]
    [InlineData("Shell/manifest.json", "")]
    [InlineData("Payload/../escape.txt", "")]
    [InlineData("Payload//absolute", "")]
    public void MapsResourceNamesToSafeRelativePaths(string resource, string expected) =>
        Assert.Equal(expected, DistributionLayout.ToSafeRelativePath(resource));

    [Theory]
    [InlineData("Shell/manifest.json", true)]
    [InlineData("Bin/3ds2apple-pack.exe", true)]
    [InlineData("../escape", false)]
    [InlineData("a/../b", false)]
    [InlineData("/etc/passwd", false)]
    [InlineData("C:/Windows/system32", false)]
    [InlineData("", false)]
    public void RejectsUnsafeRelativePaths(string path, bool expected) =>
        Assert.Equal(expected, DistributionLayout.IsSafeRelativePath(path));

    [Fact]
    public void ExpectedPayloadPathsAreSafeAndUnique()
    {
        var expected = DistributionLayout.ExpectedRelativePaths;
        Assert.Equal(expected.Count, expected.Distinct(StringComparer.Ordinal).Count());
        foreach (var path in expected)
        {
            Assert.True(DistributionLayout.IsSafeRelativePath(path), "unsafe expected path: " + path);
        }
        Assert.Contains("Shell/3ds2apple-shell.ipa", expected);
        Assert.Contains("ThirdParty/Impactor/plumesign-windows-x86_64.exe", expected);
        Assert.Contains("Bin/devpush.exe", expected);
        Assert.Contains("licenses/NOTICE", expected);
    }

    [Fact]
    public void EmbeddedInventoryIsEmptyOrMapsOnlySafePaths()
    {
        var inventory = DistributionLayout.PayloadInventory(typeof(DistributionLayout).Assembly);
        Assert.Equal(inventory.Select(file => file.RelativePath).Distinct(StringComparer.Ordinal).Count(), inventory.Count);
        foreach (var file in inventory)
        {
            Assert.StartsWith(DistributionLayout.PayloadResourcePrefix, file.ResourceName, StringComparison.Ordinal);
            Assert.True(DistributionLayout.IsSafeRelativePath(file.RelativePath), "unsafe embedded path: " + file.RelativePath);
            Assert.True(file.Bytes > 0, "empty embedded file: " + file.RelativePath);
        }
        if (inventory.Count > 0)
        {
            var embedded = inventory.Select(file => file.RelativePath).ToHashSet(StringComparer.Ordinal);
            Assert.All(DistributionLayout.ExpectedRelativePaths, path => Assert.Contains(path, embedded));
        }
    }

    [Fact]
    public void NeedsExtractionDetectsMissingAndStaleFiles()
    {
        using var temporary = new TempDir();
        var root = Path.Combine(temporary.Path, "distribution");
        var payload = new[] { new EmbeddedFile("Payload/Bin/3ds2apple-pack.exe", "Bin/3ds2apple-pack.exe", 3) };

        Assert.True(DistributionLayout.NeedsExtraction(root, payload));

        Directory.CreateDirectory(Path.Combine(root, "Bin"));
        File.WriteAllBytes(Path.Combine(root, "Bin", "3ds2apple-pack.exe"), new byte[] { 1, 2 });
        Assert.True(DistributionLayout.NeedsExtraction(root, payload));

        File.WriteAllBytes(Path.Combine(root, "Bin", "3ds2apple-pack.exe"), new byte[] { 1, 2, 3 });
        Assert.True(DistributionLayout.NeedsExtraction(root, payload));

        File.WriteAllText(Path.Combine(root, DistributionLayout.MarkerFileName), "{}");
        Assert.False(DistributionLayout.NeedsExtraction(root, payload));

        File.Delete(Path.Combine(root, "Bin", "3ds2apple-pack.exe"));
        Assert.True(DistributionLayout.NeedsExtraction(root, payload));
    }

    [Fact]
    public void ReadManifestReturnsNullForMissingMarker()
    {
        using var temporary = new TempDir();
        Assert.Null(DistributionLayout.ReadManifest(temporary.Path));
        File.WriteAllText(Path.Combine(temporary.Path, DistributionLayout.MarkerFileName), "not json");
        Assert.Null(DistributionLayout.ReadManifest(temporary.Path));
    }

    [Fact]
    public void DefaultExtractionRootLivesUnderLocalAppData()
    {
        var root = DistributionLayout.DefaultExtractionRoot();
        Assert.EndsWith(Path.Combine("distribution", LauncherInfo.Version), root);
        Assert.Contains("3ds2apple", root);
    }
}
