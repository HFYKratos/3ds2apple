using System.IO.Compression;
using System.Text;
using System.Text.Json;
using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Tools;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>Fake process layer: the launcher's tool clients are tested without any binary.</summary>
internal sealed class FakeProcessRunner : IProcessRunner
{
    private readonly Func<ProcessRequest, ProcessResult> _handler;

    public FakeProcessRunner(Func<ProcessRequest, ProcessResult> handler) => _handler = handler;

    public List<ProcessRequest> Requests { get; } = new();

    public Task<ProcessResult> RunAsync(ProcessRequest request, Action<string>? onStdOutLine = null, Action<string>? onStdErrLine = null, CancellationToken cancellationToken = default)
    {
        Requests.Add(request);
        var result = _handler(request);
        foreach (var line in result.StdOutLines)
        {
            onStdOutLine?.Invoke(line);
        }
        foreach (var line in result.StdErrLines)
        {
            onStdErrLine?.Invoke(line);
        }
        return Task.FromResult(result);
    }
}

internal sealed class TempDir : IDisposable
{
    public TempDir()
    {
        Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "3ds2apple-launcher-tests-" + Guid.NewGuid().ToString("N")[..10]);
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public string File(string name, string content)
    {
        var path = System.IO.Path.Combine(Path, name);
        var directory = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        System.IO.File.WriteAllText(path, content);
        return path;
    }

    public string Bytes(string name, byte[] content)
    {
        var path = System.IO.Path.Combine(Path, name);
        var directory = System.IO.Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory))
        {
            Directory.CreateDirectory(directory);
        }
        System.IO.File.WriteAllBytes(path, content);
        return path;
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
            // best effort
        }
    }
}

public sealed class PackCliParsingTests
{
    private const string RealInspectJson = """
        {
          "errors": [],
          "roms": [
            {
              "bytes": 1807118336,
              "container": "ncsd",
              "contentBytes": 1807101952,
              "displayName": "Pokemon Y",
              "path": "ROM/Pokemon Y.cci",
              "productCode": "CTR-P-EK2A",
              "titleID": "0004000000055E00",
              "titleVersion": 2
            }
          ]
        }
        """;

    [Fact]
    public async Task InspectParsesRealCliShape()
    {
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, RealInspectJson, string.Empty, false, true));
        var cli = new PackCli(runner, "/bin/3ds2apple-pack", "/tmp/out");
        var result = await cli.InspectAsync("ROM/Pokemon Y.cci");
        Assert.True(result.Ok);
        var rom = Assert.Single(result.Roms);
        Assert.Equal("0004000000055E00", rom.TitleID);
        Assert.Equal("CTR-P-EK2A", rom.ProductCode);
        Assert.Equal("Pokemon Y", rom.DisplayName);
        Assert.Equal("ncsd", rom.Container);
        Assert.Equal(1807118336, rom.Bytes);
        Assert.Equal(1807101952, rom.ContentBytes);
        Assert.Equal(2, rom.TitleVersion);
        Assert.Contains("rom", runner.Requests[0].Arguments);
        Assert.Contains("--json", runner.Requests[0].Arguments);
        Assert.Contains("--out", runner.Requests[0].Arguments);
    }

    [Fact]
    public async Task InspectReportsErrorsWithoutThrowing()
    {
        const string json = """{"roms":[],"errors":[{"path":"bad.3ds","error":"not a decrypted 3DS ROM"}]}""";
        var runner = new FakeProcessRunner(_ => new ProcessResult(1, json, string.Empty, false, true));
        var result = await new PackCli(runner, "pack", "/tmp/out").InspectAsync("bad.3ds");
        Assert.False(result.Ok);
        Assert.Equal("not a decrypted 3DS ROM", Assert.Single(result.Errors));
    }

    [Fact]
    public async Task AddAndListParsePackages()
    {
        const string addJson = """{"packages":[{"titleID":"0004000000055E00","displayName":"Pokemon Y","productCode":"CTR-P-EK2A","packageDir":"/tmp/out/packages/0004000000055E00","romPath":"ROM/Pokemon Y.cci","status":"imported"}],"errors":[]}""";
        const string listJson = """{"packages":[{"titleID":"0004000000055E00","displayName":"Pokemon Y","productCode":"CTR-P-EK2A","aotVersion":1,"state":"queued","pack":null,"issues":[]}],"errors":[]}""";
        var runner = new FakeProcessRunner(request => request.Arguments.Contains("add")
            ? new ProcessResult(0, addJson, string.Empty, false, true)
            : new ProcessResult(0, listJson, string.Empty, false, true));
        var cli = new PackCli(runner, "pack", "/tmp/out");
        var add = await cli.AddAsync(new[] { "ROM/Pokemon Y.cci" }, null);
        Assert.True(add.Ok);
        Assert.Equal("0004000000055E00", Assert.Single(add.Packages).TitleID);
        var list = await cli.ListAsync();
        var package = Assert.Single(list.Packages);
        Assert.Equal("queued", package.State);
        Assert.Null(package.Pack);
    }
}

public sealed class GameInfoWriterTests
{
    private const string Sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public void WritesTheShellContract()
    {
        var document = GameInfoWriter.Build("0004000000055e00", "Pokémon Y", "CTR-P-EK2A", 3, Sha, 1234, Sha, 5678, DateTimeOffset.UnixEpoch.AddSeconds(1700000000));
        var json = JsonSerializer.Serialize(document, ThreeDsTwoApple.Launcher.Core.Util.Json.WriteOptions);
        using var parsed = JsonDocument.Parse(json);
        var root = parsed.RootElement;
        Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
        Assert.Equal("0004000000055E00", root.GetProperty("titleID").GetString());
        Assert.Equal("Pokémon Y", root.GetProperty("displayName").GetString());
        Assert.True(root.GetProperty("aot").GetBoolean());
        Assert.Equal(1, root.GetProperty("packABIVersion").GetInt32());
        Assert.Equal("zk_gamepack_register", root.GetProperty("registrationSymbol").GetString());
        Assert.Equal("0004000000055E00", root.GetProperty("saveNamespace").GetString());
        Assert.Equal("Frameworks/GamePack-0004000000055E00.dylib", root.GetProperty("pack").GetProperty("file").GetString());
        Assert.True(root.GetProperty("packBundled").GetBoolean());
        Assert.Equal(1234, root.GetProperty("pack").GetProperty("size").GetInt64());
        Assert.Equal(Sha, root.GetProperty("pack").GetProperty("sha256").GetString());
        Assert.Equal("GameRom.cci", root.GetProperty("rom").GetProperty("file").GetString());
        Assert.Equal(5678, root.GetProperty("rom").GetProperty("size").GetInt64());
        Assert.Equal("2023-11-14T22:13:20Z", root.GetProperty("pushedAt").GetString());
        Assert.StartsWith("3ds2apple-launcher-windows/", root.GetProperty("launcherVersion").GetString());
    }

    [Fact]
    public void RejectsInvalidIdentity()
    {
        Assert.Throws<ArgumentException>(() => GameInfoWriter.Build("XYZ", "n", null, 1, Sha, 1, Sha, 1, DateTimeOffset.UtcNow));
        Assert.Throws<ArgumentException>(() => GameInfoWriter.Build("0004000000055E00", "n", null, 1, "nothex", 1, Sha, 1, DateTimeOffset.UtcNow));
    }

    [Fact]
    public void WritesWithoutPackWhenNotRecorded()
    {
        var document = GameInfoWriter.Build("0004000000055E00", "Pokémon Y", null, 1, null, null, Sha, 5678, DateTimeOffset.UtcNow);
        var json = JsonSerializer.Serialize(document, ThreeDsTwoApple.Launcher.Core.Util.Json.WriteOptions);
        Assert.Null(document.Pack);
        Assert.Null(document.PackBundled);
        Assert.DoesNotContain("Frameworks/GamePack-", json, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RoundTripsThroughFile()
    {
        using var temp = new TempDir();
        var path = Path.Combine(temp.Path, "Games", "0004000000055E00", "GameInfo.json");
        var document = GameInfoWriter.Build("0004000000055E00", "Pokémon Y", null, 1, Sha, 10, Sha, 20, DateTimeOffset.UtcNow);
        await GameInfoWriter.WriteAsync(path, document);
        var read = await GameInfoWriter.ReadAsync(path);
        Assert.NotNull(read);
        Assert.Equal(document.TitleID, read!.TitleID);
        Assert.Equal(document.Pack!.Size, read.Pack!.Size);
    }
}

public sealed class DevPushClientTests
{
    private const string DonePut = """{"schema":"devpush/1","type":"done","command":"put","remotePath":"Documents/Games/0004000000055E00/GamePack.dylib","bytes":100,"sha256":"abc"}""";

    [Fact]
    public async Task CapabilitiesAndDevicesParse()
    {
        const string capabilities = """{"schema":"devpush/1","type":"done","command":"capabilities","version":"0.1.0","schemaVersion":1,"commands":["devices","put","ls"],"features":{"mock":true,"progress":true}}""";
        const string devices = """{"schema":"devpush/1","type":"done","command":"devices","devices":[{"udid":"00008030001","name":"iPhone","model":"iPhone15,2","iosVersion":"17.4","connection":"usb","paired":true}]}""";
        var runner = new FakeProcessRunner(request => new ProcessResult(0, request.Arguments.Contains("capabilities") ? capabilities : devices, string.Empty, false, true));
        var client = new DevPushClient(runner, "devpush");
        var caps = await client.CapabilitiesAsync();
        Assert.Equal("0.1.0", caps.Version);
        Assert.True(caps.Has("put"));
        Assert.True(caps.Features["progress"]);
        var list = await client.DevicesAsync();
        var device = Assert.Single(list);
        Assert.Equal("00008030001", device.Udid);
        Assert.True(device.IsUsb);
        Assert.True(device.Paired);
    }

    [Fact]
    public async Task PutForwardsProgressAndDoneData()
    {
        var lines = string.Join("\n", new[]
        {
            """{"schema":"devpush/1","type":"begin","command":"put","udid":"u"}""",
            """{"schema":"devpush/1","type":"progress","command":"put","file":"GamePack.dylib","bytesSent":10,"bytesTotal":100,"percent":10}""",
            """{"schema":"devpush/1","type":"progress","command":"put","file":"GamePack.dylib","bytesSent":90,"bytesTotal":100,"percent":90}""",
            DonePut,
        });
        var runner = new FakeProcessRunner(_ => new ProcessResult(0, lines, string.Empty, false, true));
        var reported = new List<TransferProgress>();
        var client = new DevPushClient(runner, "devpush");
        var result = await client.PutAsync("com.example.app", "/tmp/GamePack.dylib", "Documents/Games/0004000000055E00/GamePack.dylib", progress: new Progress<TransferProgress>(reported.Add));
        // Progress<T> posts asynchronously; the client's report happens on the calling thread here,
        // so allow a short drain window for the dispatcher-free implementation.
        await Task.Delay(50);
        Assert.Equal(2, reported.Count);
        Assert.Equal(90, reported[1].BytesSent);
        Assert.Equal(100, result.Bytes);
        Assert.Equal("abc", result.Sha256);
        Assert.Contains("--json", runner.Requests[0].Arguments);
        Assert.Contains("put", runner.Requests[0].Arguments);
        Assert.Contains("--container", runner.Requests[0].Arguments);
    }

    [Fact]
    public async Task ErrorEventBecomesStructuredException()
    {
        const string error = """{"schema":"devpush/1","type":"error","command":"put","error":{"code":"stall_timeout","message":"no progress for 90 s","hint":"unlock the phone"},"exitCode":6}""";
        var runner = new FakeProcessRunner(_ => new ProcessResult(6, error, string.Empty, false, true));
        var client = new DevPushClient(runner, "devpush");
        var exception = await Assert.ThrowsAsync<LauncherToolException>(() => client.PutAsync("b", "/tmp/x", "Documents/x"));
        Assert.Equal("stall_timeout", exception.Code);
        Assert.Equal("unlock the phone", exception.Hint);
        Assert.Equal(6, exception.ExitCode);
    }

    [Fact]
    public async Task ExitCodeWithoutJsonIsMapped()
    {
        var runner = new FakeProcessRunner(_ => new ProcessResult(7, string.Empty, "afc: open failed", false, true));
        var exception = await Assert.ThrowsAsync<LauncherToolException>(() => new DevPushClient(runner, "devpush").ListAsync("b", "Documents"));
        Assert.Equal("afc_error", exception.Code);
    }

    [Fact]
    public void EventParserRejectsForeignLines()
    {
        Assert.Null(DevPushClient.ParseEventLine("plain text"));
        Assert.Null(DevPushClient.ParseEventLine("""{"schema":"other/1","type":"done"}"""));
        Assert.Equal(DevPushEventType.Progress, DevPushClient.ParseEventLine("""{"schema":"devpush/1","type":"progress","bytesSent":1,"bytesTotal":2}""")!.Type);
    }
}

public sealed class AppleErrorCatalogTests
{
    [Fact]
    public void MapsFreeAccountLimitsSeparately()
    {
        Assert.Equal("free_appid_limit", AppleErrorCatalog.Explain("Error 9120: app id limit reached").Code);
        Assert.Equal("free_appid_limit", AppleErrorCatalog.Explain("maximum number of app ids").Code);
        Assert.Equal("free_app_limit", AppleErrorCatalog.Explain("maximum number of installed apps").Code);
    }

    [Fact]
    public void MapsAccountAndNetworkErrors()
    {
        Assert.Equal("apple_session_expired", AppleErrorCatalog.Explain("Developer API error 1100: Your session has expired. Please log in.").Code);
        Assert.Equal("signing_server_unreachable", AppleErrorCatalog.Explain("Anisette error: dns error: failed to lookup address").Code);
        Assert.Equal("device_already_registered", AppleErrorCatalog.Explain("this device already exists on this team").Code);
    }

    [Fact]
    public void MapsDeviceRegistrationAndAppId()
    {
        Assert.Equal("device_already_registered", AppleErrorCatalog.Explain("this device already exists on this team").Code);
        Assert.Equal("app_id_taken", AppleErrorCatalog.Explain("Error 9401: app id with identifier com.x is not available").Code);
        Assert.Equal("generic_signing_failure", AppleErrorCatalog.Explain(string.Empty).Code);
    }

    [Fact]
    public void EveryCatalogEntryHasActionableText()
    {
        Assert.NotEmpty(AppleErrorCatalog.All);
        foreach (var (code, error) in AppleErrorCatalog.All)
        {
            Assert.Equal(code, error.Code);
            Assert.NotEmpty(error.Title);
            Assert.NotEmpty(error.Fix);
        }
    }
}

public sealed class ImpactorBundleTests
{
    [Fact]
    public void PinsMatchTheOfficialRelease()
    {
        Assert.Equal("2.7.2", ImpactorPins.TestedVersion);
        Assert.Equal("f493cd99081370dca7c677676e119d8808418ebccab49e1f219744b3b71e88ef", ImpactorPins.Impactor.Sha256);
        Assert.Equal("b965e51a613341cb8c7e0f3594b24c09243a235b4187f669ea958a548e6a2fe0", ImpactorPins.PlumeSign.Sha256);
        Assert.Contains("github.com/claration/impactor", ImpactorPins.ReleasePageUrl);
    }

    [Fact]
    public void DetectsModifiedBinary()
    {
        using var temp = new TempDir();
        var path = temp.File(ImpactorPins.Impactor.FileName, "not the real impactor");
        var status = ImpactorBundle.VerifyPinned(ImpactorPins.Impactor, path);
        Assert.True(status.Present);
        Assert.False(status.Ok);
        Assert.Equal(ImpactorBundle.Sha256File(path), status.ActualSha256);
    }

    [Fact]
    public void MissingBundleIsNotReady()
    {
        using var temp = new TempDir();
        var bundle = ImpactorBundle.Locate(temp.Path);
        var status = bundle.Verify();
        Assert.False(status.Ready);
        Assert.All(status.Binaries, binary => Assert.False(binary.Present));
        Assert.NotEmpty(status.MissingLicenseFiles);
    }
}

public sealed class PlumeSignRunnerTests
{
    [Fact]
    public void BuildsExactSignArguments()
    {
        var request = new PlumeSignRequest("/tmp/shell.ipa", "/tmp/out.ipa", "com.example.shell", "3ds2apple", "42", RegisterAndInstall: true);
        var arguments = PlumeSignRunner.BuildSignArguments(request);
        Assert.Equal(new[]
        {
            "sign", "--package", "/tmp/shell.ipa", "--apple-id", "--register-and-install", "--udid", "42",
            "-o", "/tmp/out.ipa", "--custom-name", "3ds2apple", "--custom-identifier", "com.example.shell",
        }, arguments);
    }

    [Fact]
    public void SignOnlyOmitsInstallFlags()
    {
        var arguments = PlumeSignRunner.BuildSignArguments(new PlumeSignRequest("/tmp/a.ipa", "/tmp/b.ipa", RegisterAndInstall: false));
        Assert.DoesNotContain("--register-and-install", arguments);
        Assert.DoesNotContain("--udid", arguments);
    }

    [Fact]
    public async Task SuccessRequiresInstallationComplete()
    {
        using var temp = new TempDir();
        var withoutMarker = new FakeProcessRunner(_ => new ProcessResult(0, "signed okay", string.Empty, false, true));
        var runner = new PlumeSignRunner(withoutMarker, "plumesign", Path.Combine(temp.Path, "logs"));
        var result = await runner.RunAsync(new PlumeSignRequest("/tmp/a.ipa", "/tmp/b.ipa"));
        Assert.False(result.Success);
        Assert.Equal("install_incomplete", result.Error!.Code);

        var withMarker = new FakeProcessRunner(_ => new ProcessResult(0, "Signed\nInstallation complete", string.Empty, false, true));
        var ok = await new PlumeSignRunner(withMarker, "plumesign", Path.Combine(temp.Path, "logs2")).RunAsync(new PlumeSignRequest("/tmp/a.ipa", "/tmp/b.ipa"));
        Assert.True(ok.Success);
        Assert.Null(ok.Error);
    }

    [Fact]
    public async Task FailureMapsToCatalog()
    {
        using var temp = new TempDir();
        var runner = new FakeProcessRunner(_ => new ProcessResult(1, "Error 9401: app id with identifier com.x is not available", string.Empty, false, true));
        var result = await new PlumeSignRunner(runner, "plumesign", temp.Path).RunAsync(new PlumeSignRequest("/tmp/a.ipa", "/tmp/b.ipa"));
        Assert.False(result.Success);
        Assert.Equal("app_id_taken", result.Error!.Code);
        Assert.True(File.Exists(result.LogPath));
    }
}

public sealed class IpaPackExtractorTests
{
    private static readonly byte[] MachOMagic = { 0xCF, 0xFA, 0xED, 0xFE, 0, 0, 0, 0, 0, 0, 0, 0 };

    private static string BuildIpa(TempDir temp, string titleId, byte[] packBytes)
    {
        var ipa = Path.Combine(temp.Path, "game.ipa");
        using var archive = ZipFile.Open(ipa, ZipArchiveMode.Create);
        var catalog = archive.CreateEntry("Payload/3ds2apple.app/GameCatalog.json");
        using (var writer = new StreamWriter(catalog.Open(), new UTF8Encoding(false)))
        {
            writer.Write("""{"schemaVersion":2,"games":[{"titleID":"0004000000055E00","displayName":"Pokemon Y","productCode":"CTR-P-EK2A","aot":true,"aotVersion":1,"packFile":"Frameworks/GamePack-0004000000055E00.dylib","packABIVersion":1}]}""");
        }
        var pack = archive.CreateEntry($"Payload/3ds2apple.app/Frameworks/GamePack-{titleId}.dylib");
        using var stream = pack.Open();
        stream.Write(packBytes);
        return ipa;
    }

    [Fact]
    public void ExtractsRealMachOPack()
    {
        using var temp = new TempDir();
        var ipa = BuildIpa(temp, "0004000000055E00", MachOMagic);
        var extracted = IpaPackExtractor.ExtractGamePack(ipa, Path.Combine(temp.Path, "out"));
        Assert.Equal("0004000000055E00", extracted.TitleID);
        Assert.Equal("Pokemon Y", extracted.DisplayName);
        Assert.Equal("CTR-P-EK2A", extracted.ProductCode);
        Assert.True(File.Exists(extracted.PackPath));
        Assert.Equal(extracted.PackSha256, ImpactorBundle.Sha256File(extracted.PackPath));
    }

    [Fact]
    public void RejectsPlaceholderPack()
    {
        using var temp = new TempDir();
        var ipa = BuildIpa(temp, "0004000000055E00", Encoding.ASCII.GetBytes("3DS2APPLE FAKE PACK"));
        var exception = Assert.Throws<LauncherToolException>(() => IpaPackExtractor.ExtractGamePack(ipa, Path.Combine(temp.Path, "out")));
        Assert.Equal("pack_placeholder", exception.Code);
    }
}

public sealed class UsbMuxClientTests
{
    [Fact]
    public void RequestFrameIsListDevices()
    {
        var frame = UsbMuxClient.BuildListDevicesRequest(7);
        var length = BitConverter.ToUInt32(frame, 0);
        Assert.Equal((uint)frame.Length, length);
        Assert.Equal(1u, BitConverter.ToUInt32(frame, 4));
        Assert.Equal(8u, BitConverter.ToUInt32(frame, 8));
        Assert.Equal(7u, BitConverter.ToUInt32(frame, 12));
        Assert.Contains("ListDevices", Encoding.UTF8.GetString(frame, 16, frame.Length - 16));
    }

    [Fact]
    public void ParsesDeviceListPlist()
    {
        const string plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>DeviceList</key><array>
              <dict><key>DeviceID</key><integer>12</integer><key>Properties</key><dict>
                <key>SerialNumber</key><string>00008030001</string>
                <key>ConnectionType</key><string>USB</string>
                <key>ProductID</key><integer>4776</integer>
              </dict></dict>
              <dict><key>DeviceID</key><integer>13</integer><key>Properties</key><dict>
                <key>SerialNumber</key><string>00008030002</string>
                <key>ConnectionType</key><string>Network</string>
              </dict></dict>
            </array></dict></plist>
            """;
        var devices = UsbMuxClient.ParseDeviceList(Encoding.UTF8.GetBytes(plist));
        Assert.Equal(2, devices.Count);
        Assert.Equal("00008030001", devices[0].Udid);
        Assert.Equal(12, devices[0].DeviceId);
        Assert.True(devices[0].IsUsb);
        Assert.Equal(4776, devices[0].ProductId);
        Assert.False(devices[1].IsUsb);
    }
}

public sealed class PushPlanAndSlugTests
{
    private const string Sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

    [Fact]
    public async Task PushPlanOrderAndManifest()
    {
        using var temp = new TempDir();
        var pack = temp.Bytes("GamePack.dylib", new byte[] { 0xCF, 0xFA, 0xED, 0xFE });
        var rom = temp.Bytes("game.cci", new byte[] { 1, 2, 3, 4, 5 });
        var plan = await GamePushPlan.CreateAsync(temp.Path, "0004000000055e00", "Pokémon Y", "CTR-P-EK2A", 1, pack, rom);
        Assert.Equal("Documents/Games/0004000000055E00", plan.RemoteDirectory);
        Assert.Equal(new[] { "GameRom.cci", "GameInfo.json" }, plan.Files.Select(file => file.RemoteName));
        Assert.Contains("GameInfo.json", plan.GameInfoPath);
        var manifest = await GameInfoWriter.ReadAsync(plan.GameInfoPath);
        Assert.NotNull(manifest);
        Assert.Equal(5, manifest!.Rom.Size);
        Assert.NotNull(manifest.Pack);
        Assert.Equal(4, manifest.Pack.Size);
        Assert.Equal("Frameworks/GamePack-0004000000055E00.dylib", manifest.Pack.File);
        Assert.True(manifest.PackBundled);
        Assert.NotEqual(Sha, manifest.Pack.Sha256);
        Assert.DoesNotContain(plan.Files, file => file.RemoteName.EndsWith(".dylib", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void BuildSlugIsScriptSafe()
    {
        Assert.Equal("pokemon-y-00055e00", BuildSlug.From("Pokémon Y", "0004000000055E00"));
        Assert.Equal("game-00055e00", BuildSlug.From("游戏", "0004000000055E00"));
        Assert.Matches("^[a-z0-9-]+$", BuildSlug.From("The Legend of Zelda: A Link Between Worlds", "00040000000ECB00"));
    }
}

public sealed class ShellManifestTests
{
    [Fact]
    public void VerifiesPinnedIpa()
    {
        using var temp = new TempDir();
        var ipa = temp.Bytes("shell.ipa", new byte[] { 1, 2, 3 });
        var sha = ImpactorBundle.Sha256File(ipa);
        var manifest = new ShellManifest(1, "shell.ipa", "0.2.0", "com.example.shell", sha, 3);
        var ok = manifest.Verify(temp.Path);
        Assert.True(ok.Ok);
        var bad = manifest with { Sha256 = new string('0', 64) };
        Assert.False(bad.Verify(temp.Path).Ok);
    }

    [Fact]
    public async Task MissingManifestReadsNull()
    {
        using var temp = new TempDir();
        Assert.Null(await ShellManifest.ReadAsync(temp.Path));
    }
}

public sealed class ToolLocatorTests
{
    [Fact]
    public void FindsDistributionBinary()
    {
        using var temp = new TempDir();
        var bin = Path.Combine(temp.Path, "Bin");
        Directory.CreateDirectory(bin);
        var tool = Path.Combine(bin, "3ds2apple-pack.exe");
        File.WriteAllText(tool, "stub");
        var locator = new ToolLocator(temp.Path);
        Assert.Equal(tool, locator.FindPackCli());
        Assert.Equal("0.1.0", ToolLocator.FirstVersionLikeToken("3ds2apple-pack 0.1.0"));
    }
}
