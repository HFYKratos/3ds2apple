<#
.SYNOPSIS
  Assemble the Windows launcher distribution directory.

.DESCRIPTION
  Publishes the Avalonia launcher self-contained, copies the pinned official Impactor bundle
  (fetching it if needed, verified against PINS.json), the base shell IPA + manifest, the tool
  CLIs (3ds2apple-pack, devpush, builder-windows) and the licence/notice files, then writes
  SHA256SUMS and build-info.txt.

  The importer only accepts real, verified files: a missing base shell or an unverified signer
  aborts the build instead of producing a package that cannot install anything.

.PARAMETER Output
  Target directory. Must not exist (no mixing old and new files).

.PARAMETER Version
  Informational version written to build-info.txt (the exe version comes from the project).

.PARAMETER PackCli / DevPush / BuilderCli
  Prebuilt tool executables to bundle. Default: build them with cargo from this checkout.

.PARAMETER SkipShell
  Build without a shell IPA (development preview only; install/push stay disabled).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File launcher/windows/tools/prepare-dist.ps1 -Version 0.1.0
#>
[CmdletBinding()]
param(
    [string]$Output = 'dist/3ds2apple-launcher',
    [string]$Version = '0.1.0',
    [string]$Configuration = 'Release',
    [string]$PackCli = '',
    [string]$DevPush = '',
    [string]$BuilderCli = '',
    [switch]$SkipShell
)

$ErrorActionPreference = 'Stop'
$windowsRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $windowsRoot)
$outputPath = if ([System.IO.Path]::IsPathRooted($Output)) { $Output } else { Join-Path (Get-Location) $Output }

if (Test-Path -LiteralPath $outputPath) {
    Write-Error "Output $outputPath already exists; use a fresh directory (no mixing old and new files)."
    exit 2
}
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null
Write-Host "[dist] $outputPath"

# 1. launcher executable (self-contained: the user installs no .NET runtime)
$x = Join-Path $windowsRoot 'src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj'
dotnet publish $x -c $Configuration -r win-x64 --self-contained true -p:PublishSingleFile=false -o $outputPath
if ($LASTEXITCODE -ne 0) { Write-Error 'dotnet publish failed'; exit 1 }

# 2. tool CLIs into Bin/
$bin = Join-Path $outputPath 'Bin'
New-Item -ItemType Directory -Force -Path $bin | Out-Null
if ([string]::IsNullOrWhiteSpace($PackCli)) {
    Write-Host '[dist] cargo build -p builder-pack --release'
    Push-Location (Join-Path $repoRoot 'builder')
    cargo build -p builder-pack --release
    if ($LASTEXITCODE -ne 0) { Pop-Location; Write-Error 'cargo build builder-pack failed'; exit 1 }
    Pop-Location
    $PackCli = Join-Path $repoRoot 'builder/target/release/3ds2apple-pack.exe'
}
if ([string]::IsNullOrWhiteSpace($DevPush)) {
    Write-Host '[dist] cargo build devpush (tools/devpush, task-16 device bridge)'
    $devpushManifest = Join-Path $repoRoot 'tools/devpush/Cargo.toml'
    if (Test-Path -LiteralPath $devpushManifest) {
        cargo build --release --manifest-path $devpushManifest
        if ($LASTEXITCODE -ne 0) { Write-Error 'cargo build devpush failed'; exit 1 }
        $DevPush = Join-Path $repoRoot 'tools/devpush/target/release/devpush.exe'
    }
    else {
        Write-Warning 'tools/devpush is not present in this checkout; pushing will stay disabled in this package.'
    }
}
if ([string]::IsNullOrWhiteSpace($BuilderCli)) {
    $candidate = Join-Path $repoRoot 'builder/target/release/builder-windows.exe'
    if (Test-Path -LiteralPath $candidate) { $BuilderCli = $candidate }
    else { Write-Warning 'builder-windows.exe not found; real macOS builds will need the path set in Settings.' }
}
foreach ($tool in @($PackCli, $DevPush, $BuilderCli)) {
    if (-not [string]::IsNullOrWhiteSpace($tool)) {
        if (-not (Test-Path -LiteralPath $tool)) { Write-Error "tool not found: $tool"; exit 1 }
        Copy-Item -Force -LiteralPath $tool -Destination $bin
        Write-Host "[dist] Bin/$(Split-Path -Leaf $tool)"
    }
}

# 3. official Impactor + plumesign (verified) and licences
$thirdParty = Join-Path $windowsRoot 'vendor/impactor'
& (Join-Path $PSScriptRoot 'fetch-impactor.ps1') -Destination (Join-Path $outputPath 'ThirdParty/Impactor')
if ($LASTEXITCODE -ne 0) { Write-Error 'Impactor bundle is not verified'; exit 1 }
Copy-Item -Force -LiteralPath (Join-Path $thirdParty 'PINS.json') -Destination (Join-Path $outputPath 'ThirdParty/Impactor/PINS.json') -ErrorAction SilentlyContinue

# 4. base shell IPA + pinned manifest
$shellTarget = Join-Path $outputPath 'Shell'
New-Item -ItemType Directory -Force -Path $shellTarget | Out-Null
$shellManifest = Join-Path $windowsRoot 'Shell/manifest.json'
if (Test-Path -LiteralPath $shellManifest) {
    Copy-Item -Force -LiteralPath $shellManifest -Destination $shellTarget
    $shellDoc = Get-Content -Raw -LiteralPath $shellManifest | ConvertFrom-Json
    $shellIpa = Join-Path $windowsRoot ('Shell/' + $shellDoc.fileName)
    if (Test-Path -LiteralPath $shellIpa) {
        Copy-Item -Force -LiteralPath $shellIpa -Destination $shellTarget
        $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $shellIpa).Hash.ToLowerInvariant()
        if ($sha -ne $shellDoc.sha256) {
            Write-Error "Shell IPA SHA-256 $sha does not match Shell/manifest.json ($($shellDoc.sha256))"
            exit 1
        }
        Write-Host "[dist] Shell/$($shellDoc.fileName) verified"
    }
    elseif (-not $SkipShell) {
        Write-Error "Shell/manifest.json names $($shellDoc.fileName) but Shell/ has no such file; use -SkipShell for a preview package."
        exit 1
    }
}
elseif (-not $SkipShell) {
    Write-Error 'Shell/manifest.json is missing. Build the ROM-free base shell on macOS and follow shell/README.md (or use -SkipShell for a preview package).'
    exit 1
}

# 5. notices, docs and hashes
$readme = Join-Path $windowsRoot 'README.md'
if (Test-Path -LiteralPath $readme) { Copy-Item -Force -LiteralPath $readme -Destination $outputPath }
@"
3ds2apple launcher (Windows) $Version
Built: $(Get-Date -Format o)
Pinned Impactor: v2.7.2 (see ThirdParty/Impactor/PINS.json)
Base shell: $(if (Test-Path -LiteralPath (Join-Path $shellTarget 'manifest.json')) { 'bundled' } else { 'NOT bundled (preview package)' })
Notes: only use ROMs you own; the package contains no game data, no keys and no Apple credentials.
"@ | Set-Content -Encoding UTF8 (Join-Path $outputPath 'build-info.txt')

$hashes = Get-ChildItem -LiteralPath $outputPath -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($outputPath.Length + 1).Replace('\', '/')
    "$((Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant())  $relative"
}
$hashes | Set-Content -Encoding ASCII (Join-Path $outputPath 'SHA256SUMS')
Write-Host "[dist] done: $outputPath ($($hashes.Count) files hashed)"
Write-Host '[dist] test on Windows: run 3ds2apple-launcher.exe --self-test, then the manual plan in docs/windows-launcher.md'
