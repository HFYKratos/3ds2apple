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
  exactly one file: 3ds2apple-launcher.exe.

  The official LLVM 21.1.8 toolchain is staged under Bin/llvm when present
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

# 3. Tool CLIs.
foreach ($tool in @('3ds2apple-pack.exe', 'builder-windows.exe', 'devpush.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $windowsRoot "Bin/$tool"))) {
        Write-Error "Bin/$tool is missing. Build it for x86_64-pc-windows-gnu first."
        exit 2
    }
}

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

# 3c. Optional official LLVM 21.1.8 toolchain (real local GamePack compile).
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
    Write-Warning "official LLVM 21.1.8 not found at $llvmSource; packaging without it (Deploy shows one actionable local-toolchain error)"
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

# 5. ZIP with exactly one file inside.
if (Test-Path -LiteralPath $zipPath) { Remove-Item -Force -LiteralPath $zipPath }
Compress-Archive -LiteralPath (Join-Path $publishDir $exeName) -DestinationPath $zipPath -CompressionLevel Optimal
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
