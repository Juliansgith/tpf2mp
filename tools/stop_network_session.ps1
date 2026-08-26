[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [string]$ArchiveSavePath,
    [switch]$StopGame,
    [switch]$KeepCurrentWatcher,
    [string]$StopReason = 'manual-stop'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
. (Join-Path $PSScriptRoot 'session_lifecycle.ps1')
. (Join-Path $PSScriptRoot 'relay_diagnostic_process.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$state = Read-Tpf2mpSessionState $safeSession $Peer
if (-not $state) { throw "No launcher state exists for session '$safeSession' and $Peer." }

function Stop-Tpf2mpVerifiedProcess {
    param([Parameter(Mandatory = $true)][Diagnostics.Process]$Process)
    $processId = $Process.Id
    try {
        Stop-Process -Id $processId -Force -ErrorAction Stop
    }
    catch {
        # Exiting after identity verification is a successful teardown, not a
        # cleanup fault. Preserve every other error while refusing PID reuse.
        if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { throw }
        return
    }
    try { [void]$Process.WaitForExit(5000) } catch { }
}

if ($ArchiveSavePath) {
    & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $Peer `
        -SavePath $ArchiveSavePath -BundleRoot (Split-Path -Parent $PSScriptRoot)
    if ($LASTEXITCODE -ne 0) { throw "Recovery archive failed with exit code $LASTEXITCODE; session was not stopped." }
}

if ($state.PSObject.Properties['lifecycleSupervisorPid'] -and $state.lifecycleSupervisorPid) {
    $supervisorPid = [int]$state.lifecycleSupervisorPid
    if ($supervisorPid -ne $PID) {
        $supervisorNative = Get-CimInstance Win32_Process `
            -Filter "ProcessId = $supervisorPid" -ErrorAction SilentlyContinue
        $sessionPattern = '(?:^|\s)-Session(?:\s+|=)' + [Regex]::Escape($safeSession) + '(?=\s|$)'
        $peerPattern = '(?:^|\s)-Peer(?:\s+|=)' + [Regex]::Escape($Peer) + '(?=\s|$)'
        if ($supervisorNative `
                -and [string]$supervisorNative.CommandLine -match 'watch_network_session_lifecycle\.ps1' `
                -and [string]$supervisorNative.CommandLine -match $sessionPattern `
                -and [string]$supervisorNative.CommandLine -match $peerPattern) {
            Stop-Process -Id $supervisorPid -Force -ErrorAction SilentlyContinue
        }
        elseif ($supervisorNative) {
            Write-Warning "Recorded lifecycle PID $supervisorPid no longer matches this session; it was not touched."
        }
    }
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

function Stop-Tpf2mpRecordedRelayProcess {
    param(
        [string]$Property,
        [string]$CommandName
    )
    if (-not $state.PSObject.Properties[$Property] -or -not $state.$Property) { return }
    $processId = [int]$state.$Property
    $native = Get-CimInstance Win32_Process -Filter "ProcessId = $processId" -ErrorAction SilentlyContinue
    if (-not $native) { return }
    $expectedExecutable = if ($state.PSObject.Properties['companionExecutable']) {
        Resolve-Tpf2mpFullPath ([string]$state.companionExecutable)
    } else { $null }
    $actualExecutable = if ($native.ExecutablePath) {
        Resolve-Tpf2mpFullPath ([string]$native.ExecutablePath)
    } else { $null }
    $credentialPath = if ($state.PSObject.Properties['relayCredentials']) {
        [Regex]::Escape([string]$state.relayCredentials)
    } else { $null }
    $commandMatches = [string]$native.CommandLine -match ([Regex]::Escape($CommandName)) `
        -and ($null -eq $credentialPath `
            -or [string]$native.CommandLine -match $credentialPath)
    if ($expectedExecutable -and $actualExecutable -and $commandMatches `
            -and [string]::Equals(
                $expectedExecutable, $actualExecutable,
                [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Process -Id $processId -Force -ErrorAction Stop
    }
    else {
        Write-Warning "Recorded relay PID $processId no longer matches its executable/command; it was not touched."
    }
}

if ($state.PSObject.Properties['transportMode'] -and $state.transportMode -eq 'secure-relay') {
    $relayCompanion = if ($state.PSObject.Properties['companionExecutable'] `
            -and $state.companionExecutable) {
        [pscustomobject]@{ FilePath = [string]$state.companionExecutable; Prefix = @() }
    } else { $null }
    $relayCredentials = if ($state.PSObject.Properties['relayCredentials']) {
        [string]$state.relayCredentials
    } else { $null }
    if ($relayCompanion -and $relayCredentials) {
        Stop-Tpf2mpVerifiedRelayProcesses -Companion $relayCompanion `
            -CredentialsPath $relayCredentials `
            -CommandName relay-diagnostics
    }
    else {
        Stop-Tpf2mpRecordedRelayProcess 'relayDiagnosticsPid' 'relay-diagnostics'
        Stop-Tpf2mpRecordedRelayProcess 'relayDiagnosticsLauncherPid' 'relay-diagnostics'
    }
    if ($state.role -eq 'host' -and $state.PSObject.Properties['relayCredentials'] `
            -and $state.relayCredentials `
            -and (Test-Path -LiteralPath ([string]$state.relayCredentials) -PathType Leaf)) {
        try {
            $companion = Get-Tpf2mpCompanionCommand (Split-Path -Parent $PSScriptRoot)
            $previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
            try {
                if ($state.PSObject.Properties['relayAllowInsecureLoopback'] `
                        -and $state.relayAllowInsecureLoopback) {
                    $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1'
                }
                & $companion.FilePath @($companion.Prefix + @(
                    'relay-session-close', '--credentials', ([string]$state.relayCredentials)
                ))
                if ($LASTEXITCODE -ne 0) { throw "relay close exited $LASTEXITCODE" }
            }
            finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
        }
        catch {
            Write-Warning "Relay session could not be closed immediately and will expire automatically: $($_.Exception.Message)"
        }
    }
    if ($relayCompanion -and $relayCredentials) {
        Stop-Tpf2mpVerifiedRelayProcesses -Companion $relayCompanion `
            -CredentialsPath $relayCredentials `
            -CommandName relay-tunnel
    }
    else {
        Stop-Tpf2mpRecordedRelayProcess 'relayTunnelPid' 'relay-tunnel'
        Stop-Tpf2mpRecordedRelayProcess 'relayTunnelLauncherPid' 'relay-tunnel'
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
        Stop-Tpf2mpVerifiedProcess $process
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
            if ($matchingProcess) { Stop-Tpf2mpVerifiedProcess $matchingProcess }
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
            [void]$game.WaitForExit(10000)
        }
    }
    elseif ($game -and -not $game.HasExited) {
        Write-Warning "PID $($state.gamePid) no longer matches the recorded game path/start time; it was not touched."
    }
}

$gameStillRunning = $false
if ($state.gamePid -and $state.gameExecutable -and $state.gameStartedAtUtc) {
    $gameStillRunning = Test-Tpf2mpExactProcessIdentity -ProcessId ([int]$state.gamePid) `
        -ExecutablePath ([string]$state.gameExecutable) `
        -StartedAtUtc ([string]$state.gameStartedAtUtc)
}
if (-not $gameStillRunning) {
    if ($state.PSObject.Properties['autosaveGuardWatcherPid'] -and $state.autosaveGuardWatcherPid) {
        $guardWatcherPid = [int]$state.autosaveGuardWatcherPid
        $guardWatcher = Get-Process -Id $guardWatcherPid -ErrorAction SilentlyContinue
        if ($guardWatcher -and -not $guardWatcher.HasExited) {
            [void]$guardWatcher.WaitForExit(5000)
            $guardWatcher.Refresh()
        }
        if ($guardWatcher -and -not $guardWatcher.HasExited) {
            $guardNative = Get-CimInstance Win32_Process `
                -Filter "ProcessId = $guardWatcherPid" -ErrorAction SilentlyContinue
            $leasePattern = if ($state.autosaveGuardLeasePath) {
                [Regex]::Escape([string]$state.autosaveGuardLeasePath)
            } else { $null }
            if ($guardNative -and [string]$guardNative.CommandLine -match 'watch_network_autosave_guard\.ps1' `
                    -and ($null -eq $leasePattern `
                        -or [string]$guardNative.CommandLine -match $leasePattern)) {
                Stop-Process -Id $guardWatcherPid -Force -ErrorAction SilentlyContinue
            }
        }
    }
    if ($state.PSObject.Properties['autosaveGuardLeasePath'] -and $state.autosaveGuardLeasePath `
            -and (Test-Path -LiteralPath ([string]$state.autosaveGuardLeasePath) -PathType Leaf)) {
        try {
            $lease = Read-Tpf2mpAutosaveGuardLease ([string]$state.autosaveGuardLeasePath)
            if ($lease -and [string]$lease.session -eq $safeSession `
                    -and [string]$lease.peer -eq $Peer) {
                [void](Restore-Tpf2mpNetworkAutosaveGuard `
                    -LeasePath ([string]$state.autosaveGuardLeasePath) -Reason $StopReason)
            }
        }
        catch { Write-Warning "Autosave guard restore requires attention: $($_.Exception.Message)" }
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
$state | Add-Member -NotePropertyName stopReason -NotePropertyValue $StopReason -Force
[void](Write-Tpf2mpSessionState $safeSession $Peer $state)
Write-Host "Stopped TPF2MP session $safeSession/$Peer ($StopReason)."
