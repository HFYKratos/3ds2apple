<#
.SYNOPSIS
  Build the one-executable Windows launcher ZIP (self-contained .NET single-file).

.DESCRIPTION
  The exe embeds the ROM-free shell template, the pinned official Impactor/plumesign,
  the Bin/ tool CLIs and LICENSE/NOTICE/THIRD_PARTY; on first run it extracts them to
  %LOCALAPPDATA%\3ds2apple\distribution\<version>. The user-facing ZIP contains exactly
  one file: 3ds2apple-launcher.exe.

  This is the Windows-side twin of tools/prepare-dist-singlefile.sh (WSL). The WSL
  script is the one exercised in this checkout; this PowerShell version mirrors it for
  release engineers on a Windows PC.

.PARAMETER Output
  Output directory; the ZIP is written as 3ds2apple-windows-single-<version>.zip.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launcher/windows/tools/prepare-dist-singlefile.ps1
#>
[CmdletBinding()]
param(
    [string]$Output = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $PSScriptRoot
$windowsRoot = Split-Path -Parent $scriptDir
$repoRoot = Split-Path -Parent (Split-Path -Parent $windowsRoot)
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $repoRoot 'dist/windows-single'
}
New-Item -ItemType Directory -Force -Path $Output | Out-Null

$version = ([xml](Get-Content -Raw -LiteralPath (Join-Path $windowsRoot 'Directory.Build.props'))).Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($version)) { $version = '0.1.0' }
$exeName = '3ds2apple-launcher.exe'
$publishDir = Join-Path $Output 'publish'
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

# 4. Single-file self-contained publish (Release embeds the payload).
if (Test-Path -LiteralPath $publishDir) { Remove-Item -Recurse -Force -LiteralPath $publishDir }
New-Item -ItemType Directory -Force -Path $publishDir | Out-Null
dotnet publish (Join-Path $windowsRoot 'src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj') `
    -c Release -r win-x64 --self-contained true -o $publishDir `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=true -p:DebugType=None -p:DebugSymbols=false --nologo
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Get-ChildItem -LiteralPath $publishDir -File | Where-Object { $_.Name -ne $exeName } | Remove-Item -Force

# 5. ZIP with exactly one file inside.
if (Test-Path -LiteralPath $zipPath) { Remove-Item -Force -LiteralPath $zipPath }
Compress-Archive -LiteralPath (Join-Path $publishDir $exeName) -DestinationPath $zipPath -CompressionLevel Optimal
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
Write-Host "[single] zip: $zipPath ($hash)"
Write-Host "[single] next: run $exeName --self-test from a folder that contains only the exe"
