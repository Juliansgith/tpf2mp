[CmdletBinding()]
param(
    [string]$Session,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [ValidateRange(5, 240)][int]$InteractiveMinutes = 120,
    [ValidateRange(5000000, 1000000000)][long]$StartingCash = 50000000,
    [string]$StartingSave,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [switch]$RequireObservedAboard,
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $Session) { $Session = 'freight-live-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
. (Join-Path $PSScriptRoot 'network_common.ps1')
$safeSession = Assert-Tpf2mpSessionId $Session
$packagedBundle = Test-Path -LiteralPath (Join-Path $projectRoot 'bin\tpf2mp.exe') -PathType Leaf

Write-Host 'This acceptance run starts a clean two-process manual network world and verifies its match checkpoint.'
Write-Host "Each company receives $StartingCash; when both windows are handed to you, build one complete vanilla cargo service."
Write-Host 'Required proof before closing either window:'
Write-Host '  1. The multiplayer panel reports freight ready and the cargo line is registered.'
Write-Host '  2. Let the source produce, settle one epoch if needed, and observe cargo waiting.'
Write-Host '  3. Let a train load, deliver, and then cross one automatic five-minute settlement.'
if ($RequireObservedAboard) {
    Write-Host '  4. While the train visibly carries cargo, press Export Checkpoint once.'
    Write-Host '  5. Save both peers, reload only if testing persistence, and complete another delivery.'
}
else {
    Write-Host '  4. Optional persistence gate: export a checkpoint while loaded, save both peers, reload, and deliver again.'
}
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
if ($LASTEXITCODE -ne 0) { throw "Localhost freight acceptance launcher exited $LASTEXITCODE" }

$audit = Join-Path ([IO.Path]::GetTempPath()) `
    "tpf2mp_bridge\$safeSession\player1\audit\$safeSession.ndjson"
$report = Join-Path $projectRoot `
    "runtime\localhost-live\$safeSession\freight-live-report.json"
$analysisArguments = @{
    Session = $safeSession
    AuditPath = $audit
    OutputPath = $report
    BundleRoot = $projectRoot
    RequireStage = 'settled'
}
if ($RequireObservedAboard) { $analysisArguments.RequireObservedAboard = $true }
& (Join-Path $PSScriptRoot 'analyze_freight_live_evidence.ps1') @analysisArguments
if ($LASTEXITCODE -ne 0) { throw "Freight evidence wrapper exited $LASTEXITCODE" }
Write-Host "PASS complete localhost freight acceptance: session=$safeSession"
