using ThreeDsTwoApple.Launcher.Core.Device;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.Core.Deploy;

/// <summary>One device inspection request: the app bundle id, the optional device and the games to stat.</summary>
public sealed record DeviceDeployInspectRequest(string BundleId, string? DeviceUdid, IReadOnlyList<string> TitleIds);

/// <summary>One marker write request (after a successful deploy).</summary>
public sealed record DeviceDeployMarkerWriteRequest(string BundleId, string? DeviceUdid, DeviceDeployMarker Marker);

/// <summary>
/// Reads the phone's deploy-relevant state (app identity, Documents/Games contents, marker)
/// and writes the marker back. The interface keeps the orchestration pure-testable; the
/// shipped implementation goes through the devpush/1 CLI only.
/// </summary>
public interface IDeviceDeployInspector
{
    Task<DeviceDeploySnapshot> InspectAsync(DeviceDeployInspectRequest request, Action<string>? log, CancellationToken cancellationToken = default);

    Task WriteMarkerAsync(DeviceDeployMarkerWriteRequest request, Action<string>? log, CancellationToken cancellationToken = default);
}

/// <summary>
/// Device-aware deploy inspection over <see cref="DevPushClient"/>.
/// </summary>
/// <remarks>
/// Contract used (all JSON, devpush/1):
/// - <c>app-attr --bundle-id &lt;id&gt; --json</c> -> <c>keys</c> map with
///   CFBundleShortVersionString / CFBundleVersion / ThreeDS2ApplePackageVersion;
/// - <c>ls --path Documents/Games --container app</c> -> one directory per installed TITLEID;
/// - <c>stat Documents/Games/&lt;TITLEID&gt;/GameRom.cci</c> and <c>GameInfo.json</c> -> sizes;
/// - <c>get Documents/.3ds2apple-deploy.json</c> -> the launcher marker (path_not_found is
///   "no marker yet", never an error).
/// The marker download/upload goes through the workspace staging directory; nothing is left
/// behind (.3ds2apple-deploy.json is the fixed remote name required by the design).
/// </remarks>
public sealed class DevPushDeviceDeployInspector : IDeviceDeployInspector
{
    private const string GamesDirectory = "Documents/Games";
    private readonly DevPushClient _client;
    private readonly string _stagingDirectory;

    public DevPushDeviceDeployInspector(DevPushClient client, string stagingDirectory)
    {
        _client = client;
        _stagingDirectory = stagingDirectory;
    }

    public async Task<DeviceDeploySnapshot> InspectAsync(DeviceDeployInspectRequest request, Action<string>? log, CancellationToken cancellationToken = default)
    {
        var attributes = await _client.AppAttrAsync(request.BundleId, request.DeviceUdid, cancellationToken).ConfigureAwait(false);
        if (!attributes.Installed)
        {
            log?.Invoke("device: the app (" + request.BundleId + ") is not installed yet; the next deploy will install it.");
            return new DeviceDeploySnapshot(
                DeviceAppIdentity.NotInstalled,
                Array.Empty<string>(),
                new Dictionary<string, DeviceGameData>(StringComparer.OrdinalIgnoreCase),
                null);
        }

        var app = new DeviceAppIdentity(true, attributes.ShortVersion, attributes.BuildVersion, attributes.PackageVersion);
        var installedIds = await ListInstalledGamesAsync(request, log, cancellationToken).ConfigureAwait(false);
        var titleIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var id in installedIds)
        {
            titleIds.Add(id);
        }
        foreach (var id in request.TitleIds)
        {
            if (TryNormalizeTitleId(id, out var normalized))
            {
                titleIds.Add(normalized);
            }
        }
        var data = new Dictionary<string, DeviceGameData>(StringComparer.OrdinalIgnoreCase);
        foreach (var titleId in titleIds)
        {
            var romBytes = await StatSizeAsync(request, titleId + "/GameRom.cci", cancellationToken).ConfigureAwait(false);
            var infoBytes = await StatSizeAsync(request, titleId + "/GameInfo.json", cancellationToken).ConfigureAwait(false);
            data[titleId] = new DeviceGameData(titleId, romBytes, infoBytes);
        }
        var marker = await ReadMarkerAsync(request, log, cancellationToken).ConfigureAwait(false);
        log?.Invoke("device: app " + app.Describe()
                    + "; " + installedIds.Count + " game(s) in Documents/Games"
                    + (marker is null ? "; no deploy marker (state unknown)" : "; deploy marker updated " + marker.UpdatedAt));
        return new DeviceDeploySnapshot(app, installedIds, data, marker);
    }

    public async Task WriteMarkerAsync(DeviceDeployMarkerWriteRequest request, Action<string>? log, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_stagingDirectory);
        var localPath = Path.Combine(_stagingDirectory, ".3ds2apple-deploy.write.json");
        try
        {
            await File.WriteAllTextAsync(localPath, request.Marker.ToJson(), cancellationToken).ConfigureAwait(false);
            await _client.PutAsync(
                request.BundleId,
                localPath,
                DeviceDeployMarker.RemotePath,
                container: "app",
                udid: request.DeviceUdid,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            log?.Invoke("deploy marker written: app package " + request.Marker.AppPackageVersion + ", " + request.Marker.Games.Count + " game(s)");
        }
        finally
        {
            TryDelete(localPath);
        }
    }

    private async Task<IReadOnlyList<string>> ListInstalledGamesAsync(DeviceDeployInspectRequest request, Action<string>? log, CancellationToken cancellationToken)
    {
        try
        {
            var entries = await _client.ListAsync(request.BundleId, GamesDirectory, "app", request.DeviceUdid, cancellationToken).ConfigureAwait(false);
            var ids = new List<string>();
            foreach (var entry in entries)
            {
                if (entry.IsDir && TryNormalizeTitleId(entry.Name, out var normalized))
                {
                    ids.Add(normalized);
                }
            }
            return ids;
        }
        catch (LauncherToolException error) when (error.Code is "path_not_found")
        {
            return Array.Empty<string>();
        }
        catch (LauncherToolException error)
        {
            log?.Invoke("device: could not list " + GamesDirectory + " (" + error.Code + "); assuming no game data is installed.");
            return Array.Empty<string>();
        }
    }

    private async Task<long?> StatSizeAsync(DeviceDeployInspectRequest request, string relativePath, CancellationToken cancellationToken)
    {
        var entry = await _client.StatAsync(request.BundleId, GamesDirectory + "/" + relativePath, "app", request.DeviceUdid, cancellationToken).ConfigureAwait(false);
        return entry is null || entry.IsDir ? null : entry.Size;
    }

    private async Task<DeviceDeployMarker?> ReadMarkerAsync(DeviceDeployInspectRequest request, Action<string>? log, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_stagingDirectory);
        var localPath = Path.Combine(_stagingDirectory, ".3ds2apple-deploy.read.json");
        try
        {
            await _client.GetAsync(
                request.BundleId,
                DeviceDeployMarker.RemotePath,
                localPath,
                container: "app",
                udid: request.DeviceUdid,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            var text = await File.ReadAllTextAsync(localPath, cancellationToken).ConfigureAwait(false);
            var marker = DeviceDeployMarker.Parse(text);
            if (marker is null)
            {
                log?.Invoke("device: " + DeviceDeployMarker.RemotePath + " exists but is not a launcher deploy marker; treating the state as unknown.");
            }
            return marker;
        }
        catch (LauncherToolException error) when (error.Code is "path_not_found")
        {
            return null;
        }
        finally
        {
            TryDelete(localPath);
        }
    }

    private static bool TryNormalizeTitleId(string? value, out string normalized)
    {
        normalized = (value ?? string.Empty).Trim().ToUpperInvariant();
        if (normalized.Length != 16 || normalized.Any(c => !Uri.IsHexDigit(c)))
        {
            normalized = string.Empty;
            return false;
        }
        return true;
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // A stale staging file is harmless; the next write overwrites it.
        }
    }
}
