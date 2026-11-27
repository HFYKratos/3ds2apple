using System.Text;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Portable file-name rules for both Library exports (0.2.2-beta4):
///   .32a  -> TITLE_ID-English name.32a (written by the Rust pack CLI)
///   IPA   -> TITLE_ID-English name.ipa (same base name as .32a; written here)
/// Illegal file-name characters become '_'; the title ID is upper-case.
/// </summary>
public static class ExportNaming
{
    /// <summary>Longest game-name component in UTF-8 bytes (TITLE_ID-name.ext stays under 255).</summary>
    public const int MaxNameBytes = 120;

    /// <summary>Characters Windows/macOS forbid in a file name (sufficient on every host).</summary>
    private static readonly char[] InvalidCharacters = { '<', '>', ':', '"', '/', '\\', '|', '?', '*' };

    /// <summary>True when the character cannot appear in a portable file name.</summary>
    public static bool IsInvalid(char character) =>
        character < 32 || InvalidCharacters.Contains(character);

    /// <summary>
    /// Sanitize a game name for a file name: invalid characters become '_', runs of
    /// underscores collapse, leading/trailing dots/spaces are removed and an empty
    /// name falls back to "game". CJK names are kept as-is (NTFS/APFS accept them).
    /// </summary>
    public static string SanitizeName(string? gameName)
    {
        if (string.IsNullOrWhiteSpace(gameName))
        {
            return "game";
        }
        var builder = new StringBuilder(gameName.Trim().Length);
        var bytes = 0;
        foreach (var character in gameName.Trim())
        {
            var mapped = IsInvalid(character) ? '_' : character;
            var added = System.Text.Encoding.UTF8.GetByteCount(mapped.ToString());
            if (bytes + added > MaxNameBytes)
            {
                break;
            }
            bytes += added;
            builder.Append(mapped);
        }
        var cleaned = builder.ToString().TrimEnd('.', ' ');
        return string.IsNullOrWhiteSpace(cleaned) ? "game" : cleaned;
    }

    /// <summary>Upper-case TITLE_ID (0004000000055E00).</summary>
    public static string NormalizeTitleId(string? titleId) =>
        (titleId ?? string.Empty).Trim().ToUpperInvariant();

    /// <summary>TITLE_ID-GameName.32a (mirrors builder/pack/src/builds.rs).</summary>
    public static string BuildPackageFileName(string gameName, string titleId) =>
        NormalizeTitleId(titleId) + "-" + SanitizeName(gameName) + ".32a";

    /// <summary>TITLE_ID-GameName.ipa (no launcher version / "unsigned" suffix any more).</summary>
    public static string IpaFileName(string gameName, string titleId) =>
        NormalizeTitleId(titleId) + "-" + SanitizeName(gameName) + ".ipa";
}
