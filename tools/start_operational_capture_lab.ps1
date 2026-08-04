[CmdletBinding()]
param(
    [string]$Session,
    [ValidateRange(5, 240)][int]$Minutes = 120,
    [ValidateRange(30, 3600)][int]$SampleTicks = 120,
    [ValidateRange(5000000, 1000000000)][long]$StartingCash = 50000000,
    [ValidateRange(0, 3600)][int]$UnattendedSeconds = 0,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$StartingSave,
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild,
    [switch]$KeepGamesOpen
)

$ErrorActionPreference = 'Stop'
$arguments = @{
    OperationalCaptureLab = $true
    InteractiveMinutes = $Minutes
    OperationalSampleTicks = $SampleTicks
    OperationalStartingCash = $StartingCash
    UnattendedOperationalSeconds = $UnattendedSeconds
    KeepGamesOpen = $KeepGamesOpen
    SkipTests = $SkipTests
    SkipInstall = $SkipInstall
    SkipNativeBuild = $SkipNativeBuild
}
if ($Session) { $arguments.Session = $Session }
if ($GameExecutable) { $arguments.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $arguments.LocalModsPath = $LocalModsPath }
if ($StartingSave) { $arguments.StartingSave = $StartingSave }

& (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @arguments
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
