using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Signing;

/// <summary>Identity read from the template IPA (Info.plist + bundle catalogue).</summary>
public sealed record TemplateIdentity(string? Version, int? Build, int CatalogSchemaVersion, int GameCount, bool HasRoms);

/// <summary>Result of inspecting an IPA as a launcher template/app.</summary>
public sealed record TemplateInspection(bool Ok, TemplateIdentity? Identity, string? Error, string? Fix);

/// <summary>
/// Minimum shell-template identity accepted by this launcher build. sha/bytes alone
/// let an old or wrong template through; these rules are enforced on both the
/// manifest and the actual IPA (Info.plist CFBundleShortVersionString /
/// CFBundleVersion) before composing or signing anything.
/// </summary>
public static class ShellTemplateRules
{
    public const string MinimumVersion = "0.2.0-beta1";
    public const int MinimumBuild = 9;
    public const int RequiredCatalogSchemaVersion = 2;

    public static (bool Ok, string? Error, string? Fix) ValidateManifest(ShellManifest manifest) =>
        Validate(manifest.Version, manifest.Build, "manifest");

    public static (bool Ok, string? Error, string? Fix) Validate(string? version, int? build, string source)
    {
        if (string.IsNullOrWhiteSpace(version))
        {
            return (false, "The shell template " + source + " has no version.", "Rebuild the ROM-free template on macOS (>= " + MinimumVersion + ", build " + MinimumBuild + ") and repack the launcher.");
        }
        if (build is null or <= 0)
        {
            return (false, "The shell template " + source + " has no build number.", "Rebuild the ROM-free template on macOS (build >= " + MinimumBuild + ") and update Shell/manifest.json.");
        }
        if (!VersionAtLeast(version, MinimumVersion))
        {
            return (false, "Shell template version " + version + " is older than the required " + MinimumVersion + ".", "Rebuild the ROM-free template on macOS with the current shell task; do not sign an old template.");
        }
        if (build < MinimumBuild)
        {
            return (false, "Shell template build " + build.ToString() + " is older than the required build " + MinimumBuild.ToString() + ".", "Rebuild the ROM-free template on macOS with the current shell task.");
        }
        return (true, null, null);
    }

    /// <summary>Semver-ish: numeric core first, then prerelease (none &gt; prerelease; beta1 &lt; beta2 &lt; rc1).</summary>
    public static bool VersionAtLeast(string? candidate, string minimum)
    {
        if (!TryParse(candidate, out var c) || !TryParse(minimum, out var m))
        {
            return false;
        }
        if (c.Major != m.Major) return c.Major > m.Major;
        if (c.Minor != m.Minor) return c.Minor > m.Minor;
        if (c.Patch != m.Patch) return c.Patch > m.Patch;
        if (c.PreRank != m.PreRank) return c.PreRank > m.PreRank;
        return c.PreNumber >= m.PreNumber;
    }

    internal static bool TryParse(string? version, out (int Major, int Minor, int Patch, int PreRank, int PreNumber) parsed)
    {
        parsed = default;
        if (string.IsNullOrWhiteSpace(version))
        {
            return false;
        }
        var text = version.Trim().TrimStart('v', 'V');
        var plus = text.IndexOf('+');
        if (plus >= 0) text = text[..plus];
        var dash = text.IndexOf('-');
        var core = dash >= 0 ? text[..dash] : text;
        var pre = dash >= 0 ? text[(dash + 1)..] : null;
        var parts = core.Split('.');
        if (parts.Length < 3
            || !int.TryParse(parts[0], out var major)
            || !int.TryParse(parts[1], out var minor)
            || !int.TryParse(parts[2], out var patch))
        {
            return false;
        }
        var rank = 3;
        var number = int.MaxValue;
        if (!string.IsNullOrWhiteSpace(pre))
        {
            var label = new string(pre.TakeWhile(char.IsLetter).ToArray()).ToLowerInvariant();
            var digits = new string(pre.SkipWhile(char.IsLetter).ToArray());
            rank = label switch { "alpha" => 0, "beta" => 1, "rc" => 2, _ => 3 };
            number = int.TryParse(digits, out var n) ? n : 0;
        }
        parsed = (major, minor, patch, rank, number);
        return true;
    }
}

/// <summary>
/// Reads the real identity out of an IPA: Payload/&lt;app&gt;/Info.plist
/// (CFBundleShortVersionString + CFBundleVersion; XML or binary plist) and the
/// bundle GameCatalog.json (must be schema 2, empty for the template), and
/// rejects any Roms/ payload.
/// </summary>
public static class IpaTemplateInspector
{
    public const string InfoPlistName = "Info.plist";
    public const string GameCatalogName = "GameCatalog.json";
    public const string RomsDirectory = "Roms/";

    public static TemplateInspection Inspect(string ipaPath, bool requireEmptyCatalog)
    {
        if (!File.Exists(ipaPath))
        {
            return Fail("The IPA to inspect does not exist: " + ipaPath, "Rebuild/repack the launcher distribution.");
        }
        ZipArchive archive;
        try
        {
            archive = ZipFile.OpenRead(ipaPath);
        }
        catch (InvalidDataException error)
        {
            return Fail("The IPA is not a readable zip: " + error.Message, "Re-download/rebuild the launcher package.");
        }
        using (archive)
        {
            var appRoot = FindAppRoot(archive);
            if (appRoot is null)
            {
                return Fail("The IPA has no Payload/*.app entry.", "Rebuild the shell template on macOS.");
            }
            var plistEntry = archive.Entries.FirstOrDefault(e => string.Equals(e.FullName, appRoot + InfoPlistName, StringComparison.OrdinalIgnoreCase));
            if (plistEntry is null)
            {
                return Fail("The IPA has no " + InfoPlistName + " in " + appRoot, "Rebuild the shell template on macOS.");
            }
            Dictionary<string, object?> plist;
            try
            {
                using var stream = plistEntry.Open();
                using var memory = new MemoryStream();
                stream.CopyTo(memory);
                plist = PlistReader.Read(memory.ToArray());
            }
            catch (Exception error) when (error is FormatException or InvalidDataException or IOException)
            {
                return Fail("Could not read Info.plist from the IPA: " + error.Message, "Rebuild the shell template on macOS; the plist is malformed.");
            }
            var version = plist.TryGetValue("CFBundleShortVersionString", out var v) ? v?.ToString() : null;
            var buildText = plist.TryGetValue("CFBundleVersion", out var b) ? b?.ToString() : null;
            var build = int.TryParse(buildText, out var parsedBuild) ? parsedBuild : (int?)null;
            var identityRules = ShellTemplateRules.Validate(version, build, "Info.plist");
            if (!identityRules.Ok)
            {
                return new TemplateInspection(false, null, identityRules.Error, identityRules.Fix);
            }

            var catalogEntries = archive.Entries.Where(e => e.FullName.EndsWith("/" + GameCatalogName, StringComparison.OrdinalIgnoreCase)).ToList();
            if (catalogEntries.Count == 0)
            {
                return Fail("The IPA has no bundle " + GameCatalogName + ".", "Rebuild the ROM-free shell template with its empty schema-2 catalogue.");
            }
            int schemaVersion = 0;
            int gameCount = 0;
            try
            {
                using var reader = new StreamReader(catalogEntries[0].Open());
                using var document = Json.TryParse(reader.ReadToEnd());
                if (document is null)
                {
                    return Fail("The bundle " + GameCatalogName + " is not valid JSON.", "Rebuild the template; the catalogue is corrupt.");
                }
                schemaVersion = (int)(Json.Long(document.RootElement, "schemaVersion") ?? 0);
                gameCount = Json.Array(document.RootElement, "games").Count;
            }
            catch (IOException error)
            {
                return Fail("Could not read the bundle " + GameCatalogName + ": " + error.Message, "Rebuild the template.");
            }
            if (schemaVersion != ShellTemplateRules.RequiredCatalogSchemaVersion)
            {
                return Fail("Bundle catalogue schemaVersion " + schemaVersion.ToString() + " is not the required schema " + ShellTemplateRules.RequiredCatalogSchemaVersion.ToString() + ".", "Rebuild the template with the current shell task (schema 2).");
            }
            if (requireEmptyCatalog && gameCount != 0)
            {
                return Fail("The shell template bundle catalogue contains " + gameCount.ToString() + " game(s); a template must be empty (packs are injected per install).", "Use the ROM-free template from shell/README.md; do not install a pre-loaded app as the template.");
            }
            var hasRoms = archive.Entries.Any(e => e.FullName.StartsWith(appRoot + RomsDirectory, StringComparison.OrdinalIgnoreCase) && !e.FullName.EndsWith("/", StringComparison.Ordinal));
            if (hasRoms)
            {
                return Fail("The IPA contains a Roms/ directory with files; game data must stay out of the signed app.", "Use the ROM-free template; ROM data is pushed separately.");
            }
            return new TemplateInspection(true, new TemplateIdentity(version, build, schemaVersion, gameCount, false), null, null);
        }
    }

    private static TemplateInspection Fail(string error, string fix) => new(false, null, error, fix);

    internal static string? FindAppRoot(ZipArchive archive)
    {
        var entry = archive.Entries.FirstOrDefault(e =>
            e.FullName.StartsWith("Payload/", StringComparison.OrdinalIgnoreCase)
            && e.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase) > 0);
        if (entry is null) return null;
        var index = entry.FullName.IndexOf(".app/", StringComparison.OrdinalIgnoreCase);
        return entry.FullName[..(index + ".app/".Length)];
    }
}

/// <summary>Minimal plist reader for Info.plist (XML and binary bplist00).</summary>
internal static class PlistReader
{
    public static Dictionary<string, object?> Read(byte[] bytes)
    {
        if (bytes.Length >= 8 && bytes.AsSpan(0, 8).SequenceEqual(Encoding.ASCII.GetBytes("bplist00")))
        {
            var value = ReadBinary(bytes);
            if (value is Dictionary<string, object?> dict) return dict;
            throw new InvalidDataException("binary plist root is not a dictionary");
        }
        var text = Encoding.UTF8.GetString(bytes);
        var start = text.IndexOf('<');
        if (start < 0) throw new FormatException("plist has no XML content");
        var doc = System.Xml.Linq.XDocument.Parse(text[start..]);
        var root = doc.Root?.Elements().FirstOrDefault() ?? throw new FormatException("plist has no root value");
        var xmlValue = ReadXml(root);
        if (xmlValue is Dictionary<string, object?> xmlDict) return xmlDict;
        throw new InvalidDataException("XML plist root is not a dictionary");
    }

    private static object? ReadXml(System.Xml.Linq.XElement element) => element.Name.LocalName switch
    {
        "dict" => ReadXmlDict(element),
        "array" => element.Elements().Select(ReadXml).ToList(),
        "string" => element.Value,
        "integer" => long.TryParse(element.Value, out var i) ? i : 0L,
        "real" => double.TryParse(element.Value, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 0d,
        "true" => true,
        "false" => false,
        "data" => Convert.FromBase64String(element.Value.Trim()),
        _ => element.Value,
    };

    private static Dictionary<string, object?> ReadXmlDict(System.Xml.Linq.XElement dict)
    {
        var result = new Dictionary<string, object?>(StringComparer.Ordinal);
        var children = dict.Elements().ToList();
        for (var i = 0; i + 1 < children.Count; i += 2)
        {
            result[children[i].Value] = ReadXml(children[i + 1]);
        }
        return result;
    }

    private static object? ReadBinary(byte[] data)
    {
        if (data.Length < 40) throw new InvalidDataException("binary plist too short");
        var trailer = data.AsSpan(data.Length - 32, 32);
        var offsetSize = trailer[6];
        var refSize = trailer[7];
        var objectCount = (long)ReadUInt(trailer.Slice(8, 8));
        var topObject = (long)ReadUInt(trailer.Slice(16, 8));
        var offsetTable = (long)ReadUInt(trailer.Slice(24, 8));
        if (offsetSize is < 1 or > 8 || refSize is < 1 or > 8 || objectCount <= 0 || topObject < 0 || topObject >= objectCount)
        {
            throw new InvalidDataException("binary plist trailer is invalid");
        }
        if (offsetTable < 8 || offsetTable + objectCount * offsetSize > data.Length - 32)
        {
            throw new InvalidDataException("binary plist offset table out of range");
        }
        var offsets = new long[objectCount];
        for (var i = 0; i < objectCount; i++)
        {
            offsets[i] = (long)ReadUInt(data.AsSpan((int)(offsetTable + i * offsetSize), offsetSize));
        }
        return ReadBinaryObject(data, offsets, (int)topObject, refSize, 0);
    }

    private static object? ReadBinaryObject(byte[] data, long[] offsets, int index, int refSize, int depth)
    {
        if (depth > 64 || index < 0 || index >= offsets.Length) throw new InvalidDataException("binary plist reference out of range");
        var offset = offsets[index];
        if (offset < 8 || offset >= data.Length) throw new InvalidDataException("binary plist object offset out of range");
        var marker = data[offset];
        var type = marker >> 4;
        var info = marker & 0x0F;
        var position = (int)offset + 1;
        switch (type)
        {
            case 0x0:
                return info switch { 0x8 => false, 0x9 => true, _ => null };
            case 0x1:
            {
                var size = 1 << info;
                if (position + size > data.Length) throw new InvalidDataException("binary plist integer out of range");
                var raw = ReadUInt(data.AsSpan(position, size));
                return size == 8 ? (long)raw : SignExtend(raw, size);
            }
            case 0x2:
            {
                var size = 1 << info;
                if (position + size > data.Length) throw new InvalidDataException("binary plist real out of range");
                return size switch
                {
                    4 => BitConverter.Int32BitsToSingle((int)ReadUInt(data.AsSpan(position, 4))),
                    8 => BitConverter.Int64BitsToDouble((long)ReadUInt(data.AsSpan(position, 8))),
                    _ => 0d,
                };
            }
            case 0x4:
            case 0x5:
            case 0x6:
            {
                var (length, bodyOffset) = ReadLength(data, position, info);
                if (bodyOffset + length > data.Length) throw new InvalidDataException("binary plist string/data out of range");
                if (type == 0x5) return Encoding.ASCII.GetString(data, bodyOffset, length);
                if (type == 0x6) return Encoding.BigEndianUnicode.GetString(data, bodyOffset, length * 2);
                return data.AsSpan(bodyOffset, length).ToArray();
            }
            case 0xA:
            {
                var (count, bodyOffset) = ReadLength(data, position, info);
                var list = new List<object?>(count);
                for (var i = 0; i < count; i++)
                {
                    var reference = (int)ReadUInt(data.AsSpan(bodyOffset + i * refSize, refSize));
                    list.Add(ReadBinaryObject(data, offsets, reference, refSize, depth + 1));
                }
                return list;
            }
            case 0xD:
            {
                var (count, bodyOffset) = ReadLength(data, position, info);
                var dict = new Dictionary<string, object?>(StringComparer.Ordinal);
                for (var i = 0; i < count; i++)
                {
                    var keyRef = (int)ReadUInt(data.AsSpan(bodyOffset + i * refSize, refSize));
                    var valueRef = (int)ReadUInt(data.AsSpan(bodyOffset + (count + i) * refSize, refSize));
                    var key = ReadBinaryObject(data, offsets, keyRef, refSize, depth + 1)?.ToString() ?? string.Empty;
                    dict[key] = ReadBinaryObject(data, offsets, valueRef, refSize, depth + 1);
                }
                return dict;
            }
            default:
                throw new InvalidDataException("unsupported binary plist object type 0x" + type.ToString("X"));
        }
    }

    private static (int Length, int BodyOffset) ReadLength(byte[] data, int position, int info)
    {
        if (info != 0x0F)
        {
            return (info, position);
        }
        var intMarker = data[position];
        if ((intMarker >> 4) != 0x1) throw new InvalidDataException("binary plist length is not an integer");
        var size = 1 << (intMarker & 0x0F);
        var length = ReadUInt(data.AsSpan(position + 1, size));
        return ((int)length, (int)(position + 1 + size));
    }

    private static ulong ReadUInt(ReadOnlySpan<byte> span)
    {
        ulong value = 0;
        foreach (var b in span) value = (value << 8) | b;
        return value;
    }

    private static long SignExtend(ulong value, int size) => size switch
    {
        1 => (sbyte)value,
        2 => (short)value,
        4 => (int)value,
        _ => (long)value,
    };
}
