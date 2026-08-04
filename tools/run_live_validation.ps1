[CmdletBinding()]
param(
    [string]$Peer = 'player1',
    [string]$Session = 'local-dev',
    [switch]$SkipInstall,
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2'
$gameExecutable = Join-Path $gameDirectory 'TransportFever2.exe'
$checklist = Join-Path $projectRoot 'investigation\LIVE_VALIDATION_CHECKLIST.md'

if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Transport Fever 2 is already running. Close it before starting a controlled validation run.'
}
if (-not (Test-Path -LiteralPath $gameExecutable)) { throw "Game executable not found: $gameExecutable" }

if (-not $SkipInstall) {
    & (Join-Path $PSScriptRoot 'install.ps1')
    if (-not $?) { throw 'Install failed.' }
}
& (Join-Path $PSScriptRoot 'make_manifest.ps1')
if (-not $?) { throw 'Manifest generation failed.' }

Write-Host 'Use a new disposable, tiny free-game map. Do not use a valued save.'
Write-Host "Enable TPF2MP Competitive Prototype with standalone, native turn proxy, and pause-on-switch."
Write-Host "Checklist: $checklist"
Write-Host 'Before quitting, click Export Research in the TPF2MP window.'

$gameProcess = Start-Process -FilePath $gameExecutable -WorkingDirectory $gameDirectory -PassThru
if ($NoWait) {
    Write-Host "Transport Fever 2 started as process $($gameProcess.Id). Evidence collection was deferred."
    return
}

$gameProcess.WaitForExit()
& (Join-Path $PSScriptRoot 'collect_live_evidence.ps1') -Peer $Peer -Session $Session
if (-not $?) { throw 'Evidence collection failed.' }

try {
    & (Join-Path $PSScriptRoot 'make_research_report.ps1') -Peer $Peer -Session $Session
    if (-not $?) { throw 'Research report generation failed.' }
}
catch {
    Write-Warning "No renderable research export was found: $($_.Exception.Message)"
}

try {
    & (Join-Path $PSScriptRoot 'make_checkpoint_report.ps1') -Peer $Peer -Session $Session -Anchor first
    if (-not $?) { throw 'Checkpoint report generation failed.' }
}
catch {
    Write-Warning "No verifiable checkpoint stream was found: $($_.Exception.Message)"
}
