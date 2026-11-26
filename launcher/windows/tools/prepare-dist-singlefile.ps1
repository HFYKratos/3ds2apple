<#
.SYNOPSIS
  Build the one-executable Windows launcher ZIP (self-contained .NET single-file).

.DESCRIPTION
  The exe embeds the ROM-free shell template, the pinned official Impactor/plumesign, the Bin/
  tool CLIs, 3dsrecomp.exe + the hand-written Darwin stubs/shim (Windows local build) and
  LICENSE/NOTICE/THIRD_PARTY. On first run it extracts them to
  <exe-dir>\3ds2apple-data\distribution\<version> when that folder is writable, and falls
  back to %LOCALAPPDATA%\3ds2apple\distribution\<version> for a read-only launcher folder
  (the workspace follows the same portable/LocalAppData rule). The user-facing ZIP contains
  3ds2apple-launcher.exe plus the repository licence texts (LICENSE, NOTICE, THIRD_PARTY.md)
  at the ZIP root, byte-identical to the repository files; those texts ship inside both
  platform packages and are never separate Release assets (see CONTRIBUTING.md#release-policy).
  The clean-run-win folder still holds only the exe.

  The official LLVM 23.1.6 toolchain is staged under Bin/llvm when present
  (THREEDS2APPLE_LLVM_DIR, default <repo>/build/win-toolchain/llvm). It is never faked: without
  it the packaged launcher's Deploy page shows one actionable local-toolchain error + Retry.

  This is the Windows-side twin of tools/prepare-dist-singlefile.sh (WSL). The WSL script is the
  one exercised in this checkout; this PowerShell version mirrors it for release engineers on a
  Windows PC. On Windows it also runs the clean-folder --self-test automatically.

.PARAMETER Output
  Output directory; defaults to the repo's git-ignored out/launchers/.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launcher/windows/tools/prepare-dist-singlefile.ps1
#>
[CmdletBinding()]
param(
    [string]$Output = ''
)

$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $windowsRoot)
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $repoRoot 'out/launchers'
}
New-Item -ItemType Directory -Force -Path $Output | Out-Null

$version = ([xml](Get-Content -Raw -LiteralPath (Join-Path $windowsRoot 'Directory.Build.props'))).Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.1.0' }
$exeName = '3ds2apple-launcher.exe'
$publishDir = Join-Path $Output 'publish-win-x64'
$zipPath = Join-Path $Output "3ds2apple-windows-single-$version.zip"

# 1. ROM-free base shell template + pinned manifest.
$shellDir = Join-Path $windowsRoot 'shell'
$shellManifest = Join-Path $shellDir 'manifest.json'
$shellIpa = Join-Path $shellDir '3ds2apple-shell.ipa'
if (-not (Test-Path -LiteralPath $shellManifest) -or -not (Test-Path -LiteralPath $shellIpa)) {
    Write-Error 'shell/manifest.json + shell/3ds2apple-shell.ipa are required (see shell/README.md).'
    exit 2
}
$shellDoc = Get-Content -Raw -LiteralPath $shellManifest | ConvertFrom-Json
$shellSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $shellIpa).Hash.ToLowerInvariant()
if ($shellSha -ne $shellDoc.sha256) {
    Write-Error "shell IPA SHA-256 $shellSha does not match shell/manifest.json ($($shellDoc.sha256))."
    exit 2
}
Write-Host "[single] shell template verified ($shellSha)"

# 2. Pinned official Impactor bundle.
if (-not (Test-Path -LiteralPath (Join-Path $windowsRoot 'vendor/impactor/Impactor-windows-x86_64-portable.exe'))) {
    & (Join-Path $windowsRoot 'tools/fetch-impactor.ps1')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# 3. Tool CLIs: rebuilt from this checkout's sources and capability-gated.
#    0.2.2-beta2 shipped a stale Bin/3ds2apple-pack.exe (0.2.0) whose clap parser
#    rejected the new "builds" / "catalog --auto-launch" commands, so both Library
#    exports failed. This script now refuses a stale CLI forever.
$cargo = if ($env:CARGO) { $env:CARGO } else { 'cargo' }
if (-not (Get-Command $cargo -ErrorAction SilentlyContinue)) {
    Write-Error 'cargo is required to rebuild the tool CLIs for the Windows package.'
    exit 2
}
$builderManifest = Join-Path $repoRoot 'builder/Cargo.toml'
$devpushManifest = Join-Path $repoRoot 'tools/devpush/Cargo.toml'
$packVersion = ((Select-String -Path $builderManifest -Pattern '^version = "([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value)
$devPushVersion = ((Select-String -Path $devpushManifest -Pattern '^version = "([^"]+)"' | Select-Object -First 1).Matches[0].Groups[1].Value)
if ([string]::IsNullOrWhiteSpace($packVersion) -or [string]::IsNullOrWhiteSpace($devPushVersion)) {
    Write-Error 'could not read the builder/devpush versions from their Cargo.toml files.'
    exit 2
}
if (-not (Select-String -Path (Join-Path $repoRoot 'builder/pack/src/main.rs') -Pattern 'Builds \{' -Quiet)) {
    Write-Error "builder/pack/src/main.rs has no 'builds' subcommand (launcher exports need it)."
    exit 2
}
Write-Host "[single] rebuilding tool CLIs from source: 3ds2apple-pack $packVersion, devpush $devPushVersion (target x86_64-pc-windows-gnu)"
Push-Location (Join-Path $repoRoot 'builder')
& $cargo build --release -p builder-pack --target x86_64-pc-windows-gnu
$packBuild = $LASTEXITCODE
Pop-Location
if ($packBuild -ne 0) {
    Write-Error 'could not build 3ds2apple-pack for x86_64-pc-windows-gnu.'
    exit 2
}
Push-Location (Join-Path $repoRoot 'tools/devpush')
& $cargo build --release --target x86_64-pc-windows-gnu
$devPushBuild = $LASTEXITCODE
Pop-Location
if ($devPushBuild -ne 0) {
    Write-Error 'could not build devpush for x86_64-pc-windows-gnu.'
    exit 2
}
$binDir = Join-Path $windowsRoot 'Bin'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item -Force -LiteralPath (Join-Path $repoRoot 'builder/target/x86_64-pc-windows-gnu/release/3ds2apple-pack.exe') -Destination (Join-Path $binDir '3ds2apple-pack.exe')
Copy-Item -Force -LiteralPath (Join-Path $repoRoot 'tools/devpush/target/x86_64-pc-windows-gnu/release/devpush.exe') -Destination (Join-Path $binDir 'devpush.exe')

# Capability gate: run the freshly built CLI (this script runs on Windows).
$packExe = Join-Path $binDir '3ds2apple-pack.exe'
$versionOut = (& $packExe --version 2>&1 | Out-String)
if ($versionOut -notmatch [regex]::Escape("3ds2apple-pack $packVersion")) {
    Write-Error ("Bin/3ds2apple-pack.exe version is not the current builder version " + $packVersion)
    exit 2
}
$helpOut = (& $packExe --help 2>&1 | Out-String)
if ($helpOut -notmatch 'builds') {
    Write-Error "Bin/3ds2apple-pack.exe has no 'builds' subcommand (stale CLI; exports would fail)."
    exit 2
}
$catalogHelp = (& $packExe catalog --help 2>&1 | Out-String)
if ($catalogHelp -notmatch '--auto-launch') {
    Write-Error "Bin/3ds2apple-pack.exe has no 'catalog --auto-launch' option (stale CLI; IPA export would fail)."
    exit 2
}
Write-Host "[single] pack CLI verified: version $packVersion, builds + catalog --auto-launch present"

# 3b. Windows local-build payload: 3dsrecomp.exe.
$recomp = Join-Path $windowsRoot 'Bin/3dsrecomp.exe'
if (-not (Test-Path -LiteralPath $recomp)) {
    foreach ($candidate in @(
            (Join-Path $repoRoot 'third_party/3dsrecomp/target/x86_64-pc-windows-gnu/release/3dsrecomp.exe'),
            (Join-Path $repoRoot 'third_party/3dsrecomp/target/release/3dsrecomp.exe'))) {
        if (Test-Path -LiteralPath $candidate) {
            Copy-Item -LiteralPath $candidate -Destination $recomp
            break
        }
    }
}
if (Test-Path -LiteralPath $recomp) {
    Write-Host "[single] 3dsrecomp.exe staged"
} else {
    Write-Warning 'Bin/3dsrecomp.exe is missing; Deploy will show one actionable local-toolchain error'
}

# 3c. Optional official LLVM 23.1.6 toolchain (real local GamePack compile).
$llvmSource = $env:THREEDS2APPLE_LLVM_DIR
if ([string]::IsNullOrWhiteSpace($llvmSource)) { $llvmSource = Join-Path $repoRoot 'build/win-toolchain/llvm' }
$llvmStage = Join-Path $windowsRoot 'Bin/llvm'
if ((Test-Path -LiteralPath (Join-Path $llvmSource 'bin/clang.exe')) -and (Test-Path -LiteralPath (Join-Path $llvmSource 'lib/clang'))) {
    if (Test-Path -LiteralPath $llvmStage) { Remove-Item -Recurse -Force -LiteralPath $llvmStage }
    New-Item -ItemType Directory -Force -Path (Join-Path $llvmStage 'bin') | Out-Null
    foreach ($tool in @('clang.exe', 'llvm-ar.exe', 'ld64.lld.exe', 'llvm-nm.exe', 'llvm-objdump.exe')) {
        $from = Join-Path $llvmSource "bin/$tool"
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $llvmStage 'bin/') }
    }
    # No runtime DLLs/PDBs: the official tools link only against system DLLs, and the
    # release folder's LLVM-C/libclang/LTO/libLLDB DLLs would add ~300 MB to the payload.
    foreach ($clangDir in Get-ChildItem -LiteralPath (Join-Path $llvmSource 'lib/clang') -Directory) {
        $include = Join-Path $clangDir.FullName 'include'
        if (Test-Path -LiteralPath $include) {
            $target = Join-Path $llvmStage ("lib/clang/" + $clangDir.Name)
            New-Item -ItemType Directory -Force -Path $target | Out-Null
            Copy-Item -Recurse -Force -LiteralPath $include -Destination $target
        }
    }
    foreach ($notice in @('LICENSE.TXT', 'LICENSE.txt')) {
        $from = Join-Path $llvmSource $notice
        if (Test-Path -LiteralPath $from) { Copy-Item -LiteralPath $from -Destination (Join-Path $llvmStage 'LICENSE.TXT') }
    }
    Write-Host "[single] LLVM staged under Bin/llvm"
} else {
    Write-Warning "official LLVM 23.1.6 not found at $llvmSource; packaging without it (Deploy shows one actionable local-toolchain error)"
}

# 4. Single-file self-contained publish (Release embeds the payload).
if (Test-Path -LiteralPath $publishDir) { Remove-Item -Recurse -Force -LiteralPath $publishDir }
New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
dotnet publish (Join-Path $windowsRoot 'src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj') `
    -c Release -r win-x64 --self-contained true -o $publishDir `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Get-ChildItem -LiteralPath $publishDir -Force | Where-Object { $_.Name -ne $exeName } | Remove-Item -Recurse -Force

# 5. ZIP = the exe + the repository licence texts at the ZIP root. The PowerShell
#    twin of the WSL script must produce the same archive contract that
#    scripts/release/verify-release.sh enforces on the published asset.
$licenseTexts = @('LICENSE', 'NOTICE', 'THIRD_PARTY.md')
foreach ($text in $licenseTexts) {
    $source = Join-Path $repoRoot $text
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Error "repository licence text is missing: $source"
        exit 2
    }
}
if (Test-Path -LiteralPath $zipPath) { Remove-Item -Force -LiteralPath $zipPath }
$zipInputs = @(Join-Path $publishDir $exeName) + @($licenseTexts | ForEach-Object { Join-Path $repoRoot $_ })
Compress-Archive -LiteralPath $zipInputs -DestinationPath $zipPath -CompressionLevel Optimal

# Positive/negative gate: exactly the exe + the three texts at the ZIP root, and
# the texts inside the archive are byte-identical to the repository files.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipArchive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $actualEntries = @($zipArchive.Entries | ForEach-Object { $_.FullName } | Sort-Object)
    $expectedEntries = @(@($exeName) + $licenseTexts | Sort-Object)
    if (Compare-Object -ReferenceObject $expectedEntries -DifferenceObject $actualEntries) {
        Write-Error "unexpected ZIP entries in ${zipPath}: $($actualEntries -join ', ')"
        exit 1
    }
    foreach ($text in $licenseTexts) {
        $entry = $zipArchive.GetEntry($text)
        $entryStream = $entry.Open()
        try {
            $sha256 = [System.Security.Cryptography.SHA256]::Create()
            try { $entryHash = ([BitConverter]::ToString($sha256.ComputeHash($entryStream)) -replace '-', '').ToLowerInvariant() }
            finally { $sha256.Dispose() }
        } finally { $entryStream.Dispose() }
        $repoHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $repoRoot $text)).Hash.ToLowerInvariant()
        if ($entryHash -ne $repoHash) {
            Write-Error "$text inside ${zipPath} ($entryHash) differs from the repository file ($repoHash)"
            exit 1
        }
    }
} finally {
    $zipArchive.Dispose()
}
Write-Host "[single] zip entries: $exeName + LICENSE + NOTICE + THIRD_PARTY.md (licence texts byte-identical to the repository)"
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Write-Host "[single] zip: $zipPath ($hash)"

# 6. Clean folder + real --self-test (Windows can execute the packaged exe).
$cleanDir = Join-Path $Output 'clean-run-win'
if (Test-Path -LiteralPath $cleanDir) { Remove-Item -Recurse -Force -LiteralPath $cleanDir }
New-Item -ItemType Directory -Force -Path $cleanDir | Out-Null
Copy-Item -LiteralPath (Join-Path $publishDir $exeName) -Destination $cleanDir
Push-Location $cleanDir
try {
    & (Join-Path $cleanDir $exeName) --self-test
    if ($LASTEXITCODE -ne 0) {
        Write-Error "clean-folder self-test FAILED (exit $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
    Write-Host '[single] clean-folder self-test PASS'
} finally {
    Pop-Location
}
