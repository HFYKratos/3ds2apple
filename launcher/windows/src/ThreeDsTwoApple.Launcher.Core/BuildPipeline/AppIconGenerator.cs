using SkiaSharp;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Renders the game's SMDH cover into the shell template's AppIcon*.png set for a
/// single-game IPA export (Windows launcher; the macOS launcher uses NSImage).
///
/// The template ships 15 icons (20/29/40/60/76/83.5 pt plus @2x/@3x and the
/// 1024 px App Store slot). The SMDH icon is 48x48, so upscaled icons are
/// visibly soft but recognisable; the caller keeps the template icons and shows
/// a warning when the game has no cover at all.
/// </summary>
public static class AppIconGenerator
{
    /// <summary>One template icon: bundle entry name plus its decoded pixel size.</summary>
    public sealed record TemplateIcon(string EntryName, int PixelWidth, int PixelHeight);

    /// <summary>
    /// Decode a PNG byte array and report its pixel size; null when it is not a
    /// readable image (the caller then leaves that template entry untouched).
    /// </summary>
    public static (int Width, int Height)? PngSize(byte[] bytes)
    {
        if (bytes is null || bytes.Length == 0)
        {
            return null;
        }
        using var bitmap = SKBitmap.Decode(bytes);
        return bitmap is null ? null : (bitmap.Width, bitmap.Height);
    }

    /// <summary>
    /// Render the cover into every template icon size. Returns one entry per
    /// template icon that could be rendered, or null when the cover cannot be
    /// read (missing/unreadable PNG): the caller then keeps the template icons.
    /// </summary>
    public static IReadOnlyDictionary<string, byte[]>? Render(
        string? coverPath,
        IReadOnlyList<TemplateIcon> templateIcons)
    {
        if (string.IsNullOrWhiteSpace(coverPath) || !File.Exists(coverPath) || templateIcons.Count == 0)
        {
            return null;
        }
        using var cover = SKBitmap.Decode(coverPath);
        if (cover is null || cover.Width <= 0 || cover.Height <= 0)
        {
            return null;
        }
        var rendered = new Dictionary<string, byte[]>(StringComparer.OrdinalIgnoreCase);
        var sampling = new SKSamplingOptions(SKFilterMode.Linear, SKMipmapMode.Linear);
        foreach (var icon in templateIcons)
        {
            if (icon.PixelWidth <= 0 || icon.PixelHeight <= 0)
            {
                continue;
            }
            var info = new SKImageInfo(icon.PixelWidth, icon.PixelHeight, SKColorType.Rgba8888, SKAlphaType.Premul);
            using var resized = cover.Resize(info, sampling);
            if (resized is null)
            {
                continue;
            }
            using var image = SKImage.FromBitmap(resized);
            using var encoded = image.Encode(SKEncodedImageFormat.Png, 100);
            if (encoded is not null && encoded.Size > 0)
            {
                rendered[icon.EntryName] = encoded.ToArray();
            }
        }
        return rendered.Count == 0 ? null : rendered;
    }

    /// <summary>
    /// Decode every template icon so the exporter knows the exact pixel size to
    /// render for each bundle entry (instead of parsing the iOS icon names).
    /// </summary>
    public static IReadOnlyList<TemplateIcon> ReadTemplateIcons(
        IEnumerable<(string EntryName, byte[] Png)> entries)
    {
        var icons = new List<TemplateIcon>();
        foreach (var (entryName, png) in entries)
        {
            var size = PngSize(png);
            if (size is { } value)
            {
                icons.Add(new TemplateIcon(entryName, value.Width, value.Height));
            }
        }
        return icons;
    }
}
