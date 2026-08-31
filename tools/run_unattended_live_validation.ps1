[CmdletBinding()]
param(
    [int]$StartupDelaySeconds = 20,
    [int]$ValidationTimeoutSeconds = 720,
    [switch]$RunConsoleBuildProbe,
    [switch]$RunFacilityCustodyProbe,
    [switch]$RunAirFacilityProbe,
    [switch]$RunWaterFacilityProbe,
    [int]$ConsoleProbeTimeoutSeconds = 120,
    [switch]$NativeHook,
    [switch]$SkipNativeBuild,
    [int]$NativeWaitMilliseconds = 45000,
    [switch]$SkipTests,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2'
$gameExecutable = Join-Path $gameDirectory 'TransportFever2.exe'
$settingsPath = 'C:\Program Files (x86)\Steam\userdata\63389028\1066780\local\settings.lua'
$gameLog = 'C:\Program Files (x86)\Steam\userdata\63389028\1066780\local\crash_dump\stdout.txt'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$session = 'auto-live'
$runDirectory = Join-Path $projectRoot "runtime\live-validation\$stamp"
$bridgeBase = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_bridge'))
$bridgePath = [IO.Path]::GetFullPath((Join-Path $bridgeBase 'auto-live\player1'))
$settingsBackup = Join-Path $runDirectory 'settings-original.lua'
$statusPath = Join-Path $runDirectory 'run-status.json'
$researchPath = Join-Path $runDirectory 'research.md'
$checkpointPath = Join-Path $runDirectory 'checkpoint-replay.md'
$baseResourceRoot = [IO.Path]::GetFullPath((Join-Path $gameDirectory 'res'))
$injectedGameScript = [IO.Path]::GetFullPath((Join-Path $baseResourceRoot 'config\game_script\tpf2_mp.lua'))
$injectedLibrary = [IO.Path]::GetFullPath((Join-Path $baseResourceRoot 'scripts\tpf2_mp'))
$validationMarker = [IO.Path]::GetFullPath((Join-Path $bridgeBase 'auto-live\enable'))
$nativeBin = Join-Path $projectRoot 'runtime\native-build\Release'
$nativeInjector = Join-Path $nativeBin 'tpf2mp_injector.exe'
$nativeDll = Join-Path $nativeBin 'tpf2mp_hook_build35924.dll'
$process = $null
$failure = $null
$validationLine = $null
$validationPassed = $false
$consoleProbePassed = $false
$consoleProbeLine = $null
$settingsRestored = $false
$gameScriptInjected = $false
$libraryInjected = $false
$nativeHookStatus = $null
$nativeHookPassed = -not $NativeHook

function Set-MinimalValidationProfile([string]$Path) {
    $content = [IO.File]::ReadAllText($Path)
    $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $start = [regex]::Match($content, '(?m)^(?<indent>[ \t]*)activeMods[ \t]*=[ \t]*\{[ \t]*\r?$')
    if (-not $start.Success) { throw 'Could not locate activeMods in settings.lua' }
    $indent = $start.Groups['indent'].Value
    $tail = $content.Substring($start.Index + $start.Length)
    $closePattern = '(?m)^' + [regex]::Escape($indent) + '\},[ \t]*\r?$'
    $close = [regex]::Match($tail, $closePattern)
    if (-not $close.Success) { throw 'Could not locate the end of activeMods in settings.lua' }
    $endIndex = $start.Index + $start.Length + $close.Index + $close.Length
    $replacement = @(
        "${indent}activeMods = {"
        "${indent}`t{ `"urbangames_legacy_vehicle_pack`", 1, },"
        "${indent}`t{ `"_urbangames_deluxe_pack`", 1, },"
        "${indent}`t{ `"_urbangames_preorder_pack`", 1, },"
        "${indent}`t{ `"tpf2_mp`", 1, },"
        "${indent}},"
    ) -join $newline
    $updated = $content.Substring(0, $start.Index) + $replacement + $content.Substring($endIndex)
    if ($updated -match '\["tpf2_mp_1"\]') { throw 'Temporary TPF2MP mod parameters already exist in settings.lua' }
    $paramsStart = [regex]::Match($updated, '(?m)^(?<indent>[ \t]*)modParams[ \t]*=[ \t]*\{[ \t]*\r?$')
    if (-not $paramsStart.Success) { throw 'Could not locate modParams in settings.lua' }
    $paramsIndent = $paramsStart.Groups['indent'].Value
    $validationParams = @(
        ''
        "${paramsIndent}`t[`"tpf2_mp_1`"] = {"
        "${paramsIndent}`t`tliveValidator = 1,"
        "${paramsIndent}`t`tpauseOnSwitch = 1,"
        "${paramsIndent}`t`tproxyMode = 0,"
        "${paramsIndent}`t`tstartupMode = 0,"
        "${paramsIndent}`t},"
    ) -join $newline
    $updated = $updated.Insert($paramsStart.Index + $paramsStart.Length, $validationParams)
    $updated = [regex]::Replace(
        $updated,
        '(?m)^(?<prefix>[ \t]*autosaveIntervalMinutes[ \t]*=[ \t]*)\d+(?<suffix>[ \t]*,)',
        '${prefix}120${suffix}'
    )
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Start-GameThroughSteam {
    $steam = 'C:\Program Files (x86)\Steam\steam.exe'
    if (-not (Test-Path -LiteralPath $steam)) { throw "Steam executable not found: $steam" }
    Start-Process -FilePath $steam -ArgumentList '-applaunch', '1066780' | Out-Null
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $candidate = Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($candidate) {
            if ($NativeHook) {
                & $nativeInjector --pid $candidate.Id --dll $nativeDll --wait-ms $NativeWaitMilliseconds |
                    ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) { throw "Native hook injection failed with exit code $LASTEXITCODE" }
            }
            return $candidate
        }
        Start-Sleep -Milliseconds $(if ($NativeHook) { 50 } else { 500 })
    }
    throw 'Steam did not launch Transport Fever 2 within 120 seconds'
}

function Send-GameConsoleCommand([int]$ProcessId, [string]$Keys) {
    $action = if ($Keys -like 'app.quit*') { 'quit' } else { 'start' }
    $helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
    function Invoke-HiddenInput([string]$InputAction) {
        $result = Join-Path $runDirectory "ui-$InputAction-$([DateTime]::UtcNow.Ticks).json"
        $child = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
            '-GameProcessId', $ProcessId, '-Action', $InputAction, '-ResultPath', $result
        ) -WindowStyle Hidden -PassThru
        if (-not $child.WaitForExit(20000)) { throw "Hidden $InputAction helper timed out" }
        $child.Refresh()
        if ($child.ExitCode -ne 0) { throw "Hidden $InputAction helper exited $($child.ExitCode)" }
    }

    Invoke-HiddenInput $action
    Invoke-HiddenInput 'accept-down'
    if ($action -eq 'start') {
        $deadline = (Get-Date).AddSeconds(120)
        $started = $false
        while ((Get-Date) -lt $deadline -and (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
            if (Test-Path -LiteralPath $gameLog) {
                $text = Get-Content -Raw -LiteralPath $gameLog
                if ($text -match '\[TPF2MP\].*"event":"engine-init".*"session":"auto-live"') {
                    $started = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 500
        }
        if (-not $started) { throw 'Game did not reach the TPF2MP engine-init marker after console start' }
        Invoke-HiddenInput 'accept-up'
    }
}

function Wait-ForProcessWindow([Diagnostics.Process]$GameProcess, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($GameProcess.HasExited) { throw "Transport Fever 2 exited before its window opened (exit $($GameProcess.ExitCode))" }
        $GameProcess.Refresh()
        if ($GameProcess.MainWindowHandle -ne 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'Timed out waiting for the Transport Fever 2 window'
}

function Request-GameQuit([Diagnostics.Process]$GameProcess) {
    if (-not $GameProcess -or $GameProcess.HasExited) { return }
    try { Send-GameConsoleCommand -ProcessId $GameProcess.Id -Keys 'app.quit{(}{)}' }
    catch { Write-Warning "Graceful console quit failed: $($_.Exception.Message)" }
    try {
        if (-not $GameProcess.WaitForExit(8000)) {
            Write-Warning "Transport Fever 2 did not quit in 8 seconds; stopping only process $($GameProcess.Id)."
            Stop-Process -Id $GameProcess.Id -Force
            $GameProcess.WaitForExit(10000) | Out-Null
        }
    }
    catch { Write-Warning "Could not finish process cleanup: $($_.Exception.Message)" }
}

New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
$requiredBridgePrefix = $bridgeBase.TrimEnd('\') + '\'
if (-not $bridgePath.StartsWith($requiredBridgePrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to reset bridge outside $bridgeBase"
}
if (Test-Path -LiteralPath $bridgePath) { Remove-Item -LiteralPath $bridgePath -Recurse -Force }
foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit',
        'content\industry')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bridgePath $folder) | Out-Null
}

try {
    if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
        throw 'Transport Fever 2 is already running; refusing to touch its active settings.'
    }
    if (-not (Test-Path -LiteralPath $gameExecutable)) { throw "Game executable not found: $gameExecutable" }
    if (-not (Test-Path -LiteralPath $settingsPath)) { throw "Settings file not found: $settingsPath" }

    if ($NativeHook) {
        if (-not $SkipNativeBuild) {
            & (Join-Path $PSScriptRoot 'build_native_hook.ps1') -GameExecutable $gameExecutable
            if ($LASTEXITCODE -ne 0) { throw "Native hook build failed with exit code $LASTEXITCODE" }
        }
        foreach ($requiredPath in @($nativeInjector, $nativeDll)) {
            if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Required native path is missing: $requiredPath" }
        }
    }

    if (-not $SkipTests) {
        & (Join-Path $PSScriptRoot 'run_tests.ps1')
        if (-not $?) { throw 'Automated tests failed.' }
    }
    if (-not $SkipInstall) {
        & (Join-Path $PSScriptRoot 'install.ps1')
        if (-not $?) { throw 'Mod installation failed.' }
    }
    if ($NativeHook) {
        & (Join-Path $PSScriptRoot 'make_manifest.ps1') -ExtraPath @($nativeInjector, $nativeDll)
    } else {
        & (Join-Path $PSScriptRoot 'make_manifest.ps1')
    }
    if (-not $?) { throw 'Manifest generation failed.' }

    Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup
    Set-MinimalValidationProfile -Path $settingsPath
    Write-Host "Disposable profile active; exact settings backup: $settingsBackup"

    $resourcePrefix = $baseResourceRoot.TrimEnd('\') + '\'
    foreach ($target in @($injectedGameScript, $injectedLibrary)) {
        if (-not $target.StartsWith($resourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing temporary injection outside $baseResourceRoot"
        }
        if (Test-Path -LiteralPath $target) { throw "Temporary injection target already exists: $target" }
    }
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\config\game_script\tpf2_mp.lua') -Destination $injectedGameScript
    $gameScriptInjected = $true
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp') -Destination $injectedLibrary -Recurse
    $libraryInjected = $true
    if ($RunConsoleBuildProbe -or $RunFacilityCustodyProbe -or $RunAirFacilityProbe -or
        $RunWaterFacilityProbe) {
        $probeSource = Join-Path $projectRoot 'investigation\live_console_probe.lua'
        if (-not (Test-Path -LiteralPath $probeSource)) { throw "Console build probe is missing: $probeSource" }
        Copy-Item -LiteralPath $probeSource -Destination (Join-Path $injectedLibrary 'live_console_probe.lua')
    }
    Set-Content -LiteralPath $validationMarker -Value $stamp -Encoding ASCII
    Write-Host 'Installed a temporary base-resource copy because app.startGame() intentionally ignores active mods.'

    $process = Start-GameThroughSteam
    Write-Host "Transport Fever 2 process=$($process.Id) session=$session"

    Wait-ForProcessWindow -GameProcess $process -TimeoutSeconds 120
    Start-Sleep -Seconds $StartupDelaySeconds
    Send-GameConsoleCommand -ProcessId $process.Id -Keys 'app.startGame{(}{)}'
    Write-Host 'Issued app.startGame() for an unsaved disposable default world.'

    # The turn proxy may intentionally pause after its first lease. Wait for
    # the engine's explicit result and resume only when it says it paused;
    # blindly pressing Space could pause an already-running game.
    $initDeadline = (Get-Date).AddSeconds(20)
    $initLine = $null
    while ((Get-Date) -lt $initDeadline -and -not $process.HasExited) {
        if (Test-Path -LiteralPath $gameLog) {
            $text = Get-Content -Raw -LiteralPath $gameLog
            $initMatch = [regex]::Matches($text, '(?m)^.*\[TPF2MP\].*"event":"auto-validation-init".*$')
            if ($initMatch.Count -gt 0) { $initLine = $initMatch[-1].Value; break }
        }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    if ($initLine -and $initLine -match '"turnPaused":true') {
        $helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
        $resumeResult = Join-Path $runDirectory "ui-resume-$([DateTime]::UtcNow.Ticks).json"
        $resume = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
            '-GameProcessId', $process.Id, '-Action', 'resume', '-ResultPath', $resumeResult
        ) -WindowStyle Hidden -PassThru
        if (-not $resume.WaitForExit(20000)) { throw 'Hidden resume helper timed out' }
        $resume.Refresh()
        if ($resume.ExitCode -ne 0) { throw "Hidden resume helper exited $($resume.ExitCode)" }
        Write-Host 'Resumed the validator after its intentional first proxy pause.'
    }
    elseif (-not $initLine) {
        Write-Warning 'Pause-detection marker was not observed in time; continuing with the authoritative completion marker.'
    }

    $deadline = (Get-Date).AddSeconds($ValidationTimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        if (Test-Path -LiteralPath $gameLog) {
            $logText = Get-Content -Raw -LiteralPath $gameLog
            $matches = @([regex]::Matches($logText, '(?m)^.*\[TPF2MP\].*"event":"auto-validation-complete".*$'))
            if ($matches.Count -gt 0) {
                $validationLine = $matches[-1].Value
                $validationPassed = $validationLine -match '"success":true'
                break
            }
        }
        Start-Sleep -Seconds 2
        $process.Refresh()
    }
    if (-not $validationLine) {
        if ($process.HasExited) { throw "Transport Fever 2 exited before validation completed (exit $($process.ExitCode))" }
        throw "Timed out after $ValidationTimeoutSeconds seconds waiting for the validation marker"
    }
    Write-Host $validationLine
    if (-not $validationPassed) { $failure = 'The in-game validator completed with a failed check.' }

    if ($NativeHook -and $validationPassed) {
        $nativeStatusSource = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native') "status-$($process.Id).json"
        $nativeDeadline = (Get-Date).AddSeconds(5)
        $nativeCommandCalls = 0
        do {
            if (Test-Path -LiteralPath $nativeStatusSource) {
                $nativeHookStatus = Get-Content -Raw -LiteralPath $nativeStatusSource | ConvertFrom-Json
                $nativeCommandCalls = (@($nativeHookStatus.luaStates) | Measure-Object -Property commandCalls -Sum).Sum
                if ($nativeCommandCalls -gt 0 -and $nativeHookStatus.commandList.commands -gt 0 -and
                    $nativeHookStatus.applyCommand.calls -gt 0) { break }
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $nativeDeadline)
        if ($nativeHookStatus) {
            Copy-Item -LiteralPath $nativeStatusSource -Destination (Join-Path $runDirectory 'native-hook-status.json') -Force
        }
        $nativeHookPassed = $nativeHookStatus -and
            $nativeHookStatus.hookVersion -eq '0.19.0' -and
            $nativeHookStatus.active -eq $true -and
            $nativeHookStatus.hooks.enabled -eq $true -and
            $nativeHookStatus.hooks.commandListSwap -eq $true -and
            $nativeHookStatus.hooks.applyCommand -eq $true -and
            $nativeHookStatus.hooks.buildProposalVisitor -eq $true -and
            $nativeHookStatus.hooks.authorityCommandVisitors -eq 31 -and
            @($nativeHookStatus.luaStates | Where-Object { $_.sendCommandWrapped -eq $true }).Count -gt 0 -and
            @($nativeHookStatus.luaStates | Where-Object { $_.commandObserverRegistered -eq $true }).Count -gt 0 -and
            $nativeCommandCalls -gt 0 -and
            $nativeHookStatus.commandList.commands -gt 0 -and
            $nativeHookStatus.commandList.invalidLayouts -eq 0 -and
            $nativeHookStatus.commandList.unknownTags -eq 0 -and
            $nativeHookStatus.commandList.pendingOverwrites -eq 0 -and
            $nativeHookStatus.applyCommand.calls -gt 0 -and
            $nativeHookStatus.applyCommand.unknownTags -eq 0 -and
            $nativeHookStatus.applyCommand.unknown -eq 0 -and
            ($nativeHookStatus.applyCommand.calls + $nativeHookStatus.commandList.pendingCommands) -eq
                ($nativeHookStatus.commandList.commands + $nativeHookStatus.applyCommand.direct) -and
            $nativeHookStatus.applyCommand.tagMismatches -eq 0 -and
            $nativeHookStatus.gates.commandVisitors.hooked -eq 31 -and
            $nativeHookStatus.gates.commandVisitors.enabled -eq $false -and
            $nativeHookStatus.gates.commandVisitors.tagMismatches -eq 0 -and
            @($nativeHookStatus.commandEvents).Count -gt 0
        if (-not $nativeHookPassed) { throw 'Native hook did not remain active or forward a real mod command.' }
        $nativeObserverStates = @($nativeHookStatus.luaStates | Where-Object { $_.commandObserverRegistered -eq $true }).Count
        Write-Host "Native hook mod integration passed; observer states=$nativeObserverStates, wrapped calls=$nativeCommandCalls, queued=$($nativeHookStatus.commandList.commands), applied=$($nativeHookStatus.applyCommand.calls)"
    }

    if (($RunConsoleBuildProbe -or $RunFacilityCustodyProbe -or $RunAirFacilityProbe -or
        $RunWaterFacilityProbe) -and $validationPassed) {
        $helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
        function Invoke-ProbeInput([string]$InputAction, [string]$InputCommand, [switch]$SkipClick) {
            $probeInputResult = Join-Path $runDirectory "ui-console-build-probe-$InputAction-$([DateTime]::UtcNow.Ticks).json"
            $inputArguments = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
                '-GameProcessId', $process.Id, '-Action', $InputAction,
                '-DelayMilliseconds', 250, '-ResultPath', $probeInputResult
            )
            if ($InputCommand) { $inputArguments += @('-Command', $InputCommand) }
            if ($SkipClick) { $inputArguments += '-SkipConsoleClick' }
            $probeInput = Start-Process -FilePath 'powershell.exe' -ArgumentList $inputArguments -WindowStyle Hidden -PassThru
            if (-not $probeInput.WaitForExit(30000)) { throw "Hidden $InputAction input timed out" }
            $probeInput.Refresh()
            if ($probeInput.ExitCode -ne 0) { throw "Hidden $InputAction input exited $($probeInput.ExitCode)" }
        }

        # app.startGame preserves Build 35924's console overlay but the new
        # world does not preserve its keyboard focus. Close and reopen it to
        # establish a known-focused prompt; clicking the prompt loses focus.
        Invoke-ProbeInput -InputAction 'toggle-console'
        Start-Sleep -Milliseconds 500
        $probeCommand = if ($RunWaterFacilityProbe) {
            'require[[tpf2_mp/live_console_probe]].runWaterFacilityTest()'
        } elseif ($RunAirFacilityProbe) {
            'require[[tpf2_mp/live_console_probe]].runAirFacilityTest()'
        } elseif ($RunFacilityCustodyProbe) {
            'require[[tpf2_mp/live_console_probe]].runFacilityCustodyTest()'
        } else {
            'require[[tpf2_mp/live_console_probe]].run()'
        }
        $probeCompletionEvent = if ($RunWaterFacilityProbe) {
            'water-facility-complete'
        } elseif ($RunAirFacilityProbe) {
            'air-facility-complete'
        } elseif ($RunFacilityCustodyProbe) {
            'facility-custody-complete'
        } else {
            'build-complete'
        }
        Invoke-ProbeInput -InputAction 'custom-stage' -InputCommand $probeCommand -SkipClick
        Invoke-ProbeInput -InputAction 'accept-down'
        Start-Sleep -Milliseconds 650
        Invoke-ProbeInput -InputAction 'accept-up'
        Start-Sleep -Milliseconds 500
        Invoke-ProbeInput -InputAction 'toggle-console'
        Write-Host $(if ($RunWaterFacilityProbe) {
            'Issued the disposable stock-harbor construction probe from the console state.'
        } elseif ($RunAirFacilityProbe) {
            'Issued the disposable stock-airport construction probe from the console state.'
        } elseif ($RunFacilityCustodyProbe) {
            'Issued the disposable native depot/station custody probe from the console state.'
        } else {
            'Issued the supported-API disposable road-build probe from the console state.'
        })

        $probeDeadline = (Get-Date).AddSeconds($ConsoleProbeTimeoutSeconds)
        $airMovementSampleIssued = $false
        $waterMovementSampleIssued = $false
        while ((Get-Date) -lt $probeDeadline -and -not $process.HasExited) {
            if (Test-Path -LiteralPath $gameLog) {
                $probeText = Get-Content -Raw -LiteralPath $gameLog
                if ($RunAirFacilityProbe -and -not $airMovementSampleIssued) {
                    $readyPattern = '(?m)^.*\[TPF2MP-CONSOLE-PROBE\].*"event":"air-facility-ready".*$'
                    $readyMatches = @([regex]::Matches($probeText, $readyPattern))
                    if ($readyMatches.Count -gt 0) {
                        $airMovementSampleIssued = $true
                        Write-Host $readyMatches[-1].Value
                        Start-Sleep -Seconds 25
                        Invoke-ProbeInput -InputAction 'toggle-console'
                        Start-Sleep -Milliseconds 500
                        Invoke-ProbeInput -InputAction 'custom-stage' `
                            -InputCommand 'require[[tpf2_mp/live_console_probe]].finishAirFacilityTest()' `
                            -SkipClick
                        Invoke-ProbeInput -InputAction 'accept-down'
                        Start-Sleep -Milliseconds 650
                        Invoke-ProbeInput -InputAction 'accept-up'
                        Start-Sleep -Milliseconds 500
                        Invoke-ProbeInput -InputAction 'toggle-console'
                    }
                }
                if ($RunWaterFacilityProbe -and -not $waterMovementSampleIssued) {
                    $readyPattern = '(?m)^.*\[TPF2MP-CONSOLE-PROBE\].*"event":"water-facility-ready".*$'
                    $readyMatches = @([regex]::Matches($probeText, $readyPattern))
                    if ($readyMatches.Count -gt 0) {
                        $waterMovementSampleIssued = $true
                        Write-Host $readyMatches[-1].Value
                        Start-Sleep -Seconds 40
                        Invoke-ProbeInput -InputAction 'toggle-console'
                        Start-Sleep -Milliseconds 500
                        Invoke-ProbeInput -InputAction 'custom-stage' `
                            -InputCommand 'require[[tpf2_mp/live_console_probe]].finishWaterFacilityTest()' `
                            -SkipClick
                        Invoke-ProbeInput -InputAction 'accept-down'
                        Start-Sleep -Milliseconds 650
                        Invoke-ProbeInput -InputAction 'accept-up'
                        Start-Sleep -Milliseconds 500
                        Invoke-ProbeInput -InputAction 'toggle-console'
                    }
                }
                $probePattern = '(?m)^.*\[TPF2MP-CONSOLE-PROBE\].*"event":"' +
                    [regex]::Escape($probeCompletionEvent) + '".*$'
                $probeMatches = @([regex]::Matches($probeText, $probePattern))
                if ($probeMatches.Count -gt 0) {
                    $consoleProbeLine = $probeMatches[-1].Value
                    $probeJsonStart = $consoleProbeLine.IndexOf('{')
                    if ($probeJsonStart -lt 0) { throw 'Console probe marker did not contain JSON.' }
                    $probePayload = $consoleProbeLine.Substring($probeJsonStart) | ConvertFrom-Json
                    $consoleProbePassed = $probePayload.success -eq $true
                    break
                }
            }
            Start-Sleep -Seconds 1
            $process.Refresh()
        }
        if (-not $consoleProbeLine) { throw "Timed out after $ConsoleProbeTimeoutSeconds seconds waiting for build-probe completion" }
        Write-Host $consoleProbeLine
        if (-not $consoleProbePassed) {
            throw $(if ($RunWaterFacilityProbe) {
                'The disposable stock-harbor construction probe failed.'
            } elseif ($RunAirFacilityProbe) {
                'The disposable stock-airport construction probe failed.'
            } elseif ($RunFacilityCustodyProbe) {
                'The disposable depot/station custody probe failed.'
            } else {
                'The disposable supported-API road-build probe failed.'
            })
        }
        Start-Sleep -Seconds 8
    }
}
catch {
    $failure = $_.Exception.Message
    Write-Warning $failure
}
finally {
    Request-GameQuit -GameProcess $process
    Remove-Item -LiteralPath $validationMarker -Force -ErrorAction SilentlyContinue
    if ($gameScriptInjected -and (Test-Path -LiteralPath $injectedGameScript)) {
        Remove-Item -LiteralPath $injectedGameScript -Force
    }
    if ($libraryInjected -and (Test-Path -LiteralPath $injectedLibrary)) {
        Remove-Item -LiteralPath $injectedLibrary -Recurse -Force
    }
    if (Test-Path -LiteralPath $settingsBackup) {
        Copy-Item -LiteralPath $settingsBackup -Destination $settingsPath -Force
        $settingsRestored = (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsBackup).Hash -eq
            (Get-FileHash -Algorithm SHA256 -LiteralPath $settingsPath).Hash
        if (-not $settingsRestored) { Write-Warning 'Settings restoration hash mismatch.' }
        else { Write-Host 'Original settings.lua restored byte-for-byte.' }
    }
}

try {
    & (Join-Path $PSScriptRoot 'collect_live_evidence.ps1') -Peer player1 -Session $session -BridgePath $bridgePath -OutputDirectory $runDirectory
}
catch { Write-Warning "Evidence collection failed: $($_.Exception.Message)" }
try {
    & (Join-Path $PSScriptRoot 'make_research_report.ps1') -Peer player1 -Session $session -BridgePath $bridgePath -OutputPath $researchPath
}
catch { Write-Warning "Research report rendering failed: $($_.Exception.Message)" }
try {
    & (Join-Path $PSScriptRoot 'make_checkpoint_report.ps1') -Peer player1 -Session $session -BridgePath $bridgePath -Anchor first -OutputPath $checkpointPath
}
catch { Write-Warning "Checkpoint/replay report rendering failed: $($_.Exception.Message)" }

$consoleProbeRequested = $RunConsoleBuildProbe -or $RunFacilityCustodyProbe -or
    $RunAirFacilityProbe -or $RunWaterFacilityProbe
$overallPassed = $validationPassed -and $nativeHookPassed -and
    (-not $consoleProbeRequested -or $consoleProbePassed)
$status = [ordered]@{
    schemaVersion = 1
    session = $session
    capturedAt = (Get-Date).ToString('o')
    passed = $overallPassed
    failure = $failure
    validationLine = $validationLine
    consoleProbeRequested = $consoleProbeRequested
    consoleProbeMode = if ($RunWaterFacilityProbe) { 'water-facility' } elseif ($RunAirFacilityProbe) { 'air-facility' } elseif ($RunFacilityCustodyProbe) { 'facility-custody' } elseif ($RunConsoleBuildProbe) { 'road-build' } else { $null }
    consoleProbePassed = $consoleProbePassed
    consoleProbeLine = $consoleProbeLine
    nativeHookRequested = [bool]$NativeHook
    nativeHookPassed = $nativeHookPassed
    nativeHookStatus = $nativeHookStatus
    settingsBackup = $settingsBackup
    settingsRestored = $settingsRestored
    bridgePath = $bridgePath
    researchPath = if (Test-Path -LiteralPath $researchPath) { $researchPath } else { $null }
    checkpointPath = if (Test-Path -LiteralPath $checkpointPath) { $checkpointPath } else { $null }
}
$status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8
Write-Host "runStatus=$statusPath"

if ($failure) { throw $failure }
if (-not $overallPassed) { throw 'Live validation did not pass.' }
Write-Host 'PASS unattended Transport Fever 2 live validation'
