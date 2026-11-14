using System.Net.Sockets;
using System.Text;
using System.Xml.Linq;
using ThreeDsTwoApple.Launcher.Core.Models;

namespace ThreeDsTwoApple.Launcher.Core.Device;

/// <summary>One device as listed by usbmuxd, with the numeric id plumesign expects.</summary>
public sealed record MuxDevice(string Udid, int DeviceId, string ConnectionType, int? ProductId)
{
    public bool IsUsb => string.Equals(ConnectionType, "usb", StringComparison.OrdinalIgnoreCase);
}

/// <summary>
/// Minimal read-only client for the Apple device service (usbmuxd) on
/// 127.0.0.1:27015. It only sends <c>ListDevices</c>: the launcher needs the
/// numeric device id for plumesign's <c>--udid</c> (it compares device numbers,
/// not UDIDs) and a fallback device list when the device bridge is missing.
/// All transfers are done by devpush; this class never opens AFC.
/// </summary>
public sealed class UsbMuxClient
{
    public const int DefaultPort = 27015;
    private readonly int _port;
    private readonly string _host;

    public UsbMuxClient(string host = "127.0.0.1", int port = DefaultPort)
    {
        _host = host;
        _port = port;
    }

    public async Task<IReadOnlyList<MuxDevice>> ListDevicesAsync(TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        using var client = new TcpClient();
        try
        {
            using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            connectTimeout.CancelAfter(timeout ?? TimeSpan.FromSeconds(4));
            await client.ConnectAsync(_host, _port, connectTimeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new LauncherToolException("usbmuxd_unavailable",
                $"The Apple device service did not answer on {_host}:{_port}.",
                "Install Apple Devices (or iTunes) from Apple, start it, connect the iPhone/iPad, then refresh.");
        }
        catch (SocketException error)
        {
            throw new LauncherToolException("usbmuxd_unavailable",
                $"Could not reach the Apple device service on {_host}:{_port} ({error.SocketErrorCode}).",
                "Install Apple Devices (or iTunes) from Apple, start it, connect the iPhone/iPad, then refresh.");
        }

        using var stream = client.GetStream();
        using var ioTimeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        ioTimeout.CancelAfter(timeout ?? TimeSpan.FromSeconds(6));

        var request = BuildListDevicesRequest(1);
        await stream.WriteAsync(request, ioTimeout.Token).ConfigureAwait(false);

        var header = new byte[16];
        await ReadExactAsync(stream, header, ioTimeout.Token).ConfigureAwait(false);
        var length = BitConverter.ToUInt32(header, 0);
        if (length < 16 || length > 4 * 1024 * 1024)
        {
            throw new LauncherToolException("usbmux_protocol", $"usbmuxd answered with an invalid frame length ({length}).", "Restart Apple Devices / iTunes and reconnect the phone.");
        }
        var payload = new byte[length - 16];
        await ReadExactAsync(stream, payload, ioTimeout.Token).ConfigureAwait(false);
        return ParseDeviceList(payload);
    }

    /// <summary>Pick the requested UDID (USB first) or the only connected device.</summary>
    public async Task<MuxDevice?> FindAsync(string? udid, TimeSpan? timeout = null, CancellationToken cancellationToken = default)
    {
        var devices = await ListDevicesAsync(timeout, cancellationToken).ConfigureAwait(false);
        if (!string.IsNullOrWhiteSpace(udid))
        {
            return devices.Where(d => string.Equals(d.Udid, udid, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(d => d.IsUsb)
                .FirstOrDefault();
        }
        return devices.Count switch
        {
            1 => devices[0],
            _ => null,
        };
    }

    /// <summary>usbmuxd frame: length, version=1, messageType=8 (ListDevices), tag; XML plist payload.</summary>
    internal static byte[] BuildListDevicesRequest(uint tag)
    {
        const string requestPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
              <dict>
                <key>MessageType</key><string>ListDevices</string>
                <key>ClientVersionString</key><string>3ds2apple-launcher</string>
                <key>ProgName</key><string>3ds2apple-launcher</string>
                <key>kLibUSBMuxVersion</key><integer>3</integer>
              </dict>
            </plist>
            """;
        var body = Encoding.UTF8.GetBytes(requestPlist);
        var header = new byte[16];
        BitConverter.GetBytes((uint)(16 + body.Length)).CopyTo(header, 0);
        BitConverter.GetBytes(1u).CopyTo(header, 4);   // version
        BitConverter.GetBytes(8u).CopyTo(header, 8);   // ListDevices
        BitConverter.GetBytes(tag).CopyTo(header, 12);
        var frame = new byte[16 + body.Length];
        header.CopyTo(frame, 0);
        body.CopyTo(frame, 16);
        return frame;
    }

    /// <summary>Parse the XML plist ListDevices response into typed device rows.</summary>
    internal static IReadOnlyList<MuxDevice> ParseDeviceList(byte[] payload)
    {
        XDocument document;
        try
        {
            document = XDocument.Parse(Encoding.UTF8.GetString(payload));
        }
        catch (System.Xml.XmlException error)
        {
            throw new LauncherToolException("usbmux_protocol", $"usbmuxd returned an unreadable plist ({error.Message}).", "Restart Apple Devices / iTunes and reconnect the phone.");
        }
        if (document.Root is null)
        {
            return Array.Empty<MuxDevice>();
        }
        var rootValue = PlistValue(document.Root);
        if (rootValue is not Dictionary<string, object?> root)
        {
            return Array.Empty<MuxDevice>();
        }
        var devices = new List<MuxDevice>();
        if (root.TryGetValue("DeviceList", out var list) && list is List<object?> rows)
        {
            foreach (var row in rows)
            {
                if (row is not Dictionary<string, object?> entry)
                {
                    continue;
                }
                var properties = entry.TryGetValue("Properties", out var propertiesValue) ? propertiesValue as Dictionary<string, object?> : null;
                var serial = properties is not null && properties.TryGetValue("SerialNumber", out var serialValue) ? serialValue as string : null;
                if (string.IsNullOrWhiteSpace(serial))
                {
                    continue;
                }
                var deviceId = entry.TryGetValue("DeviceID", out var idValue) && idValue is long id ? (int)id : 0;
                var connection = properties is not null && properties.TryGetValue("ConnectionType", out var connectionValue) ? connectionValue as string ?? "usb" : "usb";
                var productId = properties is not null && properties.TryGetValue("ProductID", out var productValue) && productValue is long product ? (int)product : (int?)null;
                devices.Add(new MuxDevice(serial, deviceId, connection, productId));
            }
        }
        return devices;
    }

    private static object? PlistValue(XElement element) => element.Name.LocalName switch
    {
        "plist" => element.Elements().Select(PlistValue).FirstOrDefault(),
        "dict" => element.Elements().Chunk(2).Where(pair => pair.Length == 2 && pair[0].Name.LocalName == "key")
            .ToDictionary(pair => pair[0].Value, pair => PlistValue(pair[1]), StringComparer.Ordinal),
        "array" => element.Elements().Select(PlistValue).ToList(),
        "string" => element.Value,
        "integer" => long.TryParse(element.Value, out var number) ? number : 0L,
        "real" => double.TryParse(element.Value, System.Globalization.CultureInfo.InvariantCulture, out var real) ? real : 0d,
        "true" => true,
        "false" => false,
        "data" => Convert.FromBase64String(element.Value.Trim()),
        _ => element.Value,
    };

    private static async Task ReadExactAsync(NetworkStream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken).ConfigureAwait(false);
            if (read == 0)
            {
                throw new LauncherToolException("usbmux_protocol", "usbmuxd closed the connection mid-frame.", "Restart Apple Devices / iTunes and reconnect the phone.");
            }
            offset += read;
        }
    }
}
