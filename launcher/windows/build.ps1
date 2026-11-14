#Requires -Version 5.1
<#
.SYNOPSIS
  Build / test / self-test the 3ds2apple Windows launcher.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File build.ps1
  powershell -ExecutionPolicy Bypass -File build.ps1 -Task test
  powershell -ExecutionPolicy Bypass -File build.ps1 -Task all
#>
[CmdletBinding()]
param(
    [ValidateSet('build', 'test', 'selftest', 'all')]
    [string]$Task = 'build',
    [string]$Configuration = 'Debug'
)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if ($Task -in @('build', 'all')) {
        dotnet build Launcher.slnx -c $Configuration
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    if ($Task -in @('test', 'all')) {
        dotnet test tests/ThreeDsTwoApple.Launcher.Core.Tests/ThreeDsTwoApple.Launcher.Core.Tests.csproj -c $Configuration
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
    if ($Task -in @('selftest', 'all')) {
        dotnet run --project src/Launcher.Desktop/ThreeDsTwoApple.Launcher.Desktop.csproj -c $Configuration -- --self-test
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
finally {
    Pop-Location
}
