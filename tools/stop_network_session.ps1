[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [string]$ArchiveSavePath,
    [switch]$StopGame,
    [switch]$KeepCurrentWatcher
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$state = Read-Tpf2mpSessionState $safeSession $Peer
if (-not $state) { throw "No launcher state exists for session '$safeSession' and $Peer." }

if ($ArchiveSavePath) {
    & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $Peer `
        -SavePath $ArchiveSavePath -BundleRoot (Split-Path -Parent $PSScriptRoot)
    if ($LASTEXITCODE -ne 0) { throw "Recovery archive failed with exit code $LASTEXITCODE; session was not stopped." }
}

if ($state.PSObject.Properties['menuCoordinatorPid'] -and $state.menuCoordinatorPid) {
    $coordinatorPid = [int]$state.menuCoordinatorPid
    $coordinatorNative = Get-CimInstance Win32_Process -Filter "ProcessId = $coordinatorPid" -ErrorAction SilentlyContinue
    $sessionPattern = '(?:^|\s)-Session(?:\s+|=)' + [Regex]::Escape($safeSession) + '(?=\s|$)'
    $peerPattern = '(?:^|\s)-Peer(?:\s+|=)' + [Regex]::Escape($Peer) + '(?=\s|$)'
    if ($coordinatorNative -and $coordinatorNative.CommandLine -match 'main_menu_coordinator\.ps1' `
        -and $coordinatorNative.CommandLine -match $sessionPattern `
        -and $coordinatorNative.CommandLine -match $peerPattern) {
        Stop-Process -Id $coordinatorPid -Force -ErrorAction SilentlyContinue
    }
}

if (-not $KeepCurrentWatcher -and $state.PSObject.Properties['recoveryWatcherPid'] -and $state.recoveryWatcherPid) {
    $watcherPid = [int]$state.recoveryWatcherPid
    $watcherNative = Get-CimInstance Win32_Process -Filter "ProcessId = $watcherPid" -ErrorAction SilentlyContinue
    $sessionPattern = '(?:^|\s)-Session(?:\s+|=)' + [Regex]::Escape($safeSession) + '(?=\s|$)'
    $peerPattern = '(?:^|\s)-Peer(?:\s+|=)' + [Regex]::Escape($Peer) + '(?=\s|$)'
    if ($watcherNative -and $watcherNative.CommandLine -match 'watch_recovery_saves\.ps1' `
        -and $watcherNative.CommandLine -match $sessionPattern `
        -and $watcherNative.CommandLine -match $peerPattern) {
        Stop-Process -Id $watcherPid -Force -ErrorAction SilentlyContinue
    }
}

$companionPids = @()
# PyInstaller's one-file supervisor must be stopped before its extracted
# service child; the reverse order can briefly create a replacement child.
foreach ($property in @('companionLauncherPid', 'companionPid')) {
    if ($state.PSObject.Properties[$property] -and $state.$property) {
        $companionPids += [int]$state.$property
    }
}
$statusPath = if ($state.bridgePath) {
    Join-Path ([string]$state.bridgePath) 'companion_state\companion_status.json'
} else { $null }
if ($statusPath -and (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    try {
        $companionStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
        if ($companionStatus.session -eq $safeSession -and $companionStatus.peer -eq $Peer -and $companionStatus.pid) {
            $companionPids += [int]$companionStatus.pid
        }
    }
    catch { }
}
$expectedExecutable = if ($state.PSObject.Properties['companionExecutable']) {
    [string]$state.companionExecutable
} else { $null }
foreach ($companionPid in @($companionPids | Select-Object -Unique)) {
    $process = Get-Tpf2mpVerifiedCompanionProcess -ProcessId $companionPid `
        -Session $safeSession -Peer $Peer -ExecutablePath $expectedExecutable
    if ($process) {
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        $process.WaitForExit(5000) | Out-Null
    }
}
if ($expectedExecutable) {
    $expectedExecutable = Resolve-Tpf2mpFullPath $expectedExecutable
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        Start-Sleep -Milliseconds 100
        $matchingPids = @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath `
                    -and [string]::Equals(
                        (Resolve-Tpf2mpFullPath ([string]$_.ExecutablePath)),
                        $expectedExecutable,
                        [StringComparison]::OrdinalIgnoreCase
                    ) `
                    -and (Test-Tpf2mpCompanionCommandLine -CommandLine ([string]$_.CommandLine) `
                        -Session $safeSession -Peer $Peer)
                } |
                ForEach-Object { [int]$_.ProcessId }
        )
        if ($matchingPids.Count -eq 0) { break }
        foreach ($matchingPid in $matchingPids) {
            $matchingProcess = Get-Tpf2mpVerifiedCompanionProcess -ProcessId $matchingPid `
                -Session $safeSession -Peer $Peer -ExecutablePath $expectedExecutable
            if ($matchingProcess) { Stop-Process -Id $matchingProcess.Id -Force -ErrorAction Stop }
        }
    }
    Start-Sleep -Milliseconds 500
    $remaining = @(
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ExecutablePath `
                -and [string]::Equals(
                    (Resolve-Tpf2mpFullPath ([string]$_.ExecutablePath)),
                    $expectedExecutable,
                    [StringComparison]::OrdinalIgnoreCase
                ) `
                -and (Test-Tpf2mpCompanionCommandLine -CommandLine ([string]$_.CommandLine) `
                    -Session $safeSession -Peer $Peer)
            }
    )
    if ($remaining.Count -gt 0) {
        throw "Companion shutdown left $($remaining.Count) verified $safeSession/$Peer process(es) running."
    }
}
if ($StopGame -and $state.gamePid) {
    $game = Get-Process -Id ([int]$state.gamePid) -ErrorAction SilentlyContinue
    $expectedGamePath = if ($state.PSObject.Properties['gameExecutable']) {
        Resolve-Tpf2mpFullPath ([string]$state.gameExecutable)
    } else { $null }
    $pathMatches = $game -and $expectedGamePath -and $game.Path `
        -and [string]::Equals((Resolve-Tpf2mpFullPath $game.Path), $expectedGamePath, [StringComparison]::OrdinalIgnoreCase)
    $startMatches = $game -and $state.PSObject.Properties['gameStartedAtUtc'] -and $state.gameStartedAtUtc `
        -and [Math]::Abs(($game.StartTime.ToUniversalTime() - [DateTime]::Parse([string]$state.gameStartedAtUtc).ToUniversalTime()).TotalSeconds) -lt 2
    if ($game -and $game.ProcessName -eq 'TransportFever2' -and $pathMatches -and $startMatches -and -not $game.HasExited) {
        if ($game.CloseMainWindow()) {
            if (-not $game.WaitForExit(15000)) {
                Write-Warning "Game PID $($game.Id) did not close within 15 seconds; terminating only that verified session PID."
                Stop-Process -Id $game.Id -Force -ErrorAction Stop
                $game.WaitForExit(10000) | Out-Null
            }
        }
        else {
            Write-Warning "Game PID $($game.Id) rejected a normal close request; terminating only that verified session PID."
            Stop-Process -Id $game.Id -Force -ErrorAction Stop
        }
    }
    elseif ($game -and -not $game.HasExited) {
        Write-Warning "PID $($state.gamePid) no longer matches the recorded game path/start time; it was not touched."
    }
}

if ($state.PSObject.Properties['stagedStartingSaveManifest'] -and $state.stagedStartingSaveManifest `
    -and (Test-Path -LiteralPath ([string]$state.stagedStartingSaveManifest) -PathType Leaf)) {
    try {
        $stagedManifest = Get-Content -LiteralPath ([string]$state.stagedStartingSaveManifest) -Raw | ConvertFrom-Json
        Remove-Tpf2mpStagedStartingSave $stagedManifest
        $state.stagedStartingSave = $null
    }
    catch { Write-Warning "Staged starting-save cleanup requires attention: $($_.Exception.Message)" }
}

$launcherConfig = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_launcher') 'active.ini'
if (Test-Path -LiteralPath $launcherConfig -PathType Leaf) {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $launcherConfig) {
        if ($line -match '^([A-Za-z0-9_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    if ($values.sessionId -eq $safeSession -and $values.peerId -eq $Peer) {
        Remove-Item -LiteralPath $launcherConfig -Force
    }
}

$state.status = 'stopped'
$state | Add-Member -NotePropertyName stoppedAtUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
[void](Write-Tpf2mpSessionState $safeSession $Peer $state)
Write-Host "Stopped TPF2MP companion for $safeSession/$Peer."
