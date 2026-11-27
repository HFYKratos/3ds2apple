namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Default Library export folders (0.2.2-beta5): everything lives below the
/// portable data root's workspace:
///   .32a build package -> &lt;data&gt;/workspace/export/32a/
///   single-game IPA    -> &lt;data&gt;/workspace/export/ipa/
/// The launcher creates the folder before exporting; the dialog shows this path.
/// </summary>
public static class ExportPaths
{
    public const string ExportDirectoryName = "export";
    public const string BuildPackageDirectoryName = "32a";
    public const string IpaDirectoryName = "ipa";

    /// <summary>&lt;workspace root&gt;/export/32a (workspace root itself is &lt;data&gt;/workspace).</summary>
    public static string BuildPackageDirectory(string workspaceRoot) =>
        Path.Combine(workspaceRoot, ExportDirectoryName, BuildPackageDirectoryName);

    /// <summary>&lt;workspace root&gt;/export/ipa.</summary>
    public static string IpaDirectory(string workspaceRoot) =>
        Path.Combine(workspaceRoot, ExportDirectoryName, IpaDirectoryName);

    /// <summary>Create a folder (idempotent) and return it.</summary>
    public static string EnsureDirectory(string directory)
    {
        Directory.CreateDirectory(directory);
        return directory;
    }

    /// <summary>Default .32a destination folder, created on demand.</summary>
    public static string DefaultBuildPackageFolder(string workspaceRoot) =>
        EnsureDirectory(BuildPackageDirectory(workspaceRoot));

    /// <summary>Default IPA folder, created on demand.</summary>
    public static string DefaultIpaFolder(string workspaceRoot) =>
        EnsureDirectory(IpaDirectory(workspaceRoot));

    /// <summary>Default full IPA path: &lt;workspace&gt;/export/ipa/TITLE_ID-English name.ipa.</summary>
    public static string DefaultIpaPath(string workspaceRoot, string gameName, string titleId) =>
        Path.Combine(DefaultIpaFolder(workspaceRoot), SingleGameIpaExporter.OutputFileName(gameName, titleId));
}
