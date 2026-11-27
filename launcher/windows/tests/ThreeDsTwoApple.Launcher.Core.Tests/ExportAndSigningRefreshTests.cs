using ThreeDsTwoApple.Launcher.Core.BuildPipeline;
using ThreeDsTwoApple.Launcher.Core.Deploy;
using ThreeDsTwoApple.Launcher.Core.LauncherState;
using ThreeDsTwoApple.Launcher.Core.Localization;
using ThreeDsTwoApple.Launcher.Core.Signing;
using Xunit;

namespace ThreeDsTwoApple.Launcher.Core.Tests;

/// <summary>0.2.2-beta5: both Library exports default to workspace/export/{32a,ipa}.</summary>
public sealed class ExportPathsTests
{
    [Fact]
    public void DefaultFoldersAreBelowWorkspaceExport()
    {
        using var temp = new TempDir();
        var workspaceRoot = Path.Combine(temp.Path, "workspace");

        Assert.Equal(Path.Combine(workspaceRoot, "export", "32a"), ExportPaths.BuildPackageDirectory(workspaceRoot));
        Assert.Equal(Path.Combine(workspaceRoot, "export", "ipa"), ExportPaths.IpaDirectory(workspaceRoot));

        var packageFolder = ExportPaths.DefaultBuildPackageFolder(workspaceRoot);
        var ipaFolder = ExportPaths.DefaultIpaFolder(workspaceRoot);
        Assert.True(Directory.Exists(packageFolder));
        Assert.True(Directory.Exists(ipaFolder));
        Assert.EndsWith(Path.Combine("export", "32a"), packageFolder, StringComparison.Ordinal);
        Assert.EndsWith(Path.Combine("export", "ipa"), ipaFolder, StringComparison.Ordinal);
    }

    [Fact]
    public void DefaultIpaPathUsesTheSharedTitleIdNameConvention()
    {
        using var temp = new TempDir();
        var workspaceRoot = Path.Combine(temp.Path, "workspace");
        const string titleId = "0004000000055E00";

        var path = ExportPaths.DefaultIpaPath(workspaceRoot, "Example Game", titleId);

        Assert.Equal(Path.Combine(workspaceRoot, "export", "ipa", titleId + "-Example Game.ipa"), path);
        Assert.Equal(titleId + "-Example Game.ipa", Path.GetFileName(path));
        Assert.True(Directory.Exists(Path.GetDirectoryName(path)));
    }

    [Fact]
    public void EnsureDirectoryIsIdempotent()
    {
        using var temp = new TempDir();
        var directory = Path.Combine(temp.Path, "export", "32a");
        Assert.Equal(directory, ExportPaths.EnsureDirectory(directory));
        Assert.Equal(directory, ExportPaths.EnsureDirectory(directory));
        Assert.True(Directory.Exists(directory));
    }
}

/// <summary>0.2.2-beta5 dialog copy: new labels, no long format descriptions.</summary>
public sealed class ExportDialogCopyTests
{
    [Fact]
    public void LabelsAndDestinationsMatchTheNewExportFolders()
    {
        Assert.Equal("Finished build package", LanguageCatalog.English["library.export.formatBuildPackage"]);
        Assert.Equal("已完成构建包", LanguageCatalog.ChineseSimplified["library.export.formatBuildPackage"]);
        Assert.Equal("Ready-to-sign package", LanguageCatalog.English["library.export.formatIpa"]);
        Assert.Equal("可自签安装包", LanguageCatalog.ChineseSimplified["library.export.formatIpa"]);

        Assert.Contains("workspace/export/32a", LanguageCatalog.English["library.export.destinationBuildPackage"], StringComparison.Ordinal);
        Assert.Contains("workspace/export/ipa", LanguageCatalog.English["library.export.destinationIpa"], StringComparison.Ordinal);
        Assert.Contains("workspace/export/32a", LanguageCatalog.ChineseSimplified["library.export.destinationBuildPackage"], StringComparison.Ordinal);
        Assert.Contains("workspace/export/ipa", LanguageCatalog.ChineseSimplified["library.export.destinationIpa"], StringComparison.Ordinal);
    }

    [Fact]
    public void TheLongFormatDescriptionsAreGone()
    {
        foreach (var key in new[] { "library.export.detailBuildPackage", "library.export.detailIpa" })
        {
            Assert.False(LanguageCatalog.English.ContainsKey(key), key);
            Assert.False(LanguageCatalog.ChineseSimplified.ContainsKey(key), key);
        }
    }

    [Fact]
    public void RefreshSigningCopyExplainsItOnlyRenewsTheLastIpa()
    {
        var hint = LanguageCatalog.English["deploy.refreshSigningHint"];
        Assert.Contains("7-day", hint, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("does not add games", hint, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("Disabled until an IPA exists", hint, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("不会新增游戏", LanguageCatalog.ChineseSimplified["deploy.refreshSigningHint"], StringComparison.Ordinal);
        Assert.Equal("签名已续期并完成安装，数据保留。", LanguageCatalog.ChineseSimplified["deploy.refreshSigningDone"]);
    }
}

/// <summary>0.2.2-beta5 "Refresh signing" path selection + install wiring.</summary>
public sealed class SigningRefreshServiceTests
{
    private const string TitleId = "0004000000055E00";

    private sealed class FakeInstaller : IAppIpaInstaller
    {
        public List<(string IpaPath, string? BundleIdOverride, string? DeviceUdid)> Calls { get; } = new();
        public bool Installed { get; set; } = true;

        public Task<ShellInstallOutcome> InstallAsync(
            ShellManifest shell,
            string shellDirectory,
            string ipaPath,
            string? bundleIdOverride,
            string? deviceUdid,
            Action<string>? log,
            CancellationToken cancellationToken)
        {
            Calls.Add((ipaPath, bundleIdOverride, deviceUdid));
            return Task.FromResult(new ShellInstallOutcome(Installed, shell.BundleId, null, null, null));
        }
    }

    private static ShellManifest Shell() => new(
        SchemaVersion: 1,
        FileName: "3ds2apple-shell.ipa",
        Version: "0.2.2",
        BundleId: "com.kratos.3ds2apple",
        Sha256: new string('a', 64),
        Bytes: 1,
        Build: 1);

    [Fact]
    public void RecordedIpaMustStillExistAndIsPersisted()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        var ipa = temp.Bytes("last.ipa", new byte[] { 1, 2, 3 });
        SigningRefreshService.RecordInstallableIpa(workspace, ipa);
        Assert.Equal(Path.GetFullPath(ipa), workspace.State.LastInstallableIpaPath);
        Assert.NotNull(workspace.State.LastInstallableIpaAt);

        var reopened = LauncherWorkspace.Open(temp.Path);
        Assert.Equal(Path.GetFullPath(ipa), reopened.State.LastInstallableIpaPath);
        Assert.True(new SigningRefreshService(reopened).CanRefresh);

        File.Delete(ipa);
        Assert.False(new SigningRefreshService(reopened).CanRefresh);
        SigningRefreshService.RecordInstallableIpa(reopened, Path.Combine(temp.Path, "missing.ipa"));
        Assert.Equal(Path.GetFullPath(ipa), reopened.State.LastInstallableIpaPath);
    }

    [Fact]
    public async Task RefreshInstallsTheSavedIpaOverTheExistingBundleId()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        var ipa = temp.Bytes("composed.ipa", new byte[] { 9, 9, 9 });
        SigningRefreshService.RecordInstallableIpa(workspace, ipa);
        workspace.State.InstalledBundleId = "com.kratos.3ds2apple.abc";
        workspace.SaveState();
        var installer = new FakeInstaller();
        var service = new SigningRefreshService(workspace);

        var outcome = await service.RefreshAsync(installer, Shell(), temp.Path, "device-udid", log: null);

        Assert.True(outcome.Installed, outcome.Error);
        var call = Assert.Single(installer.Calls);
        Assert.Equal(Path.GetFullPath(ipa), call.IpaPath);
        Assert.Equal("com.kratos.3ds2apple.abc", call.BundleIdOverride);
        Assert.Equal("device-udid", call.DeviceUdid);
        Assert.NotNull(workspace.State.InstalledAt);
    }

    [Fact]
    public async Task MissingIpaIsRefusedWithoutCallingTheInstaller()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        var installer = new FakeInstaller();
        var service = new SigningRefreshService(workspace);

        Assert.False(service.CanRefresh);
        var outcome = await service.RefreshAsync(installer, Shell(), temp.Path, null, log: null);

        Assert.False(outcome.Installed);
        Assert.Contains("Deploy", outcome.Error, StringComparison.OrdinalIgnoreCase);
        Assert.Empty(installer.Calls);
    }

    [Fact]
    public async Task InstallerFailureIsReportedVerbatim()
    {
        using var temp = new TempDir();
        var workspace = LauncherWorkspace.Open(temp.Path);
        var ipa = temp.Bytes("composed.ipa", new byte[] { 4, 4 });
        SigningRefreshService.RecordInstallableIpa(workspace, ipa);
        var installer = new FakeInstaller { Installed = false };
        var service = new SigningRefreshService(workspace);

        var outcome = await service.RefreshAsync(installer, Shell(), temp.Path, null, log: null);

        Assert.False(outcome.Installed);
        Assert.NotNull(outcome.Error);
        Assert.Single(installer.Calls);
    }
}
