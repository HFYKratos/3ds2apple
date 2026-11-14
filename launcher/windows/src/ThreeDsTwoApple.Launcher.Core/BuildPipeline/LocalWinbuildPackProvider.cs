using System.Security.Cryptography;
using System.Text.RegularExpressions;
using ThreeDsTwoApple.Launcher.Core.Models;
using ThreeDsTwoApple.Launcher.Core.Tools;

namespace ThreeDsTwoApple.Launcher.Core.BuildPipeline;

/// <summary>
/// Resolved paths for the experimental local build: 3dsrecomp (ROM -> C -> arm64
/// objects) plus the official open-source LLVM/Clang + ld64.lld toolchain and the
/// hand-written Darwin headers from tools/winbuild. No Apple SDK is involved and
/// no Apple file is required on the PC.
/// </summary>
public sealed record LocalToolchain(
    string? RecompilerPath,
    string? LlvmBinDirectory,
    string? ResourceIncludeDirectory,
    string? DarwinStubsDirectory,
    string? ShimSourcePath,
    string? GamePackIncludeDirectory,
    string? PackCliPath)
{
    /// <summary>File name of an LLVM tool on this OS (the launcher ships Windows binaries).</summary>
    public static string ToolFileName(string name) =>
        OperatingSystem.IsWindows() ? name + ".exe" : name;

    public string? ClangPath => Combine(LlvmBinDirectory, ToolFileName("clang"));
    public string? LlvmArPath => Combine(LlvmBinDirectory, ToolFileName("llvm-ar"));
    public string? Ld64LldPath => Combine(LlvmBinDirectory, ToolFileName("ld64.lld"));

    private static string? Combine(string? directory, string file) =>
        string.IsNullOrWhiteSpace(directory) ? null : Path.Combine(directory, file);

    /// <summary>Human names of everything missing; empty means the local build can run.</summary>
    public IReadOnlyList<string> MissingTools(
        Func<string, bool>? fileExists = null,
        Func<string, bool>? directoryExists = null)
    {
        var file = fileExists ?? File.Exists;
        var directory = directoryExists ?? Directory.Exists;
        var missing = new List<string>();
        if (!IsFile(file, RecompilerPath)) missing.Add("3dsrecomp.exe (set its path in Settings)");
        if (!IsFile(file, ClangPath)) missing.Add("clang.exe (install the official LLVM release and set its bin folder)");
        if (!IsFile(file, LlvmArPath)) missing.Add("llvm-ar.exe (part of the LLVM release)");
        if (!IsFile(file, Ld64LldPath)) missing.Add("ld64.lld.exe (part of the LLVM release)");
        if (!IsDirectory(directory, ResourceIncludeDirectory)) missing.Add("LLVM clang resource headers (lib/clang/<version>/include)");
        if (!IsDirectory(directory, DarwinStubsDirectory)) missing.Add("tools/winbuild/darwin-stubs/include (hand-written ISO C headers, no Apple SDK)");
        if (!IsFile(file, ShimSourcePath)) missing.Add("ios/zakuro-ios/gamepack/zk_gamepack_shim.c");
        if (!IsDirectory(directory, GamePackIncludeDirectory)) missing.Add("ios/zakuro-ios/include (zakuro_gamepack.h)");
        return missing;
    }

    private static bool IsFile(Func<string, bool> exists, string? path) =>
        !string.IsNullOrWhiteSpace(path) && exists(path);

    private static bool IsDirectory(Func<string, bool> exists, string? path) =>
        !string.IsNullOrWhiteSpace(path) && exists(path);
}

/// <summary>
/// Finds the local-build toolchain: explicit launcher settings override, then
/// environment variables, the bundled distribution layout, the dev checkout and
/// finally the official LLVM install location. Every path is reported; nothing
/// is guessed as ready.
/// </summary>
public static class LocalToolchainResolver
{
    public const string RepositoryEnvironmentVariable = "THREEDS2APPLE_REPO";
    public const string DarwinStubsEnvironmentVariable = "THREEDS2APPLE_DARWIN_STUBS";
    public const string LlvmEnvironmentVariable = "WINBUILD_LLVM_DIR";

    public static LocalToolchain Resolve(ToolLocator locator)
    {
        var repository = FindRepositoryRoot(locator.DistributionRoot);
        var llvm = locator.FindLlvmBinDirectory();
        return new LocalToolchain(
            RecompilerPath: locator.FindRecompiler(),
            LlvmBinDirectory: llvm,
            ResourceIncludeDirectory: FindResourceIncludeDirectory(llvm),
            DarwinStubsDirectory: FindDarwinStubs(locator, repository),
            ShimSourcePath: FindFirstFile(
                Path.Combine(locator.DistributionRoot, "tools", "winbuild", "zk_gamepack_shim.c"),
                repository is null ? null : Path.Combine(repository, "ios", "zakuro-ios", "gamepack", "zk_gamepack_shim.c")),
            GamePackIncludeDirectory: FindFirstDirectory(
                Path.Combine(locator.DistributionRoot, "tools", "winbuild", "include"),
                repository is null ? null : Path.Combine(repository, "ios", "zakuro-ios", "include")),
            PackCliPath: locator.FindPackCli());
    }

    /// <summary>Walk up from the distribution folder until the repo's winbuild stubs are found.</summary>
    public static string? FindRepositoryRoot(string distributionRoot)
    {
        var configured = Environment.GetEnvironmentVariable(RepositoryEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(configured) && Directory.Exists(configured))
        {
            return Path.GetFullPath(configured);
        }
        var current = new DirectoryInfo(Path.GetFullPath(distributionRoot));
        for (var level = 0; level < 8 && current is not null; level++)
        {
            if (Directory.Exists(Path.Combine(current.FullName, "tools", "winbuild", "darwin-stubs", "include")))
            {
                return current.FullName;
            }
            current = current.Parent;
        }
        return null;
    }

    /// <summary>lib/clang/&lt;highest version&gt;/include next to the LLVM bin folder.</summary>
    public static string? FindResourceIncludeDirectory(string? llvmBinDirectory)
    {
        if (string.IsNullOrWhiteSpace(llvmBinDirectory))
        {
            return null;
        }
        var root = Directory.GetParent(Path.GetFullPath(llvmBinDirectory).TrimEnd(Path.DirectorySeparatorChar));
        if (root is null)
        {
            return null;
        }
        var clangRoot = Path.Combine(root.FullName, "lib", "clang");
        if (!Directory.Exists(clangRoot))
        {
            return null;
        }
        var candidate = Directory.GetDirectories(clangRoot)
            .OrderByDescending(path => Version.TryParse(Path.GetFileName(path), out var version) ? version : new Version(0, 0))
            .Select(path => Path.Combine(path, "include"))
            .FirstOrDefault(Directory.Exists);
        return candidate;
    }

    private static string? FindDarwinStubs(ToolLocator locator, string? repository)
    {
        var configured = Environment.GetEnvironmentVariable(DarwinStubsEnvironmentVariable);
        return FindFirstDirectory(
            configured,
            Path.Combine(locator.DistributionRoot, "tools", "winbuild", "darwin-stubs", "include"),
            repository is null ? null : Path.Combine(repository, "tools", "winbuild", "darwin-stubs", "include"));
    }

    private static string? FindFirstDirectory(params string?[] candidates) =>
        candidates.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path) && Directory.Exists(path));

    private static string? FindFirstFile(params string?[] candidates) =>
        candidates.FirstOrDefault(path => !string.IsNullOrWhiteSpace(path) && File.Exists(path));
}

/// <summary>
/// Experimental local GamePack build: runs 3dsrecomp on this PC (ROM -> generated
/// C -> arm64 objects, with a clang wrapper that has no Apple SDK), then links
/// the GamePack dylib with LLVM's ld64.lld and records it through the pack CLI.
/// Feature-flagged in the launcher until a runtime end-to-end check ships.
/// </summary>
public sealed class LocalWinbuildPackProvider : IPackBuildProvider
{
    public const string MissingToolsCode = "local_tools_missing";
    public const string RecompFailedCode = "local_recomp_failed";
    public const string LinkFailedCode = "local_link_failed";
    public const string InvalidPackCode = "local_invalid_pack";
    public const string RecordFailedCode = "record_failed";

    private static readonly Regex CompiledLine = new(@"^compiled (\d+) of (\d+)$", RegexOptions.Compiled);
    private static readonly Regex WroteLine = new(@"^wrote (\d+) files", RegexOptions.Compiled);

    private readonly LocalToolchain? _tools;
    private readonly PackCli? _packCli;
    private readonly IProcessRunner _runner;
    private readonly Func<string, bool> _fileExists;
    private readonly Func<string, bool> _directoryExists;

    public LocalWinbuildPackProvider(
        LocalToolchain? tools,
        PackCli? packCli,
        IProcessRunner runner,
        Func<string, bool>? fileExists = null,
        Func<string, bool>? directoryExists = null)
    {
        _tools = tools;
        _packCli = packCli;
        _runner = runner;
        _fileExists = fileExists ?? File.Exists;
        _directoryExists = directoryExists ?? Directory.Exists;
    }

    public string Name => "Local build (3dsrecomp + open-source LLVM/LLD on this PC — experimental)";

    public bool Installable => true;

    public async Task<PackBuildOutcome> BuildAsync(
        PackBuildRequest request,
        IProgress<BuildProgress>? progress,
        Action<string>? log,
        CancellationToken cancellationToken = default)
    {
        if (_tools is null)
        {
            return PackBuildOutcome.Failure(MissingToolsCode,
                "The experimental local build is enabled but no toolchain was resolved. Install the official LLVM release (winget install LLVM.LLVM), build/install 3dsrecomp, and set the paths in Settings.");
        }
        var missing = _tools.MissingTools(_fileExists, _directoryExists);
        if (missing.Count > 0)
        {
            return PackBuildOutcome.Failure(MissingToolsCode,
                "The local build needs: " + string.Join("; ", missing) + ". See docs/windows-build.md (Windows local build) and tools/winbuild/README.md.");
        }
        if (string.IsNullOrWhiteSpace(request.RomPath) || !_fileExists(request.RomPath))
        {
            return PackBuildOutcome.Failure("local_rom_missing", "The ROM file for this game is missing: " + request.RomPath);
        }
        if (_packCli is null)
        {
            return PackBuildOutcome.Failure(RecordFailedCode, "3ds2apple-pack.exe is missing; it writes the single GameInfo.json schema.");
        }

        var buildName = BuildSlug.From(request.DisplayName, request.TitleID);
        var root = Path.Combine(request.WorkDirectory, "local-build", buildName);
        var recompDir = Path.Combine(root, "recomp");
        var objDir = Path.Combine(root, "obj");
        var dylibPath = Path.Combine(root, "GamePack-" + request.TitleID + ".dylib");
        Directory.CreateDirectory(root);
        Directory.CreateDirectory(objDir);

        var clang = _tools.ClangPath!;
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["CC"] = LocalToolchain.ToolFileName("clang") + " --target=arm64-apple-ios16.0",
            ["AR"] = _tools.LlvmArPath!,
            ["CPATH"] = _tools.DarwinStubsDirectory!,
            ["PATH"] = _tools.LlvmBinDirectory + Path.PathSeparator + (Environment.GetEnvironmentVariable("PATH") ?? string.Empty),
        };

        log?.Invoke($"Local build: {request.RomPath} -> {buildName} (3dsrecomp, then LLVM/LLD)");
        progress?.Report(new BuildProgress("recomp", 0, "Running 3dsrecomp (ROM -> C -> arm64 objects)…"));
        var recompArguments = new[] { "port", request.RomPath, recompDir, "--name", buildName };
        var recomp = await _runner.RunAsync(
            new ProcessRequest(_tools.RecompilerPath!, recompArguments, request.WorkDirectory, env, TimeSpan.FromMinutes(120)),
            onStdOutLine: line => OnRecompLine(line, progress, log),
            onStdErrLine: line => log?.Invoke("[recomp] " + line),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!recomp.Ok)
        {
            return PackBuildOutcome.Failure(RecompFailedCode,
                "3dsrecomp failed (exit " + recomp.ExitCode + "): " + FirstMeaningfulLine(recomp) + ". Run it once from a terminal to see the full log; a missing C compiler is the usual Windows cause.");
        }

        var archive = Path.Combine(recompDir, "code", "librecomp.a");
        if (!_fileExists(archive))
        {
            return PackBuildOutcome.Failure(RecompFailedCode,
                "3dsrecomp finished but produced no code/librecomp.a. Check that the ROM is a decrypted .3ds/.cci and that the LLVM clang wrapper works.");
        }

        progress?.Report(new BuildProgress("link", 90, "Linking the GamePack Mach-O with ld64.lld…"));
        var shimObject = Path.Combine(objDir, "zk_gamepack_shim.o");
        var shim = await _runner.RunAsync(
            new ProcessRequest(clang, new[]
            {
                "-target", "arm64-apple-ios16.0", "-O2", "-fPIC", "-nostdinc",
                "-isystem", _tools.ResourceIncludeDirectory!,
                "-isystem", _tools.DarwinStubsDirectory!,
                "-I", _tools.GamePackIncludeDirectory!,
                "-DZK_GAMEPACK_TITLE_ID=0x" + request.TitleID + "ULL",
                "-c", _tools.ShimSourcePath!,
                "-o", shimObject,
            }, root, Timeout: TimeSpan.FromMinutes(5)),
            onStdErrLine: line => log?.Invoke("[clang] " + line),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!shim.Ok)
        {
            return PackBuildOutcome.Failure(LinkFailedCode, "The GamePack shim did not compile: " + FirstMeaningfulLine(shim));
        }

        var linkArguments = new[]
        {
            "-arch", "arm64",
            "-platform_version", "ios", "16.0.0", "16.0.0",
            "-dylib",
            "-undefined", "dynamic_lookup",
            "-dead_strip",
            "-install_name", "@rpath/GamePack-" + request.TitleID + ".dylib",
            "-o", dylibPath,
            shimObject, archive,
        };
        var link = await _runner.RunAsync(
            new ProcessRequest(_tools.Ld64LldPath!, linkArguments, root, Timeout: TimeSpan.FromMinutes(10)),
            onStdErrLine: line => log?.Invoke("[ld64.lld] " + line),
            cancellationToken: cancellationToken).ConfigureAwait(false);
        if (!link.Ok)
        {
            return PackBuildOutcome.Failure(LinkFailedCode, "ld64.lld could not link the GamePack dylib: " + FirstMeaningfulLine(link));
        }

        progress?.Report(new BuildProgress("validate", 96, "Checking the Mach-O GamePack…"));
        if (!IsArm64MachODylib(dylibPath))
        {
            return PackBuildOutcome.Failure(InvalidPackCode,
                "The linker output is not an arm64 Mach-O dylib: " + dylibPath + ". Check the LLVM installation and the ROM's title.");
        }

        progress?.Report(new BuildProgress("record", 98, "Recording GameInfo.json through 3ds2apple-pack…"));
        var record = await _packCli.RecordAsync(request.TitleID, dylibPath, request.DisplayName, request.ProductCode, cancellationToken).ConfigureAwait(false);
        if (!record.Ok)
        {
            return PackBuildOutcome.Failure(RecordFailedCode, "The pack CLI could not record the pack: " + PackCli.FirstMeaningfulLine(record));
        }
        byte[] bytes;
        try
        {
            bytes = await File.ReadAllBytesAsync(dylibPath, cancellationToken).ConfigureAwait(false);
        }
        catch (IOException error)
        {
            return PackBuildOutcome.Failure(RecordFailedCode, "The recorded pack cannot be read back: " + error.Message);
        }
        var packRecord = new PackRecord(Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(), bytes.LongLength, "gamepack-macho");
        progress?.Report(new BuildProgress("done", 100, "Real GamePack built locally"));
        log?.Invoke($"Local build done: {dylibPath} ({packRecord.Bytes} bytes, sha256 {packRecord.Sha256})");
        return new PackBuildOutcome(true, true, dylibPath, packRecord, null, null, buildName);
    }

    private void OnRecompLine(string line, IProgress<BuildProgress>? progress, Action<string>? log)
    {
        var compiled = CompiledLine.Match(line);
        if (compiled.Success && int.TryParse(compiled.Groups[1].Value, out var done) && int.TryParse(compiled.Groups[2].Value, out var total) && total > 0)
        {
            var percent = 90.0 * done / total;
            progress?.Report(new BuildProgress("recomp", percent, $"Compiling generated C ({done}/{total})"));
            return;
        }
        var wrote = WroteLine.Match(line);
        if (wrote.Success)
        {
            progress?.Report(new BuildProgress("recomp", 5, "Generated C for " + wrote.Groups[1].Value + " source files"));
            return;
        }
        if (!string.IsNullOrWhiteSpace(line))
        {
            log?.Invoke("[recomp] " + line);
        }
    }

    /// <summary>Thin 64-bit Mach-O dylib with CPU type arm64 (MH_DYLIB = 6).</summary>
    public static bool IsArm64MachODylib(string path)
    {
        try
        {
            using var stream = File.OpenRead(path);
            Span<byte> header = stackalloc byte[16];
            if (stream.Read(header) != header.Length)
            {
                return false;
            }
            var magic = BitConverter.ToUInt32(header[..4]);
            var cpuType = BitConverter.ToInt32(header.Slice(4, 4));
            var fileType = BitConverter.ToUInt32(header.Slice(12, 4));
            const uint MHMagic64 = 0xFEEDFACF;
            const int CpuTypeArm64 = 0x0100000C;
            const uint MhDylib = 6;
            return magic == MHMagic64 && cpuType == CpuTypeArm64 && fileType == MhDylib;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static string FirstMeaningfulLine(ProcessResult result)
    {
        foreach (var line in result.Combined.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n'))
        {
            if (!string.IsNullOrWhiteSpace(line))
            {
                return line.Trim();
            }
        }
        return "exit code " + result.ExitCode;
    }
}
