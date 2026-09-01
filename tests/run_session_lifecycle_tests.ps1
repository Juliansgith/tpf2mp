[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\session_lifecycle.ps1')

$caseRoot = Join-Path $TemporaryRoot 'session-lifecycle'
$localAppData = Join-Path $caseRoot 'local-app-data'
New-Item -ItemType Directory -Force -Path $caseRoot, $localAppData | Out-Null
$previousLocalAppData = $env:LOCALAPPDATA
$env:LOCALAPPDATA = $localAppData
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()

function Start-TestProcess([int]$Milliseconds) {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine @(
            '-NoProfile', '-Command', "Start-Sleep -Milliseconds $Milliseconds"
        )) -PassThru -WindowStyle Hidden
    $processes.Add($process)
    return $process
}

$fakeStop = Join-Path $caseRoot 'fake-stop.ps1'
[IO.File]::WriteAllText($fakeStop, @'
param(
    [string]$Session,
    [string]$Peer,
    [switch]$StopGame,
    [string]$StopReason
)
$receipt = [pscustomobject]@{
    session = $Session
    peer = $Peer
    stopGame = [bool]$StopGame
    stopReason = $StopReason
}
[IO.File]::WriteAllText($env:TPF2MP_LIFECYCLE_TEST_RECEIPT,
    ($receipt | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

function Start-LifecycleWatcher {
    param(
        [Diagnostics.Process]$Game,
        [Diagnostics.Process]$Owner,
        [string]$Session,
        [string]$StatusPath,
        [string]$ReceiptPath
    )
    $env:TPF2MP_LIFECYCLE_TEST_RECEIPT = $ReceiptPath
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        (Join-Path $ProjectRoot 'tools\watch_network_session_lifecycle.ps1'),
        '-Session', $Session, '-Peer', 'player1',
        '-GameProcessId', $Game.Id,
        '-GameExecutable', $Game.Path,
        '-GameStartedAtUtc', $Game.StartTime.ToUniversalTime().ToString('o'),
        '-BundleRoot', $ProjectRoot, '-StatusPath', $StatusPath,
        '-StopScriptPath', $fakeStop
    )
    if ($Owner) {
        $arguments += @(
            '-OwnerLauncherProcessId', $Owner.Id,
            '-OwnerLauncherExecutable', $Owner.Path,
            '-OwnerLauncherStartedAtUtc', $Owner.StartTime.ToUniversalTime().ToString('o')
        )
    }
    $watcher = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -PassThru -WindowStyle Hidden
    $processes.Add($watcher)
    return $watcher
}

try {
    $game = Start-TestProcess 30000
    $owner = Start-TestProcess 700
    $status = Join-Path $caseRoot 'launcher-close-status.json'
    $receipt = Join-Path $caseRoot 'launcher-close-receipt.json'
    $watcher = Start-LifecycleWatcher -Game $game -Owner $owner `
        -Session 'lifecycle-launcher-close' -StatusPath $status -ReceiptPath $receipt
    if (-not $watcher.WaitForExit(10000) -or $watcher.ExitCode -ne 0) {
        throw 'Lifecycle watcher did not clean up after its owning launcher exited.'
    }
    $result = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if ($result.stopGame -ne $true -or $result.stopReason -cne 'launcher-process-ended') {
        throw 'Launcher exit did not request a complete game/session teardown.'
    }
    $lifecycle = Get-Content -LiteralPath $status -Raw | ConvertFrom-Json
    if ($lifecycle.status -cne 'cleaned' -or $lifecycle.reason -cne 'launcher-process-ended') {
        throw 'Launcher-exit cleanup did not publish its terminal lifecycle receipt.'
    }

    $game2 = Start-TestProcess 700
    $owner2 = Start-TestProcess 30000
    $status2 = Join-Path $caseRoot 'game-close-status.json'
    $receipt2 = Join-Path $caseRoot 'game-close-receipt.json'
    $watcher2 = Start-LifecycleWatcher -Game $game2 -Owner $owner2 `
        -Session 'lifecycle-game-close' -StatusPath $status2 -ReceiptPath $receipt2
    if (-not $watcher2.WaitForExit(10000) -or $watcher2.ExitCode -ne 0) {
        throw 'Lifecycle watcher did not clean up after the exact game exited.'
    }
    $result2 = Get-Content -LiteralPath $receipt2 -Raw | ConvertFrom-Json
    if ($result2.stopGame -ne $false -or $result2.stopReason -cne 'game-process-ended') {
        throw 'Game exit did not request detached companion/relay teardown.'
    }

    $faultedSession = 'lifecycle-faulted-game-close'
    [void](Write-Tpf2mpSessionState $faultedSession player1 ([ordered]@{
        schemaVersion = 3
        status = 'failed'
    }))
    $game3 = Start-TestProcess 700
    $owner3 = Start-TestProcess 30000
    $status3 = Join-Path $caseRoot 'faulted-game-close-status.json'
    $receipt3 = Join-Path $caseRoot 'faulted-game-close-receipt.json'
    $watcher3 = Start-LifecycleWatcher -Game $game3 -Owner $owner3 `
        -Session $faultedSession -StatusPath $status3 -ReceiptPath $receipt3
    if (-not $watcher3.WaitForExit(10000) -or $watcher3.ExitCode -ne 0) {
        throw 'Lifecycle watcher abandoned a faulted session before its game exited.'
    }
    $result3 = Get-Content -LiteralPath $receipt3 -Raw | ConvertFrom-Json
    if ($result3.stopGame -ne $false -or $result3.stopReason -cne 'game-process-ended') {
        throw 'Faulted-session game exit did not request detached helper teardown.'
    }

    $settings = Join-Path $caseRoot 'settings.lua'
    $leasePath = Join-Path $caseRoot 'lease.json'
    [IO.File]::WriteAllText($settings, @'
config = {
  game = {
    autosaveIntervalMinutes = 10,
  },
}
'@, [Text.UTF8Encoding]::new($false))
    $oldGame = Start-TestProcess 30000
    [void](Enter-Tpf2mpNetworkAutosaveGuard -LeasePath $leasePath -SettingsPath $settings `
        -Session 'old-managed-session' -Peer player2)
    [void](Bind-Tpf2mpNetworkAutosaveGuard -LeasePath $leasePath `
        -GameProcess $oldGame -GameExecutable $oldGame.Path)
    [void](Write-Tpf2mpSessionState 'old-managed-session' player2 `
        ([ordered]@{ schemaVersion = 3; status = 'joined-world-ready' }))
    $replacementReceipt = Join-Path $caseRoot 'replacement-receipt.json'
    $env:TPF2MP_LIFECYCLE_TEST_RECEIPT = $replacementReceipt
    Invoke-Tpf2mpReplaceManagedSessionConflicts -Session 'new-managed-session' -Peer player2 `
        -AutosaveGuardLeasePath $leasePath -StopScriptPath $fakeStop
    $replacement = Get-Content -LiteralPath $replacementReceipt -Raw | ConvertFrom-Json
    if ($replacement.session -cne 'old-managed-session' -or $replacement.peer -cne 'player2' `
            -or $replacement.stopGame -ne $true `
            -or $replacement.stopReason -cne 'replaced-by-new-managed-session/player2') {
        throw 'A new launcher did not reclaim the exact prior managed autosave-guard owner.'
    }
    Stop-Process -Id $oldGame.Id -Force -ErrorAction SilentlyContinue
    [void]$oldGame.WaitForExit(5000)
    [void](Restore-Tpf2mpNetworkAutosaveGuard -LeasePath $leasePath -Reason 'test-cleanup')

    $managedSession = 'managed-stop-test'
    $companion = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine @(
            '-NoProfile', '-Command', 'Start-Sleep -Seconds 30',
            '--session', $managedSession, '--peer', 'player1'
        )) -PassThru -WindowStyle Hidden
    $processes.Add($companion)
    [void](Write-Tpf2mpSessionState $managedSession player1 ([ordered]@{
        schemaVersion = 3
        session = $managedSession
        role = 'host'
        peer = 'player1'
        status = 'hosting-world-ready'
        companionPid = $companion.Id
        companionLauncherPid = $companion.Id
        companionExecutable = $companion.Path
        bridgePath = Join-Path $caseRoot 'managed-stop-bridge'
        gamePid = $null
    }))
    & (Join-Path $ProjectRoot 'tools\stop_network_session.ps1') `
        -Session $managedSession -Peer player1 -StopReason 'lifecycle-test'
    $companion.Refresh()
    $stoppedState = Read-Tpf2mpSessionState $managedSession player1
    if (-not $companion.HasExited -or $stoppedState.status -cne 'stopped' `
            -or $stoppedState.stopReason -cne 'lifecycle-test') {
        throw 'Verified session teardown left its detached companion or state active.'
    }

    $overlayCleanup = Get-Content -LiteralPath `
        (Join-Path $ProjectRoot 'tools\cleanup_localhost_runtime_overlay.ps1') -Raw
    $requiredOverlayPairs = @(
        @('multiplayer_menu_bootstrap.lua', 'tpf2mp_multiplayer_menu_bootstrap.lua'),
        @('localhost_bootstrap.lua', 'tpf2mp_localhost_bootstrap.lua')
    )
    foreach ($pair in $requiredOverlayPairs) {
        $sourcePattern = [regex]::Escape("Source = Join-Path `$PSScriptRoot '$($pair[0])'")
        $targetPattern = [regex]::Escape("Target = Join-Path `$resourceRoot 'scripts\$($pair[1])'")
        if ($overlayCleanup -notmatch "(?s)$sourcePattern.{0,300}$targetPattern") {
            throw "Guarded cleanup does not inventory disposable overlay $($pair[1])."
        }
    }
}
finally {
    foreach ($process in $processes) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                [void]$process.WaitForExit(5000)
            }
        }
        catch { }
    }
    $env:TPF2MP_LIFECYCLE_TEST_RECEIPT = $null
    $env:LOCALAPPDATA = $previousLocalAppData
}

Write-Host 'PASS launcher/game exit teardown, overlay inventory, and prior managed-session replacement'
