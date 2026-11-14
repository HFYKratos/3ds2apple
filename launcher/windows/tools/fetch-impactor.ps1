<#
.SYNOPSIS
  Fetch and verify the official Impactor v2.7.2 + plumesign binaries for the launcher bundle.

.DESCRIPTION
  Downloads the two official Windows x86_64 files from the GitHub release, verifies their
  SHA-256 against PINS.json (the same hashes compiled into the launcher), and copies the
  licence/source note files next to them. Anything that does not match the pinned digest is
  deleted and the script exits non-zero: never ship an unverified signer.

.PARAMETER Destination
  Directory to place the binaries in. Default: vendor/impactor (the repo layout that
  tools/prepare-dist.ps1 and the launcher's ThirdParty/Impactor expect).

.PARAMETER CheckOnly
  Do not download; only verify the files that are already there.

.PARAMETER Force
  Re-download even when a file exists.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools/fetch-impactor.ps1
  powershell -ExecutionPolicy Bypass -File tools/fetch-impactor.ps1 -CheckOnly
#>
[CmdletBinding()]
param(
    [string]$Destination = '',
    [switch]$CheckOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoDirectory = Split-Path -Parent $PSScriptRoot
$pinsPath = Join-Path $repoDirectory 'vendor/impactor/PINS.json'
if (-not (Test-Path -LiteralPath $pinsPath)) {
    Write-Error "PINS.json not found at $pinsPath"
    exit 2
}
$pins = Get-Content -Raw -LiteralPath $pinsPath | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $repoDirectory 'vendor/impactor'
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null

$failures = 0
foreach ($binary in $pins.binaries) {
    $target = Join-Path $Destination $binary.fileName
    if (-not $CheckOnly -and ((-not (Test-Path -LiteralPath $target)) -or $Force)) {
        $url = $pins.downloadBase + $binary.fileName
        $partial = $target + '.part'
        Write-Host "[download] $url"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $partial
            Move-Item -Force -LiteralPath $partial -Destination $target
        }
        catch {
            Remove-Item -Force -LiteralPath $partial -ErrorAction SilentlyContinue
            Write-Error "download failed: $url ($($_.Exception.Message))"
            $failures++
            continue
        }
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "[missing] $($binary.fileName)"
        $failures++
        continue
    }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $target).Hash.ToLowerInvariant()
    $size = (Get-Item -LiteralPath $target).Length
    if ($hash -ne $binary.sha256 -or $size -ne [long]$binary.bytes) {
        Write-Host "[MISMATCH] $($binary.fileName): sha256=$hash bytes=$size"
        Write-Host "           expected sha256=$($binary.sha256) bytes=$($binary.bytes)"
        if (-not $CheckOnly) {
            Remove-Item -Force -LiteralPath $target
            Write-Host "           deleted the unverified file; get the official release from $($pins.releasePage)"
        }
        $failures++
    }
    else {
        Write-Host "[ok] $($binary.fileName)  $($binary.sha256.Substring(0, 16))..."
    }
}

$companions = @('LICENSE-Impactor-MIT.txt', 'LICENSE-apple-codesign-MPL-2.0.txt', 'README-source-and-licenses.txt', 'PINS.json')
foreach ($name in $companions) {
    $source = Join-Path $repoDirectory ('vendor/impactor/' + $name)
    $target = Join-Path $Destination $name
    if ((Test-Path -LiteralPath $source) -and ($source -ne $target)) {
        Copy-Item -Force -LiteralPath $source -Destination $target
    }
    if (-not (Test-Path -LiteralPath $target)) {
        Write-Host "[missing] $name"
        $failures++
    }
}

if ($failures -gt 0) {
    Write-Error "Impactor bundle is NOT ready ($failures problem(s)); see https://github.com/claration/impactor/releases/tag/v2.7.2"
    exit 1
}
Write-Host "Impactor v$($pins.testedVersion) + plumesign verified (SHA-256 pinned, official unmodified release)."
exit 0
