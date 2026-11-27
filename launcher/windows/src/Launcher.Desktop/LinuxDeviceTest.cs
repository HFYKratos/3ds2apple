using ThreeDsTwoApple.Launcher.Core;
using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Signing;
using ThreeDsTwoApple.Launcher.Core.Util;

namespace ThreeDsTwoApple.Launcher.App;

/// <summary>
/// P1 real-device acceptance entry (developer/testing only): runs the launcher's
/// own service layer (import -> DeployOrchestrator -> plumesign installer ->
/// devpush pusher -> verify -> Refresh signing) without Avalonia so a headless
/// Linux machine can be driven over SSH. It prints only sanitized status lines and
/// never prints the Apple ID, password, 2FA code or device UDID.
///
///   --linux-device-test [--workspace <dir>] [--package <32a>]
///                       [--no-deploy] [--refresh-signing] [--report <path>]
/// </summary>
internal static class LinuxDeviceTest
{
    public static async Task<int> RunAsync(string[] args)
    {
        var workspace = Option(args, "--workspace");
        if (!string.IsNullOrWhiteSpace(workspace))
        {
            Environment.SetEnvironmentVariable("THREEDS2APPLE_WORKSPACE", workspace);
        }
        var package = Option(args, "--package");
        var reportPath = Option(args, "--report");
        var refreshSigning = args.Contains("--refresh-signing");
        var noDeploy = args.Contains("--no-deploy");
        var rom = Option(args, "--rom");
        var skipAccount = args.Contains("--skip-account");
        var aotName = Option(args, "--name");
        var aotExport = args.Contains("--export-32a");
        var lines = new List<string>();
        void Line(string text)
        {
            var safe = Privacy.SanitizeLogLine(RedactAppleId(text));
            Console.WriteLine(safe);
            lines.Add(safe);
        }

        void SaveReport()
        {
            if (string.IsNullOrWhiteSpace(reportPath))
            {
                return;
            }
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath))!);
                File.WriteAllLines(reportPath, lines);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                Console.WriteLine("linux-device-test: could not write report: " + exception.Message);
            }
        }

        try
        {
            var services = LauncherServices.Create();
            var state = services.Workspace;
            Line("linux-device-test: workspace=" + state.Root);
            Line("linux-device-test: shell dir=" + services.ShellDirectory);

            if (!string.IsNullOrWhiteSpace(rom))
            {
                var exit = await RunAotBuildAsync(services, rom!, aotName, aotExport, Line);
                SaveReport();
                return exit;
            }

            if (!skipAccount)
            {
                var accountService = services.CreatePlumesignAccountService();
                var accountStatus = accountService is null ? null : await accountService.StatusAsync();
                Line("account: signedIn=" + (accountStatus?.SignedIn == true) + " — " + (accountStatus?.Summary ?? "plumesign missing"));
                if (accountStatus?.SignedIn != true)
                {
                    Line("RESULT: ACCOUNT_NOT_SIGNED_IN");
                    SaveReport();
                    return 3;
                }
            }
            else
            {
                Line("account: skipped (--skip-account; local AOT/cache verification only)");
            }

            string? deviceUdid = null;
            if (services.DevPush is { } bridge)
            {
                try
                {
                    var devices = await bridge.DevicesAsync();
                    var usb = devices.Where(device => device.IsUsb).ToList();
                    Line("device: connected=" + devices.Count + " usb=" + usb.Count
                         + (usb.Count > 0 ? " — " + usb[0].Display : string.Empty));
                    deviceUdid = (usb.Count > 0 ? usb[0] : devices.FirstOrDefault())?.Udid;
                }
                catch (Exception exception) when (exception is LauncherToolException or IOException or UnauthorizedAccessException)
                {
                    Line("device: unavailable (" + exception.Message + ") — import/cache verification continues");
                }
            }
            else
            {
                Line("device: devpush bridge missing");
            }

            var shell = await services.LoadShellAsync();
            if (shell is null)
            {
                Line("RESULT: SHELL_MISSING");
                SaveReport();
                return 4;
            }
            Line("shell: v" + shell.Version + " build " + shell.Build + " bundle=" + shell.BundleId
                 + " verify=" + shell.Verify(services.ShellDirectory).Ok);

            var compatibility = await services.BuildCompatibility.ResolveAsync();
            if (!string.IsNullOrWhiteSpace(package))
            {
                Line("import: " + package);
                var import = await services.CreateBuildPackageService().ImportAsync(package, replace: true, compatibility);
                Line("import: ok=" + import.Ok + (import.Error is null ? string.Empty : " error=" + import.Error));
                Line("import: cache=" + import.BuildCacheStatus + " — " + (import.BuildCacheDetail ?? string.Empty));
            }
            foreach (var game in state.State.Games)
            {
                var build = game.Build;
                Line("game: " + game.TitleID + " buildRecord=" + (build is null ? "none" : build.BuildCompatShort)
                     + " launcher=" + (build?.LauncherVersion ?? "-"));
            }
            if (noDeploy)
            {
                Line("deploy: skipped (--no-deploy)");
                SaveReport();
                return 0;
            }
            var entries = state.State.Games;
            if (entries.Count == 0)
            {
                Line("deploy: no games in the workspace");
                SaveReport();
                return 2;
            }
            var orchestrator = services.CreateDeployOrchestrator(shell);
            var request = new DeployRequest(
                entries.Select(entry => entry.TitleID).ToList(),
                Path.Combine(services.ShellDirectory, shell.FileName),
                BundleIdOverride: null,
                DeviceUdid: deviceUdid,
                RebuildExistingPacks: false,
                AcceptOrphanedGames: false);
            var progress = new Progress<DeployProgress>(item =>
                Line("deploy progress: " + item.Step + " " + item.Status + " — " + item.Message));
            var outcome = await orchestrator.RunAsync(request, progress, line => Line("[deploy] " + line));
            Line("deploy: success=" + outcome.Success + " failedStep=" + (outcome.FailedStep?.ToString() ?? "-")
                 + " error=" + (outcome.ErrorCode ?? "-") + " message=" + (outcome.ErrorMessage ?? "-"));
            foreach (var game in outcome.Games)
            {
                Line("deploy game: " + game.TitleID + " built=" + game.Built + " pushed=" + game.Pushed
                     + " verified=" + game.Verified + " error=" + (game.ErrorCode ?? "-") + " " + (game.ErrorMessage ?? string.Empty));
            }
            if (!outcome.Success)
            {
                Line("deploy fix: " + (outcome.ErrorFix ?? "-"));
            }
            if (outcome.Success)
            {
                SigningRefreshService.RecordInstallableIpa(state, outcome.ComposedIpaPath);
            }

            var ok = outcome.Success;
            if (refreshSigning)
            {
                var installer = services.CreateShellInstallService();
                if (installer is null)
                {
                    Line("refresh-signing: no installer");
                    ok = false;
                }
                else
                {
                    var signing = new SigningRefreshService(state);
                    Line("refresh-signing: canRefresh=" + signing.CanRefresh);
                    var refreshed = await signing.RefreshAsync(
                        installer, shell, services.ShellDirectory, deviceUdid, line => Line("[refresh] " + line));
                    Line("refresh-signing: installed=" + refreshed.Installed + " error=" + (refreshed.Error ?? "-"));
                    ok = ok && refreshed.Installed;
                }
            }
            Line("RESULT: " + (ok ? "DEPLOY_OK" : "DEPLOY_FAILED"));
            SaveReport();
            return ok ? 0 : 1;
        }
        catch (Exception exception)
        {
            Line("RESULT: EXCEPTION " + exception);
            SaveReport();
            return 1;
        }
    }

    /// <summary>AOT: build a real GamePack from a user ROM with the Linux payload's own toolchain, then export a .32a.</summary>
    private static async Task<int> RunAotBuildAsync(
        LauncherServices services,
        string romPath,
        string? name,
        bool export,
        Action<string> line)
    {
        if (!File.Exists(romPath))
        {
            line("aot: ROM not found: " + romPath);
            return 2;
        }
        if (services.Pack is not { } pack)
        {
            line("aot: 3ds2apple-pack is missing from the payload");
            return 2;
        }
        var provider = services.CreateDeployBuildProvider();
        if (provider is null)
        {
            line("aot: no local build provider (3ds2apple-pack missing)");
            return 2;
        }
        line("aot: provider=" + provider.Name + " installable=" + provider.Installable);
        var tools = services.LocalTools;
        line("aot: recompiler=" + (tools?.RecompilerPath ?? "missing")
             + " llvm=" + (tools?.LlvmBinDirectory ?? "missing")
             + " stubs=" + (tools?.DarwinStubsDirectory ?? "missing"));
        if (tools is not null)
        {
            var missing = tools.MissingTools();
            line("aot: missingTools=" + (missing.Count == 0 ? "none" : string.Join("; ", missing)));
        }

        var added = await pack.AddAsync(new[] { romPath }, name);
        var errors = added.Errors.Count > 0 ? string.Join("; ", added.Errors) : string.Empty;
        line("aot: romImport ok=" + added.Ok + (errors.Length > 0 ? " errors=" + errors : string.Empty));
        var imported = added.Packages.FirstOrDefault();
        if (imported is null)
        {
            line("aot: pack CLI returned no package for the ROM");
            return 2;
        }
        var titleId = imported.TitleID;
        var displayName = string.IsNullOrWhiteSpace(imported.DisplayName) ? (name ?? titleId) : imported.DisplayName;
        line("aot: title=" + titleId + " display=" + displayName);

        var work = Path.Combine(services.Workspace.WorkDirectory, "linux-aot", titleId);
        var request = new PackBuildRequest(titleId, displayName, imported.ProductCode, romPath, work);
        var progress = new Progress<BuildProgress>(item => line("aot progress: " + item.Stage + " " + (item.Percent?.ToString("F0") ?? "?") + "% — " + item.Message));
        var outcome = await provider.BuildAsync(request, progress, text => line("[aot] " + text));
        line("aot: success=" + outcome.Success + " installable=" + outcome.Installable
             + " pack=" + (outcome.PackPath ?? "-") + " error=" + (outcome.ErrorCode ?? "-") + " " + (outcome.ErrorMessage ?? string.Empty));
        if (!outcome.Success)
        {
            line("RESULT: AOT_BUILD_FAILED");
            return 1;
        }
        if (outcome.Pack is { } packRecord)
        {
            line("aot: pack sha256=" + packRecord.Sha256 + " bytes=" + packRecord.Bytes);
        }
        if (!export)
        {
            line("aot: .32a export skipped (--export-32a not set)");
            line("RESULT: AOT_BUILD_OK");
            return 0;
        }
        var exportRoot = Path.Combine(services.Workspace.Root, "linux-aot-export");
        var compatibility = await services.BuildCompatibility.ResolveAsync();
        var exported = await pack.ExportBuildsAsync(
            new[] { titleId },
            exportRoot,
            LauncherInfo.Version,
            LauncherInfo.Version,
            compatibility.ClangVersion,
            compatibility.Ld64Version,
            "O2",
            lto: false,
            fastMath: false,
            romDirectories: new[] { Path.GetDirectoryName(Path.GetFullPath(romPath))! });
        foreach (var build in exported.Packages)
        {
            line("aot: .32a " + build.Path + " bytes=" + build.Bytes + " sha256=" + build.Sha256 + " romIncluded=" + build.RomIncluded);
        }
        line("aot: export ok=" + exported.Ok + (exported.Errors.Count > 0 ? " errors=" + string.Join("; ", exported.Errors) : string.Empty));
        line("RESULT: " + (exported.Ok ? "AOT_EXPORT_OK" : "AOT_EXPORT_FAILED"));
        return exported.Ok ? 0 : 1;
    }

    private static string RedactAppleId(string text) =>
        System.Text.RegularExpressions.Regex.Replace(
            text,
            @"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}",
            "<apple-id>",
            System.Text.RegularExpressions.RegexOptions.CultureInvariant);

    private static string? Option(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}
