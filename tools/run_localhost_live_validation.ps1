[CmdletBinding()]
param(
    [string]$Session,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [ValidateRange(60, 3600)][int]$SoakTicks = 300,
    [ValidateRange(30, 3600)][int]$ClockRunTicks = 30,
    [ValidateRange(120, 3600)][int]$TimeoutSeconds = 900,
    [ValidateRange(30, 600)][int]$ConsensusTimeoutSeconds = 180,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$StartingSave,
    [string]$RestorePlan,
    [string]$Player1StartingSave,
    [string]$Player2StartingSave,
    [switch]$RequireVehicleSyncRound,
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild,
    [switch]$InteractiveAfterValidation,
    [switch]$ManualOnly,
    [ValidateRange(5, 240)][int]$InteractiveMinutes = 120,
    [switch]$OperationalCaptureLab,
    [ValidateRange(30, 3600)][int]$OperationalSampleTicks = 120,
    [ValidateRange(5000000, 1000000000)][long]$OperationalStartingCash = 50000000,
    [ValidateRange(0, 3600)][int]$UnattendedOperationalSeconds = 0,
    [switch]$NativeFreshWorld,
    [switch]$TownDevelopment,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [switch]$KeepGamesOpen
)

$ErrorActionPreference = 'Stop'
if ($ManualOnly -and $OperationalCaptureLab) {
    throw 'ManualOnly and OperationalCaptureLab are mutually exclusive.'
}
if ($NativeFreshWorld -and -not $OperationalCaptureLab) {
    throw 'NativeFreshWorld is an observer-only capture mode; use it with OperationalCaptureLab.'
}
if ($NativeFreshWorld -and ($StartingSave -or $Player1StartingSave -or $Player2StartingSave -or $RestorePlan)) {
    throw 'NativeFreshWorld cannot be combined with a starting save or restore plan.'
}
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
$restorePlanPath = $null
$restorePlanData = $null
if ($RestorePlan) {
    if (-not $ManualOnly) { throw 'RestorePlan requires ManualOnly so no validator mutates the restored match.' }
    if ($StartingSave -or -not $Player1StartingSave -or -not $Player2StartingSave) {
        throw 'RestorePlan requires Player1StartingSave and Player2StartingSave, and cannot use StartingSave.'
    }
    $restorePlanPath = Resolve-Tpf2mpFullPath $RestorePlan
    if (-not (Test-Path -LiteralPath $restorePlanPath -PathType Leaf)) {
        throw "Restore plan is missing: $restorePlanPath"
    }
    $restorePlanData = Get-Content -LiteralPath $restorePlanPath -Raw | ConvertFrom-Json
    if (-not $restorePlanData.resumeSession) { throw 'Restore plan has no resumeSession.' }
    if ($Session -and $Session -ne [string]$restorePlanData.resumeSession) {
        throw 'Session must equal the restore plan resumeSession.'
    }
    $Session = [string]$restorePlanData.resumeSession
}
elseif ($Player1StartingSave -or $Player2StartingSave) {
    throw 'Peer-specific starting saves require RestorePlan.'
}
if (-not $Session) { $Session = 'localhost-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
if ($Session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Unsafe session name: $Session" }

$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered.' }
$game = Resolve-Tpf2mpFullPath $game
$gameRoot = Split-Path -Parent $game
$gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash.ToLowerInvariant()
if ($gameHash -ne $script:Tpf2ExeHash) {
    throw "Localhost native validation requires exact Build 35924; installed SHA-256 is $gameHash"
}
if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Transport Fever 2 is already running; refusing to mix a disposable localhost lab with an interactive game.'
}

$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$userData = Split-Path -Parent $mods
$settingsPath = Join-Path $userData 'settings.lua'
$saveDirectory = [IO.Path]::GetFullPath((Join-Path $userData 'save'))
if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) { throw "Settings file is missing: $settingsPath" }
$runRoot = Join-Path $projectRoot ("runtime\localhost-live\$Session")
$bridgeBase = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$Session"))
$tempBridgeRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_bridge'))
$bridgePrefix = $tempBridgeRoot.TrimEnd('\') + '\'
if (-not $bridgeBase.StartsWith($bridgePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing bridge reset outside $tempBridgeRoot"
}
$peer1Bridge = Join-Path $bridgeBase 'player1'
$peer2Bridge = Join-Path $bridgeBase 'player2'
$settingsBackup = Join-Path $runRoot 'settings-original.lua'
$manifestPath = Join-Path $runRoot 'match-manifest.json'
$matchContentProfilePath = Join-Path $runRoot 'match-content-profile.json'
$statusPath = Join-Path $runRoot 'run-status.json'
$usingNativeSaveLoader = -not [string]::IsNullOrWhiteSpace($StartingSave) -or $null -ne $restorePlanData
$usingNativeMenuBootstrap = $usingNativeSaveLoader -or $NativeFreshWorld
$bootstrapFileName = if ($usingNativeMenuBootstrap) {
    'tpf2mp_multiplayer_menu_bootstrap.lua'
} else { 'tpf2mp_localhost_bootstrap.lua' }
$bootstrapSource = Join-Path $PSScriptRoot $(if ($usingNativeMenuBootstrap) {
    'multiplayer_menu_bootstrap.lua'
} else { 'localhost_bootstrap.lua' })
$bootstrapTarget = Join-Path $gameRoot "res\scripts\$bootstrapFileName"
$bootstrapRelative = "res/scripts/$bootstrapFileName"
$baseResourceRoot = [IO.Path]::GetFullPath((Join-Path $gameRoot 'res'))
$injectedGameScript = [IO.Path]::GetFullPath((Join-Path $baseResourceRoot 'config\game_script\tpf2_mp.lua'))
$injectedLibrary = [IO.Path]::GetFullPath((Join-Path $baseResourceRoot 'scripts\tpf2_mp'))
$steamAppIdPath = Join-Path $gameRoot 'steam_appid.txt'
$sharedLog = Join-Path $userData 'crash_dump\stdout.txt'
$nativeStatusRoot = Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native'
$hostProcess = $null
$clientProcess = $null
$peer1Game = $null
$peer2Game = $null
$peer1RecoveryWatcher = $null
$peer2RecoveryWatcher = $null
$createdSteamMarker = $false
$preexistingSteamMarker = Test-Path -LiteralPath $steamAppIdPath -PathType Leaf
$preexistingSteamMarkerContent = if ($preexistingSteamMarker) { Get-Content -LiteralPath $steamAppIdPath -Raw } else { $null }
$injectedBootstrap = $false
$gameScriptInjected = $false
$libraryInjected = $false
$settingsRestored = $false
$failure = $null
$peerResults = @{}
$finalPassed = $false
$collectInteractiveEvidence = $false
$interactiveEvidenceCollected = $false
$interactiveEvidenceError = $null
$operationalAnalysisPath = $null
$operationalAnalysisError = $null
$startingSaveCopy = $null
$startingSaveManifest = $null
$stagedStartingSave = $null
$peerStartingSaveCopies = @{}
$peerStartingSaveManifests = @{}
$peerStagedStartingSaves = @{}
$peerStartingCompanyPlayerIds = @{}
$stagedStartingFiles = @()
$startingCompanyPlayerIds = ''

function Set-LocalhostValidationSettings([string]$Path) {
    $content = [IO.File]::ReadAllText($Path)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $start = [regex]::Match($content, '(?m)^(?<indent>[ \t]*)activeMods[ \t]*=[ \t]*\{[ \t]*\r?$')
    if (-not $start.Success) { throw 'Could not locate activeMods in settings.lua' }
    $indent = $start.Groups['indent'].Value
    $tail = $content.Substring($start.Index + $start.Length)
    $close = [regex]::Match($tail, '(?m)^' + [regex]::Escape($indent) + '\},[ \t]*\r?$')
    if (-not $close.Success) { throw 'Could not locate the end of activeMods in settings.lua' }
    $end = $start.Index + $start.Length + $close.Index + $close.Length
    $replacement = @(
        "${indent}activeMods = {"
        "${indent}`t{ `"!tpf2_mp`", 1, },"
        "${indent}},"
    ) -join $newline
    $updated = $content.Substring(0, $start.Index) + $replacement + $content.Substring($end)
    $updated = [regex]::Replace(
        $updated,
        '(?m)^(?<prefix>[ \t]*autosaveIntervalMinutes[ \t]*=[ \t]*)\d+(?<suffix>[ \t]*,)',
        '${prefix}120${suffix}'
    )
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Resolve-CompanionCommand {
    $packaged = Join-Path $projectRoot 'bin\tpf2mp.exe'
    if (Test-Path -LiteralPath $packaged -PathType Leaf) {
        return [pscustomobject]@{ File = $packaged; Prefix = @(); IsPython = $false }
    }
    $pythonCandidates = @(
        'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe',
        'python.exe',
        'py.exe'
    )
    foreach ($candidate in $pythonCandidates) {
        try {
            $resolved = (Get-Command $candidate -ErrorAction Stop).Source
            return [pscustomobject]@{ File = $resolved; Prefix = @('-m', 'tpf2mp'); IsPython = $true }
        }
        catch { }
    }
    throw 'No packaged companion or Python 3.10+ runtime was found.'
}

$companionCommand = Resolve-CompanionCommand
function Invoke-Companion([string[]]$Arguments) {
    $oldPythonPath = $env:PYTHONPATH
    if ($companionCommand.IsPython) { $env:PYTHONPATH = Join-Path $projectRoot 'companion' }
    try {
        & $companionCommand.File @($companionCommand.Prefix + $Arguments)
        if ($LASTEXITCODE -ne 0) { throw "Companion command failed with exit code $LASTEXITCODE" }
    }
    finally { $env:PYTHONPATH = $oldPythonPath }
}

function Start-Companion([string]$Role, [string[]]$Arguments, [string]$LogBase) {
    $oldPythonPath = $env:PYTHONPATH
    if ($companionCommand.IsPython) { $env:PYTHONPATH = Join-Path $projectRoot 'companion' }
    try {
        return Start-Process -FilePath $companionCommand.File `
            -ArgumentList @($companionCommand.Prefix + $Arguments) `
            -WorkingDirectory $projectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput ($LogBase + '.stdout.txt') `
            -RedirectStandardError ($LogBase + '.stderr.txt')
    }
    finally { $env:PYTHONPATH = $oldPythonPath }
}

function Start-GamePeer([string]$Peer, [string]$BridgePath) {
    $env:SteamAppId = [string]$script:Tpf2AppId
    $env:SteamGameId = [string]$script:Tpf2AppId
    $env:TPF2MP_PEER_ID = $Peer
    $env:TPF2MP_SESSION_ID = $Session
    $env:TPF2MP_BRIDGE_DIR = $BridgePath
    $env:TPF2MP_START_NETWORK = if ($OperationalCaptureLab) { '0' } else { '1' }
    $env:TPF2MP_NETWORK_AUTOTEST = if ($OperationalCaptureLab -or $ManualOnly) { '0' } else { '1' }
    $env:TPF2MP_MANUAL_NETWORK = if ($ManualOnly) { '1' } else { '0' }
    $env:TPF2MP_NETWORK_SOAK_TICKS = [string]$SoakTicks
    $env:TPF2MP_NETWORK_CLOCK_RUN_TICKS = [string]$ClockRunTicks
    $env:TPF2MP_OPERATIONAL_CAPTURE = if ($OperationalCaptureLab) { '1' } else { '0' }
    $env:TPF2MP_OPERATIONAL_SAMPLE_TICKS = [string]$OperationalSampleTicks
    $env:TPF2MP_STARTING_CASH = if ($OperationalCaptureLab -or $ManualOnly) {
        [string]$OperationalStartingCash
    } else { '5000000' }
    $peerStagedSave = if ($script:peerStagedStartingSaves.ContainsKey($Peer)) {
        [string]$script:peerStagedStartingSaves[$Peer]
    } else { [string]$script:stagedStartingSave }
    $env:TPF2MP_STAGED_SAVE_NAME = if ($peerStagedSave) {
        [IO.Path]::GetFileNameWithoutExtension($peerStagedSave)
    } else { '' }
    $peerCompanyPlayerIds = if ($script:peerStartingCompanyPlayerIds.ContainsKey($Peer)) {
        [string]$script:peerStartingCompanyPlayerIds[$Peer]
    } else { [string]$script:startingCompanyPlayerIds }
    $env:TPF2MP_STARTING_COMPANY_PLAYER_IDS = $peerCompanyPlayerIds
    $env:TPF2MP_TOWN_DEVELOPMENT = if ($TownDevelopment) { '1' } else { '0' }
    $env:TPF2MP_AGENT_MODE = $AgentMode
    $env:TPF2MP_RESTORE_RESUME = if ($script:restorePlanData) { '1' } else { '0' }
    $env:TPF2MP_RESTORE_FROM_SESSION = if ($script:restorePlanData) {
        [string]$script:restorePlanData.session
    } else { '' }
    $env:TPF2MP_RESTORE_BOUNDARY = if ($script:restorePlanData) {
        [string]$script:restorePlanData.boundarySeq
    } else { '' }
    $env:TPF2MP_RESTORE_CORE_DIGEST = if ($script:restorePlanData) {
        [string]$script:restorePlanData.coreDigest
    } else { '' }
    $env:TPF2MP_RESTORE_CONVERGENCE_KEY = if ($script:restorePlanData) {
        [string]$script:restorePlanData.convergenceKey
    } else { '' }
    $env:TPF2MP_RESTORE_PLAN_CHECKSUM = if ($script:restorePlanData) {
        [string]$script:restorePlanData.checksum
    } else { '' }
    # Build 35924's Vulkan/UI startup can enter its Internal error path when
    # created minimized, while a hidden window has no targetable main handle.
    # Use an ordinary window; the exact-PID helper may foreground it briefly.
    return Start-Process -FilePath $game -WorkingDirectory $gameRoot -WindowStyle Normal -PassThru `
        -ArgumentList @('--script', $bootstrapRelative)
}

function Start-RecoveryWatcher([string]$Peer, [string]$BridgePath, [Diagnostics.Process]$GameProcess) {
    $stdout = Join-Path $runRoot "$Peer-recovery-watcher.stdout.log"
    $stderr = Join-Path $runRoot "$Peer-recovery-watcher.stderr.log"
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'watch_recovery_saves.ps1'),
        '-Session', $Session, '-Peer', $Peer, '-BridgePath', $BridgePath,
        '-SaveDirectory', $saveDirectory, '-GameProcessId', [string]$GameProcess.Id,
        '-GameExecutable', $game,
        '-GameStartedAtUtc', $GameProcess.StartTime.ToUniversalTime().ToString('o'),
        '-BundleRoot', $projectRoot
    )
    $watcher = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Start-Sleep -Milliseconds 300
    $watcher.Refresh()
    if ($watcher.HasExited) {
        $errorText = if (Test-Path -LiteralPath $stderr -PathType Leaf) {
            Get-Content -LiteralPath $stderr -Raw
        } else { '' }
        throw "$Peer recovery watcher exited during startup: $errorText"
    }
    return $watcher
}

function Wait-GameWindow([Diagnostics.Process]$GameProcess, [int]$WaitSeconds = 120) {
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
            -Context 'before its menu window opened')
        if ($GameProcess.MainWindowHandle -ne 0) { return }
        Start-Sleep -Milliseconds 250
    }
    throw "Timed out waiting for game PID $($GameProcess.Id) to create its menu window."
}

function Wait-MenuBootstrap([Diagnostics.Process]$GameProcess, [string]$Peer, [string]$BridgePath) {
    Wait-GameWindow $GameProcess
    if ($NativeFreshWorld) {
        [void](Wait-Tpf2mpMainMenuEntry -GameProcess $GameProcess -BridgePath $BridgePath `
            -Session $Session -Peer $Peer -TimeoutSeconds 120)
        Write-Host "$Peer game PID $($GameProcess.Id) reached the stock Free Game menu."
        return
    }
    elseif ($usingNativeSaveLoader) {
        [void](Wait-Tpf2mpMenuStage -GameProcess $GameProcess -BridgePath $BridgePath `
            -Session $Session -Peer $Peer -Stage @('ready-to-click-load-game') -TimeoutSeconds 120)
        Write-Host "$Peer game PID $($GameProcess.Id) reached its native pinned-save loader."
        return
    }
    $statusPath = Join-Path $BridgePath 'launcher\game_bootstrap.json'
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
            -Context "before $Peer menu bootstrap became ready")
        if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
            try {
                $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                if ($status.peer -eq $Peer -and $status.session -eq $Session `
                    -and $status.stage -eq 'waiting-for-launcher') {
                    Write-Host "$Peer game PID $($GameProcess.Id) reached its isolated menu bootstrap."
                    return
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "$Peer game PID $($GameProcess.Id) did not publish its menu bootstrap status."
}

function Invoke-GameInput(
    [Diagnostics.Process]$GameProcess,
    [string]$Action,
    [string]$SavePath,
    [string]$Command,
    [switch]$SkipConsoleClick,
    [switch]$PhysicalPixels
) {
    $helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
    $result = Join-Path $runRoot ("ui-{0}-{1}-{2}.json" -f $GameProcess.Id, $Action, [DateTime]::UtcNow.Ticks)
    $helperStdout = $result + '.stdout.txt'
    $helperStderr = $result + '.stderr.txt'
    $childArguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
        '-GameProcessId', [string]$GameProcess.Id, '-Action', $Action,
        '-DelayMilliseconds', '350', '-ResultPath', $result
    )
    if ($SavePath) {
        if ($SavePath.Contains('"')) { throw 'Save path contains an unsupported quote.' }
        # Start-Process flattens ArgumentList before launching Windows
        # PowerShell; preserve a path under "Program Files (x86)" explicitly.
        $childArguments += @('-SavePath', ('"' + $SavePath + '"'))
    }
    if ($Command) {
        if ($Command.Contains('"')) { throw 'Console command contains an unsupported quote.' }
        # Launcher-issued bootstrap commands deliberately contain no spaces,
        # so Windows PowerShell's ArgumentList flattening cannot split them.
        $childArguments += @('-Command', $Command)
    }
    if ($SkipConsoleClick) { $childArguments += '-SkipConsoleClick' }
    if ($PhysicalPixels) { $childArguments += '-PhysicalPixels' }
    $child = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $helperStdout -RedirectStandardError $helperStderr `
        -ArgumentList $childArguments
    if (-not $child.WaitForExit(30000)) {
        Stop-Process -Id $child.Id -Force -ErrorAction SilentlyContinue
        throw "The $Action input helper timed out for game PID $($GameProcess.Id)."
    }
    # A second parameterless wait is required for redirected streams and for
    # Windows PowerShell 5.1 to populate Process.ExitCode reliably.
    $child.WaitForExit()
    $child.Refresh()
    $childExitCode = $child.ExitCode
    $helperResultWritten = Test-Path -LiteralPath $result -PathType Leaf
    if (($null -ne $childExitCode -and $childExitCode -ne 0) -or -not $helperResultWritten) {
        $helperError = if (Test-Path -LiteralPath $helperStderr -PathType Leaf) {
            $rawHelperError = Get-Content -LiteralPath $helperStderr -Raw
            if ($null -eq $rawHelperError) { '' } else { $rawHelperError.Trim() }
        }
        else { '' }
        throw "The $Action input helper exited $childExitCode for game PID $($GameProcess.Id): $helperError"
    }
}

function Read-NativeStatus([Diagnostics.Process]$GameProcess) {
    $path = Join-Path $nativeStatusRoot "status-$($GameProcess.Id).json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Test-NativeWorldReady($Status) {
    if ($null -eq $Status) { return $false }
    try {
        if ($OperationalCaptureLab) {
            $observerStates = @($Status.luaStates | Where-Object { $_.commandObserverRegistered -eq $true }).Count
            return $Status.active -eq $true `
                -and $Status.hooks.enabled -eq $true `
                -and $Status.gates.buildProposal.enabled -ne $true `
                -and $Status.gates.commandVisitors.enabled -ne $true `
                -and $observerStates -ge 1
        }
        return $Status.active -eq $true `
            -and $Status.hooks.enabled -eq $true `
            -and $Status.gates.buildProposal.enabled -eq $true `
            -and $Status.gates.commandVisitors.enabled -eq $true
    }
    catch { return $false }
}

function Start-NativeFreshWorld(
    [Diagnostics.Process]$GameProcess,
    [string]$Peer,
    [string]$BridgePath
) {
    $evidence = Join-Path $runRoot "native-fresh-world-$Peer"
    New-Item -ItemType Directory -Force -Path $evidence | Out-Null
    # The game remembers a window rectangle that may extend beyond a changed
    # monitor/DPI layout. Keep stock new-game controls inside the physical
    # desktop before relying on their published live rectangles.
    Invoke-GameInput $GameProcess 'maximize'
    $deadline = (Get-Date).AddSeconds(120)
    $menu = $null
    while ((Get-Date) -lt $deadline) {
        [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
            -Context "before the $Peer native Free Game page opened")
        $menu = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $Session -Peer $Peer
        if ($menu -and $menu.error) { throw "Menu bootstrap failed: $($menu.error)" }
        if ($menu -and $menu.components.createNewGameRect -and $menu.components.menuRect) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $menu -or -not $menu.components.createNewGameRect) {
        throw "$Peer did not expose the stock Free Game button."
    }
    Invoke-Tpf2mpUiRectangleClick $GameProcess $menu.components.createNewGameRect `
        $menu.components.menuRect (Join-Path $evidence 'click-free-game.json')

    $deadline = (Get-Date).AddSeconds(120)
    $wizard = $null
    while ((Get-Date) -lt $deadline) {
        [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
            -Context "before the $Peer native Free Game wizard was ready")
        $wizard = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $Session -Peer $Peer
        if ($wizard -and $wizard.error) { throw "Menu bootstrap failed: $($wizard.error)" }
        if ($wizard -and $wizard.components.menuRect `
            -and ($wizard.components.nextGameRect -or $wizard.components.startGameRect)) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not $wizard -or (-not $wizard.components.nextGameRect -and -not $wizard.components.startGameRect)) {
        throw "$Peer did not expose the stock Free Game Next/Start control."
    }
    if ($wizard.components.nextGameRect) {
        Invoke-Tpf2mpUiRectangleClick $GameProcess $wizard.components.nextGameRect `
            $wizard.components.menuRect (Join-Path $evidence 'click-next-game.json')
        Start-Sleep -Milliseconds 500
        $deadline = (Get-Date).AddSeconds(120)
        $start = $null
        while ((Get-Date) -lt $deadline) {
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
                -Context "before the $Peer native Free Game Start button was ready")
            $start = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $Session -Peer $Peer
            if ($start -and $start.error) { throw "Menu bootstrap failed: $($start.error)" }
            if ($start -and $start.components.startGameRect -and $start.components.menuRect) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    else { $start = $wizard }
    if (-not $start -or -not $start.components.startGameRect) {
        throw "$Peer did not expose the stock Free Game Start button after Next."
    }
    Invoke-Tpf2mpUiRectangleClick $GameProcess $start.components.startGameRect `
        $start.components.menuRect (Join-Path $evidence 'click-start-game.json')

    $nativePath = Join-Path $nativeStatusRoot "status-$($GameProcess.Id).json"
    [void](Wait-Tpf2mpNativeWorld -GameProcess $GameProcess -NativeStatusPath $nativePath `
        -RequireGameScriptObserver -TimeoutSeconds 240)
    Write-Host "$Peer game PID $($GameProcess.Id) generated a native Free Game world with active modifiers."
}

function Start-GameWorldViaConsole(
    [Diagnostics.Process]$GameProcess,
    [string]$Peer,
    [string]$SavePath
) {
    Wait-GameWindow $GameProcess
    $requestedSave = $SavePath
    if ($requestedSave) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($requestedSave)
        Write-Host "$Peer selecting pinned native save $baseName through the Load Game page."
        [void](Invoke-Tpf2mpPinnedSaveLoad -GameProcess $GameProcess -BridgePath $(if ($Peer -eq 'player1') {
                $peer1Bridge
            } else { $peer2Bridge }) -Session $Session -Peer $Peer -ExpectedSaveBaseName $baseName `
            -EvidenceDirectory (Join-Path $runRoot "native-save-load-$Peer") -TimeoutSeconds 180)
        $nativePath = Join-Path $nativeStatusRoot "status-$($GameProcess.Id).json"
        if ($OperationalCaptureLab) {
            [void](Wait-Tpf2mpNativeWorld -GameProcess $GameProcess -NativeStatusPath $nativePath `
                -RequireGameScriptObserver -TimeoutSeconds 240)
        }
        else {
            [void](Wait-Tpf2mpNativeWorld -GameProcess $GameProcess -NativeStatusPath $nativePath `
                -RequireGameScriptObserver -RequireAuthorityGates -TimeoutSeconds 240)
        }
        Write-Host "$Peer game PID $($GameProcess.Id) loaded its pinned native world without console re-entry."
        return
    }
    elseif ($NativeFreshWorld) {
        Start-NativeFreshWorld $GameProcess $Peer $(if ($Peer -eq 'player1') {
                $peer1Bridge
            } else { $peer2Bridge })
        return
    }
    else {
        # Normalize a potentially stale synthetic Return state left by an
        # earlier interrupted/crashed empty-world lab.
        Invoke-GameInput $GameProcess 'accept-up'
        Invoke-GameInput $GameProcess 'start'
        Invoke-GameInput $GameProcess 'accept-down'
    }
    $ready = $false
    try {
        $deadline = (Get-Date).AddSeconds(180)
        while ((Get-Date) -lt $deadline) {
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $GameProcess `
                -Context "while loading the $Peer disposable world")
            if (Test-NativeWorldReady (Read-NativeStatus $GameProcess)) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }
    finally {
        if (-not $requestedSave) {
            try { Invoke-GameInput $GameProcess 'accept-up' }
            catch { Write-Warning "Could not release staged Return for $Peer PID $($GameProcess.Id): $($_.Exception.Message)" }
        }
    }
    if (-not $ready) {
        if ($OperationalCaptureLab) {
            throw "$Peer game PID $($GameProcess.Id) did not reach the observer-active, gates-disabled capture boundary."
        }
        throw "$Peer game PID $($GameProcess.Id) did not activate both native network gates after app.startGame()."
    }
    if ($OperationalCaptureLab) {
        Write-Host "$Peer game PID $($GameProcess.Id) reached its unrestricted operational-capture boundary."
    }
    else { Write-Host "$Peer game PID $($GameProcess.Id) reached its native-authority world boundary." }
}

function Copy-StartingSaveTriplet([string]$Source, [string]$DestinationDirectory) {
    $sourceSave = [IO.Path]::GetFullPath($Source)
    if (-not (Test-Path -LiteralPath $sourceSave -PathType Leaf)) {
        throw "Starting save is missing: $sourceSave"
    }
    if ([IO.Path]::GetExtension($sourceSave) -ne '.sav') {
        throw 'StartingSave must name a .sav file.'
    }
    $sourceLua = $sourceSave + '.lua'
    if (-not (Test-Path -LiteralPath $sourceLua -PathType Leaf)) {
        throw "Starting save metadata is missing: $sourceLua"
    }
    New-Item -ItemType Directory -Force -Path $DestinationDirectory | Out-Null
    $destinationSave = Join-Path $DestinationDirectory 'starting-world.sav'
    $destinationLua = $destinationSave + '.lua'
    Copy-Item -LiteralPath $sourceSave -Destination $destinationSave -Force
    Copy-Item -LiteralPath $sourceLua -Destination $destinationLua -Force
    $sourceImage = [IO.Path]::ChangeExtension($sourceSave, '.jpg')
    $destinationImage = [IO.Path]::ChangeExtension($destinationSave, '.jpg')
    if (Test-Path -LiteralPath $sourceImage -PathType Leaf) {
        Copy-Item -LiteralPath $sourceImage -Destination $destinationImage -Force
    }
    $files = @($destinationSave, $destinationLua)
    if (Test-Path -LiteralPath $destinationImage -PathType Leaf) { $files += $destinationImage }
    $manifest = [ordered]@{
        schemaVersion = 1
        source = $sourceSave
        copiedAtUtc = [DateTime]::UtcNow.ToString('o')
        files = @($files | ForEach-Object {
            $item = Get-Item -LiteralPath $_
            [ordered]@{
                name = $item.Name
                bytes = $item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
    }
    return [pscustomobject]@{ Save = $destinationSave; Manifest = $manifest }
}

function Stage-StartingSaveForConsole(
    [string]$SourceSave, [string]$DestinationDirectory, [string]$Label = ''
) {
    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        throw "Game save directory is missing: $DestinationDirectory"
    }
    $safeLabel = if ($Label) { '_' + ($Label -replace '[^A-Za-z0-9_-]', '_') } else { '' }
    $safeBaseName = 'tpf2mp_lab_' + $Session + $safeLabel
    $destinationSave = [IO.Path]::GetFullPath((Join-Path $DestinationDirectory ($safeBaseName + '.sav')))
    $savePrefix = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\') + '\'
    if (-not $destinationSave.StartsWith($savePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to stage a save outside $DestinationDirectory"
    }
    $sourceFiles = @(
        @{ Source = $SourceSave; Destination = $destinationSave },
        @{ Source = $SourceSave + '.lua'; Destination = $destinationSave + '.lua' },
        @{ Source = [IO.Path]::ChangeExtension($SourceSave, '.jpg'); Destination = [IO.Path]::ChangeExtension($destinationSave, '.jpg') }
    )
    foreach ($entry in $sourceFiles) {
        if (Test-Path -LiteralPath $entry.Destination) {
            throw "Refusing to overwrite an existing staged save file: $($entry.Destination)"
        }
        if (Test-Path -LiteralPath $entry.Source -PathType Leaf) {
            Copy-Item -LiteralPath $entry.Source -Destination $entry.Destination
            $script:stagedStartingFiles += $entry.Destination
        }
    }
    if (-not (Test-Path -LiteralPath $destinationSave -PathType Leaf) `
        -or -not (Test-Path -LiteralPath ($destinationSave + '.lua') -PathType Leaf)) {
        throw 'The console staging copy is incomplete.'
    }
    return $destinationSave
}

function Get-StagedStartingSave([string]$Peer) {
    if ($script:peerStagedStartingSaves.ContainsKey($Peer)) {
        return [string]$script:peerStagedStartingSaves[$Peer]
    }
    return $script:stagedStartingSave
}

function Request-GameQuit([Diagnostics.Process]$GameProcess, [string]$Peer) {
    if (-not $GameProcess) { return }
    try { $GameProcess.Refresh() } catch { return }
    if ($GameProcess.HasExited) { return }
    try {
        Invoke-GameInput $GameProcess 'quit'
        Invoke-GameInput $GameProcess 'accept-down'
        if (-not $GameProcess.WaitForExit(12000)) {
            try { Invoke-GameInput $GameProcess 'accept-up' } catch { }
        }
    }
    catch { Write-Warning "Graceful console quit failed for $Peer PID $($GameProcess.Id): $($_.Exception.Message)" }
}

function Read-CompanionStatus([string]$BridgePath) {
    $path = Join-Path $BridgePath 'companion_state\companion_status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Test-CompanionConnected($Status) {
    return $null -ne $Status -and $null -ne $Status.PSObject.Properties['connected'] -and $Status.connected -eq $true
}

function Read-ValidationResult([string]$BridgePath, [string]$Peer) {
    $outbox = Join-Path $BridgePath 'game_outbox'
    if (-not (Test-Path -LiteralPath $outbox -PathType Container)) { return $null }
    $matches = @()
    foreach ($file in Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' | Sort-Object Name) {
        try {
            $message = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($message.session -eq $Session -and $message.peer -eq $Peer -and $message.kind -eq 'validation' `
                -and $message.payload.kind -eq 'localhost-network') {
                $matches += $message
            }
        }
        catch { }
    }
    return $matches | Select-Object -Last 1
}

function Read-OperationalCapture([string]$BridgePath, [string]$Peer) {
    $outbox = Join-Path $BridgePath 'game_outbox'
    if (-not (Test-Path -LiteralPath $outbox -PathType Container)) { return $null }
    $matches = @()
    foreach ($file in Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' | Sort-Object Name) {
        try {
            $message = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($message.session -eq $Session -and $message.peer -eq $Peer `
                -and $message.kind -eq 'operational' `
                -and $message.payload.scope -eq 'local-operational-observation-only' `
                -and $message.payload.initialized -eq $true) {
                $matches += $message
            }
        }
        catch { }
    }
    return $matches | Select-Object -Last 1
}

function Stop-ExactProcess([Diagnostics.Process]$Process, [string]$Label, [int]$GraceSeconds = 10) {
    if (-not $Process) { return }
    try { $Process.Refresh() } catch { return }
    if ($Process.HasExited) { return }
    if (-not $Process.WaitForExit($GraceSeconds * 1000)) {
        Write-Warning "$Label PID $($Process.Id) did not exit within ${GraceSeconds}s; terminating only that disposable PID."
        Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
        $Process.WaitForExit(10000) | Out-Null
    }
}

New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
try {
    if ($restorePlanData) {
        $p1Source = Resolve-Tpf2mpFullPath $Player1StartingSave
        $p2Source = Resolve-Tpf2mpFullPath $Player2StartingSave
        Invoke-Companion -Arguments @(
            'verify-restore-plan', $restorePlanPath,
            '--save', "player1=$p1Source", '--save', "player2=$p2Source"
        )
        foreach ($entry in @(
            @{ Peer = 'player1'; Source = $p1Source },
            @{ Peer = 'player2'; Source = $p2Source }
        )) {
            $copy = Copy-StartingSaveTriplet $entry.Source `
                (Join-Path $runRoot "starting-save-$($entry.Peer)")
            $peerStartingSaveCopies[$entry.Peer] = $copy.Save
            $peerStartingSaveManifests[$entry.Peer] = $copy.Manifest
            $copy.Manifest | ConvertTo-Json -Depth 8 | Set-Content `
                -LiteralPath (Join-Path $runRoot "starting-save-manifest-$($entry.Peer).json") -Encoding UTF8
            $peerStagedStartingSaves[$entry.Peer] = Stage-StartingSaveForConsole `
                $copy.Save $saveDirectory $entry.Peer
        }
        Invoke-Companion -Arguments @(
            'verify-restore-plan', $restorePlanPath,
            '--save', "player1=$($peerStartingSaveCopies.player1)",
            '--save', "player2=$($peerStartingSaveCopies.player2)"
        )
        $peerOwners = Get-Tpf2mpPeerStartingCompanyPlayerIds `
            -Player1Save $peerStartingSaveCopies.player1 `
            -Player2Save $peerStartingSaveCopies.player2
        # Native player entity IDs are local-world identities. Each restored
        # peer must retain the mapping saved in its own world; the two lists
        # are intentionally not required to match across machines.
        $peerStartingCompanyPlayerIds.player1 = $peerOwners.player1
        $peerStartingCompanyPlayerIds.player2 = $peerOwners.player2
        Write-Host "Verified and staged both peer-specific saves for restore boundary $($restorePlanData.boundarySeq)."
    }
    elseif ($StartingSave) {
        $startingCopy = Copy-StartingSaveTriplet $StartingSave (Join-Path $runRoot 'starting-save')
        $startingSaveCopy = $startingCopy.Save
        $startingCompanyPlayerIds = Read-Tpf2mpStartingCompanyPlayerIds $startingSaveCopy
        $startingSaveManifest = $startingCopy.Manifest
        $startingSaveManifest | ConvertTo-Json -Depth 8 | Set-Content `
            -LiteralPath (Join-Path $runRoot 'starting-save-manifest.json') -Encoding UTF8
        $stagedStartingSave = Stage-StartingSaveForConsole $startingSaveCopy $saveDirectory
        Write-Host "Pinned a read-only working copy of the populated save: $startingSaveCopy"
        Write-Host "Staged a uniquely named console-load copy: $stagedStartingSave"
    }
    if (-not $SkipTests) {
        & (Join-Path $PSScriptRoot 'run_tests.ps1')
    }
    if (-not $SkipInstall) {
        & (Join-Path $PSScriptRoot 'install.ps1') -LocalModsPath $mods
    }
    if (-not $SkipNativeBuild) {
        & (Join-Path $PSScriptRoot 'build_native_hook.ps1') -GameExecutable $game
    }

    $nativeRoot = Join-Path $projectRoot 'runtime\native-build\Release'
    if (Test-Path -LiteralPath (Join-Path $projectRoot 'bin\native\tpf2mp_injector.exe')) {
        $nativeRoot = Join-Path $projectRoot 'bin\native'
    }
    $injector = Join-Path $nativeRoot 'tpf2mp_injector.exe'
    $hook = Join-Path $nativeRoot 'tpf2mp_hook_build35924.dll'
    foreach ($required in @($injector, $hook, $bootstrapSource)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required localhost component is missing: $required" }
    }
    & $injector --verify $game
    if ($LASTEXITCODE -ne 0) { throw 'Native executable profile verification failed.' }

    $listenerProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    try { $listenerProbe.Start() } finally { $listenerProbe.Stop() }

    if (Test-Path -LiteralPath $bridgeBase) { Remove-Item -LiteralPath $bridgeBase -Recurse -Force }
    foreach ($peerBridge in @($peer1Bridge, $peer2Bridge)) {
        foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit', 'launcher')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $peerBridge $folder) | Out-Null
        }
        if ($ManualOnly) {
            # Build 35924's Lua file cache can reopen an existing launcher
            # file, but a file first created after the world transition may be
            # invisible to the sandbox. Seed the path before either process
            # starts and change only its contents after both worlds load.
            [IO.File]::WriteAllText((Join-Path $peerBridge 'launcher\manual-bootstrap-ready'),
                'waiting', [Text.UTF8Encoding]::new($false))
        }
    }

    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup -Force
    Set-LocalhostValidationSettings $settingsPath

    # Empty app.startGame() worlds and older laboratory saves both need the
    # multiplayer game-script resource available in the base cache. Reuse an
    # identical installed overlay, or create one only for this run.
    $resourcePrefix = $baseResourceRoot.TrimEnd('\') + '\'
    foreach ($target in @($injectedGameScript, $injectedLibrary, $bootstrapTarget)) {
        if (-not $target.StartsWith($resourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing temporary injection outside $baseResourceRoot"
        }
    }
    $overlay = @(Install-Tpf2mpRuntimeOverlay -BundleRoot $projectRoot -GameExecutable $game)
    $gameScriptEntry = $overlay | Where-Object { $_.target -eq $injectedGameScript } | Select-Object -First 1
    $libraryEntry = $overlay | Where-Object { $_.target -eq $injectedLibrary } | Select-Object -First 1
    $gameScriptInjected = $null -ne $gameScriptEntry -and $gameScriptEntry.created -eq $true
    $libraryInjected = $null -ne $libraryEntry -and $libraryEntry.created -eq $true
    if ($usingNativeMenuBootstrap) {
        $bootstrapInstall = Install-Tpf2mpMenuBootstrap -BundleRoot $projectRoot -GameExecutable $game
        $injectedBootstrap = $bootstrapInstall.created -eq $true
    }
    elseif (Test-Path -LiteralPath $bootstrapTarget -PathType Leaf) {
        if ((Get-FileHash -LiteralPath $bootstrapTarget -Algorithm SHA256).Hash -ne `
            (Get-FileHash -LiteralPath $bootstrapSource -Algorithm SHA256).Hash) {
            throw "Existing localhost bootstrap differs from this bundle: $bootstrapTarget"
        }
    }
    else {
        Copy-Item -LiteralPath $bootstrapSource -Destination $bootstrapTarget
        $injectedBootstrap = $true
    }
    if (-not (Test-Path -LiteralPath $steamAppIdPath)) {
        [IO.File]::WriteAllText($steamAppIdPath, [string]$script:Tpf2AppId, [Text.UTF8Encoding]::new($false))
        $createdSteamMarker = $true
    }
    elseif ((Get-Content -LiteralPath $steamAppIdPath -Raw).Trim() -ne [string]$script:Tpf2AppId) {
        throw "Existing steam_appid.txt belongs to another application: $steamAppIdPath"
    }

    $installedMod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
    $fingerprintSource = Join-Path $projectRoot 'companion\tpf2mp'
    [void](Write-Tpf2mpMatchContentProfile -Path $matchContentProfilePath `
        -AgentMode $AgentMode -TownDevelopment $TownDevelopment.IsPresent)
    $fingerprintArguments = @(
        'fingerprint', '--game-exe', $game, '--mod-dir', $installedMod,
        '--companion-dir', $fingerprintSource, '--extra', $nativeRoot,
        '--extra', $matchContentProfilePath, '--output', $manifestPath
    )
    if ($startingSaveCopy) { $fingerprintArguments += @('--save', $startingSaveCopy) }
    if ($restorePlanPath) { $fingerprintArguments += @('--extra', $restorePlanPath) }
    Invoke-Companion -Arguments $fingerprintArguments

    if ($OperationalCaptureLab) {
        # This mode intentionally has no TCP companion. Each process is an
        # isolated standalone hot-seat world with native mutation gates off;
        # its purpose is to observe real operations, not claim synchronization.
        $peer1Game = Start-GamePeer 'player1' $peer1Bridge
        Wait-MenuBootstrap $peer1Game 'player1' $peer1Bridge
        & $injector --pid $peer1Game.Id --dll $hook --wait-ms 60000
        if ($LASTEXITCODE -ne 0) { throw "Native hook injection failed for PID $($peer1Game.Id)" }

        $peer2Game = Start-GamePeer 'player2' $peer2Bridge
        Wait-MenuBootstrap $peer2Game 'player2' $peer2Bridge
        & $injector --pid $peer2Game.Id --dll $hook --wait-ms 60000
        if ($LASTEXITCODE -ne 0) { throw "Native hook injection failed for PID $($peer2Game.Id)" }
        foreach ($peerBridge in @($peer1Bridge, $peer2Bridge)) {
            [IO.File]::WriteAllText((Join-Path $peerBridge 'launcher\start'), 'start', [Text.UTF8Encoding]::new($false))
        }
        Start-GameWorldViaConsole $peer1Game 'player1' (Get-StagedStartingSave 'player1')
        Start-GameWorldViaConsole $peer2Game 'player2' (Get-StagedStartingSave 'player2')

        $captureDeadline = (Get-Date).AddSeconds(240)
        do {
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer1Game `
                -Context 'before the player1 capture-lab sample')
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer2Game `
                -Context 'before the player2 capture-lab sample')
            $peer1Capture = Read-OperationalCapture $peer1Bridge 'player1'
            $peer2Capture = Read-OperationalCapture $peer2Bridge 'player2'
            if ($peer1Capture -and $peer2Capture) { break }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $captureDeadline)
        if (-not $peer1Capture -or -not $peer2Capture) {
            throw 'Timed out waiting for initialized operational samples from both game instances.'
        }

        foreach ($entry in @(
            @{ Peer = 'player1'; Game = $peer1Game; Capture = $peer1Capture },
            @{ Peer = 'player2'; Game = $peer2Game; Capture = $peer2Capture }
        )) {
            $payload = $entry.Capture.payload
            if (-not $payload.clock -or -not $payload.structural -or -not $payload.mobility `
                -or -not $payload.autonomy -or -not $payload.journal -or -not $payload.accounts `
                -or -not $payload.digests.model -or -not $payload.digests.core `
                -or -not $payload.digests.structural -or -not $payload.digests.mobility) {
                throw "$($entry.Peer) operational sample is missing a required observation domain."
            }
            $nativePath = Join-Path $nativeStatusRoot "status-$($entry.Game.Id).json"
            $native = Read-NativeStatus $entry.Game
            if (-not $native -or $native.active -ne $true -or $native.hooks.enabled -ne $true `
                -or $native.gates.buildProposal.enabled -eq $true `
                -or $native.gates.commandVisitors.enabled -eq $true `
                -or $native.commandList.invalidLayouts -ne 0 `
                -or $native.applyCommand.unknownTags -ne 0) {
                throw "$($entry.Peer) did not retain a clean observer-only native boundary."
            }
            $entry.Capture | ConvertTo-Json -Depth 40 | Set-Content `
                -LiteralPath (Join-Path $runRoot "$($entry.Peer)-initial-operational.json") -Encoding UTF8
            Copy-Item -LiteralPath $nativePath `
                -Destination (Join-Path $runRoot "native-$($entry.Game.Id)-initial.json") -Force
        }

        $labStatusPath = Join-Path $runRoot 'interactive-lab.json'
        $labStatus = [ordered]@{
            schemaVersion = 2
            mode = 'operational-capture-local-only'
            synchronized = $false
            session = $Session
            status = 'ready'
            startedAt = (Get-Date).ToString('o')
            expiresAt = (Get-Date).AddMinutes($InteractiveMinutes).ToString('o')
            player1GamePid = $peer1Game.Id
            player2GamePid = $peer2Game.Id
            player1Bridge = $peer1Bridge
            player2Bridge = $peer2Bridge
            sampleIntervalTicks = $OperationalSampleTicks
            companyStartingCash = $OperationalStartingCash
            instructions = @(
                'These are two isolated hot-seat worlds, not synchronized multiplayer.',
                'Do not press Initialise Match, Standalone / Network, Toggle Build Gate, or Authorize Next Build.',
                'Window 1 / Company 1: build a two-station passenger railway, depot, line, train, and assignment.',
                'Window 2 / Company 1: build a producer-to-consumer cargo route, depot, line, and vehicle.',
                'Run both at speed 3 until vehicles complete a trip and loads or balances change; then Sample Pax / Cargo, Export Research, and Export Snapshot in both.',
                'Reconcile Turn, then Cycle Company in both windows. Window 1 / Company 2 builds a small cargo-truck service; Window 2 / Company 2 builds a small passenger-bus service.',
                'In Window 1 only, while Company 2 is active, attempt one harmless edit of Company 1 private track; it should be refused. Do not delete working infrastructure.',
                'Run at speed 3 for at least five more minutes, then Sample Pax / Cargo, Reconcile Turn, Export Research, Export Snapshot, and Export Checkpoint in both.',
                'Close either game window to finish; evidence is collected automatically.'
            )
        }
        $labStatus | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $labStatusPath -Encoding UTF8
        $finalPassed = $true
        Write-Host "OPERATIONAL CAPTURE LAB READY: player1 PID $($peer1Game.Id), player2 PID $($peer2Game.Id)"
        Write-Host "Each company has a disposable audited research grant of $OperationalStartingCash; native borrowing remains disabled."
        Write-Host 'The windows are deliberately isolated and unrestricted; no network-sync claim is being made.'
        Write-Host 'TEST PHASE 1: window 1 gets a Company 1 passenger railway; window 2 gets a Company 1 cargo route.'
        Write-Host 'TEST PHASE 2: run at speed 3 to a completed loaded trip, then Sample Pax / Cargo + Export Research + Export Snapshot in both.'
        Write-Host 'TEST PHASE 3: Reconcile + Cycle; Window 1 Company 2 builds cargo trucks, Window 2 Company 2 builds passenger buses.'
        Write-Host 'TEST PHASE 4: in Window 1 verify Company 2 cannot edit Company 1 private track; run five more minutes, sample, reconcile, and export Research/Snapshot/Checkpoint.'
        if ($UnattendedOperationalSeconds -gt 0) {
            Write-Host "UNATTENDED POPULATED PROBE: collecting $UnattendedOperationalSeconds seconds of loaded-world telemetry."
        }
        else { Write-Host 'Finish by closing either game window. The launcher will collect and analyze both worlds automatically.' }
        Write-Host "labStatus=$labStatusPath"
        $interactiveDeadline = if ($UnattendedOperationalSeconds -gt 0) {
            (Get-Date).AddSeconds($UnattendedOperationalSeconds)
        }
        else { (Get-Date).AddMinutes($InteractiveMinutes) }
        while ((Get-Date) -lt $interactiveDeadline) {
            $peer1Game.Refresh(); $peer2Game.Refresh()
            if ($peer1Game.HasExited -or $peer2Game.HasExited) { break }
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer1Game `
                -Context 'during the player1 operational lab')
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer2Game `
                -Context 'during the player2 operational lab')
            if ((Test-Path -LiteralPath (Join-Path $peer1Bridge 'launcher\stop')) `
                -or (Test-Path -LiteralPath (Join-Path $peer2Bridge 'launcher\stop'))) { break }
            Start-Sleep -Seconds 1
        }
        $labStatus.status = 'stopping'
        $labStatus.endedAt = (Get-Date).ToString('o')
        $labStatus | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $labStatusPath -Encoding UTF8
        $collectInteractiveEvidence = $true
    }
    else {
    $hostArgs = @(
        'host', '--session', $Session, '--peer', 'player1', '--bind', '127.0.0.1',
        '--port', [string]$Port, '--bridge', $peer1Bridge,
        '--required-peer', 'player1', '--required-peer', 'player2',
        '--completion-timeout', [string]$ConsensusTimeoutSeconds,
        '--manifest', $manifestPath
    )
    if ($restorePlanPath) { $hostArgs += @('--restore-plan', $restorePlanPath) }
    $clientArgs = @(
        'client', '127.0.0.1', '--session', $Session, '--peer', 'player2',
        '--port', [string]$Port, '--bridge', $peer2Bridge, '--manifest', $manifestPath
    )
    $hostProcess = Start-Companion 'host' $hostArgs (Join-Path $runRoot 'host-companion')
    Start-Sleep -Milliseconds 400
    $clientProcess = Start-Companion 'client' $clientArgs (Join-Path $runRoot 'client-companion')

    $linkDeadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 250
        $hostStatus = Read-CompanionStatus $peer1Bridge
        $clientStatus = Read-CompanionStatus $peer2Bridge
    } while ((Get-Date) -lt $linkDeadline -and -not ((Test-CompanionConnected $hostStatus) -and (Test-CompanionConnected $clientStatus)))
    if (-not ((Test-CompanionConnected $hostStatus) -and (Test-CompanionConnected $clientStatus))) {
        throw 'The localhost host/client companions did not establish their TCP session.'
    }
    Write-Host "Companions connected on 127.0.0.1:$Port for session $Session"

    # Build 35924 shares its profile cache, shader cache, stdout, and lockfile.
    # Starting both renderers simultaneously can race those shared files, so
    # establish and hook each stable menu process before creating the next.
    $peer1Game = Start-GamePeer 'player1' $peer1Bridge
    Wait-MenuBootstrap $peer1Game 'player1' $peer1Bridge
    & $injector --pid $peer1Game.Id --dll $hook --wait-ms 60000
    if ($LASTEXITCODE -ne 0) { throw "Native hook injection failed for PID $($peer1Game.Id)" }

    $peer2Game = Start-GamePeer 'player2' $peer2Bridge
    Wait-MenuBootstrap $peer2Game 'player2' $peer2Bridge
    & $injector --pid $peer2Game.Id --dll $hook --wait-ms 60000
    if ($LASTEXITCODE -ne 0) { throw "Native hook injection failed for PID $($peer2Game.Id)" }
    Write-Host "Started and staged exact game PIDs $($peer1Game.Id) (host) and $($peer2Game.Id) (client)."
    foreach ($peerBridge in @($peer1Bridge, $peer2Bridge)) {
        [IO.File]::WriteAllText((Join-Path $peerBridge 'launcher\start'), 'start', [Text.UTF8Encoding]::new($false))
    }
    Write-Host 'Both hooks are active; both menu bootstraps received their peer-specific launcher marker.'
    Start-GameWorldViaConsole $peer1Game 'player1' (Get-StagedStartingSave 'player1')
    Start-GameWorldViaConsole $peer2Game 'player2' (Get-StagedStartingSave 'player2')
    if ($restorePlanData) {
        Write-Host 'Both exact processes loaded their own plan-attested save; awaiting restore checkpoint consensus.'
    }
    elseif ($startingSaveCopy) {
        Write-Host 'Both exact processes loaded the same pinned populated save with native authority active.'
    }
    else { Write-Host 'Both exact processes are running disposable app.startGame worlds with native authority active.' }

    if ($ManualOnly) {
        # The game script exists in a transient pre-load world as well as the
        # pinned save. Arm the host bootstrap only after both processes crossed
        # the native save-loader boundary, otherwise a checkpoint can belong to
        # a world that app.loadGame immediately replaces.
        foreach ($peerBridge in @($peer1Bridge, $peer2Bridge)) {
            [IO.File]::WriteAllText((Join-Path $peerBridge 'launcher\manual-bootstrap-ready'),
                'ready', [Text.UTF8Encoding]::new($false))
        }
        # The native hook reads this barrier outside Build 35924's stale Lua
        # file cache. Its persistent menu state then issues one authorized
        # speed wake and bounded readiness events without focus-sensitive
        # console automation. Match initialisation and every operation still
        # travel through host ordering and two-peer checkpoint consensus.
        Write-Host 'Armed the native paused-world bootstrap barrier for both exact processes.'
        Write-Host 'Waiting for the host-only ordered match bootstrap and its two-peer checkpoint.'
        $bootstrapDeadline = (Get-Date).AddSeconds([Math]::Min($TimeoutSeconds, 240))
        $bootstrapReady = $false
        do {
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer1Game `
                -Context 'before player1 manual-network bootstrap completed')
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer2Game `
                -Context 'before player2 manual-network bootstrap completed')
            $hostStatus = Read-CompanionStatus $peer1Bridge
            $clientStatus = Read-CompanionStatus $peer2Bridge
            if ($hostStatus -and $hostStatus.sessionFault) {
                throw "Manual bootstrap faulted before checkpoint: $($hostStatus.sessionFault)"
            }
            $bootstrapReady = (Test-CompanionConnected $hostStatus) `
                -and (Test-CompanionConnected $clientStatus) `
                -and [int64]($hostStatus.lastAgreedCheckpointSeq) -ge 1
            if ($bootstrapReady -and $restorePlanData) {
                $bootstrapReady = $hostStatus.restoreStatus -eq 'complete' `
                    -and [int64]$hostStatus.restoreCommitSeq -ge 1
            }
            if (-not $bootstrapReady) { Start-Sleep -Milliseconds 500 }
        } while (-not $bootstrapReady -and (Get-Date) -lt $bootstrapDeadline)
        if (-not $bootstrapReady) {
            throw 'Timed out waiting for the manual network match-initialise checkpoint.'
        }
        foreach ($gameProcess in @($peer1Game, $peer2Game)) {
            $nativePath = Join-Path $nativeStatusRoot "status-$($gameProcess.Id).json"
            if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) {
                throw "Native status is missing for PID $($gameProcess.Id)"
            }
            $native = Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json
            if ($native.hookVersion -ne '0.13.0' `
                -or $native.active -ne $true -or $native.hooks.enabled -ne $true `
                -or $native.gates.buildProposal.enabled -ne $true `
                -or $native.gates.commandVisitors.enabled -ne $true `
                -or $native.commandList.invalidLayouts -ne 0 `
                -or $native.applyCommand.unknownTags -ne 0 `
                -or $native.gates.commandVisitors.tagMismatches -ne 0) {
                throw "Native manual-network authority evidence failed for PID $($gameProcess.Id)"
            }
            Copy-Item -LiteralPath $nativePath `
                -Destination (Join-Path $runRoot "native-$($gameProcess.Id).json") -Force
        }
        $peer1RecoveryWatcher = Start-RecoveryWatcher 'player1' $peer1Bridge $peer1Game
        $peer2RecoveryWatcher = Start-RecoveryWatcher 'player2' $peer2Bridge $peer2Game
        $finalPassed = $true
        if ($restorePlanData) {
            Write-Host 'PASS coordinated restore: both attested saves accepted recovery.resume and a fresh checkpoint.'
        }
        else {
            Write-Host 'PASS manual network bootstrap: both peers accepted match.initialise and checkpoint consensus.'
        }
    }
    else {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $nextProgress = Get-Date
    while ((Get-Date) -lt $deadline) {
        foreach ($entry in @(
            @{ Peer = 'player1'; Bridge = $peer1Bridge; Game = $peer1Game },
            @{ Peer = 'player2'; Bridge = $peer2Bridge; Game = $peer2Game }
        )) {
            $entry.Game.Refresh()
            if (-not $peerResults[$entry.Peer] -or -not $entry.Game.HasExited) {
                [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $entry.Game `
                    -Context "before $($entry.Peer) validation completed")
            }
            $result = Read-ValidationResult $entry.Bridge $entry.Peer
            if ($result) {
                $peerResults[$entry.Peer] = $result
                if ($result.payload.status -eq 'failed') {
                    throw "$($entry.Peer) validation failed: $($result.payload.error)"
                }
            }
        }
        if ($peerResults.Count -eq 2) { break }
        if ((Get-Date) -ge $nextProgress) {
            $hostStatus = Read-CompanionStatus $peer1Bridge
            $clientStatus = Read-CompanionStatus $peer2Bridge
            $hostOut = @(Get-ChildItem -LiteralPath (Join-Path $peer1Bridge 'game_outbox') -File -Filter '*.json').Count
            $clientOut = @(Get-ChildItem -LiteralPath (Join-Path $peer2Bridge 'game_outbox') -File -Filter '*.json').Count
            Write-Host ("Waiting: host/client outbox {0}/{1}, next commit {2}, checkpoint {3}, TCP {4}/{5}" -f `
                $hostOut, $clientOut, $hostStatus.nextCommitSeq, $hostStatus.lastAgreedCheckpointSeq,
                $hostStatus.status, $clientStatus.status)
            $nextProgress = (Get-Date).AddSeconds(15)
        }
        Start-Sleep -Seconds 1
    }
    if ($peerResults.Count -ne 2) { throw "Timed out after $TimeoutSeconds seconds waiting for both live validation records." }

    foreach ($peer in @('player1', 'player2')) {
        $peerResults[$peer] | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $runRoot "$peer-validation.json") -Encoding UTF8
        if ($peerResults[$peer].payload.status -ne 'passed') {
            throw "$peer validation failed: $($peerResults[$peer].payload.error)"
        }
    }
    $p1 = $peerResults.player1.payload
    $p2 = $peerResults.player2.payload
    if ($p1.digest -ne $p2.digest) { throw "Final canonical core divergence: player1=$($p1.digest), player2=$($p2.digest)" }
    if ($p1.structuralDigest -ne $p2.structuralDigest) {
        throw "Final structural divergence: player1=$($p1.structuralDigest), player2=$($p2.structuralDigest)"
    }
    $hostStatus = Read-CompanionStatus $peer1Bridge
    if ($null -eq $hostStatus -or $null -eq $hostStatus.PSObject.Properties['mobilityOutcomes']) {
        throw 'Host companion did not publish ordered mobility outcomes.'
    }
    $badMobility = @($hostStatus.mobilityOutcomes.PSObject.Properties | Where-Object { $_.Value -ne 'converged' })
    if ($badMobility.Count -gt 0) { throw "At least one ordered mobility sample diverged: $($badMobility.Name -join ', ')" }
    if ($RequireVehicleSyncRound) {
        if ($null -eq $hostStatus.PSObject.Properties['vehicleSync']) {
            throw 'Host companion did not publish vehicle synchronization status.'
        }
        $vehicleSync = $hostStatus.vehicleSync
        $pending = [int]$vehicleSync.pendingRounds
        $releaseOrdered = if ($null -ne $vehicleSync.PSObject.Properties['pendingByStatus'] `
            -and $null -ne $vehicleSync.pendingByStatus.PSObject.Properties['release-ordered']) {
            [int]$vehicleSync.pendingByStatus.'release-ordered'
        } else { 0 }
        $safePausedPending = $pending -eq 0 -or (
            [int]$hostStatus.clock.effectiveSpeed -eq 0 -and $releaseOrdered -eq $pending)
        if ([int]$vehicleSync.trackedVehicles -lt 1 -or [int]$vehicleSync.releases -lt 1 `
            -or [int]$vehicleSync.faults -ne 0 -or -not $safePausedPending) {
            throw ("Populated vehicle rendezvous did not finish cleanly: " +
                "tracked=$($vehicleSync.trackedVehicles), releases=$($vehicleSync.releases), " +
                "scheduled=$($vehicleSync.scheduledReleases), " +
                "unscheduled=$($vehicleSync.unscheduledReleases), faults=$($vehicleSync.faults), " +
                "pending=$pending, releaseOrdered=$releaseOrdered")
        }
    }

    foreach ($gameProcess in @($peer1Game, $peer2Game)) {
        $nativePath = Join-Path $nativeStatusRoot "status-$($gameProcess.Id).json"
        if (-not (Test-Path -LiteralPath $nativePath -PathType Leaf)) { throw "Native status is missing for PID $($gameProcess.Id)" }
        $native = Get-Content -LiteralPath $nativePath -Raw | ConvertFrom-Json
        if ($native.active -ne $true -or $native.hooks.enabled -ne $true `
            -or $native.gates.buildProposal.enabled -ne $true `
            -or $native.gates.commandVisitors.enabled -ne $true `
            -or $native.commandList.invalidLayouts -ne 0 `
            -or $native.applyCommand.unknownTags -ne 0 `
            -or $native.gates.commandVisitors.tagMismatches -ne 0) {
            throw "Native authority evidence failed for PID $($gameProcess.Id)"
        }
        Copy-Item -LiteralPath $nativePath -Destination (Join-Path $runRoot "native-$($gameProcess.Id).json") -Force
    }
    $finalPassed = $true
    Write-Host "PASS two live game processes converged: core=$($p1.digest), structure=$($p1.structuralDigest)"
    }
    if ($InteractiveAfterValidation) {
        if (-not $ManualOnly) {
        foreach ($peerBridge in @($peer1Bridge, $peer2Bridge)) {
            $readyMarker = Join-Path $peerBridge 'launcher\manual-handoff-ready'
            if (Test-Path -LiteralPath $readyMarker -PathType Leaf) {
                Remove-Item -LiteralPath $readyMarker -Force
            }
            [IO.File]::WriteAllText((Join-Path $peerBridge 'launcher\manual-handoff'),
                'manual', [Text.UTF8Encoding]::new($false))
        }
        $handoffDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $handoffDeadline) {
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer1Game `
                -Context 'during the player1 validator-to-human authority handoff')
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer2Game `
                -Context 'during the player2 validator-to-human authority handoff')
            $player1Ready = Test-Path -LiteralPath (Join-Path $peer1Bridge 'launcher\manual-handoff-ready') -PathType Leaf
            $player2Ready = Test-Path -LiteralPath (Join-Path $peer2Bridge 'launcher\manual-handoff-ready') -PathType Leaf
            if ($player1Ready -and $player2Ready) { break }
            Start-Sleep -Milliseconds 250
        }
        if (-not (Test-Path -LiteralPath (Join-Path $peer1Bridge 'launcher\manual-handoff-ready') -PathType Leaf) `
            -or -not (Test-Path -LiteralPath (Join-Path $peer2Bridge 'launcher\manual-handoff-ready') -PathType Leaf)) {
            throw 'Both game GUI states did not acknowledge validator-to-human authority handoff.'
        }
        Write-Host 'Both peers acknowledged manual network authority; vanilla GUI capture is active.'
        }
        else {
            Write-Host 'Both peers entered manual network authority directly; vanilla GUI capture is active.'
        }
        $labStatusPath = Join-Path $runRoot 'interactive-lab.json'
        $labStatus = [ordered]@{
            schemaVersion = 1
            session = $Session
            status = 'ready'
            startedAt = (Get-Date).ToString('o')
            expiresAt = (Get-Date).AddMinutes($InteractiveMinutes).ToString('o')
            player1GamePid = $peer1Game.Id
            player2GamePid = $peer2Game.Id
            player1Bridge = $peer1Bridge
            player2Bridge = $peer2Bridge
            mode = if ($ManualOnly) { 'manual-network' } else { 'post-validation-network' }
            companyStartingCash = if ($ManualOnly) { $OperationalStartingCash } else { 5000000 }
            instructions = @(
                $(if ($ManualOnly) {
                    'Both game windows are connected after a safe ordered match bootstrap; no synthetic validator construction ran.'
                } else { 'Both game windows remain connected after the automated proof.' }),
                'Use each peer only as its assigned company; export research/snapshot after useful tests.',
                'Evidence is collected automatically before cleanup when the lab ends.',
                'Close either game window or use Stop companion in the launcher to end the lab.'
            )
        }
        $labStatus | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $labStatusPath -Encoding UTF8
        Write-Host "MANUAL LAB READY for up to $InteractiveMinutes minutes: player1 PID $($peer1Game.Id), player2 PID $($peer2Game.Id)"
        Write-Host "labStatus=$labStatusPath"
        Write-Host 'Export useful Research/Snapshot records before stopping; evidence is bundled automatically after both games close.'
        $interactiveDeadline = (Get-Date).AddMinutes($InteractiveMinutes)
        while ((Get-Date) -lt $interactiveDeadline) {
            $peer1Game.Refresh()
            $peer2Game.Refresh()
            if ($peer1Game.HasExited -or $peer2Game.HasExited) { break }
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer1Game `
                -Context 'during the player1 post-validation lab')
            [void](Assert-Tpf2mpGameProcessHealthy -GameProcess $peer2Game `
                -Context 'during the player2 post-validation lab')
            if ((Test-Path -LiteralPath (Join-Path $peer1Bridge 'launcher\stop')) `
                -or (Test-Path -LiteralPath (Join-Path $peer2Bridge 'launcher\stop'))) { break }
            Start-Sleep -Seconds 1
        }
        $labStatus.status = 'stopping'
        $labStatus.endedAt = (Get-Date).ToString('o')
        $labStatus | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $labStatusPath -Encoding UTF8
        $collectInteractiveEvidence = $true
        Write-Host 'Manual localhost lab ending; exact disposable processes will be cleaned up.'
    }
    }
}
catch {
    $failure = $_.Exception.Message
    if ($_.ScriptStackTrace) { $failure += "`n" + $_.ScriptStackTrace }
    Write-Warning $failure
}
finally {
    if (-not $KeepGamesOpen) {
        # These worlds are explicitly disposable. Neither app.quit() through
        # the console nor the bootstrap's launcher/stop -> app.stopGame() path
        # is safe from a UI update callback on Build 35924; both can re-enter
        # UI::CCore::InvokeStoredFunctions and create a crash dump. Terminate
        # only the two exact recorded PIDs; there is no save boundary here.
        foreach ($entry in @(
            @{ Process = $peer2Game; Label = 'player2 game' },
            @{ Process = $peer1Game; Label = 'player1 game' }
        )) { Stop-ExactProcess $entry.Process $entry.Label 1 }
    }
    Stop-ExactProcess $peer2RecoveryWatcher 'player2 recovery watcher' 1
    Stop-ExactProcess $peer1RecoveryWatcher 'player1 recovery watcher' 1
    Stop-ExactProcess $clientProcess 'client companion' 1
    Stop-ExactProcess $hostProcess 'host companion' 1
    foreach ($name in @('SteamAppId', 'SteamGameId', 'TPF2MP_PEER_ID', 'TPF2MP_SESSION_ID',
        'TPF2MP_BRIDGE_DIR', 'TPF2MP_START_NETWORK', 'TPF2MP_NETWORK_AUTOTEST',
        'TPF2MP_MANUAL_NETWORK',
        'TPF2MP_NETWORK_SOAK_TICKS', 'TPF2MP_NETWORK_CLOCK_RUN_TICKS',
        'TPF2MP_OPERATIONAL_CAPTURE',
        'TPF2MP_OPERATIONAL_SAMPLE_TICKS', 'TPF2MP_STARTING_CASH',
        'TPF2MP_TOWN_DEVELOPMENT', 'TPF2MP_AGENT_MODE',
        'TPF2MP_STAGED_SAVE_NAME', 'TPF2MP_STARTING_COMPANY_PLAYER_IDS',
        'TPF2MP_RESTORE_RESUME', 'TPF2MP_RESTORE_FROM_SESSION',
        'TPF2MP_RESTORE_BOUNDARY', 'TPF2MP_RESTORE_CORE_DIGEST',
        'TPF2MP_RESTORE_CONVERGENCE_KEY', 'TPF2MP_RESTORE_PLAN_CHECKSUM')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
    if ($injectedBootstrap -and (Test-Path -LiteralPath $bootstrapTarget)) {
        Remove-Item -LiteralPath $bootstrapTarget -Force
    }
    if ($libraryInjected -and (Test-Path -LiteralPath $injectedLibrary)) {
        Remove-Item -LiteralPath $injectedLibrary -Recurse -Force
    }
    if ($gameScriptInjected -and (Test-Path -LiteralPath $injectedGameScript)) {
        Remove-Item -LiteralPath $injectedGameScript -Force
    }
    if ($createdSteamMarker -and (Test-Path -LiteralPath $steamAppIdPath)) {
        Remove-Item -LiteralPath $steamAppIdPath -Force
    }
    if (Test-Path -LiteralPath $settingsBackup) {
        Copy-Item -LiteralPath $settingsBackup -Destination $settingsPath -Force
        $settingsRestored = (Get-FileHash -LiteralPath $settingsBackup -Algorithm SHA256).Hash -eq `
            (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    }
    if (Test-Path -LiteralPath $sharedLog -PathType Leaf) {
        Copy-Item -LiteralPath $sharedLog -Destination (Join-Path $runRoot 'shared-last-writer-stdout.txt') -Force
    }
    foreach ($stagedFile in @($stagedStartingFiles)) {
        if (Test-Path -LiteralPath $stagedFile -PathType Leaf) {
            $resolvedStaged = [IO.Path]::GetFullPath($stagedFile)
            $stagedPrefix = $saveDirectory.TrimEnd('\') + '\'
            if ($resolvedStaged.StartsWith($stagedPrefix, [StringComparison]::OrdinalIgnoreCase) `
                -and [IO.Path]::GetFileName($resolvedStaged).StartsWith('tpf2mp_lab_', [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedStaged -Force
            }
        }
    }
}

if ($collectInteractiveEvidence) {
    try {
        & (Join-Path $PSScriptRoot 'collect_live_evidence.ps1') `
            -Session $Session -Peer both -BundleRoot $projectRoot
        if ($LASTEXITCODE -ne 0) { throw "collector exited $LASTEXITCODE" }
        $interactiveEvidenceCollected = $true
    }
    catch {
        $interactiveEvidenceError = $_.Exception.Message
        if (-not $failure) { $failure = "Automatic lab evidence collection failed: $interactiveEvidenceError" }
        Write-Warning "Automatic lab evidence collection failed: $interactiveEvidenceError"
    }
}

if ($OperationalCaptureLab -and $collectInteractiveEvidence) {
    try {
        $operationalAnalysisPath = Join-Path $runRoot 'operational-analysis'
        & (Join-Path $PSScriptRoot 'analyze_operational_capture.ps1') `
            -Session $Session -BridgeRoot $bridgeBase -OutputDirectory $operationalAnalysisPath
        if ($LASTEXITCODE -ne 0) { throw "operational analyzer exited $LASTEXITCODE" }
    }
    catch {
        $operationalAnalysisError = $_.Exception.Message
        if (-not $failure) { $failure = "Operational evidence analysis failed: $operationalAnalysisError" }
        Write-Warning "Operational evidence analysis failed: $operationalAnalysisError"
    }
}

try {
    $audit = Join-Path $peer1Bridge "audit\$Session.ndjson"
    if (Test-Path -LiteralPath $audit -PathType Leaf) {
        $replayLog = Join-Path $runRoot 'audit-replay.txt'
        $oldPythonPath = $env:PYTHONPATH
        if ($companionCommand.IsPython) { $env:PYTHONPATH = Join-Path $projectRoot 'companion' }
        try {
            & $companionCommand.File @($companionCommand.Prefix + @('replay', $audit, '--session', $Session)) *>&1 |
                Tee-Object -FilePath $replayLog
            if ($LASTEXITCODE -ne 0 -and -not $failure) { $failure = 'Audit replay validation failed.' }
        }
        finally { $env:PYTHONPATH = $oldPythonPath }
    }
}
catch { if (-not $failure) { $failure = "Evidence replay failed: $($_.Exception.Message)" } }

$peer1GamePid = if ($peer1Game) { $peer1Game.Id } else { $null }
$peer2GamePid = if ($peer2Game) { $peer2Game.Id } else { $null }
$peer1Payload = if ($peerResults.ContainsKey('player1')) { $peerResults.player1.payload } else { $null }
$peer2Payload = if ($peerResults.ContainsKey('player2')) { $peerResults.player2.payload } else { $null }
$steamMarkerClean = if ($createdSteamMarker) {
    -not (Test-Path -LiteralPath $steamAppIdPath)
} elseif ($preexistingSteamMarker) {
    (Test-Path -LiteralPath $steamAppIdPath -PathType Leaf) -and
        ((Get-Content -LiteralPath $steamAppIdPath -Raw) -eq $preexistingSteamMarkerContent)
} else {
    -not (Test-Path -LiteralPath $steamAppIdPath)
}
$runStatus = [ordered]@{
    schemaVersion = 1
    session = $Session
    completedAt = (Get-Date).ToString('o')
    passed = $finalPassed -and -not $failure -and $settingsRestored
    failure = $failure
    gameExecutable = $game
    gameSha256 = $gameHash
    port = $Port
    soakTicks = $SoakTicks
    clockRunTicks = $ClockRunTicks
    requireVehicleSyncRound = $RequireVehicleSyncRound.IsPresent
    interactiveAfterValidation = $InteractiveAfterValidation.IsPresent
    manualOnly = $ManualOnly.IsPresent
    interactiveMinutes = $InteractiveMinutes
    operationalCaptureLab = $OperationalCaptureLab.IsPresent
    townDevelopment = $TownDevelopment.IsPresent
    agentMode = $AgentMode
    matchContentProfile = $matchContentProfilePath
    operationalSampleTicks = $OperationalSampleTicks
    operationalStartingCash = $OperationalStartingCash
    unattendedOperationalSeconds = $UnattendedOperationalSeconds
    nativeFreshWorld = $NativeFreshWorld.IsPresent
    startingSave = $StartingSave
    startingSaveCopy = $startingSaveCopy
    stagedStartingSave = $stagedStartingSave
    startingSaveManifest = $startingSaveManifest
    restorePlan = $restorePlanPath
    restoreBoundarySeq = if ($restorePlanData) { $restorePlanData.boundarySeq } else { $null }
    player1StartingSave = $Player1StartingSave
    player2StartingSave = $Player2StartingSave
    peerStartingSaveCopies = $peerStartingSaveCopies
    peerStagedStartingSaves = $peerStagedStartingSaves
    peerStartingCompanyPlayerIds = $peerStartingCompanyPlayerIds
    interactiveEvidenceCollected = $interactiveEvidenceCollected
    interactiveEvidenceError = $interactiveEvidenceError
    operationalAnalysisPath = $operationalAnalysisPath
    operationalAnalysisError = $operationalAnalysisError
    peer1GamePid = $peer1GamePid
    peer2GamePid = $peer2GamePid
    peer1Result = $peer1Payload
    peer2Result = $peer2Payload
    settingsRestored = $settingsRestored
    steamMarkerRestored = $steamMarkerClean
    temporaryBootstrapRemoved = if ($injectedBootstrap) {
        -not (Test-Path -LiteralPath $bootstrapTarget)
    } else { Test-Path -LiteralPath $bootstrapTarget -PathType Leaf }
    temporaryGameScriptRemoved = if ($gameScriptInjected) {
        -not (Test-Path -LiteralPath $injectedGameScript)
    } else { Test-Path -LiteralPath $injectedGameScript -PathType Leaf }
    temporaryLibraryRemoved = if ($libraryInjected) {
        -not (Test-Path -LiteralPath $injectedLibrary)
    } else { Test-Path -LiteralPath $injectedLibrary -PathType Container }
    temporaryStartingSaveRemoved = @($stagedStartingFiles | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0
    bridgeRoot = $bridgeBase
    evidenceRoot = $runRoot
}
$runStatus.passed = $runStatus.passed -and $steamMarkerClean -and $runStatus.temporaryBootstrapRemoved `
    -and $runStatus.temporaryGameScriptRemoved -and $runStatus.temporaryLibraryRemoved `
    -and $runStatus.temporaryStartingSaveRemoved
$runStatus | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $statusPath -Encoding UTF8
Write-Host "runStatus=$statusPath"
if (-not $runStatus.passed) {
    if (-not $failure) { $failure = 'Localhost validation did not satisfy every cleanup/evidence postcondition.' }
    throw $failure
}
if ($OperationalCaptureLab) {
    Write-Host 'PASS disposable two-instance operational capture lab'
}
elseif ($ManualOnly) { Write-Host 'PASS disposable two-instance manual localhost network lab' }
else { Write-Host 'PASS disposable two-instance localhost live validation' }
