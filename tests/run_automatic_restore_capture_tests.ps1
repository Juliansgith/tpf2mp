[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\automatic_restore_capture.ps1')
. (Join-Path $ProjectRoot 'tools\network_common.ps1')
$root = Join-Path $TemporaryRoot 'automatic-restore-capture'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$wakeOutbox = Join-Path $root 'wake-outbox'
New-Item -ItemType Directory -Force -Path $wakeOutbox | Out-Null
@{
    protocol = 1; session = 'wake-session'; peer = 'player2'; kind = 'clock_health'
    payload = @{ effectiveSpeed = 0 }
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath `
    (Join-Path $wakeOutbox '000000000007.json') -Encoding UTF8
$wakeEvidence = Find-Tpf2mpPausedWakeEvidence -OutboxPath $wakeOutbox `
    -Session 'wake-session' -Peer 'player2'
if (-not $wakeEvidence -or (Split-Path -Leaf $wakeEvidence) -ne '000000000007.json') {
    throw 'Existing signed game-script progress was not accepted as paused wake evidence.'
}
if (Find-Tpf2mpPausedWakeEvidence -OutboxPath $wakeOutbox `
        -Session 'other-session' -Peer 'player2') {
    throw 'Paused wake evidence crossed a session identity boundary.'
}
$script:healthChecks = 0
$health = { $script:healthChecks++ }
$ready = {
    param($peer)
    if ($peer -eq 'player1') {
        return [pscustomobject]@{
            status = 'restore-point-ready-awaiting-next-boundary'
            receiptBoundArchiveReady = $true
            gameProcessId = 101
            lastArchivedBoundary = 12
            publishedRecoveryPlanChecksum = '12ab34cd'
            receivedRecoveryPlanChecksum = $null
            receiptSave = 'host.sav'
        }
    }
    return [pscustomobject]@{
        status = 'restore-point-ready-awaiting-next-boundary'
        receiptBoundArchiveReady = $true
        gameProcessId = 102
        lastArchivedBoundary = 12
        publishedRecoveryPlanChecksum = $null
        receivedRecoveryPlanChecksum = '12ab34cd'
        receiptSave = 'client.sav'
    }
}
$result = Wait-Tpf2mpAutomaticRestoreCapture -Session 'capture-test' `
    -HostBridgePath (Join-Path $root 'host') -SourceBoundarySeq 11 `
    -ExpectedHostGameProcessId 101 -ExpectedClientGameProcessId 102 `
    -TimeoutSeconds 300 -PollMilliseconds 50 -HealthCheck $health -StatusReader $ready
if ($result.status -ne 'completed' -or $result.boundarySeq -ne 12 `
        -or $result.planChecksum -ne '12ab34cd' -or $script:healthChecks -ne 1 `
        -or -not (Test-Path -LiteralPath $result.marker -PathType Leaf)) {
    throw 'Automatic restore capture did not accept a matching fresh paired archive.'
}

$mismatched = {
    param($peer)
    return [pscustomobject]@{
        status = 'ready'
        receiptBoundArchiveReady = $true
        lastArchivedBoundary = if ($peer -eq 'player1') { 12 } else { 13 }
        publishedRecoveryPlanChecksum = if ($peer -eq 'player1') { '12ab34cd' } else { $null }
        receivedRecoveryPlanChecksum = if ($peer -eq 'player2') { '12ab34cd' } else { $null }
        receiptSave = "$peer.sav"
    }
}
$rejected = $false
try {
    Wait-Tpf2mpAutomaticRestoreCapture -Session 'capture-mismatch' `
        -HostBridgePath (Join-Path $root 'mismatch') -TimeoutSeconds 300 `
        -PollMilliseconds 50 -StatusReader $mismatched | Out-Null
}
catch { $rejected = $_.Exception.Message -match 'disagree on boundary' }
if (-not $rejected) { throw 'Automatic restore capture accepted mismatched peer boundaries.' }

$failedBridge = Join-Path $root 'failed-preparation'
$failedState = Join-Path $failedBridge 'companion_state'
New-Item -ItemType Directory -Force -Path $failedState | Out-Null
@{
    anchorPreparationStatus = 'failed'
    anchorPreparationDetail = 'vehicle phases are not restore-safe'
    sessionFault = $null
} | ConvertTo-Json | Set-Content -LiteralPath `
    (Join-Path $failedState 'companion_status.json') -Encoding UTF8
$failedFast = $false
try {
    Wait-Tpf2mpAutomaticRestoreCapture -Session 'capture-unsafe-phase' `
        -HostBridgePath $failedBridge -TimeoutSeconds 300 `
        -PollMilliseconds 50 -StatusReader $ready | Out-Null
}
catch { $failedFast = $_.Exception.Message -match 'vehicle phases are not restore-safe' }
if (-not $failedFast) { throw 'Automatic restore capture ignored a failed phase proof.' }

$restartNamespace = {
    param($peer)
    return [pscustomobject]@{
        status = 'ready'
        receiptBoundArchiveReady = $true
        lastArchivedBoundary = 8
        publishedRecoveryPlanChecksum = if ($peer -eq 'player1') { '12ab34cd' } else { $null }
        receivedRecoveryPlanChecksum = if ($peer -eq 'player2') { '12ab34cd' } else { $null }
        receiptSave = "$peer.sav"
    }
}
$restarted = Wait-Tpf2mpAutomaticRestoreCapture -Session 'capture-restarted-sequence' `
    -HostBridgePath (Join-Path $root 'restarted') -SourceBoundarySeq 11 `
    -TimeoutSeconds 300 -PollMilliseconds 50 -StatusReader $restartNamespace
if ($restarted.boundarySeq -ne 8 -or $restarted.sourceBoundarySeq -ne 11) {
    throw 'Automatic restore capture confused independent source/resume sequence namespaces.'
}

Write-Host 'PASS automatic paired restore capture acceptance and fail-closed boundaries'
