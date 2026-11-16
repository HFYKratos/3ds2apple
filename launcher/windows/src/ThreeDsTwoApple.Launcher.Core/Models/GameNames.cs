namespace ThreeDsTwoApple.Launcher.Core.Models;

/// <summary>
/// Display metadata helpers for a ROM/package. The 3ds2apple-pack CLI supplies a
/// <c>displayNames</c> map (BCP-47 keys extracted from the ROM's SMDH), a
/// <c>publisher</c> and a package-relative <c>cover.png</c>; the launcher must pick
/// the name for the current UI language instead of asking the user to type one.
/// </summary>
public static class GameNames
{
    /// <summary>Zoomed key priority for the Simplified Chinese UI (BCP-47 spellings seen in SMDH/CLI).</summary>
    private static readonly string[] ChineseKeys = { "zh-Hans", "zh-CN", "zh-SG", "zh" };

    /// <summary>Zoomed key priority for the English UI.</summary>
    private static readonly string[] EnglishKeys = { "en", "en-US", "en-GB" };

    /// <summary>
    /// Pick the best available name for <paramref name="uiLanguageTag"/>: exact language,
    /// then English, then the default display name, then any non-empty entry.
    /// </summary>
    public static string Resolve(IReadOnlyDictionary<string, string>? displayNames, string? displayName, string? uiLanguageTag)
    {
        var fallback = string.IsNullOrWhiteSpace(displayName) ? string.Empty : displayName.Trim();
        if (displayNames is null || displayNames.Count == 0)
        {
            return fallback;
        }
        var normalized = NormalizeTag(uiLanguageTag);
        var preferred = normalized == "zh-Hans" ? ChineseKeys : EnglishKeys;
        foreach (var key in preferred)
        {
            var value = Lookup(displayNames, key);
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }
        // Any UI language falls back to English first, then to the default name.
        if (!string.IsNullOrWhiteSpace(fallback))
        {
            return fallback;
        }
        foreach (var key in displayNames.Keys.OrderBy(key => key, StringComparer.OrdinalIgnoreCase))
        {
            var value = displayNames[key];
            if (!string.IsNullOrWhiteSpace(value))
            {
                return value.Trim();
            }
        }
        return fallback;
    }

    /// <summary>Normalize a UI language tag to the two languages the launcher ships.</summary>
    public static string NormalizeTag(string? uiLanguageTag)
    {
        if (string.IsNullOrWhiteSpace(uiLanguageTag))
        {
            return "en";
        }
        var tag = uiLanguageTag.Trim().Replace('_', '-').ToLowerInvariant();
        if (tag.StartsWith("zh", StringComparison.Ordinal))
        {
            // Traditional Chinese is not translated; the documented fallback is English.
            if (tag.Contains("hant", StringComparison.Ordinal) || tag.Contains("-tw", StringComparison.Ordinal)
                || tag.Contains("-hk", StringComparison.Ordinal) || tag.Contains("-mo", StringComparison.Ordinal))
            {
                return "en";
            }
            return "zh-Hans";
        }
        return "en";
    }

    /// <summary>Resolve the cover image path of a package; relative CLI values are package-relative.</summary>
    public static string? ResolveCoverPath(string? packageDirectory, string? coverPath)
    {
        if (string.IsNullOrWhiteSpace(coverPath))
        {
            if (string.IsNullOrWhiteSpace(packageDirectory))
            {
                return null;
            }
            var conventional = Path.Combine(packageDirectory, "cover.png");
            return File.Exists(conventional) ? conventional : null;
        }
        try
        {
            if (Path.IsPathRooted(coverPath))
            {
                return File.Exists(coverPath) ? Path.GetFullPath(coverPath) : null;
            }
            if (string.IsNullOrWhiteSpace(packageDirectory))
            {
                return null;
            }
            var combined = Path.GetFullPath(Path.Combine(packageDirectory, coverPath));
            return File.Exists(combined) ? combined : null;
        }
        catch (Exception exception) when (exception is IOException or ArgumentException or NotSupportedException)
        {
            return null;
        }
    }

    /// <summary>Trim a publisher string; empty when unknown.</summary>
    public static string ResolvePublisher(string? publisher) => string.IsNullOrWhiteSpace(publisher) ? string.Empty : publisher.Trim();

    private static string? Lookup(IReadOnlyDictionary<string, string> names, string wanted)
    {
        if (names.TryGetValue(wanted, out var direct))
        {
            return direct;
        }
        foreach (var pair in names)
        {
            if (string.Equals(pair.Key, wanted, StringComparison.OrdinalIgnoreCase))
            {
                return pair.Value;
            }
        }
        return null;
    }
}
