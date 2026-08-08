[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$state = Read-Tpf2mpSessionState $safeSession $Peer
if (-not $state) {
    $result = [ordered]@{ session = $safeSession; peer = $Peer; status = 'not-started' }
}
else {
    $game = if ($state.gamePid) { Get-Process -Id ([int]$state.gamePid) -ErrorAction SilentlyContinue } else { $null }
    $companionStatus = $null
    $statusPath = if ($state.bridgePath) { Join-Path ([string]$state.bridgePath) 'companion_state\companion_status.json' } else { $null }
    if ($statusPath -and (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
        try { $companionStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } catch { }
    }
    $menuStatus = $null
    $menuStatusPath = if ($state.bridgePath) { Join-Path ([string]$state.bridgePath) 'launcher\menu_status.json' } else { $null }
    if ($menuStatusPath -and (Test-Path -LiteralPath $menuStatusPath -PathType Leaf)) {
        try { $menuStatus = Get-Content -LiteralPath $menuStatusPath -Raw | ConvertFrom-Json } catch { }
    }
    $nativeStatus = $null
    if ($state.PSObject.Properties['nativeStatusPath'] -and $state.nativeStatusPath `
        -and (Test-Path -LiteralPath ([string]$state.nativeStatusPath) -PathType Leaf)) {
        try { $nativeStatus = Get-Content -LiteralPath ([string]$state.nativeStatusPath) -Raw | ConvertFrom-Json } catch { }
    }
    $recoveryPointer = $null
    $recoveryPointerPath = Join-Path (Get-Tpf2mpSessionRoot $safeSession $Peer) 'latest-recovery-archive.json'
    if (Test-Path -LiteralPath $recoveryPointerPath -PathType Leaf) {
        try { $recoveryPointer = Get-Content -LiteralPath $recoveryPointerPath -Raw | ConvertFrom-Json } catch { }
    }
    $recoveryWatcher = $null
    if ($state.PSObject.Properties['recoveryWatcherStatusPath'] -and $state.recoveryWatcherStatusPath `
        -and (Test-Path -LiteralPath ([string]$state.recoveryWatcherStatusPath) -PathType Leaf)) {
        try { $recoveryWatcher = Get-Content -LiteralPath ([string]$state.recoveryWatcherStatusPath) -Raw | ConvertFrom-Json } catch { }
    }
    $companionPid = if ($state.companionPid) { [int]$state.companionPid } else { $null }
    if ($companionStatus -and $companionStatus.session -eq $safeSession `
        -and $companionStatus.peer -eq $Peer -and $companionStatus.pid) {
        $companionPid = [int]$companionStatus.pid
    }
    $expectedExecutable = if ($state.PSObject.Properties['companionExecutable']) {
        [string]$state.companionExecutable
    } else { $null }
    $companion = if ($companionPid) {
        Get-Tpf2mpVerifiedCompanionProcess -ProcessId $companionPid `
            -Session $safeSession -Peer $Peer -ExecutablePath $expectedExecutable
    } else { $null }
    $connectedPeers = @()
    if ($companionStatus -and $companionStatus.PSObject.Properties['connectedPeers']) {
        $connectedPeers = @($companionStatus.connectedPeers)
    }
    $result = [ordered]@{
        session = $safeSession
        peer = $Peer
        role = $state.role
        launcherStatus = $state.status
        companionRunning = $null -ne $companion -and -not $companion.HasExited
        gameRunning = $null -ne $game -and -not $game.HasExited
        menuStage = if ($menuStatus) { $menuStatus.stage } else { $null }
        nativeHookActive = $null -ne $nativeStatus -and $nativeStatus.active -eq $true -and $nativeStatus.hooks.enabled -eq $true
        buildGateActive = $null -ne $nativeStatus -and $nativeStatus.gates.buildProposal.enabled -eq $true
        commandGatesActive = $null -ne $nativeStatus -and $nativeStatus.gates.commandVisitors.enabled -eq $true
        gameScriptObserverActive = $null -ne $nativeStatus `
            -and @($nativeStatus.luaStates | Where-Object { $_.commandObserverRegistered -eq $true }).Count -gt 0
        networkStatus = if ($companionStatus) { $companionStatus.status } else { 'unavailable' }
        connected = if ($companionStatus -and $companionStatus.PSObject.Properties['connected']) { $companionStatus.connected } else { $false }
        connectedPeers = $connectedPeers
        nextCommitSeq = if ($companionStatus -and $companionStatus.PSObject.Properties['nextCommitSeq']) { $companionStatus.nextCommitSeq } else { $null }
        lastCommitSeq = if ($companionStatus -and $companionStatus.PSObject.Properties['lastCommitSeq']) { $companionStatus.lastCommitSeq } else { $null }
        pendingProposalPrepareSeq = if ($companionStatus -and $companionStatus.PSObject.Properties['pendingProposalPrepareSeq']) { $companionStatus.pendingProposalPrepareSeq } else { $null }
        sharedClock = if ($companionStatus -and $companionStatus.PSObject.Properties['clock']) { $companionStatus.clock } else { $null }
        lastCheckpointSeq = if ($companionStatus -and $companionStatus.PSObject.Properties['lastAgreedCheckpointSeq']) { $companionStatus.lastAgreedCheckpointSeq } else { $null }
        fault = if ($companionStatus -and $companionStatus.PSObject.Properties['sessionFault']) { $companionStatus.sessionFault } else { $null }
        error = if ($companionStatus -and $companionStatus.PSObject.Properties['lastError']) { $companionStatus.lastError } elseif ($state.PSObject.Properties['error']) { $state.error } else { $null }
        fingerprint = $state.fingerprint
        bridgePath = $state.bridgePath
        pinnedStartingSave = if ($state.PSObject.Properties['pinnedStartingSave']) { $state.pinnedStartingSave } else { $null }
        recoveryWatcherStatus = if ($recoveryWatcher) { $recoveryWatcher.status } else { $null }
        recoveryWatcherBoundary = if ($recoveryWatcher -and $recoveryWatcher.PSObject.Properties['lastArchivedBoundary']) {
            $recoveryWatcher.lastArchivedBoundary
        } else { $null }
        recoveryArchiveCount = if ($recoveryWatcher) { $recoveryWatcher.archiveCount } else { 0 }
        recoveryWatcherError = if ($recoveryWatcher) { $recoveryWatcher.error } else { $null }
        firstFaultEvidence = if ($recoveryWatcher -and $recoveryWatcher.PSObject.Properties['firstFaultEvidenceSummary']) {
            $recoveryWatcher.firstFaultEvidenceSummary
        } else { $null }
        firstFaultEvidenceError = if ($recoveryWatcher -and $recoveryWatcher.PSObject.Properties['firstFaultEvidenceError']) {
            $recoveryWatcher.firstFaultEvidenceError
        } else { $null }
        latestRecoveryArchive = if ($recoveryPointer) { $recoveryPointer.archiveDirectory } else { $null }
        stdout = $state.stdout
        stderr = $state.stderr
    }
}

if ($AsJson) { $result | ConvertTo-Json -Depth 8 }
else { [pscustomobject]$result | Format-List }
