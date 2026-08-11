[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $ProjectRoot 'tools\network_common.ps1')
. (Join-Path $ProjectRoot 'tools\recovery_save_common.ps1')

$session = 'fault-watch-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$sessionRoot = Get-Tpf2mpSessionRoot $session 'player1'
$automaticSession = 'auto-save-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$automaticSessionRoot = Get-Tpf2mpSessionRoot $automaticSession 'player1'
$latchedSession = 'latched-save-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$latchedSessionRoot = Get-Tpf2mpSessionRoot $latchedSession 'player1'
$incidentalSession = 'incidental-ready-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$incidentalSessionRoot = Get-Tpf2mpSessionRoot $incidentalSession 'player1'
$uiSession = 'ui-save-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$uiSessionRoot = Get-Tpf2mpSessionRoot $uiSession 'player2'
$supportRoot = Get-Tpf2mpSupportRoot
$supportPrefix = $supportRoot.TrimEnd('\') + '\'

function Read-TestJsonStatus([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}
if (-not $sessionRoot.StartsWith($supportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fault-watcher test resolved a session outside the TPF2MP support root.'
}

$bridge = Join-Path $TemporaryRoot 'fault-watcher-bridge'
$statusRoot = Join-Path $bridge 'companion_state'
$saveRoot = Join-Path $TemporaryRoot 'fault-watcher\1066780\local\save'
$fakeGame = Join-Path $TemporaryRoot 'fault-watcher\TransportFever2.exe'
$fakeCollector = Join-Path $TemporaryRoot 'fake-evidence-collector.ps1'
New-Item -ItemType Directory -Force -Path $statusRoot, $saveRoot, (Split-Path -Parent $fakeGame) | Out-Null
[IO.File]::WriteAllBytes($fakeGame, [byte[]](0))
[IO.File]::WriteAllText((Join-Path $statusRoot 'companion_status.json'),
    ([ordered]@{
        schemaVersion = 1
        session = $session
        peer = 'player1'
        sessionFault = 'first-fault-test:physical-digest-mismatch'
    } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

$collectorSource = @'
[CmdletBinding()]
param(
    [string]$Session, [string]$Peer, [string]$BridgePath,
    [string]$OutputDirectory, [string]$BundleRoot, [string]$GameExecutable
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$attemptFile = Join-Path (Split-Path -Parent $OutputDirectory) 'collector-attempts.txt'
$attempt = if (Test-Path -LiteralPath $attemptFile) {
    [int](Get-Content -LiteralPath $attemptFile -Raw)
} else { 0 }
$attempt++
[IO.File]::WriteAllText($attemptFile, [string]$attempt, [Text.UTF8Encoding]::new($false))
if ($attempt -eq 1) { throw 'synthetic transient collector failure' }
[ordered]@{
    session = $Session
    peer = $Peer
    bridge = [IO.Path]::GetFullPath($BridgePath)
    bundle = [IO.Path]::GetFullPath($BundleRoot)
    game = [IO.Path]::GetFullPath($GameExecutable)
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'evidence.json') -Encoding UTF8
'@
[IO.File]::WriteAllText($fakeCollector, $collectorSource, [Text.UTF8Encoding]::new($false))

try {
    & (Join-Path $ProjectRoot 'tools\watch_recovery_saves.ps1') `
        -Session $session -Peer player1 -BridgePath $bridge -SaveDirectory $saveRoot `
        -GameProcessId 2147483000 -GameExecutable $fakeGame `
        -GameStartedAtUtc ([DateTime]::UtcNow.ToString('o')) -BundleRoot $ProjectRoot `
        -EvidenceCollectorPath $fakeCollector -OneShot
    if (-not $?) { throw 'Fault-watcher fixture returned failure.' }

    $watcherStatusPath = Join-Path $sessionRoot 'recovery-watcher-status.json'
    $watcher = Get-Content -LiteralPath $watcherStatusPath -Raw | ConvertFrom-Json
    if ($watcher.schemaVersion -ne 7 -or $watcher.status -ne 'stopped-game-exited') {
        throw 'Fault watcher did not preserve its terminal status after capturing evidence.'
    }
    if ($watcher.lifetimeHours -ne 720 -or -not $watcher.expiresAtUtc) {
        throw 'Fault watcher did not advertise the 30-day long-session guard.'
    }
    $watcherExpiry = [DateTime]::Parse([string]$watcher.expiresAtUtc).ToUniversalTime()
    $watcherStart = [DateTime]::Parse([string]$watcher.startedAtUtc).ToUniversalTime()
    if ([Math]::Abs(($watcherExpiry - $watcherStart).TotalHours - 720) -gt 1) {
        throw 'Fault watcher expiry does not match its advertised lifetime.'
    }
    if ($watcher.firstFaultEvidenceAttempted -ne $true `
        -or $watcher.firstFault -ne 'first-fault-test:physical-digest-mismatch' `
        -or $watcher.firstFaultEvidenceError) {
        throw 'Fault watcher did not record the first session fault exactly once.'
    }
    if ($watcher.firstFaultEvidenceAttempts -ne 2 `
        -or @($watcher.firstFaultEvidenceAttemptDirectories).Count -ne 2) {
        throw 'Fault watcher did not retry a transient evidence-collector failure exactly once.'
    }
    if (-not (Test-Path -LiteralPath $watcher.firstFaultEvidenceSummary -PathType Leaf)) {
        throw 'Fault watcher did not retain its evidence summary.'
    }
    $evidence = Get-Content -LiteralPath $watcher.firstFaultEvidenceSummary -Raw | ConvertFrom-Json
    if ($evidence.session -ne $session -or $evidence.peer -ne 'player1' `
        -or $evidence.bridge -ne [IO.Path]::GetFullPath($bridge)) {
        throw 'Fault watcher passed the wrong session identity to its evidence collector.'
    }
    Write-Host 'PASS first session fault survives a transient collector failure and game exit'

    $automaticBridge = Join-Path $TemporaryRoot 'automatic-save-watcher-bridge'
    $automaticStatusRoot = Join-Path $automaticBridge 'companion_state'
    $automaticSaveRoot = Join-Path $TemporaryRoot 'automatic-save-watcher\1066780\local\save'
    New-Item -ItemType Directory -Force -Path $automaticStatusRoot, $automaticSaveRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $automaticStatusRoot 'companion_status.json'),
        ([ordered]@{
            schemaVersion = 1
            session = $automaticSession
            peer = 'player1'
            anchorReady = $true
            anchorBoundarySeq = 8
            anchorCoreDigest = 'deadbeef'
            anchorConvergenceKey = '1234abcd'
            anchorPreparationStatus = 'ready'
            anchorPreparationCheckpointSeq = 8
            sessionFault = $null
        } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $automaticBaseName = Get-Tpf2mpRecoverySaveBaseName `
        -Session $automaticSession -Peer player1 -BoundarySeq 8
    if ($automaticBaseName.Length -gt 50) {
        throw 'Automatic recovery save name exceeds the native dialog limit.'
    }
    $automaticSave = Join-Path $automaticSaveRoot ($automaticBaseName + '.sav')
    [IO.File]::WriteAllBytes($automaticSave, [byte[]](1, 2, 3))
    [IO.File]::WriteAllText($automaticSave + '.lua', 'function data() return {} end',
        [Text.UTF8Encoding]::new($false))
    $currentProcess = Get-Process -Id $PID
    & (Join-Path $ProjectRoot 'tools\watch_recovery_saves.ps1') `
        -Session $automaticSession -Peer player1 -BridgePath $automaticBridge `
        -SaveDirectory $automaticSaveRoot -GameProcessId $PID `
        -GameExecutable $currentProcess.Path `
        -GameStartedAtUtc ($currentProcess.StartTime.ToUniversalTime().ToString('o')) `
        -BundleRoot $ProjectRoot -EvidenceCollectorPath $fakeCollector -OneShot
    if (-not $?) { throw 'Automatic native-save watcher fixture returned failure.' }
    $automaticWatcher = Get-Content -LiteralPath `
        (Join-Path $automaticSessionRoot 'recovery-watcher-status.json') -Raw | ConvertFrom-Json
    if ($automaticWatcher.status -ne 'waiting-for-save-stability' `
        -or $automaticWatcher.automaticSaveName -ne $automaticBaseName `
        -or $automaticWatcher.candidateSave -ne $automaticSave) {
        throw 'Watcher missed the exact automatic save completed just before its READY poll.'
    }
    Write-Host 'PASS automatic native save survives the watcher READY-poll race'

    $latchedBridge = Join-Path $TemporaryRoot 'latched-save-watcher-bridge'
    $latchedStatusRoot = Join-Path $latchedBridge 'companion_state'
    $latchedSaveRoot = Join-Path $TemporaryRoot 'latched-save-watcher\1066780\local\save'
    New-Item -ItemType Directory -Force -Path $latchedStatusRoot, $latchedSaveRoot | Out-Null
    $latchedStatusPath = Join-Path $latchedStatusRoot 'companion_status.json'
    $latchedStatus = [ordered]@{
        schemaVersion = 1
        session = $latchedSession
        peer = 'player1'
        anchorReady = $true
        anchorReceiptReady = $true
        anchorBoundarySeq = 12
        anchorCoreDigest = 'deadbeef'
        anchorConvergenceKey = '1234abcd'
        anchorPreparationStatus = 'ready'
        anchorPreparationCheckpointSeq = 12
        sessionFault = $null
    }
    [IO.File]::WriteAllText($latchedStatusPath,
        ($latchedStatus | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    $latchedStdout = Join-Path $TemporaryRoot 'latched-save-watcher.stdout.log'
    $latchedStderr = Join-Path $TemporaryRoot 'latched-save-watcher.stderr.log'
    $latchedArgs = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $ProjectRoot 'tools\watch_recovery_saves.ps1'),
        '-Session', $latchedSession, '-Peer', 'player1', '-BridgePath', $latchedBridge,
        '-SaveDirectory', $latchedSaveRoot, '-GameProcessId', [string]$PID,
        '-GameExecutable', $currentProcess.Path,
        '-GameStartedAtUtc', $currentProcess.StartTime.ToUniversalTime().ToString('o'),
        '-BundleRoot', $ProjectRoot, '-EvidenceCollectorPath', $fakeCollector,
        '-PollSeconds', '1', '-StableSeconds', '2', '-DisableUiSaveFallback'
    )
    $latchedWatcher = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $latchedArgs) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $latchedStdout -RedirectStandardError $latchedStderr
    try {
        $latchedWatcherStatus = Join-Path $latchedSessionRoot 'recovery-watcher-status.json'
        $deadline = (Get-Date).AddSeconds(12)
        do {
            Start-Sleep -Milliseconds 100
            $observed = Read-TestJsonStatus $latchedWatcherStatus
        } while ((-not $observed -or $observed.status -ne 'ready-save-now') `
            -and (Get-Date) -lt $deadline)
        if (-not $observed -or $observed.status -ne 'ready-save-now') {
            throw 'Latched-readiness watcher never observed the strict READY boundary.'
        }
        $latchedBaseName = Get-Tpf2mpRecoverySaveBaseName `
            -Session $latchedSession -Peer player1 -BoundarySeq 12
        $latchedSave = Join-Path $latchedSaveRoot ($latchedBaseName + '.sav')
        [IO.File]::WriteAllBytes($latchedSave, [byte[]](7, 7, 7))
        [IO.File]::WriteAllText($latchedSave + '.lua', 'return { delayed = true }',
            [Text.UTF8Encoding]::new($false))
        $deadline = (Get-Date).AddSeconds(12)
        do {
            Start-Sleep -Milliseconds 100
            $observed = Read-TestJsonStatus $latchedWatcherStatus
        } while ((-not $observed -or $observed.status -ne 'waiting-for-save-stability') `
            -and (Get-Date) -lt $deadline)
        if (-not $observed -or $observed.status -ne 'waiting-for-save-stability') {
            throw 'Latched-readiness watcher never began save stability checking.'
        }
        $latchedStatus.anchorReady = $false
        [IO.File]::WriteAllText($latchedStatusPath,
            ($latchedStatus | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        $deadline = (Get-Date).AddSeconds(12)
        do {
            Start-Sleep -Milliseconds 100
            $observed = Read-TestJsonStatus $latchedWatcherStatus
        } while ((-not $observed -or $observed.status -ne 'filing-ordered-receipt') `
            -and (Get-Date) -lt $deadline)
        if (-not $observed -or $observed.status -ne 'filing-ordered-receipt' `
                -or -not $observed.requestId) {
            throw 'Strict readiness staleness discarded a latched prepared-boundary save.'
        }
        Write-Host 'PASS prepared boundary remains receipt-valid while native metadata finalizes'
    }
    finally {
        $latchedWatcher.Refresh()
        if (-not $latchedWatcher.HasExited) {
            Stop-Process -Id $latchedWatcher.Id -Force -ErrorAction SilentlyContinue
            $latchedWatcher.WaitForExit(10000) | Out-Null
        }
    }

    $incidentalBridge = Join-Path $TemporaryRoot 'incidental-ready-watcher-bridge'
    $incidentalStatusRoot = Join-Path $incidentalBridge 'companion_state'
    $incidentalSaveRoot = Join-Path $TemporaryRoot 'incidental-ready-watcher\1066780\local\save'
    New-Item -ItemType Directory -Force `
        -Path $incidentalStatusRoot, $incidentalSaveRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $incidentalStatusRoot 'companion_status.json'),
        ([ordered]@{
            schemaVersion = 1
            session = $incidentalSession
            peer = 'player1'
            anchorReady = $true
            anchorBoundarySeq = 9
            anchorCoreDigest = 'deadbeef'
            anchorConvergenceKey = '1234abcd'
            anchorPreparationStatus = 'idle'
            anchorPreparationCheckpointSeq = $null
            sessionFault = $null
        } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    & (Join-Path $ProjectRoot 'tools\watch_recovery_saves.ps1') `
        -Session $incidentalSession -Peer player1 -BridgePath $incidentalBridge `
        -SaveDirectory $incidentalSaveRoot -GameProcessId $PID `
        -GameExecutable $currentProcess.Path `
        -GameStartedAtUtc ($currentProcess.StartTime.ToUniversalTime().ToString('o')) `
        -BundleRoot $ProjectRoot -EvidenceCollectorPath $fakeCollector -OneShot
    if (-not $?) { throw 'Incidental READY watcher fixture returned failure.' }
    $incidentalWatcher = Get-Content -LiteralPath `
        (Join-Path $incidentalSessionRoot 'recovery-watcher-status.json') -Raw | ConvertFrom-Json
    if ($incidentalWatcher.uiSaveFallbackStatus -ne 'manual-save-available' `
        -or $incidentalWatcher.uiSaveFallbackAttempts -ne 0) {
        throw 'Incidental READY checkpoint armed the focus-stealing stock-UI fallback.'
    }
    Write-Host 'PASS incidental READY checkpoints never launch stock-UI save automation'

    $receiptPrefix = "tpf2mp_${automaticSession}_player1"
    $receiptOriginal = Join-Path $automaticSaveRoot ($receiptPrefix + '_original.sav')
    $receiptOverwritten = Join-Path $automaticSaveRoot ($receiptPrefix + '_retry.sav')
    [IO.File]::WriteAllBytes($receiptOriginal, [byte[]](9, 8, 7))
    [IO.File]::WriteAllText($receiptOriginal + '.lua', 'return { original = true }',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes($receiptOverwritten, [byte[]](3, 2, 1))
    [IO.File]::WriteAllText($receiptOverwritten + '.lua', 'return { retry = true }',
        [Text.UTF8Encoding]::new($false))
    $receipt = [pscustomobject]@{
        saveSha256 = (Get-FileHash -LiteralPath $receiptOriginal -Algorithm SHA256).Hash.ToLowerInvariant()
        metadataSha256 = (Get-FileHash -LiteralPath ($receiptOriginal + '.lua') `
            -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $bound = Get-Tpf2mpReceiptBoundSave -SaveDirectory $automaticSaveRoot `
        -ExpectedSavePrefix $receiptPrefix -AutomaticSaveName $automaticBaseName `
        -Receipt $receipt -PreferredSavePath $receiptOverwritten
    if ($bound.FullName -ne $receiptOriginal) {
        throw 'Duplicate accepted receipt selected later, unattested save bytes.'
    }
    Write-Host 'PASS duplicate receipt retries retain the originally attested native save'

    $uiBridge = Join-Path $TemporaryRoot 'stock-ui-save-bridge'
    $uiSaveRoot = Join-Path $TemporaryRoot 'stock-ui-save\1066780\local\save'
    $uiEvidence = Join-Path $TemporaryRoot 'stock-ui-save-evidence'
    $fakeInput = Join-Path $TemporaryRoot 'fake-game-input.ps1'
    $delayedWriter = Join-Path $TemporaryRoot 'delayed-metadata-writer.ps1'
    New-Item -ItemType Directory -Force -Path $uiBridge, $uiSaveRoot | Out-Null
    $fakeInputSource = @'
[CmdletBinding()]
param(
    [int]$GameProcessId, [string]$Action, [string]$Command,
    [int]$DelayMilliseconds, [string]$ResultPath,
    [int]$ClientX, [int]$ClientY, [int]$UiWidth, [int]$UiHeight,
    [switch]$PhysicalPixels
)
$entry = "$Action|$ClientX|$ClientY|$Command"
[IO.File]::AppendAllText($env:TPF2MP_UI_TEST_LOG, $entry + [Environment]::NewLine)
if ($Action -eq 'click-ui' -and $ClientX -eq 1443 -and $ClientY -eq 858) {
    [IO.File]::WriteAllBytes($env:TPF2MP_UI_TEST_SAVE, [byte[]](4, 5, 6))
    if ($env:TPF2MP_UI_TEST_DELAYED_WRITER) {
        Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                $env:TPF2MP_UI_TEST_DELAYED_WRITER, '-MetadataPath',
                ($env:TPF2MP_UI_TEST_SAVE + '.lua'), '-DelayMilliseconds', '11000') | Out-Null
    }
    else {
        [IO.File]::WriteAllText($env:TPF2MP_UI_TEST_SAVE + '.lua', 'return { ui = true }')
    }
}
if ($ResultPath) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ResultPath) | Out-Null
    @{ action = $Action; processId = $GameProcessId } | ConvertTo-Json |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
'@
    [IO.File]::WriteAllText($fakeInput, $fakeInputSource, [Text.UTF8Encoding]::new($false))
    $delayedWriterSource = @'
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$MetadataPath,
    [Parameter(Mandatory = $true)][int]$DelayMilliseconds)
Start-Sleep -Milliseconds $DelayMilliseconds
[IO.File]::WriteAllText($MetadataPath, 'return { ui = true }')
'@
    [IO.File]::WriteAllText(
        $delayedWriter, $delayedWriterSource, [Text.UTF8Encoding]::new($false))
    $uiBaseName = Get-Tpf2mpRecoverySaveBaseName `
        -Session $uiSession -Peer player2 -BoundarySeq 9
    $env:TPF2MP_UI_TEST_SAVE = Join-Path $uiSaveRoot ($uiBaseName + '.sav')
    $env:TPF2MP_UI_TEST_LOG = Join-Path $TemporaryRoot 'stock-ui-input.log'
    $env:TPF2MP_UI_TEST_DELAYED_WRITER = $delayedWriter
    $currentProcess = Get-Process -Id $PID
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $ProjectRoot 'tools\save_recovery_via_ui.ps1') `
        -Session $uiSession -Peer player2 -BoundarySeq 9 -BridgePath $uiBridge `
        -SaveDirectory $uiSaveRoot -SaveBaseName $uiBaseName -GameProcessId $PID `
        -GameExecutable $currentProcess.Path `
        -GameStartedAtUtc $currentProcess.StartTime.ToUniversalTime().ToString('o') `
        -EvidenceDirectory $uiEvidence -InputHelperPath $fakeInput `
        -PublishedUiWaitSeconds 0 -TimeoutSeconds 10 -SaveCompletionTimeoutSeconds 20
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $env:TPF2MP_UI_TEST_SAVE) `
        -or -not (Test-Path -LiteralPath ($env:TPF2MP_UI_TEST_SAVE + '.lua'))) {
        throw 'Stock-UI recovery fallback did not create the exact automatic save fixture.'
    }
    $uiResult = Get-Content -LiteralPath (Join-Path $uiEvidence 'stock-ui-save.json') `
        -Raw | ConvertFrom-Json
    $uiActions = Get-Content -LiteralPath $env:TPF2MP_UI_TEST_LOG
    if ($uiResult.status -ne 'completed' -or $uiResult.saveName -ne $uiBaseName `
        -or $uiResult.nativeActivityObserved -ne $true `
        -or [double]$uiResult.durationSeconds -lt 10 `
        -or @($uiActions | Where-Object { $_ -like 'replace-ui-text*' }).Count -ne 1) {
        throw 'Stock-UI recovery fallback lost its bounded name or input sequence.'
    }
    Remove-Item Env:\TPF2MP_UI_TEST_SAVE -ErrorAction SilentlyContinue
    Remove-Item Env:\TPF2MP_UI_TEST_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\TPF2MP_UI_TEST_DELAYED_WRITER -ErrorAction SilentlyContinue
    Write-Host 'PASS stock-UI fallback creates the bounded recovery save automatically'

    $logRoot = Join-Path $TemporaryRoot 'fault-watcher\logs'
    $companionLog = Join-Path $logRoot 'companion.stdout.log'
    New-Item -ItemType Directory -Force -Path $logRoot, $sessionRoot | Out-Null
    [IO.File]::WriteAllText($companionLog, "before-fault`nafter-fault`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sessionRoot 'session-state.json'),
        ([ordered]@{
            schemaVersion = 3
            session = $session
            peer = 'player1'
            bridgePath = $bridge
            stdout = $companionLog
            stderr = $null
            gamePid = $null
        } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    $fakeMods = Join-Path $TemporaryRoot 'fault-watcher\steam\userdata\1\1066780\local\mods'
    $installedMod = Join-Path $fakeMods 'tpf2_mp_1'
    New-Item -ItemType Directory -Force -Path $fakeMods | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tpf2_mp_1') -Destination $installedMod -Recurse
    $crashRoot = Join-Path (Split-Path -Parent $fakeMods) 'crash_dump'
    New-Item -ItemType Directory -Force -Path $crashRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $crashRoot 'stdout.txt'),
        "[TPF2MP] fixture first fault`n", [Text.UTF8Encoding]::new($false))

    $realEvidenceRoot = Join-Path $TemporaryRoot 'real-fault-evidence'
    & (Join-Path $ProjectRoot 'tools\collect_live_evidence.ps1') `
        -Session $session -Peer player1 -BridgePath $bridge `
        -OutputDirectory $realEvidenceRoot -BundleRoot $ProjectRoot `
        -GameExecutable $fakeGame -LocalModsPath $fakeMods
    if (-not $?) { throw 'Real evidence collector fixture returned failure.' }
    $realEvidence = Get-Content -LiteralPath (Join-Path $realEvidenceRoot 'evidence.json') -Raw | ConvertFrom-Json
    if ($realEvidence.schemaVersion -ne 3) { throw 'Evidence collector wrote an obsolete summary schema.' }
    $logArtifact = @($realEvidence.peers.player1.sessionArtifacts | Where-Object {
        $_.source -eq [IO.Path]::GetFullPath($companionLog)
    }) | Select-Object -First 1
    if (-not $logArtifact -or $logArtifact.tailTruncated -ne $false `
        -or (Get-Content -LiteralPath $logArtifact.copy -Raw) -ne "before-fault`nafter-fault`n") {
        throw 'Evidence collector did not preserve the exact bounded session log.'
    }
    if ($realEvidence.mod.matches -ne $true -or -not $realEvidence.gameLog.copy) {
        throw 'Evidence collector omitted its source/install or game-log proof.'
    }
    Write-Host 'PASS first-fault bundle contains exact session and game diagnostics'
}
finally {
    Remove-Item Env:\TPF2MP_UI_TEST_SAVE -ErrorAction SilentlyContinue
    Remove-Item Env:\TPF2MP_UI_TEST_LOG -ErrorAction SilentlyContinue
    foreach ($candidateRoot in @(
        $sessionRoot, $automaticSessionRoot, $latchedSessionRoot,
        $incidentalSessionRoot, $uiSessionRoot
    )) {
      if (Test-Path -LiteralPath $candidateRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($candidateRoot)
        if (-not $resolved.StartsWith($supportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a fault-watcher fixture outside the support root.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
      }
    }
}
