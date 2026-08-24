[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Host', 'Join')][string]$Role,
    [Parameter(Mandatory = $true)][string]$Session,
    [string]$HostAddress = '127.0.0.1',
    [string]$BindAddress = '0.0.0.0',
    [ValidateRange(1, 65535)][int]$Port = 29742,
    [string]$StartingSave,
    [string]$RestorePlan,
    [string]$ManifestPath,
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$SaveDirectory,
    [ValidateRange(5, 600)][int]$CompletionTimeoutSeconds = 45,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [switch]$TownDevelopment,
    [switch]$NoLaunchGame
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

$agentModeExplicit = $PSBoundParameters.ContainsKey('AgentMode')
$townDevelopmentExplicit = $PSBoundParameters.ContainsKey('TownDevelopment')
$townDevelopmentEnabled = $TownDevelopment.IsPresent
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$restorePlanPath = $null
$restorePlanData = $null
if ($RestorePlan) {
    if (-not $StartingSave) { throw 'RestorePlan requires this peer''s attested StartingSave.' }
    $restorePlanPath = Resolve-Tpf2mpFullPath $RestorePlan
    if (-not (Test-Path -LiteralPath $restorePlanPath -PathType Leaf)) {
        throw "Restore plan is missing: $restorePlanPath"
    }
    $restorePlanData = Get-Content -LiteralPath $restorePlanPath -Raw | ConvertFrom-Json
    [void](Assert-Tpf2mpCurrentRestorePlan $restorePlanData)
    if ([string]$restorePlanData.resumeSession -ne $Session) {
        throw 'Session must equal the restore plan resumeSession.'
    }
}
$safeSession = Assert-Tpf2mpSessionId $Session
$peer = if ($Role -eq 'Host') { 'player1' } else { 'player2' }
if ($Role -eq 'Join' -and ($HostAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$')) {
    throw 'Host address contains unsupported characters.'
}
if ($BindAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$') { throw 'Bind address contains unsupported characters.' }

$existingState = Read-Tpf2mpSessionState $safeSession $peer
if ($existingState) {
    $existingPids = @()
    foreach ($property in @('companionPid', 'companionLauncherPid')) {
        if ($existingState.PSObject.Properties[$property] -and $existingState.$property) {
            $existingPids += [int]$existingState.$property
        }
    }
    $existingStatusPath = if ($existingState.bridgePath) {
        Join-Path ([string]$existingState.bridgePath) 'companion_state\companion_status.json'
    } else { $null }
    if ($existingStatusPath -and (Test-Path -LiteralPath $existingStatusPath -PathType Leaf)) {
        try {
            $existingStatus = Get-Content -LiteralPath $existingStatusPath -Raw | ConvertFrom-Json
            if ($existingStatus.session -eq $safeSession -and $existingStatus.peer -eq $peer -and $existingStatus.pid) {
                $existingPids += [int]$existingStatus.pid
            }
        }
        catch { }
    }
    $existingExecutable = if ($existingState.PSObject.Properties['companionExecutable']) {
        [string]$existingState.companionExecutable
    } else { $null }
    foreach ($existingPid in @($existingPids | Select-Object -Unique)) {
        $existingProcess = Get-Tpf2mpVerifiedCompanionProcess -ProcessId $existingPid `
            -Session $safeSession -Peer $peer -ExecutablePath $existingExecutable
        if ($existingProcess) {
            throw "Session '$safeSession' already has a running $peer companion (PID $($existingProcess.Id))."
        }
    }
}
if ($Role -eq 'Host') {
    Assert-Tpf2mpHostPortAvailable -Port $Port -Session $safeSession
    if ($StartingSave -and -not $restorePlanData) {
        if ($Port -ge 65535) {
            throw 'Gameplay port 65535 leaves no adjacent port for automatic starting-save sync.'
        }
        Assert-Tpf2mpHostPortAvailable -Port ($Port + 1) -Session $safeSession
    }
}
else {
    Assert-Tpf2mpLoopbackJoinTarget -HostAddress $HostAddress -Port $Port -Session $safeSession
}

$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered; pass -GameExecutable.' }
$gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash.ToLowerInvariant()
if ($gameHash -ne $script:Tpf2ExeHash) {
    throw "Network mode supports only Transport Fever 2 Build 35924; installed SHA-256 is $gameHash"
}
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$resolvedSaveDirectory = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory -LocalModsPath $mods
$installedMod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
if (-not (Test-Path -LiteralPath $installedMod -PathType Container)) {
    throw "TPF2MP is not installed at $installedMod"
}
$installedModLua = Join-Path $installedMod 'mod.lua'
if (-not (Test-Path -LiteralPath $installedModLua -PathType Leaf) `
    -or (Get-Content -LiteralPath $installedModLua -Raw) -notmatch 'tpf2mp_launcher/active\.ini') {
    throw 'The installed mod predates launcher-managed sessions. Reinstall TPF2MP 0.17 before hosting or joining.'
}
$companionSource = Join-Path $bundle 'companion\tpf2mp'
if (-not (Test-Path -LiteralPath $companionSource -PathType Container)) {
    throw "Companion fingerprint source is missing: $companionSource"
}
$native = Get-Tpf2mpNativePaths $bundle
$companion = Get-Tpf2mpCompanionCommand $bundle

$sessionRoot = Get-Tpf2mpSessionRoot $safeSession $peer
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
$bridge = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$safeSession\$peer")
foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit',
        'content\industry')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bridge $folder) | Out-Null
}
$staleTraffic = @(Get-ChildItem -LiteralPath (Join-Path $bridge 'game_outbox') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count `
    + @(Get-ChildItem -LiteralPath (Join-Path $bridge 'game_inbox') -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
if ($staleTraffic -gt 0) {
    throw "Session '$safeSession' already has bridge traffic. Use a new session name to prevent replaying stale commands."
}

$startingSaveOriginal = $StartingSave
$pinnedSave = $null
$stagedSave = $null
$startingCompanyPlayerIds = ''
$gameProcess = $null
$nativeStatusPath = $null
$runtimeOverlay = $null
$menuBootstrap = $null
$directLaunch = $null
if ($StartingSave) {
    $startingSaveOriginal = Resolve-Tpf2mpFullPath $StartingSave
    if ($restorePlanData) {
        $verifyArguments = @($companion.Prefix) + @(
            'verify-restore-save', $restorePlanPath, '--peer', $peer,
            '--save', $startingSaveOriginal
        )
        & $companion.FilePath @verifyArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Restore save verification failed with exit code $LASTEXITCODE"
        }
        $resolvedProfile = Resolve-Tpf2mpRestoreMatchProfile -RestorePlan $restorePlanData `
            -AgentMode $AgentMode -TownDevelopment $townDevelopmentEnabled `
            -AgentModeExplicit $agentModeExplicit -TownDevelopmentExplicit $townDevelopmentExplicit
        $AgentMode = $resolvedProfile.agentMode
        $townDevelopmentEnabled = $resolvedProfile.townDevelopment
        if ($resolvedProfile.legacyUnbound) {
            Write-Warning 'Legacy restore plan v2 does not bind agent/town policy; retaining explicit launcher policy.'
        }
    }
    $pinnedSave = Copy-Tpf2mpPinnedStartingSave $startingSaveOriginal (Join-Path $sessionRoot 'starting-save')
    $StartingSave = $pinnedSave.savePath
    $startingCompanyPlayerIds = Read-Tpf2mpStartingCompanyPlayerIds $StartingSave
    if ($restorePlanData -and -not $startingCompanyPlayerIds) {
        throw 'The attested restore save does not expose exactly two native company-player identities.'
    }
    $pinnedSave | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath (Join-Path $sessionRoot 'starting-save-manifest.json') -Encoding UTF8
}
else {
    Write-Warning 'No starting save was pinned. Both peers must still enter structurally identical worlds; an identical shared save is strongly recommended.'
}
if (-not $ManifestPath) { $ManifestPath = Join-Path $sessionRoot 'match-manifest.json' }
$manifest = Resolve-Tpf2mpFullPath $ManifestPath
$matchContentProfile = Write-Tpf2mpMatchContentProfile `
    -Path (Join-Path $sessionRoot 'match-content-profile.json') `
    -AgentMode $AgentMode -TownDevelopment $townDevelopmentEnabled
$fingerprintArgs = @(
    'fingerprint', '--game-exe', $game, '--mod-dir', $installedMod,
    '--companion-dir', $companionSource, '--extra', $native.Root,
    '--extra', $matchContentProfile, '--output', $manifest
)
if ($StartingSave -and -not $restorePlanData) { $fingerprintArgs += @('--save', $StartingSave) }
if ($restorePlanPath) { $fingerprintArgs += @('--extra', $restorePlanPath) }
$invokeFingerprint = @($companion.Prefix) + $fingerprintArgs
& $companion.FilePath @invokeFingerprint
if ($LASTEXITCODE -ne 0) { throw "Match fingerprint generation failed with exit code $LASTEXITCODE" }
$fingerprint = [string](Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json).fingerprint

$launcherConfig = Write-Tpf2mpLauncherConfig -Session $safeSession -Peer $peer -BridgePath $bridge `
    -AgentMode $AgentMode -TownDevelopment $townDevelopmentEnabled
$stdout = Join-Path $sessionRoot 'companion.stdout.log'
$stderr = Join-Path $sessionRoot 'companion.stderr.log'
$saveSyncPort = if ($Role -eq 'Host' -and $pinnedSave -and -not $restorePlanData) {
    $Port + 1
} else { $null }
$saveSyncStatus = if ($saveSyncPort) {
    Join-Path $sessionRoot 'save-sync-status.json'
} else { $null }
$companionArgs = if ($Role -eq 'Host') {
    @(
        'host', '--session', $safeSession, '--peer', $peer, '--bind', $BindAddress,
        '--port', $Port, '--bridge', $bridge,
        '--required-peer', 'player1', '--required-peer', 'player2',
        '--completion-timeout', $CompletionTimeoutSeconds, '--manifest', $manifest
    )
}
else {
    @('client', $HostAddress, '--session', $safeSession, '--peer', $peer,
        '--port', $Port, '--bridge', $bridge, '--manifest', $manifest)
}
if ($Role -eq 'Host' -and $restorePlanPath) {
    $companionArgs += @('--restore-plan', $restorePlanPath)
}
if ($Role -eq 'Host' -and $saveSyncPort) {
    $companionArgs += @(
        '--share-save', $pinnedSave.savePath,
        '--save-sync-port', $saveSyncPort,
        '--save-sync-status', $saveSyncStatus
    )
}
$companionCommandLine = ConvertTo-Tpf2mpCommandLine (@($companion.Prefix) + $companionArgs)
$companionProcess = Start-Process -FilePath $companion.FilePath -ArgumentList $companionCommandLine `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr

$state = [ordered]@{
    schemaVersion = 3
    session = $safeSession
    role = $Role.ToLowerInvariant()
    peer = $peer
    hostAddress = if ($Role -eq 'Host') { $BindAddress } else { $HostAddress }
    port = $Port
    fingerprint = $fingerprint
    manifestPath = $manifest
    matchContentProfile = $matchContentProfile
    agentMode = $AgentMode
    townDevelopment = $townDevelopmentEnabled
    restorePlan = $restorePlanPath
    restoreBoundarySeq = if ($restorePlanData) { $restorePlanData.boundarySeq } else { $null }
    startingCompanyPlayerIds = $startingCompanyPlayerIds
    startingSave = $startingSaveOriginal
    pinnedStartingSave = if ($pinnedSave) { $pinnedSave.savePath } else { $null }
    pinnedStartingSaveManifest = if ($pinnedSave) { Join-Path $sessionRoot 'starting-save-manifest.json' } else { $null }
    saveSyncPort = $saveSyncPort
    saveSyncStatusPath = $saveSyncStatus
    stagedStartingSave = $null
    stagedStartingSaveManifest = $null
    bridgePath = $bridge
    launcherConfig = $launcherConfig
    companionPid = $companionProcess.Id
    companionLauncherPid = $companionProcess.Id
    companionExecutable = (Resolve-Tpf2mpFullPath $companion.FilePath)
    gamePid = $null
    gameExecutable = $game
    gameStartedAtUtc = $null
    launcherClosedGame = $false
    launcherCleanupReason = $null
    menuCoordinatorPid = $null
    menuCoordinatorStdout = $null
    menuCoordinatorStderr = $null
    recoveryWatcherPid = $null
    recoveryWatcherStatusPath = $null
    recoveryWatcherStdout = $null
    recoveryWatcherStderr = $null
    nativeStatusPath = $null
    nativeSaveLoadReceipt = $null
    pausedNetworkWake = $null
    runtimeOverlay = $null
    menuBootstrap = $null
    directLaunchMarker = $null
    initialRecoveryArchive = $null
    status = 'starting-companion'
    error = $null
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    stdout = $stdout
    stderr = $stderr
}
[void](Write-Tpf2mpSessionState $safeSession $peer $state)

try {
    if ($pinnedSave -and -not $restorePlanData) {
        & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') -Session $safeSession -Peer $peer `
            -SavePath $pinnedSave.savePath -BundleRoot $bundle
        if ($LASTEXITCODE -ne 0) { throw "Initial recovery archive failed with exit code $LASTEXITCODE" }
        $state.initialRecoveryArchive = Join-Path $sessionRoot 'latest-recovery-archive.json'
        [void](Write-Tpf2mpSessionState $safeSession $peer $state)
    }
    $deadline = (Get-Date).AddSeconds(12)
    $companionStatus = $null
    do {
        $companionProcess.Refresh()
        if ($companionProcess.HasExited) {
            $errorText = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
            throw "Companion exited during startup (code $($companionProcess.ExitCode)): $errorText"
        }
        $statusPath = Join-Path $bridge 'companion_state\companion_status.json'
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            try { $companionStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json } catch { }
        }
        $ready = $Role -eq 'Host' -and $companionStatus -and $companionStatus.listening -eq $true
        if ($Role -eq 'Join') { $ready = $companionStatus -and $companionStatus.status -in @('connecting', 'connected') }
        if ($ready) { break }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)

    if (-not $ready) { throw 'Companion did not publish a ready status within 12 seconds.' }
    if ($companionStatus.session -ne $safeSession -or $companionStatus.peer -ne $peer `
        -or $companionStatus.matchFingerprint -ne $fingerprint) {
        throw 'Companion readiness status does not match the requested session, peer, and fingerprint.'
    }
    if ($saveSyncPort) {
        $saveSyncReady = $null
        if (Test-Path -LiteralPath $saveSyncStatus -PathType Leaf) {
            try { $saveSyncReady = Get-Content -LiteralPath $saveSyncStatus -Raw | ConvertFrom-Json }
            catch { }
        }
        if (-not $saveSyncReady -or $saveSyncReady.listening -ne $true `
                -or [string]$saveSyncReady.session -ne $safeSession `
                -or [int]$saveSyncReady.port -ne [int]$saveSyncPort `
                -or [string]$saveSyncReady.bundleId -notmatch '^[0-9a-f]{64}$') {
            throw 'Host companion did not publish a valid automatic starting-save sync listener.'
        }
        Write-Host "Automatic save sync ready on TCP $saveSyncPort (bundle $($saveSyncReady.bundleId.Substring(0, 12)))."
    }
    if (-not $companionStatus.PSObject.Properties['pid'] -or -not $companionStatus.pid) {
        throw 'Companion readiness status did not include its service PID.'
    }
    $serviceProcess = Get-Tpf2mpVerifiedCompanionProcess -ProcessId ([int]$companionStatus.pid) `
        -Session $safeSession -Peer $peer -ExecutablePath $state.companionExecutable
    if (-not $serviceProcess) { throw 'Companion readiness status named an invalid service process.' }
    $state.companionPid = $serviceProcess.Id

    $state.status = if ($Role -eq 'Host') { 'hosting' } else { 'joining' }
    if (-not $NoLaunchGame) {
        $menuBootstrap = Install-Tpf2mpMenuBootstrap -BundleRoot $bundle -GameExecutable $game
        $runtimeOverlay = Install-Tpf2mpRuntimeOverlay -BundleRoot $bundle -GameExecutable $game
        $directLaunch = Enable-Tpf2mpDirectLaunch -GameExecutable $game
        $state.menuBootstrap = $menuBootstrap
        $state.runtimeOverlay = $runtimeOverlay
        $state.directLaunchMarker = $directLaunch

        if ($StartingSave) {
            $stagedSave = New-Tpf2mpStagedStartingSave -SourceSave $StartingSave `
                -SaveDirectory $resolvedSaveDirectory -Session $safeSession -Peer $peer
            $stagedManifestPath = Join-Path $sessionRoot 'staged-save-manifest.json'
            $stagedSave | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stagedManifestPath -Encoding UTF8
            $state.stagedStartingSave = $stagedSave.savePath
            $state.stagedStartingSaveManifest = $stagedManifestPath
        }

        $launch = Start-Tpf2mpDirectGame -GameExecutable $game -Session $safeSession -Peer $peer `
            -BridgePath $bridge -SessionRoot $sessionRoot `
            -StagedSaveBaseName $(if ($stagedSave) { $stagedSave.baseName } else { $null }) `
            -StartingCompanyPlayerIds $startingCompanyPlayerIds `
            -RestorePlan $restorePlanData -RequireMenuEntry -StartNetwork `
            -ManualNetwork:([bool]$stagedSave)
        $gameProcess = $launch.process
        $state.gamePid = $gameProcess.Id
        $state.gameStartedAtUtc = $gameProcess.StartTime.ToUniversalTime().ToString('o')
        $state.gameStdout = $launch.stdout
        $state.gameStderr = $launch.stderr
        $state.status = 'injecting-native-hook'
        [void](Write-Tpf2mpSessionState $safeSession $peer $state)

        $nativeStatusPath = Add-Tpf2mpNativeHook -GameProcess $gameProcess -NativePaths $native
        $state.nativeStatusPath = $nativeStatusPath
        if ($stagedSave) {
            $menu = Wait-Tpf2mpMainMenuEntry -GameProcess $gameProcess -BridgePath $bridge `
                -Session $safeSession -Peer $peer -TimeoutSeconds 120
            $state.status = 'awaiting-multiplayer-selection'
            [void](Write-Tpf2mpSessionState $safeSession $peer $state)
            $loadReceipt = Invoke-Tpf2mpPinnedSaveLoad -GameProcess $gameProcess -BridgePath $bridge `
                -Session $safeSession -Peer $peer -ExpectedSaveBaseName $stagedSave.baseName `
                -EvidenceDirectory (Join-Path $sessionRoot 'native-save-load') -TimeoutSeconds 600
            $state.nativeSaveLoadReceipt = Join-Path $sessionRoot 'native-save-load\native-save-load.json'
            $state.status = 'waiting-for-network-world'
            [void](Write-Tpf2mpSessionState $safeSession $peer $state)
            [void](Wait-Tpf2mpNativeWorld -GameProcess $gameProcess -NativeStatusPath $nativeStatusPath `
                -RequireGameScriptObserver -RequireAuthorityGates)
            [IO.File]::WriteAllText((Join-Path $bridge 'launcher\manual-bootstrap-ready'),
                'ready', [Text.UTF8Encoding]::new($false))
            $wakeEvidence = Join-Path $sessionRoot 'paused-network-wake'
            & (Join-Path $PSScriptRoot 'ensure_paused_network_wake.ps1') `
                -GameProcessId $gameProcess.Id -GameExecutable $game `
                -GameStartedAtUtc $state.gameStartedAtUtc -BridgePath $bridge `
                -Session $safeSession -Peer $peer `
                -EvidenceDirectory $wakeEvidence `
                -RequirePersistentMenuPump `
                -RequireRestoreValidated:($null -ne $restorePlanData)
            $state.pausedNetworkWake = Join-Path $wakeEvidence 'paused-network-wake.json'
            Remove-Tpf2mpStagedStartingSave $stagedSave
            $state.stagedStartingSave = $null
            $state.status = if ($Role -eq 'Host') { 'hosting-world-ready' } else { 'joined-world-ready' }
        }
        else {
            $menu = Wait-Tpf2mpMainMenuEntry -GameProcess $gameProcess -BridgePath $bridge `
                -Session $safeSession -Peer $peer -TimeoutSeconds 120
            $coordinatorStdout = Join-Path $sessionRoot 'main-menu-coordinator.stdout.log'
            $coordinatorStderr = Join-Path $sessionRoot 'main-menu-coordinator.stderr.log'
            $coordinatorArguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'main_menu_coordinator.ps1'),
                '-GameProcessId', $gameProcess.Id,
                '-GameExecutable', $game,
                '-GameStartedAtUtc', $state.gameStartedAtUtc,
                '-BridgePath', $bridge,
                '-Session', $safeSession,
                '-Peer', $peer,
                '-EvidenceDirectory', (Join-Path $sessionRoot 'main-menu-entry')
            )
            $coordinator = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
                -ArgumentList (ConvertTo-Tpf2mpCommandLine $coordinatorArguments) -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $coordinatorStdout -RedirectStandardError $coordinatorStderr
            $state.menuCoordinatorPid = $coordinator.Id
            $state.menuCoordinatorStdout = $coordinatorStdout
            $state.menuCoordinatorStderr = $coordinatorStderr
            $state.status = 'awaiting-world-selection'
        }

        # Both peers must independently attest their own native save.  The
        # client watcher hands the file to its authenticated companion; it
        # never writes into the game's positive local-sequence namespace.
        $recoveryWatcherStdout = Join-Path $sessionRoot 'recovery-watcher.stdout.log'
        $recoveryWatcherStderr = Join-Path $sessionRoot 'recovery-watcher.stderr.log'
        $recoveryWatcherArguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'watch_recovery_saves.ps1'),
            '-Session', $safeSession,
            '-Peer', $peer,
            '-BridgePath', $bridge,
            '-SaveDirectory', $resolvedSaveDirectory,
            '-GameProcessId', $gameProcess.Id,
            '-GameExecutable', $game,
            '-GameStartedAtUtc', $state.gameStartedAtUtc,
            '-MatchContentProfilePath', $matchContentProfile,
            '-BundleRoot', $bundle
        )
        $recoveryWatcher = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList (ConvertTo-Tpf2mpCommandLine $recoveryWatcherArguments) -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $recoveryWatcherStdout -RedirectStandardError $recoveryWatcherStderr
        Start-Sleep -Milliseconds 300
        $recoveryWatcher.Refresh()
        if ($recoveryWatcher.HasExited) {
            $watcherError = if (Test-Path -LiteralPath $recoveryWatcherStderr -PathType Leaf) {
                Get-Content -LiteralPath $recoveryWatcherStderr -Raw
            } else { '' }
            throw "Automatic recovery watcher exited during startup: $watcherError"
        }
        $state.recoveryWatcherPid = $recoveryWatcher.Id
        $state.recoveryWatcherStatusPath = Join-Path $sessionRoot 'recovery-watcher-status.json'
        $state.recoveryWatcherStdout = $recoveryWatcherStdout
        $state.recoveryWatcherStderr = $recoveryWatcherStderr
    }
    [void](Write-Tpf2mpSessionState $safeSession $peer $state)
    Write-Host "TPF2MP $Role session ready: $safeSession ($peer), fingerprint $fingerprint"
    Write-Host "Bridge: $bridge"
    if ($StartingSave -and -not $NoLaunchGame) {
        if ($restorePlanData) {
            Write-Host 'The peer-specific attested save was loaded; gameplay remains paused until the restore checkpoint converges.'
        }
        else {
            Write-Host 'The pinned starting save was selected and loaded automatically; native authority gates are active.'
        }
    }
    else {
        Write-Host 'Select a TPF2MP-enabled world; the launcher has already selected Network mode and this peer/session.'
    }
    $state | ConvertTo-Json -Depth 12
}
catch {
    $failure = $_
    $state.status = 'failed'
    $state.error = $failure.Exception.Message
    if ($gameProcess) {
        try {
            $gameProcess.Refresh()
            if (-not $gameProcess.HasExited) {
                Write-Warning (
                    "Launch failed before the authority boundary was ready; " `
                    + "the launcher is closing partial game PID $($gameProcess.Id) so it cannot be mistaken for a playable session."
                )
                Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
                [void]$gameProcess.WaitForExit(10000)
                $state.launcherClosedGame = $true
                $state.launcherCleanupReason = 'failed-before-world-ready'
            }
        }
        catch { }
    }
    if ($stagedSave) {
        try { Remove-Tpf2mpStagedStartingSave $stagedSave }
        catch { Write-Warning "Staged starting-save cleanup requires attention: $($_.Exception.Message)" }
    }
    $cleanupPids = @($state.companionLauncherPid, $state.companionPid)
    if ($companionStatus -and $companionStatus.session -eq $safeSession `
        -and $companionStatus.peer -eq $peer -and $companionStatus.pid) {
        $cleanupPids += [int]$companionStatus.pid
    }
    foreach ($cleanupPid in @($cleanupPids | Where-Object { $_ } | Select-Object -Unique)) {
        $cleanupProcess = Get-Tpf2mpVerifiedCompanionProcess -ProcessId ([int]$cleanupPid) `
            -Session $safeSession -Peer $peer -ExecutablePath $state.companionExecutable
        if ($cleanupProcess) {
            Stop-Process -Id $cleanupProcess.Id -Force -ErrorAction SilentlyContinue
            [void]$cleanupProcess.WaitForExit(5000)
        }
    }
    [void](Write-Tpf2mpSessionState $safeSession $peer $state)
    throw $failure
}
