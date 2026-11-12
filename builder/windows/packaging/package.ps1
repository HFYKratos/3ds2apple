#Requires -Version 3.0
<#
.SYNOPSIS
    Assemble the portable Windows release ZIP for the 3ds2apple Builder.

.DESCRIPTION
    Copies builder-windows.exe plus the licence/notice/README files into a
    versioned folder, writes SHA256SUMS, and zips the folder. The binaries are
    unsigned: Windows SmartScreen will warn on first run, and the README explains
    how to verify the download and what the warning means.

    Only .NET APIs are used for hashing and zipping, so the script runs on stock
    Windows PowerShell without extra modules.

.PARAMETER ExePath
    Path to the built builder-windows.exe (release build).

.PARAMETER Version
    Version string used in the artifact name, e.g. 0.1.0.

.PARAMETER OutDir
    Directory that receives the folder and the ZIP.

.PARAMETER RepoRoot
    Repository root, source of LICENSE / NOTICE / README.md.

.EXAMPLE
    .\package.ps1 -ExePath .\target\release\builder-windows.exe -Version 0.1.0 -OutDir .\dist
#>
param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $bytes = $sha.ComputeHash($stream)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

if (-not (Test-Path -LiteralPath $ExePath)) {
    throw "builder-windows.exe not found: $ExePath (run: cargo build -p builder-windows --release)"
}
if ($Version -notmatch '^[0-9]+\.[0-9]+\.[0-9]+') {
    throw "Version must start with x.y.z, got '$Version'"
}

$name = "builder-windows-$Version-windows-x86_64"
$stage = Join-Path $OutDir $name
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

$binary = Join-Path $stage 'builder-windows.exe'
Copy-Item -LiteralPath $ExePath -Destination $binary

foreach ($document in @('LICENSE', 'NOTICE', 'README.md')) {
    $path = Join-Path $RepoRoot $document
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $stage $document)
    }
}
$windowsReadme = Join-Path $PSScriptRoot '..\README.md'
if (Test-Path -LiteralPath $windowsReadme) {
    Copy-Item -LiteralPath $windowsReadme -Destination (Join-Path $stage 'README-Windows.md')
}

$hash = Get-Sha256Hex -Path $binary
Set-Content -LiteralPath (Join-Path $stage 'SHA256SUMS') -Value "$hash  builder-windows.exe" -Encoding ASCII

$zip = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $zip) {
    Remove-Item -LiteralPath $zip -Force
}
# Create entries by hand with forward slashes: .NET's CreateFromDirectory on
# Windows writes backslash entry names, which some non-Windows unzip tools do
# not treat as directories.
$archive = [System.IO.Compression.ZipFile]::Open($zip, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $prefixLength = $stage.Length + 1
    foreach ($file in Get-ChildItem -LiteralPath $stage -File -Recurse) {
        $relative = $name + '/' + $file.FullName.Substring($prefixLength).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $archive,
            $file.FullName,
            $relative,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

$zipHash = Get-Sha256Hex -Path $zip
Write-Output "folder:     $stage"
Write-Output "zip:        $zip"
Write-Output "zip_sha256: $zipHash"
Write-Output "exe_sha256: $hash"
