[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StartingSave,
    [Parameter(Mandatory)][string]$GameExecutable,
    [Parameter(Mandatory)][string]$LocalModsPath,
    [Parameter(Mandatory)][string]$Session,
    [string]$HostCredentials,
    [string]$JoinCredentials,
    [string]$ConfigDigest,
    [ValidateRange(1024,65534)][int]$Port=30842,
    [ValidateSet('skeleton','vanilla','empty')][string]$AgentMode='skeleton',
    [switch]$TownDevelopment
)
# Two real worlds; no physical input, console paste, GUI clicks or fullscreen.
# One harness-owned autosave guard covers both local processes. The production
# one-game-per-PC launcher keeps its existing guard ownership rules.
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
. (Join-Path $PSScriptRoot 'network_autosave_guard.ps1')
$bundle=Split-Path -Parent $PSScriptRoot
$native=Get-Tpf2mpNativePaths $bundle
$saveDirectory=Join-Path (Split-Path -Parent $LocalModsPath) 'save'
$run=Join-Path $bundle ('runtime\lobby-native-acceptance\'+(Assert-Tpf2mpSessionId $Session))
if (Test-Path -LiteralPath $run) { throw 'Acceptance evidence already exists.' }
if (@(Get-CimInstance Win32_Process -Filter "Name = 'TransportFever2.exe'").Count) { throw 'Close games before this disposable test.' }
[void](New-Item -ItemType Directory -Path $run)
$games=@(); $staged=@(); $startedPeers=@(); $guard=$null; $failure=$null; $agreed=$null; $received=$null
$lease=Join-Path $run 'autosave-guard.json'
try {
    if ($HostCredentials -or $JoinCredentials) {
        if (-not $HostCredentials -or -not $JoinCredentials -or $ConfigDigest -notmatch '^[0-9a-f]{64}$') {
            throw 'Relay acceptance needs both role credential files and the locked lobby digest.'
        }
        foreach ($role in @('Host','Join')) {
            $launch = @{Role=$role; Session=$Session; Port=$Port; GameExecutable=$GameExecutable
                LocalModsPath=$LocalModsPath; NoLaunchGame=$true; AgentMode=$AgentMode
                CompletionTimeoutSeconds=180; AllowInsecureLoopback=$true; LobbyConfigDigest=$ConfigDigest
                TownDevelopment=$TownDevelopment}
            if ($role -eq 'Host') { $launch.RelayCredentials=$HostCredentials; $launch.StartingSave=$StartingSave }
            else { $launch.RelayCredentials=$JoinCredentials }
            & (Join-Path $PSScriptRoot 'start_relay_network_session.ps1') @launch | Out-Host
            $startedPeers+= $(if ($role -eq 'Host') {'player1'} else {'player2'})
        }
        $received=Get-Content -LiteralPath (Join-Path (Get-Tpf2mpSessionRoot $Session 'player2') 'received-starting-save.json') -Raw | ConvertFrom-Json
    } else {
    & (Join-Path $PSScriptRoot 'start_network_session.ps1') -Role Host -Session $Session -Port $Port `
        -StartingSave $StartingSave -GameExecutable $GameExecutable -LocalModsPath $LocalModsPath `
        -NoLaunchGame -AgentMode $AgentMode -TownDevelopment:$TownDevelopment -CompletionTimeoutSeconds 180 | Out-Null
    $startedPeers+='player1'
    & (Join-Path $PSScriptRoot 'sync_starting_save.ps1') -Session $Session -Port $Port `
        -HostAddress '127.0.0.1' -LocalModsPath $LocalModsPath -SaveDirectory $saveDirectory
    $received=Get-Content -LiteralPath (Join-Path (Get-Tpf2mpSessionRoot $Session 'player2') 'received-starting-save.json') -Raw | ConvertFrom-Json
    & (Join-Path $PSScriptRoot 'start_network_session.ps1') -Role Join -Session $Session -Port $Port `
        -StartingSave $received.savePath -GameExecutable $GameExecutable -LocalModsPath $LocalModsPath `
        -NoLaunchGame -AgentMode $AgentMode -TownDevelopment:$TownDevelopment -CompletionTimeoutSeconds 180 | Out-Null
    $startedPeers+='player2'
    }
    [void](Install-Tpf2mpMenuBootstrap -BundleRoot $bundle -GameExecutable $GameExecutable)
    [void](Install-Tpf2mpRuntimeOverlay -BundleRoot $bundle -GameExecutable $GameExecutable)
    [void](Enable-Tpf2mpDirectLaunch -GameExecutable $GameExecutable)
    $guard=Enter-Tpf2mpNetworkAutosaveGuard -LeasePath $lease `
        -SettingsPath (Join-Path (Split-Path $saveDirectory) 'settings.lua') -Session $Session -Peer player1
    foreach ($peer in @('player1','player2')) {
        $state=Read-Tpf2mpSessionState $Session $peer
        $source=if ($peer -eq 'player1') { $StartingSave } else { [string]$received.savePath }
        $copy=New-Tpf2mpStagedStartingSave -SourceSave $source -SaveDirectory $saveDirectory -Session $Session -Peer $peer
        $staged+=,$copy
        $launch=Start-Tpf2mpDirectGame -GameExecutable $GameExecutable -Session $Session -Peer $peer `
            -BridgePath $state.bridgePath -SessionRoot (Get-Tpf2mpSessionRoot $Session $peer) `
            -StagedSaveBaseName $copy.baseName -MatchFingerprint $state.fingerprint `
            -AutomaticWorldLoad -StartNetwork -ManualNetwork -ContinueSavedMatch
        $games+=,$launch.process
        $nativeStatus=Add-Tpf2mpNativeHook -GameProcess $launch.process -NativePaths $native
        [void](Wait-Tpf2mpNativeWorld -GameProcess $launch.process -NativeStatusPath $nativeStatus `
            -RequireGameScriptObserver -RequireAuthorityGates -TimeoutSeconds 240)
        [IO.File]::WriteAllText((Join-Path $state.bridgePath 'launcher\manual-bootstrap-ready'),'ready')
        & (Join-Path $PSScriptRoot 'ensure_paused_network_wake.ps1') -GameProcessId $launch.process.Id `
            -GameExecutable $GameExecutable -GameStartedAtUtc $launch.process.StartTime.ToUniversalTime().ToString('o') `
            -BridgePath $state.bridgePath -Session $Session -Peer $peer -RequirePersistentMenuPump `
            -EvidenceDirectory (Join-Path $run $peer)
        Write-Host "native_acceptance_world_ready=$peer"
    }
    $deadline=[DateTime]::UtcNow.AddSeconds(90)
    do {
        $statuses=@(foreach ($peer in @('player1','player2')) {
            $state=Read-Tpf2mpSessionState $Session $peer
            Get-Content -LiteralPath (Join-Path $state.bridgePath 'companion_state\companion_status.json') -Raw | ConvertFrom-Json
        })
        # Only the host owns checkpoint consensus. The client publishes its
        # synchronized commit cursor, not a second lastAgreedCheckpointSeq.
        if ($statuses[0].sessionFault) { throw "Native acceptance session faulted: $($statuses[0].sessionFault)" }
        if ($statuses[0].connected -and $statuses[1].connected -and $statuses[1].synchronized -and
            [int64]$statuses[0].lastAgreedCheckpointSeq -gt 0 -and
            [int64]$statuses[1].lastCommitSeq -ge [int64]$statuses[0].lastAgreedCheckpointSeq) { $agreed=$statuses; break }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $agreed) { throw 'Both worlds loaded, but the initialization checkpoint did not converge.' }
} catch { $failure=$_.Exception.Message }
finally {
    $cleanupErrors=@()
    foreach ($process in $games) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(10000) }
            $process.Dispose()
        } catch { $cleanupErrors += $_.Exception.Message }
    }
    foreach ($peer in $startedPeers) {
        try {
            & (Join-Path $PSScriptRoot 'stop_network_session.ps1') -Session $Session -Peer $peer -StopReason native-lobby-acceptance | Out-Host
        } catch { $cleanupErrors += $_.Exception.Message }
    }
    foreach ($copy in $staged) {
        try { Remove-Tpf2mpStagedStartingSave $copy } catch { $cleanupErrors += $_.Exception.Message }
    }
    try {
        if ($guard) { [void](Restore-Tpf2mpNetworkAutosaveGuard -LeasePath $lease -Reason native-lobby-acceptance) }
        [void](Remove-Tpf2mpManagedRuntimeOverlay -BundleRoot $bundle -GameExecutable $GameExecutable -SkipIfGameRunning)
    } catch { $cleanupErrors += $_.Exception.Message }
    if ($cleanupErrors.Count) { $failure = "$failure Cleanup: $($cleanupErrors -join '; ')" }
    @{schemaVersion=1; passed=($null -eq $failure); error=$failure; status=$agreed; received=$received} |
        ConvertTo-Json -Depth 25 | Set-Content -LiteralPath (Join-Path $run 'report.json') -Encoding UTF8
}
if ($failure) { throw $failure }
Write-Host "PASS native transfer + direct load + two-world checkpoint: $run"
