[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$SaveDirectory,
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [string]$MatchContentProfilePath,
    [string]$BundleRoot,
    [string]$EvidenceCollectorPath,
    [ValidateRange(1, 60)][int]$PollSeconds = 2,
    [ValidateRange(2, 120)][int]$StableSeconds = 6,
    [ValidateRange(2, 120)][int]$UiSaveFallbackDelaySeconds = 8,
    [ValidateRange(1, 8760)][int]$LifetimeHours = 720,
    [switch]$DisableUiSaveFallback,
    [switch]$OneShot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
. (Join-Path $PSScriptRoot 'recovery_plan_common.ps1')
. (Join-Path $PSScriptRoot 'recovery_save_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$evidenceCollector = Resolve-Tpf2mpFullPath $(if ($EvidenceCollectorPath) {
    $EvidenceCollectorPath
} else {
    Join-Path $PSScriptRoot 'collect_live_evidence.ps1'
})
if (-not (Test-Path -LiteralPath $evidenceCollector -PathType Leaf)) {
    throw "First-fault evidence collector is missing: $evidenceCollector"
}
$safeSession = Assert-Tpf2mpSessionId $Session
$bridge = Resolve-Tpf2mpFullPath $BridgePath
$saveRoot = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory
$expectedGame = Resolve-Tpf2mpFullPath $GameExecutable
$expectedStart = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
$sessionRoot = Get-Tpf2mpSessionRoot $safeSession $Peer
$recoveryRoot = Join-Path $sessionRoot 'recovery'
$statusPath = Join-Path $sessionRoot 'recovery-watcher-status.json'
$companionStatusPath = Join-Path $bridge 'companion_state\companion_status.json'
$publishedPlanPath = Join-Path $bridge 'companion_state\published_restore_plan.json'
$receivedPlanPath = Join-Path $bridge 'companion_state\received_restore_plan.json'
$requestRoot = Join-Path $bridge 'companion_state\anchor_requests'
$resultRoot = Join-Path $bridge 'companion_state\anchor_results'
$auditPath = Join-Path $bridge "audit\$safeSession.ndjson"
$matchProfilePath = Resolve-Tpf2mpFullPath $(if ($MatchContentProfilePath) {
    $MatchContentProfilePath
} else { Join-Path $sessionRoot 'match-content-profile.json' })
$companion = Get-Tpf2mpCompanionCommand $bundle
$deadline = (Get-Date).AddHours($LifetimeHours)
$expectedSavePrefix = "tpf2mp_${safeSession}_${Peer}"
New-Item -ItemType Directory -Force -Path $recoveryRoot, $requestRoot, $resultRoot | Out-Null

$watch = [ordered]@{
    schemaVersion = 7
    session = $safeSession
    peer = $Peer
    status = 'starting'
    gameProcessId = $GameProcessId
    saveDirectory = $saveRoot
    expectedSavePrefix = $expectedSavePrefix
    auditPath = if ($Peer -eq 'player1') { $auditPath } else { $null }
    anchorBoundary = $null
    anchorReadyObservedAtUtc = $null
    automaticSaveName = $null
    uiSaveFallbackEnabled = -not $DisableUiSaveFallback
    uiSaveFallbackAttempts = 0
    uiSaveFallbackStatus = 'idle'
    uiSaveFallbackStartedAtUtc = $null
    uiSaveCompletionTimeoutSeconds = 1200
    uiSaveFallbackEvidence = $null
    uiSaveFallbackError = $null
    candidateSave = $null
    candidateStableSinceUtc = $null
    requestId = $null
    receiptStatus = $null
    receiptError = $null
    lastArchivedBoundary = $null
    latestArchivePointer = $null
    pendingArchivePointer = $null
    latestRecoveryPlan = $null
    receiptSave = $null
    publishedRecoveryPlan = $null
    publishedRecoveryPlanChecksum = $null
    receivedRecoveryPlan = $null
    receivedRecoveryPlanChecksum = $null
    receiptBoundArchiveReady = $false
    receiptBoundArchiveAttempts = 0
    receiptBoundArchiveError = $null
    archiveCount = 0
    firstFault = $null
    firstFaultObservedAtUtc = $null
    firstFaultEvidenceAttempted = $false
    firstFaultEvidenceAttempts = 0
    firstFaultEvidenceAttemptDirectories = @()
    firstFaultEvidenceDirectory = $null
    firstFaultEvidenceSummary = $null
    firstFaultEvidenceError = $null
    limitation = 'A restore point is valid only after both independently saved peers file ordered receipts for the same READY boundary.'
    lifetimeHours = $LifetimeHours
    expiresAtUtc = $deadline.ToUniversalTime().ToString('o')
    error = $null
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    updatedAtUtc = [DateTime]::UtcNow.ToString('o')
}

function Write-RecoveryWatcherStatus([string]$Status, [string]$ErrorText = $null) {
    $watch.status = $Status
    $watch.error = $ErrorText
    $watch.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = $statusPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, ($watch | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $statusPath -Force
}

function Get-ExactRecoveryGame {
    $game = Get-Process -Id $GameProcessId -ErrorAction SilentlyContinue
    if (-not $game -or $game.HasExited -or -not $game.Path) { return $null }
    $pathMatches = [string]::Equals(
        (Resolve-Tpf2mpFullPath $game.Path), $expectedGame, [StringComparison]::OrdinalIgnoreCase)
    $startMatches = [Math]::Abs(
        ($game.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds) -lt 2
    if (-not $pathMatches -or -not $startMatches) {
        throw 'Recorded game PID was reused; recovery watcher stopped without reading or archiving saves.'
    }
    return $game
}

function Get-CompanionStatus {
    if (-not (Test-Path -LiteralPath $companionStatusPath -PathType Leaf)) { return $null }
    try { $status = Get-Content -LiteralPath $companionStatusPath -Raw | ConvertFrom-Json }
    catch { return $null }
    if ($status.session -ne $safeSession -or $status.peer -ne $Peer) { return $null }
    return $status
}

function Test-PreparedBoundary([object]$CompanionStatus, [int]$Boundary) {
    if (-not $CompanionStatus -or $Boundary -lt 1) { return $false }
    $statusProperty = $CompanionStatus.PSObject.Properties['anchorPreparationStatus']
    $checkpointProperty = `
        $CompanionStatus.PSObject.Properties['anchorPreparationCheckpointSeq']
    if (-not $statusProperty -or -not $checkpointProperty) { return $false }
    return [string]$statusProperty.Value -eq 'ready' `
        -and [int]$checkpointProperty.Value -eq $Boundary
}

function Capture-FirstFaultEvidence([object]$CompanionStatus) {
    if (-not $CompanionStatus -or $watch.firstFaultEvidenceAttempted) { return }
    $faultProperty = $CompanionStatus.PSObject.Properties['sessionFault']
    if (-not $faultProperty) { return }
    $fault = [string]$faultProperty.Value
    if ([string]::IsNullOrWhiteSpace($fault)) { return }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $watch.firstFault = $fault.Substring(0, [Math]::Min($fault.Length, 512))
    $watch.firstFaultObservedAtUtc = [DateTime]::UtcNow.ToString('o')
    $watch.firstFaultEvidenceAttempted = $true
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $output = Join-Path $sessionRoot "fault-evidence\$stamp-attempt-$attempt"
        $watch.firstFaultEvidenceAttempts = $attempt
        $watch.firstFaultEvidenceAttemptDirectories = @(
            $watch.firstFaultEvidenceAttemptDirectories) + @($output)
        $watch.firstFaultEvidenceDirectory = $output
        $watch.firstFaultEvidenceError = $null
        Write-RecoveryWatcherStatus ([string]$watch.status)

        try {
            & $evidenceCollector -Session $safeSession -Peer $Peer -BridgePath $bridge `
                -OutputDirectory $output -BundleRoot $bundle -GameExecutable $expectedGame
            if (-not $?) { throw 'First-fault evidence collector returned failure.' }
            $summary = Join-Path $output 'evidence.json'
            if (-not (Test-Path -LiteralPath $summary -PathType Leaf)) {
                throw 'First-fault evidence collector did not write evidence.json.'
            }
            $watch.firstFaultEvidenceSummary = $summary
            $watch.firstFaultEvidenceError = $null
            break
        }
        catch {
            $watch.firstFaultEvidenceError = $_.Exception.Message
            Write-RecoveryWatcherStatus ([string]$watch.status) $watch.error
        }
    }
    Write-RecoveryWatcherStatus ([string]$watch.status) $watch.error
}

function Test-ContainsInteger([object]$Values, [int]$Expected) {
    foreach ($value in @($Values)) {
        $parsed = 0
        if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -eq $Expected) { return $true }
    }
    return $false
}

function Get-StableCandidateSignature([IO.FileInfo]$Save) {
    $metadataPath = $Save.FullName + '.lua'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $null }
    $metadata = Get-Item -LiteralPath $metadataPath
    $imagePath = [IO.Path]::ChangeExtension($Save.FullName, '.jpg')
    $image = if (Test-Path -LiteralPath $imagePath -PathType Leaf) { Get-Item -LiteralPath $imagePath } else { $null }
    $parts = @(
        $Save.FullName.ToLowerInvariant(), [string]$Save.Length, [string]$Save.LastWriteTimeUtc.Ticks,
        [string]$metadata.Length, [string]$metadata.LastWriteTimeUtc.Ticks
    )
    if ($image) { $parts += @([string]$image.Length, [string]$image.LastWriteTimeUtc.Ticks) }
    return ($parts -join '|')
}

function Get-NewRecoverySave([DateTime]$AfterUtc, [int]$Boundary) {
    $automaticBaseName = Get-Tpf2mpRecoverySaveBaseName `
        -Session $safeSession -Peer $Peer -BoundarySeq $Boundary
    # The game sees the same READY companion status as this watcher. It can
    # finish the automatic SaveGame command just before our next two-second
    # poll records READY, so admit only the exact automatic name in that small
    # pre-observation window. Arbitrary/manual prefix saves still have to be
    # newer than the watcher observation.
    $automaticGraceUtc = $AfterUtc.AddSeconds(-[Math]::Max(4, $PollSeconds * 2))
    return @(Get-ChildItem -LiteralPath $saveRoot -File -Filter '*.sav' -ErrorAction SilentlyContinue |
        Where-Object {
            $automaticRecent = $_.BaseName -ieq $automaticBaseName `
                -and $_.LastWriteTimeUtc -ge $automaticGraceUtc
            $manualRecent = $_.LastWriteTimeUtc -ge $AfterUtc
            ($automaticRecent -or ($manualRecent -and $_.BaseName.StartsWith(
                $expectedSavePrefix, [StringComparison]::OrdinalIgnoreCase))) `
                -and (Test-Path -LiteralPath ($_.FullName + '.lua') -PathType Leaf)
        } |
        Sort-Object LastWriteTimeUtc -Descending) | Select-Object -First 1
}

function Submit-AnchorRequest([object]$CompanionStatus, [IO.FileInfo]$Save) {
    $requestId = [guid]::NewGuid().ToString('N').ToLowerInvariant()
    $request = [ordered]@{
        schemaVersion = 1
        session = $safeSession
        peer = $Peer
        requestId = $requestId
        boundarySeq = [int]$CompanionStatus.anchorBoundarySeq
        coreDigest = [string]$CompanionStatus.anchorCoreDigest
        convergenceKey = [string]$CompanionStatus.anchorConvergenceKey
        savePath = $Save.FullName
        savedAtUnix = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    }
    if (-not $request.coreDigest -or -not $request.convergenceKey) {
        throw 'READY companion status omitted the checkpoint digest or convergence key.'
    }
    $path = Join-Path $requestRoot ($requestId + '.json')
    $temporary = $path + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, ($request | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $path
    return $requestId
}

function New-VerifiedRestorePlan([int]$Boundary) {
    if ($Peer -ne 'player1') { throw 'Only the host audit can produce a restore plan.' }
    if (-not (Test-Path -LiteralPath $auditPath -PathType Leaf)) { throw 'Host audit is not available yet.' }
    if (-not (Test-Path -LiteralPath $matchProfilePath -PathType Leaf)) {
        throw 'Match-content profile is missing; refusing to create an under-bound restore plan.'
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $planPath = Join-Path $recoveryRoot "auto-restore-plan-$Boundary-$stamp.json"
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') { $env:PYTHONPATH = Join-Path $bundle 'companion' }
    try {
        $arguments = @(
            'restore-plan', $auditPath, '--session', $safeSession,
            '--boundary', [string]$Boundary, '--match-profile', $matchProfilePath,
            '--output', $planPath
        )
        $output = @(& $companion.FilePath @($companion.Prefix + $arguments) 2>&1)
        foreach ($line in $output) { Write-Host $line }
        if ($LASTEXITCODE -ne 0) { throw "Recovery-plan companion exited $LASTEXITCODE" }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    if ([int]$plan.boundarySeq -ne $Boundary) {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        throw "Latest verified restore boundary moved from $Boundary to $($plan.boundarySeq)."
    }
    return $planPath
}

function Publish-VerifiedRestorePlan([string]$Path) {
    if ($Peer -ne 'player1') { throw 'Only player1 may publish a restore plan.' }
    $publication = Publish-Tpf2mpVerifiedRestorePlan -BundleRoot $bundle `
        -Session $safeSession -PlanPath $Path -Destination $publishedPlanPath
    $watch.publishedRecoveryPlan = $publication.path
    $watch.publishedRecoveryPlanChecksum = $publication.checksum
}

$script:receivedPlanAttemptHash = $null
$script:receivedPlanAttempts = 0
$script:receivedPlanRetryAt = [DateTime]::MinValue
function Receive-And-BindRestorePlan {
    if ($Peer -ne 'player2' -or $watch.receiptBoundArchiveReady `
        -or -not $watch.lastArchivedBoundary -or -not $watch.receiptSave `
        -or -not (Test-Path -LiteralPath $receivedPlanPath -PathType Leaf)) { return }
    $fileHash = (Get-FileHash -LiteralPath $receivedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($fileHash -ne $script:receivedPlanAttemptHash) {
        $script:receivedPlanAttemptHash = $fileHash
        $script:receivedPlanAttempts = 0
        $script:receivedPlanRetryAt = [DateTime]::MinValue
    }
    if ($script:receivedPlanAttempts -ge 3 -or [DateTime]::UtcNow -lt $script:receivedPlanRetryAt) { return }
    $script:receivedPlanAttempts++
    $watch.receiptBoundArchiveAttempts = $script:receivedPlanAttempts
    try {
        $plan = Read-Tpf2mpVerifiedRestorePlan -BundleRoot $bundle `
            -Session $safeSession -PlanPath $receivedPlanPath
        if ([int]$plan.boundarySeq -lt [int]$watch.lastArchivedBoundary) {
            $script:receivedPlanAttempts = 0
            $script:receivedPlanRetryAt = [DateTime]::UtcNow.AddSeconds(10)
            $watch.receiptBoundArchiveAttempts = 0
            return
        }
        if ([int]$plan.boundarySeq -ne [int]$watch.lastArchivedBoundary `
            -or @($plan.requiredPeers) -notcontains $Peer) {
            throw 'Received restore plan does not bind this peer and archived boundary.'
        }
        $watch.receiptBoundArchiveError = $null
        Write-RecoveryWatcherStatus 'binding-local-save-to-verified-plan'
        $archive = New-Tpf2mpReceiptBoundArchive -BundleRoot $bundle `
            -Session $safeSession -Peer $Peer -ReceivedPlanPath $receivedPlanPath `
            -SavePath ([string]$watch.receiptSave) -BoundarySeq ([int]$plan.boundarySeq)
        $watch.receivedRecoveryPlan = $archive.durablePlan
        $watch.receivedRecoveryPlanChecksum = [string]$plan.checksum
        $watch.latestRecoveryPlan = $archive.durablePlan
        $watch.latestArchivePointer = $archive.latestPointer
        $watch.archiveCount = [int]$watch.archiveCount + 1
        $watch.receiptBoundArchiveReady = $true
        Write-RecoveryWatcherStatus 'restore-point-ready-awaiting-next-boundary'
    }
    catch {
        $script:receivedPlanRetryAt = [DateTime]::UtcNow.AddSeconds(10)
        $watch.receiptBoundArchiveAttempts = $script:receivedPlanAttempts
        $watch.receiptBoundArchiveError = $_.Exception.Message
        Write-RecoveryWatcherStatus 'receipt-plan-binding-failed' $_.Exception.Message
    }
}

$readyObservedAt = $null
$candidateSignature = $null
$candidateStableSince = $null
$candidate = $null
$requestId = $null
$requestBoundary = 0
$uiSaveFallbackBoundary = 0
$uiSaveFallbackRetryAt = [DateTime]::MinValue

try {
    Write-RecoveryWatcherStatus 'waiting-for-ready-boundary'
    while ((Get-Date) -lt $deadline) {
        $status = Get-CompanionStatus
        Capture-FirstFaultEvidence $status
        Receive-And-BindRestorePlan
        if (-not (Get-ExactRecoveryGame)) {
            Write-RecoveryWatcherStatus 'stopped-game-exited'
            break
        }
        $readyBoundary = 0
        if ($status -and $status.anchorReady -eq $true) {
            [void][int]::TryParse([string]$status.anchorBoundarySeq, [ref]$readyBoundary)
        }

        if ($readyBoundary -gt 0 -and $readyBoundary -ne $watch.lastArchivedBoundary `
            -and -not $requestId -and $requestBoundary -ne $readyBoundary) {
            $readyObservedAt = [DateTime]::UtcNow
            $requestBoundary = $readyBoundary
            $candidateSignature = $null
            $candidateStableSince = $null
            $candidate = $null
            $watch.anchorBoundary = $readyBoundary
            $watch.anchorReadyObservedAtUtc = $readyObservedAt.ToString('o')
            $watch.automaticSaveName = Get-Tpf2mpRecoverySaveBaseName `
                -Session $safeSession -Peer $Peer -BoundarySeq $readyBoundary
            $preparedBoundary = Test-PreparedBoundary $status $readyBoundary
            $uiSaveFallbackBoundary = if ($preparedBoundary) { $readyBoundary } else { 0 }
            $uiSaveFallbackRetryAt = [DateTime]::MinValue
            $watch.uiSaveFallbackAttempts = 0
            $watch.uiSaveFallbackStatus = if ($preparedBoundary) {
                'waiting-for-native-command'
            } else { 'manual-save-available' }
            $watch.uiSaveFallbackEvidence = $null
            $watch.uiSaveFallbackError = $null
            $watch.uiSaveFallbackStartedAtUtc = $null
            $watch.candidateSave = $null
            $watch.candidateStableSinceUtc = $null
            $watch.receiptStatus = $null
            $watch.receiptError = $null
            $watch.receiptSave = $null
            $watch.pendingArchivePointer = $null
            $watch.receivedRecoveryPlan = $null
            $watch.receivedRecoveryPlanChecksum = $null
            $watch.receiptBoundArchiveReady = $false
            $watch.receiptBoundArchiveAttempts = 0
            $watch.receiptBoundArchiveError = $null
            Write-RecoveryWatcherStatus 'ready-save-now'
        }

        # Preparation status can become visible one poll after the generic
        # READY projection. Arm UI automation only for that explicit workflow;
        # ordinary paused economy/operation checkpoints must never steal focus.
        if ($readyBoundary -gt 0 -and $requestBoundary -eq $readyBoundary `
            -and $uiSaveFallbackBoundary -ne $readyBoundary `
            -and (Test-PreparedBoundary $status $readyBoundary)) {
            $uiSaveFallbackBoundary = $readyBoundary
            $uiSaveFallbackRetryAt = [DateTime]::MinValue
            $watch.uiSaveFallbackAttempts = 0
            $watch.uiSaveFallbackStatus = 'waiting-for-native-command'
            $watch.uiSaveFallbackError = $null
            Write-RecoveryWatcherStatus 'prepared-boundary-awaiting-native-save'
        }

        if ($readyObservedAt -and -not $requestId) {
            $newCandidate = Get-NewRecoverySave $readyObservedAt $requestBoundary
            if ($newCandidate) {
                $signature = Get-StableCandidateSignature $newCandidate
                if ($signature -and $signature -ne $candidateSignature) {
                    $candidate = $newCandidate
                    $candidateSignature = $signature
                    $candidateStableSince = [DateTime]::UtcNow
                    $watch.candidateSave = $candidate.FullName
                    $watch.candidateStableSinceUtc = $candidateStableSince.ToString('o')
                    Write-RecoveryWatcherStatus 'waiting-for-save-stability'
                }
                elseif ($signature -and $candidateStableSince `
                    -and ([DateTime]::UtcNow - $candidateStableSince).TotalSeconds -ge $StableSeconds) {
                    $latest = Get-CompanionStatus
                    $receiptReady = $latest -and ((
                        $latest.PSObject.Properties['anchorReceiptReady'] `
                            -and $latest.anchorReceiptReady -eq $true) `
                        -or (-not $latest.PSObject.Properties['anchorReceiptReady'] `
                            -and $latest.anchorReady -eq $true))
                    if (-not $receiptReady `
                        -or [int]$latest.anchorBoundarySeq -ne $requestBoundary) {
                        $readyObservedAt = $null
                        $requestBoundary = 0
                        Write-RecoveryWatcherStatus 'boundary-left-ready-state-resave-required'
                    }
                    else {
                        $requestId = Submit-AnchorRequest $latest $candidate
                        $watch.requestId = $requestId
                        $watch.receiptStatus = 'pending'
                        Write-RecoveryWatcherStatus 'filing-ordered-receipt'
                    }
                }
            }
        }

        if (-not $OneShot -and -not $DisableUiSaveFallback `
            -and $readyObservedAt -and -not $requestId -and -not $candidate `
            -and $uiSaveFallbackBoundary -eq $requestBoundary `
            -and $watch.uiSaveFallbackAttempts -lt 3 `
            -and [DateTime]::UtcNow -ge $uiSaveFallbackRetryAt `
            -and ([DateTime]::UtcNow - $readyObservedAt).TotalSeconds `
                -ge $UiSaveFallbackDelaySeconds) {
            $watch.uiSaveFallbackAttempts = [int]$watch.uiSaveFallbackAttempts + 1
            $attempt = [int]$watch.uiSaveFallbackAttempts
            $uiEvidence = Join-Path $recoveryRoot `
                "stock-ui-save-b$requestBoundary-attempt-$attempt"
            New-Item -ItemType Directory -Force -Path $uiEvidence | Out-Null
            $watch.uiSaveFallbackStatus = 'running'
            $watch.uiSaveFallbackStartedAtUtc = [DateTime]::UtcNow.ToString('o')
            $watch.uiSaveFallbackEvidence = $uiEvidence
            $watch.uiSaveFallbackError = $null
            Write-RecoveryWatcherStatus 'saving-ready-boundary-through-stock-ui'
            try {
                $uiArguments = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                    (Join-Path $PSScriptRoot 'save_recovery_via_ui.ps1'),
                    '-Session', $safeSession, '-Peer', $Peer,
                    '-BoundarySeq', [string]$requestBoundary,
                    '-BridgePath', $bridge, '-SaveDirectory', $saveRoot,
                    '-SaveBaseName', ([string]$watch.automaticSaveName),
                    '-GameProcessId', [string]$GameProcessId,
                    '-GameExecutable', $expectedGame,
                    '-GameStartedAtUtc', $expectedStart.ToString('o'),
                    '-EvidenceDirectory', $uiEvidence,
                    '-SaveCompletionTimeoutSeconds',
                    [string]$watch.uiSaveCompletionTimeoutSeconds
                )
                # A failed focus/dialog attempt is an expected bounded retry,
                # not an unhandled watcher error. Preserve the child process's
                # complete output beside its receipts without polluting the
                # launcher's stderr stream or disguising a final failure.
                $uiProcessLog = Join-Path $uiEvidence 'process.log'
                $uiOutput = @(
                    & (Join-Path $PSHOME 'powershell.exe') @uiArguments 2>&1
                )
                $uiExitCode = $LASTEXITCODE
                $uiOutput | Set-Content -LiteralPath $uiProcessLog -Encoding UTF8
                if ($uiExitCode -ne 0) {
                    $lastLine = @($uiOutput | Select-Object -Last 1) -join ''
                    $suffix = if ($lastLine) { ": $lastLine" } else { '' }
                    throw "Stock-UI recovery save exited $uiExitCode$suffix"
                }
                $watch.uiSaveFallbackStatus = 'completed'
                Write-RecoveryWatcherStatus 'stock-ui-save-completed-awaiting-stability'
            }
            catch {
                $watch.uiSaveFallbackError = $_.Exception.Message
                $partialSave = Join-Path $saveRoot `
                    (([string]$watch.automaticSaveName) + '.sav')
                $partialMetadata = $partialSave + '.lua'
                $partialTemporary = $partialMetadata + '.tmp'
                $partialFresh = @($partialSave, $partialTemporary) | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                } | Where-Object {
                    (Get-Item -LiteralPath $_).LastWriteTimeUtc `
                        -ge $readyObservedAt.AddSeconds(-4)
                }
                $metadataComplete = (Test-Path -LiteralPath $partialMetadata -PathType Leaf) `
                    -and (Get-Item -LiteralPath $partialMetadata).Length -gt 0
                if ($partialFresh -and -not $metadataComplete) {
                    # A retry can open a second stock Save dialog over an
                    # engine which is still finalising the first save. Stop
                    # automatic retries; the normal candidate poll will still
                    # accept the file if native metadata appears later.
                    $watch.uiSaveFallbackStatus = 'native-save-incomplete-no-retry'
                    $watch.uiSaveFallbackAttempts = 3
                    $uiSaveFallbackRetryAt = [DateTime]::MaxValue
                    Write-RecoveryWatcherStatus `
                        'native-save-incomplete-awaiting-finalization' $_.Exception.Message
                }
                else {
                    $watch.uiSaveFallbackStatus = 'failed'
                    $uiSaveFallbackRetryAt = [DateTime]::UtcNow.AddSeconds(15)
                    Write-RecoveryWatcherStatus `
                        'stock-ui-save-failed-manual-save-still-available' $_.Exception.Message
                }
            }
        }

        if ($requestId) {
            $resultPath = Join-Path $resultRoot ($requestId + '.json')
            if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                try { $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json }
                catch { $result = $null }
                if ($result -and $result.status -eq 'rejected') {
                    $watch.receiptStatus = 'rejected'
                    $watch.receiptError = [string]$result.error
                    Write-RecoveryWatcherStatus 'receipt-rejected-resave-required' $watch.receiptError
                    $requestId = $null
                    $requestBoundary = 0
                    $readyObservedAt = $null
                }
                elseif ($result -and $result.status -eq 'accepted') {
                    $watch.receiptStatus = 'accepted'
                    $watch.receiptError = $null
                    $receiptSave = Get-Tpf2mpReceiptBoundSave `
                        -SaveDirectory $saveRoot -ExpectedSavePrefix $expectedSavePrefix `
                        -AutomaticSaveName ([string]$watch.automaticSaveName) `
                        -Receipt $result -PreferredSavePath $candidate.FullName
                    if ($Peer -eq 'player2') {
                        Write-RecoveryWatcherStatus 'archiving-local-receipt-save'
                        & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $Peer `
                            -SavePath $receiptSave.FullName -BoundarySeq $requestBoundary `
                            -PendingReceipt -BundleRoot $bundle
                        if ($LASTEXITCODE -ne 0) { throw "Recovery archive exited $LASTEXITCODE" }
                        $watch.lastArchivedBoundary = $requestBoundary
                        $watch.pendingArchivePointer = Join-Path $sessionRoot `
                            "pending-recovery-archive-b$requestBoundary.json"
                        $watch.receiptSave = $receiptSave.FullName
                        $watch.archiveCount = [int]$watch.archiveCount + 1
                        Write-RecoveryWatcherStatus 'receipt-filed-awaiting-verified-plan'
                        $requestId = $null
                        $requestBoundary = 0
                        $readyObservedAt = $null
                    }
                    else {
                        $latest = Get-CompanionStatus
                        if ($latest -and (Test-ContainsInteger $latest.restorePoints $requestBoundary)) {
                            Write-RecoveryWatcherStatus 'building-verified-restore-plan'
                            $planPath = New-VerifiedRestorePlan $requestBoundary
                            & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $Peer `
                                -SavePath $receiptSave.FullName -RecoveryPlanPath $planPath `
                                -BoundarySeq $requestBoundary -BundleRoot $bundle
                            if ($LASTEXITCODE -ne 0) { throw "Recovery archive exited $LASTEXITCODE" }
                            $watch.lastArchivedBoundary = $requestBoundary
                            $watch.latestRecoveryPlan = $planPath
                            $watch.latestArchivePointer = Join-Path $sessionRoot 'latest-recovery-archive.json'
                            $watch.archiveCount = [int]$watch.archiveCount + 1
                            $watch.receiptBoundArchiveReady = $true
                            Publish-VerifiedRestorePlan $planPath
                            Write-RecoveryWatcherStatus 'restore-point-ready-awaiting-next-boundary'
                            $requestId = $null
                            $requestBoundary = 0
                            $readyObservedAt = $null
                        }
                        else {
                            Write-RecoveryWatcherStatus 'receipt-filed-waiting-for-peer'
                        }
                    }
                }
            }
        }

        if ($OneShot) { break }
        Start-Sleep -Seconds $PollSeconds
    }
    if ((Get-Date) -ge $deadline) { Write-RecoveryWatcherStatus 'expired' }
}
catch {
    Write-RecoveryWatcherStatus 'failed' $_.Exception.Message
    throw
}

Write-Host "Recovery watcher status: $statusPath"
