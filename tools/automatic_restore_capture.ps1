Set-StrictMode -Version Latest

function Read-Tpf2mpRecoveryWatcherStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }
    $path = Join-Path $env:LOCALAPPDATA `
        "TPF2MP\sessions\$Session\$Peer\recovery-watcher-status.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Read-Tpf2mpAnchorCompanionStatus([string]$HostBridgePath) {
    $path = Join-Path $HostBridgePath 'companion_state\companion_status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Wait-Tpf2mpAutomaticRestoreCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$HostBridgePath,
        [ValidateRange(300, 3600)][int]$TimeoutSeconds = 3000,
        [ValidateRange(0, [int]::MaxValue)][int]$SourceBoundarySeq = 0,
        [ValidateRange(0, [int]::MaxValue)][int]$ExpectedHostGameProcessId = 0,
        [ValidateRange(0, [int]::MaxValue)][int]$ExpectedClientGameProcessId = 0,
        [ValidateRange(50, 5000)][int]$PollMilliseconds = 500,
        [scriptblock]$HealthCheck,
        [scriptblock]$StatusReader
    )
    if ($Session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Automatic restore capture received an unsafe session id.'
    }
    $hostBridge = [IO.Path]::GetFullPath($HostBridgePath)
    $launcher = Join-Path $hostBridge 'launcher'
    New-Item -ItemType Directory -Force -Path $launcher | Out-Null
    $marker = Join-Path $launcher 'prepare-restore'
    [IO.File]::WriteAllText($marker, 'ready', [Text.UTF8Encoding]::new($false))

    $useDefaultStatusReader = -not $StatusReader
    $started = [DateTime]::UtcNow
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextProgress = Get-Date
    do {
        if ($HealthCheck) { & $HealthCheck }
        $companionStatus = Read-Tpf2mpAnchorCompanionStatus $hostBridge
        if ($companionStatus -and $companionStatus.sessionFault) {
            throw "Recovery preparation faulted the session: $($companionStatus.sessionFault)"
        }
        if ($companionStatus -and $companionStatus.anchorPreparationStatus -eq 'failed') {
            throw "Recovery preparation was refused: $($companionStatus.anchorPreparationDetail)"
        }
        $hostStatus = if ($useDefaultStatusReader) {
            Read-Tpf2mpRecoveryWatcherStatus -Session $Session -Peer 'player1'
        } else { & $StatusReader 'player1' }
        $clientStatus = if ($useDefaultStatusReader) {
            Read-Tpf2mpRecoveryWatcherStatus -Session $Session -Peer 'player2'
        } else { & $StatusReader 'player2' }
        foreach ($entry in @(
            @{ Peer = 'player1'; Status = $hostStatus },
            @{ Peer = 'player2'; Status = $clientStatus }
        )) {
            if ($entry.Status -and [string]$entry.Status.status -eq 'failed') {
                throw "$($entry.Peer) recovery watcher failed: $($entry.Status.error)"
            }
        }

        $hostCurrent = $ExpectedHostGameProcessId -eq 0 -or (
            $hostStatus -and [int]$hostStatus.gameProcessId -eq $ExpectedHostGameProcessId)
        $clientCurrent = $ExpectedClientGameProcessId -eq 0 -or (
            $clientStatus -and [int]$clientStatus.gameProcessId -eq $ExpectedClientGameProcessId)
        $hostReady = $hostCurrent -and $hostStatus `
            -and $hostStatus.receiptBoundArchiveReady -eq $true
        $clientReady = $clientCurrent -and $clientStatus `
            -and $clientStatus.receiptBoundArchiveReady -eq $true
        if ($hostReady -and $clientReady) {
            $hostBoundary = [int]$hostStatus.lastArchivedBoundary
            $clientBoundary = [int]$clientStatus.lastArchivedBoundary
            $hostChecksum = [string]$hostStatus.publishedRecoveryPlanChecksum
            $clientChecksum = [string]$clientStatus.receivedRecoveryPlanChecksum
            if ($hostBoundary -lt 1 -or $hostBoundary -ne $clientBoundary) {
                throw "Recovery archives disagree on boundary: host=$hostBoundary client=$clientBoundary"
            }
            if ($hostChecksum -notmatch '^[0-9a-f]{8}$' -or $hostChecksum -ne $clientChecksum) {
                throw "Recovery archives disagree on plan checksum: host=$hostChecksum client=$clientChecksum"
            }
            $hostSave = $hostStatus.PSObject.Properties['candidateSave']
            $clientSave = $clientStatus.PSObject.Properties['candidateSave']
            $hostArchive = $hostStatus.PSObject.Properties['latestArchivePointer']
            $clientArchive = $clientStatus.PSObject.Properties['latestArchivePointer']
            return [pscustomobject][ordered]@{
                schemaVersion = 1
                requested = $true
                status = 'completed'
                session = $Session
                marker = $marker
                sourceBoundarySeq = $SourceBoundarySeq
                hostGameProcessId = if ($ExpectedHostGameProcessId -gt 0) {
                    $ExpectedHostGameProcessId
                } else { $null }
                clientGameProcessId = if ($ExpectedClientGameProcessId -gt 0) {
                    $ExpectedClientGameProcessId
                } else { $null }
                boundarySeq = $hostBoundary
                planChecksum = $hostChecksum
                hostWatcherStatus = [string]$hostStatus.status
                clientWatcherStatus = [string]$clientStatus.status
                hostAutomaticSave = if ($hostSave) { [string]$hostSave.Value } else { $null }
                clientAutomaticSave = if ($clientSave) { [string]$clientSave.Value } else { $null }
                hostArchivePointer = if ($hostArchive) { [string]$hostArchive.Value } else { $null }
                clientArchivePointer = if ($clientArchive) { [string]$clientArchive.Value } else { $null }
                startedAtUtc = $started.ToString('o')
                completedAtUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
        if ((Get-Date) -ge $nextProgress) {
            $hostText = if ($hostStatus) {
                "status=$($hostStatus.status), ui=$($hostStatus.uiSaveFallbackStatus), attempts=$($hostStatus.uiSaveFallbackAttempts), boundary=$($hostStatus.anchorBoundary)"
            } else { 'status=not-published' }
            $clientText = if ($clientStatus) {
                "status=$($clientStatus.status), ui=$($clientStatus.uiSaveFallbackStatus), attempts=$($clientStatus.uiSaveFallbackAttempts), boundary=$($clientStatus.anchorBoundary)"
            } else { 'status=not-published' }
            Write-Host "Waiting for paired recovery archives: player1 [$hostText]; player2 [$clientText]"
            $nextProgress = (Get-Date).AddSeconds(30)
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ((Get-Date) -lt $deadline)
    throw "Timed out after $TimeoutSeconds seconds waiting for both receipt-bound recovery archives."
}
