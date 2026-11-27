using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>
/// Renames the composed single-game app on the device home screen (0.2.2-beta4):
/// the shell template ships CFBundleDisplayName "3ds2apple", but a single-game IPA
/// must show the game's name and localize it like the original SMDH titles.
/// The composer rewrites Payload/&lt;app&gt;/Info.plist (CFBundleDisplayName +
/// CFBundleName = English displayName) and adds Payload/&lt;app&gt;/&lt;lang&gt;.lproj/
/// InfoPlist.strings for every GameInfo.displayNames language (en always present),
/// so a Chinese device shows the Chinese name. The bundle id is untouched.
/// </summary>
public static class AppDisplayNameRewriter
{
    public const string InfoPlistName = "Info.plist";
    public const string InfoPlistStringsName = "InfoPlist.strings";

    private static readonly Regex LanguageTag = new("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", RegexOptions.Compiled);

    /// <summary>
    /// Rewrite Info.plist bytes (XML or binary) with CFBundleDisplayName and
    /// CFBundleName set to <paramref name="displayName"/>. The output is XML,
    /// which iOS accepts exactly like the original binary plist.
    /// </summary>
    public static byte[] RewriteInfoPlist(byte[] plistBytes, string displayName)
    {
        var plist = PlistReader.Read(plistBytes);
        plist["CFBundleDisplayName"] = displayName;
        plist["CFBundleName"] = displayName;
        return PlistXml.Write(plist);
    }

    /// <summary>
    /// lproj folder name -> display name. "en" always carries the English
    /// displayName (base fallback); every valid GameInfo.displayNames language is
    /// added with its localized SMDH name.
    /// </summary>
    public static IReadOnlyDictionary<string, string> LocalizedNames(
        string englishDisplayName,
        IReadOnlyDictionary<string, string>? displayNames)
    {
        var names = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["en"] = englishDisplayName,
        };
        if (displayNames is not null)
        {
            foreach (var pair in displayNames.OrderBy(item => item.Key, StringComparer.OrdinalIgnoreCase))
            {
                if (string.IsNullOrWhiteSpace(pair.Value))
                {
                    continue;
                }
                var language = NormalizeLanguage(pair.Key);
                if (language is null)
                {
                    continue;
                }
                names.TryAdd(language, pair.Value.Trim());
            }
        }
        return names;
    }

    /// <summary>Valid lproj language for an SMDH displayNames key, or null.</summary>
    public static string? NormalizeLanguage(string? key)
    {
        if (string.IsNullOrWhiteSpace(key))
        {
            return null;
        }
        var language = key.Trim().Replace('_', '-');
        if (string.Equals(language, "Base", StringComparison.OrdinalIgnoreCase)
            || !LanguageTag.IsMatch(language))
        {
            return null;
        }
        var parts = language.Split('-');
        if (parts.Length == 1)
        {
            return parts[0].ToLowerInvariant();
        }
        return parts[0].ToLowerInvariant() + "-" + string.Join("-", parts.Skip(1));
    }

    /// <summary>InfoPlist.strings content for one localised CFBundleDisplayName.</summary>
    public static byte[] InfoPlistStrings(string displayName)
    {
        var escaped = displayName.Replace("\\", "\\\\", StringComparison.Ordinal)
            .Replace("\"", "\\\"", StringComparison.Ordinal);
        var text = "\"CFBundleDisplayName\" = \"" + escaped + "\";\n";
        return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(text);
    }
}

/// <summary>Minimal XML plist writer for the types <see cref="PlistReader"/> returns.</summary>
internal static class PlistXml
{
    public static byte[] Write(IReadOnlyDictionary<string, object?> plist)
    {
        var document = new XDocument(
            new XDeclaration("1.0", "UTF-8", null),
            new XElement("plist",
                new XAttribute("version", "1.0"),
                Dict(plist)));
        var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + Environment.NewLine + (document.Root?.ToString() ?? string.Empty);
        return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(body);
    }

    private static XElement Element(object? value) => value switch
    {
        string text => new XElement("string", text),
        bool flag => flag ? new XElement("true") : new XElement("false"),
        long number => new XElement("integer", number.ToString(CultureInfo.InvariantCulture)),
        int number => new XElement("integer", number.ToString(CultureInfo.InvariantCulture)),
        short number => new XElement("integer", number.ToString(CultureInfo.InvariantCulture)),
        double number => new XElement("real", number.ToString("R", CultureInfo.InvariantCulture)),
        float number => new XElement("real", number.ToString("R", CultureInfo.InvariantCulture)),
        byte[] data => new XElement("data", Convert.ToBase64String(data)),
        IReadOnlyDictionary<string, object?> dict => Dict(dict),
        IEnumerable<object?> list => new XElement("array", list.Select(Element)),
        null => new XElement("string", string.Empty),
        _ => new XElement("string", Convert.ToString(value, CultureInfo.InvariantCulture) ?? string.Empty),
    };

    private static XElement Dict(IReadOnlyDictionary<string, object?> dict) =>
        new("dict", dict.SelectMany(pair => new object[] { new XElement("key", pair.Key), Element(pair.Value) }));
}
