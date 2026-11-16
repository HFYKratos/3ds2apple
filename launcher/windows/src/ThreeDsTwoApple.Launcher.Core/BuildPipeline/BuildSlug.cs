using System.Text;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>Builds a deterministic ASCII build slug the local build scripts accept.</summary>
public static class BuildSlug
{
    public static string From(string displayName, string titleId)
    {
        var normalized = (displayName ?? string.Empty).Normalize(NormalizationForm.FormD);
        var builder = new StringBuilder();
        var lastWasDash = false;
        foreach (var c in normalized)
        {
            if (c is >= 'A' and <= 'Z')
            {
                builder.Append(char.ToLowerInvariant(c));
                lastWasDash = false;
            }
            else if (c is >= 'a' and <= 'z' or >= '0' and <= '9')
            {
                builder.Append(c);
                lastWasDash = false;
            }
            else if (System.Globalization.CharUnicodeInfo.GetUnicodeCategory(c) == System.Globalization.UnicodeCategory.NonSpacingMark)
            {
                continue;
            }
            else if (!lastWasDash && builder.Length > 0)
            {
                builder.Append('-');
                lastWasDash = true;
            }
        }
        var slug = builder.ToString().Trim('-');
        if (slug.Length > 40)
        {
            slug = slug[..40].TrimEnd('-');
        }
        var suffix = titleId.Length >= 8 ? titleId[^8..].ToLowerInvariant() : titleId.ToLowerInvariant();
        return slug.Length == 0 ? "game-" + suffix : slug + "-" + suffix;
    }
}
