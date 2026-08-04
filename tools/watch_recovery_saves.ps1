[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1')][string]$Peer,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$SaveDirectory,
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [string]$BundleRoot,
    [ValidateRange(1, 60)][int]$PollSeconds = 2,
    [ValidateRange(2, 120)][int]$StableSeconds = 6,
    [ValidateRange(1, 48)][int]$LifetimeHours = 12,
    [switch]$OneShot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
$bridge = Resolve-Tpf2mpFullPath $BridgePath
$saveRoot = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory
$expectedGame = Resolve-Tpf2mpFullPath $GameExecutable
$expectedStart = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
$sessionRoot = Get-Tpf2mpSessionRoot $safeSession $Peer
$recoveryRoot = Join-Path $sessionRoot 'recovery'
$statusPath = Join-Path $sessionRoot 'recovery-watcher-status.json'
$auditPath = Join-Path $bridge "audit\$safeSession.ndjson"
$companionStatusPath = Join-Path $bridge 'companion_state\companion_status.json'
$companion = Get-Tpf2mpCompanionCommand $bundle
$deadline = (Get-Date).AddHours($LifetimeHours)
New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null

$watch = [ordered]@{
    schemaVersion = 1
    session = $safeSession
    peer = $Peer
    status = 'starting'
    gameProcessId = $GameProcessId
    saveDirectory = $saveRoot
    auditPath = $auditPath
    lastAgreedBoundary = $null
    boundaryObservedAtUtc = $null
    candidateSave = $null
    candidateStableSinceUtc = $null
    lastArchivedBoundary = $null
    latestArchivePointer = $null
    archiveCount = 0
    limitation = 'Archives are linked to an agreed authority checkpoint and a later stable native save; no supported exact-tick save command exists.'
    error = $null
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    updatedAtUtc = [DateTime]::UtcNow.ToString('o')
}

function Write-RecoveryWatcherStatus([string]$Status, [string]$ErrorText = $null) {
    $watch.status = $Status
    $watch.error = $ErrorText
    $watch.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    $temporary = $statusPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($temporary, ($watch | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
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

function Get-LatestAgreedBoundary {
    if (-not (Test-Path -LiteralPath $companionStatusPath -PathType Leaf)) { return $null }
    try { $status = Get-Content -LiteralPath $companionStatusPath -Raw | ConvertFrom-Json }
    catch { return $null }
    if ($status.session -ne $safeSession -or $status.peer -ne $Peer -or $status.role -ne 'host') {
        return $null
    }
    if (-not $status.PSObject.Properties['lastAgreedCheckpointSeq']) { return $null }
    $boundary = 0
    if (-not [int]::TryParse([string]$status.lastAgreedCheckpointSeq, [ref]$boundary) -or $boundary -lt 1) {
        return $null
    }
    return $boundary
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

function Get-NewRecoverySave([DateTime]$AfterUtc) {
    $candidates = @(Get-ChildItem -LiteralPath $saveRoot -File -Filter '*.sav' -ErrorAction SilentlyContinue |
        Where-Object {
            -not $_.Name.StartsWith('tpf2mp_', [StringComparison]::OrdinalIgnoreCase) `
                -and $_.LastWriteTimeUtc -ge $AfterUtc `
                -and (Test-Path -LiteralPath ($_.FullName + '.lua') -PathType Leaf)
        } |
        Sort-Object LastWriteTimeUtc -Descending)
    return $candidates | Select-Object -First 1
}

function New-VerifiedRecoveryPlan([int]$Boundary) {
    if (-not (Test-Path -LiteralPath $auditPath -PathType Leaf)) {
        throw 'Host audit is not available yet.'
    }
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
    $planPath = Join-Path $recoveryRoot "auto-recovery-plan-$Boundary-$stamp.json"
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') { $env:PYTHONPATH = Join-Path $bundle 'companion' }
    try {
        $arguments = @('recovery-plan', $auditPath, '--session', $safeSession, '--output', $planPath)
        $output = @(& $companion.FilePath @($companion.Prefix + $arguments) 2>&1)
        foreach ($line in $output) { Write-Host $line }
        if ($LASTEXITCODE -ne 0) { throw "Recovery-plan companion exited $LASTEXITCODE" }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
    $plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    if ([int]$plan.anchor.boundarySeq -ne $Boundary) {
        Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
        throw "Latest verified recovery boundary moved from $Boundary to $($plan.anchor.boundarySeq)."
    }
    return $planPath
}

$observedBoundary = $null
$boundaryObservedAt = $null
$candidateSignature = $null
$candidateStableSince = $null

try {
    Write-RecoveryWatcherStatus 'waiting-for-checkpoint'
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ExactRecoveryGame)) {
            Write-RecoveryWatcherStatus 'stopped-game-exited'
            break
        }

        $boundary = Get-LatestAgreedBoundary
        if ($boundary -and $boundary -ne $observedBoundary) {
            $observedBoundary = $boundary
            $boundaryObservedAt = [DateTime]::UtcNow
            $candidateSignature = $null
            $candidateStableSince = $null
            $watch.lastAgreedBoundary = $boundary
            $watch.boundaryObservedAtUtc = $boundaryObservedAt.ToString('o')
            $watch.candidateSave = $null
            $watch.candidateStableSinceUtc = $null
            Write-RecoveryWatcherStatus 'waiting-for-native-save'
        }

        if ($observedBoundary -and $observedBoundary -ne $watch.lastArchivedBoundary) {
            $candidate = Get-NewRecoverySave $boundaryObservedAt
            if ($candidate) {
                $signature = Get-StableCandidateSignature $candidate
                if ($signature -and $signature -ne $candidateSignature) {
                    $candidateSignature = $signature
                    $candidateStableSince = [DateTime]::UtcNow
                    $watch.candidateSave = $candidate.FullName
                    $watch.candidateStableSinceUtc = $candidateStableSince.ToString('o')
                    Write-RecoveryWatcherStatus 'waiting-for-save-stability'
                }
                elseif ($signature -and $candidateStableSince `
                    -and ([DateTime]::UtcNow - $candidateStableSince).TotalSeconds -ge $StableSeconds) {
                    Write-RecoveryWatcherStatus 'archiving'
                    $planPath = New-VerifiedRecoveryPlan $observedBoundary
                    & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $Peer `
                        -SavePath $candidate.FullName -RecoveryPlanPath $planPath -BundleRoot $bundle
                    if ($LASTEXITCODE -ne 0) { throw "Recovery archive exited $LASTEXITCODE" }
                    $pointerPath = Join-Path $sessionRoot 'latest-recovery-archive.json'
                    $pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
                    if (-not $pointer.recoveryPlanPath) {
                        throw 'Automatic recovery archive was not linked to its verified plan.'
                    }
                    $watch.lastArchivedBoundary = $observedBoundary
                    $watch.latestArchivePointer = $pointerPath
                    $watch.archiveCount = [int]$watch.archiveCount + 1
                    Write-RecoveryWatcherStatus 'archived-awaiting-next-checkpoint'
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

