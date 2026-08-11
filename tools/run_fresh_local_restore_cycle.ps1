[CmdletBinding()]
param(
    [string]$BundleRoot,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild,
    [ValidateRange(300, 3600)][int]$CaptureTimeoutSeconds = 3000,
    [ValidateRange(1, 5)][int]$MaxRestoreAttempts = 3
)

$ErrorActionPreference = 'Stop'
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = [IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $PSScriptRoot 'network_common.ps1')

$source = Get-Tpf2mpLatestLocalRestorePair -BundleRoot $bundle
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$tag = "fresh-capture-$stamp"
$captureStatusPath = Join-Path $bundle `
    "runtime\localhost-live\$($source.resumeSession)--$tag\run-status.json"
$captureArgs = @{
    Session = [string]$source.resumeSession
    RestorePlan = [string]$source.planPath
    Player1StartingSave = [string]$source.peers.player1.savePath
    Player2StartingSave = [string]$source.peers.player2.savePath
    Port = $Port
    ManualOnly = $true
    AutoPrepareRestorePoint = $true
    RestoreCaptureTimeoutSeconds = $CaptureTimeoutSeconds
    EvidenceTag = $tag
}
if ($GameExecutable) { $captureArgs.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $captureArgs.LocalModsPath = $LocalModsPath }
if ($SkipTests) { $captureArgs.SkipTests = $true }
if ($SkipInstall) { $captureArgs.SkipInstall = $true }
if ($SkipNativeBuild) { $captureArgs.SkipNativeBuild = $true }

Write-Host ("Capturing a fresh paired boundary from {0} boundary {1}." -f `
    $source.resumeSession, $source.boundarySeq)
& (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @captureArgs
if (-not (Test-Path -LiteralPath $captureStatusPath -PathType Leaf)) {
    throw 'Fresh recovery capture did not publish run-status evidence.'
}
$captureStatus = Get-Content -LiteralPath $captureStatusPath -Raw | ConvertFrom-Json
$capture = $captureStatus.automaticRestoreCapture
if ($captureStatus.passed -ne $true -or $capture.status -ne 'completed') {
    throw "Fresh paired recovery capture failed: $($capture.error)"
}

$fresh = Get-Tpf2mpLatestLocalRestorePair -BundleRoot $bundle
if ([string]$fresh.session -ne [string]$source.resumeSession `
        -or [int]$fresh.boundarySeq -ne [int]$capture.boundarySeq `
        -or [string]$fresh.planChecksum -ne [string]$capture.planChecksum) {
    throw 'Latest-pair discovery did not select the recovery boundary just captured.'
}
$acceptanceRoot = Join-Path $bundle 'runtime\restore-acceptance'
$before = @()
if (Test-Path -LiteralPath $acceptanceRoot -PathType Container) {
    $before = @(Get-ChildItem -LiteralPath $acceptanceRoot -File -Filter '*.json' |
        Select-Object -ExpandProperty FullName)
}
$acceptanceArgs = @{
    BundleRoot = $bundle
    Port = $Port
    MaxAttempts = $MaxRestoreAttempts
}
if ($GameExecutable) { $acceptanceArgs.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $acceptanceArgs.LocalModsPath = $LocalModsPath }
if ($SkipTests) { $acceptanceArgs.SkipTests = $true }
if ($SkipInstall) { $acceptanceArgs.SkipInstall = $true }
if ($SkipNativeBuild) { $acceptanceArgs.SkipNativeBuild = $true }
Write-Host ("Reloading freshly captured boundary {0} as {1}." -f `
    $fresh.boundarySeq, $fresh.resumeSession)
& (Join-Path $PSScriptRoot 'run_latest_local_restore_acceptance.ps1') @acceptanceArgs
$acceptance = @(Get-ChildItem -LiteralPath $acceptanceRoot -File -Filter '*.json' |
    Where-Object { $before -notcontains $_.FullName } |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
if (-not $acceptance) { throw 'Fresh restore reload did not publish an acceptance receipt.' }
$accepted = Get-Content -LiteralPath $acceptance.FullName -Raw | ConvertFrom-Json
if ([string]$accepted.sourceSession -ne [string]$fresh.session `
        -or [int]$accepted.boundarySeq -ne [int]$fresh.boundarySeq `
        -or [string]$accepted.planChecksum -ne [string]$fresh.planChecksum `
        -or [string]$accepted.result -ne 'passed-and-cleaned-up') {
    throw 'Fresh restore acceptance receipt does not bind the captured pair.'
}

$outputRoot = Join-Path $bundle 'runtime\fresh-restore-cycle'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$receiptPath = Join-Path $outputRoot "$stamp.json"
[ordered]@{
    schemaVersion = 1
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceSession = [string]$source.session
    firstResumeSession = [string]$source.resumeSession
    sourceBoundarySeq = [int]$source.boundarySeq
    capturedBoundarySeq = [int]$fresh.boundarySeq
    capturedPlanChecksum = [string]$fresh.planChecksum
    finalResumeSession = [string]$fresh.resumeSession
    captureRunStatus = $captureStatusPath
    restoreAcceptanceReceipt = $acceptance.FullName
    result = 'fresh-pair-captured-reloaded-converged-and-cleaned-up'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "PASS fresh two-peer recovery cycle: $receiptPath"
