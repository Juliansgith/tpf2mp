[CmdletBinding()]
param(
    [string]$Session,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [ValidateRange(5, 240)][int]$InteractiveMinutes = 120,
    [ValidateRange(5000000, 1000000000)][long]$StartingCash = 200000000,
    [string]$StartingSave,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [ValidateSet('ANY', 'ROAD', 'TRAM')][string]$Carrier = 'ANY',
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Session) { $Session = 'feeder-live-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
. (Join-Path $PSScriptRoot 'network_common.ps1')
$safeSession = Assert-Tpf2mpSessionId $Session
$packagedBundle = Test-Path -LiteralPath (Join-Path $projectRoot 'bin\tpf2mp.exe') -PathType Leaf

Write-Host 'This acceptance run starts a clean two-process manual network world and verifies a real passenger feeder.'
Write-Host "Company 1 receives $StartingCash. Build the service from the player1 window; replication supplies player2."
Write-Host 'Required proof before closing either window:'
Write-Host '  1. Build and assign a passenger corridor between two towns (rail is the simplest proof).'
Write-Host '  2. In one endpoint town, build a ROAD/TRAM line through at least two distinct station groups.'
Write-Host '     One local stop must join the exact station group used by that intercity terminal; nearby-but-separate is not enough.'
Write-Host '  3. Buy and assign at least one passenger vehicle to each line; wait for both services to auto-register.'
Write-Host '  4. Unpause and let the local vehicle board and complete a trip. Let the corridor run too.'
Write-Host '  5. Keep running through an automatic five-minute economy settlement; the corridor must show feeder access.'
if ($Carrier -ne 'ANY') {
    Write-Host "     This run specifically requires a $Carrier local feeder."
}
Write-Host '  6. The first non-zero local feeder load automatically opens a passenger-aboard checkpoint.'
Write-Host 'Close either game when finished. Evidence collection and strict audit analysis then run automatically.'

$runArguments = @{
    Session = $safeSession
    Port = $Port
    ManualOnly = $true
    InteractiveAfterValidation = $true
    InteractiveMinutes = $InteractiveMinutes
    OperationalStartingCash = $StartingCash
    AgentMode = $AgentMode
}
if ($StartingSave) { $runArguments.StartingSave = $StartingSave }
if ($GameExecutable) { $runArguments.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $runArguments.LocalModsPath = $LocalModsPath }
if ($packagedBundle) {
    Write-Host 'Packaged bundle detected; using its verified installed mod, companion, and native binaries.'
}
if ($packagedBundle -or $SkipTests) { $runArguments.SkipTests = $true }
if ($packagedBundle -or $SkipInstall) { $runArguments.SkipInstall = $true }
if ($packagedBundle -or $SkipNativeBuild) { $runArguments.SkipNativeBuild = $true }

& (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @runArguments
if ($LASTEXITCODE -ne 0) { throw "Localhost passenger-feeder acceptance launcher exited $LASTEXITCODE" }

$audit = Join-Path ([IO.Path]::GetTempPath()) `
    "tpf2mp_bridge\$safeSession\player1\audit\$safeSession.ndjson"
$report = Join-Path $projectRoot `
    "runtime\localhost-live\$safeSession\passenger-feeder-live-report.json"
$analysisArguments = @{
    Session = $safeSession
    AuditPath = $audit
    OutputPath = $report
    BundleRoot = $projectRoot
    RequireStage = 'settled'
    Carrier = $Carrier
    RequireObservedAboard = $true
}
& (Join-Path $PSScriptRoot 'analyze_feeder_live_evidence.ps1') @analysisArguments
if ($LASTEXITCODE -ne 0) { throw "Passenger-feeder evidence wrapper exited $LASTEXITCODE" }
Write-Host "PASS complete localhost passenger-feeder acceptance: session=$safeSession"
