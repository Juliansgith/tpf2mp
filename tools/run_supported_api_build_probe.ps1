[CmdletBinding()]
param(
    [int]$StartupDelaySeconds = 20,
    [int]$WorldReadyTimeoutSeconds = 180,
    [int]$ProbeTimeoutSeconds = 120,
    [switch]$CapabilityOnly,
    [switch]$BuildGateTest,
    [switch]$CommandGateTest,
    [switch]$TrackBuildTest,
    [switch]$SignalTest,
    [switch]$SignalGuiCaptureTest,
    [switch]$OwnershipTransferTest,
    [switch]$ProposalOwnershipTest,
    [switch]$StationUpgradeCodecTest,
    [switch]$VehiclePurchaseTest,
    [switch]$NativeHook,
    [switch]$SkipNativeBuild,
    [int]$NativeWaitMilliseconds = 45000
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$gameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2'
$gameExecutable = Join-Path $gameDirectory 'TransportFever2.exe'
$steamExecutable = 'C:\Program Files (x86)\Steam\steam.exe'
$localGameRoot = 'C:\Program Files (x86)\Steam\userdata\63389028\1066780\local'
$gameLog = Join-Path $localGameRoot 'crash_dump\stdout.txt'
$settingsPath = Join-Path $localGameRoot 'settings.lua'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDirectory = Join-Path $projectRoot "runtime\supported-api-probe\$stamp"
$statusPath = Join-Path $runDirectory 'run-status.json'
$bootstrapTarget = [IO.Path]::GetFullPath((Join-Path $gameDirectory 'res\config\game_script\tpf2_mp_probe.lua'))
$scriptsRoot = [IO.Path]::GetFullPath((Join-Path $gameDirectory 'res\scripts'))
$libraryTarget = [IO.Path]::GetFullPath((Join-Path $scriptsRoot 'tpf2_mp_probe'))
$helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
$nativeBuild = Join-Path $PSScriptRoot 'build_native_hook.ps1'
$nativeBin = Join-Path $projectRoot 'runtime\native-build\Release'
$nativeInjector = Join-Path $nativeBin 'tpf2mp_injector.exe'
$nativeDll = Join-Path $nativeBin 'tpf2mp_hook_build35924.dll'

$process = $null
$bootstrapInjected = $false
$libraryInjected = $false
$acceptHeld = $false
$failure = $null
$worldReadyLine = $null
$capabilitiesLine = $null
$probeLine = $null
$probePassed = $false
$nativeHookStatus = $null
$nativeHookPassed = -not $NativeHook

function Start-GameThroughSteam {
    Start-Process -FilePath $steamExecutable -ArgumentList '-applaunch', '1066780' | Out-Null
    $launchDeadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $launchDeadline) {
        $candidate = Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue |
            Sort-Object StartTime -Descending | Select-Object -First 1
        if ($candidate) {
            if ($NativeHook) {
                & $nativeInjector --pid $candidate.Id --dll $nativeDll --wait-ms $NativeWaitMilliseconds |
                    ForEach-Object { Write-Host $_ }
                if ($LASTEXITCODE -ne 0) {
                    throw "Native hook injection failed with exit code $LASTEXITCODE"
                }
            }
            return $candidate
        }
        Start-Sleep -Milliseconds 50
    }
    throw 'Steam did not launch Transport Fever 2 within 120 seconds'
}

function Wait-ForProcessWindow([Diagnostics.Process]$GameProcess) {
    $windowDeadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $windowDeadline) {
        if ($GameProcess.HasExited) { throw 'Transport Fever 2 exited before its window opened' }
        $GameProcess.Refresh()
        if ($GameProcess.MainWindowHandle -ne 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw 'Timed out waiting for the Transport Fever 2 window'
}

function Invoke-GameInput(
    [string]$InputAction,
    [string]$InputCommand,
    [switch]$SkipConsoleClick,
    [string]$ScreenshotPath,
    [int]$ClientX = -1,
    [int]$ClientY = -1,
    [int]$UiWidth = -1,
    [int]$UiHeight = -1
) {
    $resultPath = Join-Path $runDirectory "ui-$InputAction-$([DateTime]::UtcNow.Ticks).json"
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper,
        '-GameProcessId', $process.Id, '-Action', $InputAction,
        '-DelayMilliseconds', 250, '-ResultPath', $resultPath
    )
    if ($InputCommand) { $arguments += @('-Command', $InputCommand) }
    if ($SkipConsoleClick) { $arguments += '-SkipConsoleClick' }
    if ($ScreenshotPath) { $arguments += @('-ScreenshotPath', $ScreenshotPath) }
    if ($ClientX -ge 0) { $arguments += @('-ClientX', $ClientX) }
    if ($ClientY -ge 0) { $arguments += @('-ClientY', $ClientY) }
    if ($UiWidth -gt 0) { $arguments += @('-UiWidth', $UiWidth) }
    if ($UiHeight -gt 0) { $arguments += @('-UiHeight', $UiHeight) }
    $child = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    if (-not $child.WaitForExit(30000)) { throw "Hidden $InputAction helper timed out" }
    $child.Refresh()
    if ($child.ExitCode -ne 0) { throw "Hidden $InputAction helper exited $($child.ExitCode)" }
}

function Find-LatestMarker([string]$Event) {
    if (-not (Test-Path -LiteralPath $gameLog)) { return $null }
    $logText = Get-Content -Raw -LiteralPath $gameLog
    $pattern = '(?m)^.*\[TPF2MP-CONSOLE-PROBE\].*"event":"' + [regex]::Escape($Event) + '".*$'
    $matches = @([regex]::Matches($logText, $pattern))
    if ($matches.Count -eq 0) { return $null }
    return $matches[-1].Value
}

function Invoke-StagedConsoleCommand([string]$Command) {
    Invoke-GameInput -InputAction 'toggle-console'
    Start-Sleep -Milliseconds 500
    Invoke-GameInput -InputAction 'custom-stage' -InputCommand $Command -SkipConsoleClick
    Invoke-GameInput -InputAction 'accept-down'
    Start-Sleep -Milliseconds 650
    Invoke-GameInput -InputAction 'accept-up'
    Start-Sleep -Milliseconds 350
    Invoke-GameInput -InputAction 'toggle-console'
}

function Wait-ForProbeMarker([string]$Event, [int]$TimeoutSeconds) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline -and -not $process.HasExited) {
        $line = Find-LatestMarker -Event $Event
        if ($line) { return $line }
        Start-Sleep -Milliseconds 250
        $process.Refresh()
    }
    return $null
}

function ConvertFrom-ProbeMarker([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return $null }
    $jsonStart = $Line.IndexOf('{')
    if ($jsonStart -lt 0) { return $null }
    return ($Line.Substring($jsonStart) | ConvertFrom-Json)
}

function Invoke-ProbeLogicalClick($Payload, [string]$Label) {
    $point = $Payload.logicalClick
    if (-not $point -or $point.width -le 0 -or $point.height -le 0) {
        throw "$Label did not expose a usable GUI click rectangle"
    }
    Invoke-GameInput -InputAction 'click-ui' `
        -ClientX ([Math]::Round($point.x)) -ClientY ([Math]::Round($point.y)) `
        -UiWidth ([Math]::Round($point.width)) -UiHeight ([Math]::Round($point.height))
    Write-Host "Physically clicked $Label at UI $([Math]::Round($point.x)),$([Math]::Round($point.y))."
}

New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null

try {
    $exclusiveModeCount = @($CapabilityOnly, $BuildGateTest, $CommandGateTest, $TrackBuildTest, $SignalTest, $SignalGuiCaptureTest, $OwnershipTransferTest, $ProposalOwnershipTest, $StationUpgradeCodecTest, $VehiclePurchaseTest).Where({ $_ }).Count
    if ($exclusiveModeCount -gt 1) {
        throw '-CapabilityOnly, -BuildGateTest, -CommandGateTest, -TrackBuildTest, -SignalTest, -SignalGuiCaptureTest, -OwnershipTransferTest, -ProposalOwnershipTest, -StationUpgradeCodecTest, and -VehiclePurchaseTest are mutually exclusive.'
    }
    if (($BuildGateTest -or $CommandGateTest) -and -not $NativeHook) {
        throw '-BuildGateTest and -CommandGateTest require -NativeHook.'
    }
    if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
        throw 'Transport Fever 2 is already running; refusing to start an overlapping probe.'
    }
    foreach ($requiredPath in @($gameExecutable, $steamExecutable, $settingsPath, $helper)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required path is missing: $requiredPath" }
    }
    if ($NativeHook) {
        if (-not $SkipNativeBuild) {
            & $nativeBuild -GameExecutable $gameExecutable
            if ($LASTEXITCODE -ne 0) { throw "Native hook build failed with exit code $LASTEXITCODE" }
        }
        foreach ($requiredPath in @($nativeInjector, $nativeDll)) {
            if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Required native path is missing: $requiredPath" }
        }
    }

    $requiredScriptsPrefix = $scriptsRoot.TrimEnd('\') + '\'
    if (-not $libraryTarget.StartsWith($requiredScriptsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing temporary injection outside $scriptsRoot"
    }
    if (Test-Path -LiteralPath $bootstrapTarget) { throw "Temporary bootstrap target already exists: $bootstrapTarget" }
    if (Test-Path -LiteralPath $libraryTarget) { throw "Temporary library target already exists: $libraryTarget" }

    Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $runDirectory 'settings-before.lua')
    Copy-Item -LiteralPath (Join-Path $projectRoot 'investigation\live_probe_bootstrap.lua') -Destination $bootstrapTarget
    $bootstrapInjected = $true
    New-Item -ItemType Directory -Path $libraryTarget | Out-Null
    $libraryInjected = $true
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\util.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\json.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\hash.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\canonical.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\proposal_codec.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\operation_codec.lua') -Destination $libraryTarget
    Copy-Item -LiteralPath (Join-Path $projectRoot 'investigation\live_console_probe.lua') -Destination $libraryTarget
    Write-Host "Minimal probe resources injected; evidence directory: $runDirectory"

    $process = Start-GameThroughSteam
    Wait-ForProcessWindow -GameProcess $process
    Write-Host "Transport Fever 2 process=$($process.Id)"
    if ($SignalGuiCaptureTest) {
        Invoke-GameInput -InputAction 'maximize'
    }
    Start-Sleep -Seconds $StartupDelaySeconds

    Invoke-GameInput -InputAction 'start'
    Invoke-GameInput -InputAction 'accept-down'
    $acceptHeld = $true
    $worldDeadline = (Get-Date).AddSeconds($WorldReadyTimeoutSeconds)
    while ((Get-Date) -lt $worldDeadline -and -not $process.HasExited) {
        $worldReadyLine = Find-LatestMarker -Event 'world-ready'
        if ($worldReadyLine) { break }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    if (-not $worldReadyLine) {
        if ($process.HasExited) { throw 'Transport Fever 2 exited before the minimal world-ready marker' }
        throw "Timed out after $WorldReadyTimeoutSeconds seconds waiting for the minimal world-ready marker"
    }
    Invoke-GameInput -InputAction 'accept-up'
    $acceptHeld = $false
    Write-Host $worldReadyLine
    Start-Sleep -Seconds 4

    # app.startGame preserves the console overlay but the new world does not
    # preserve its keyboard focus. Close it, then reopen it through the staged
    # action so the prompt is known-focused before typing.
    Invoke-GameInput -InputAction 'toggle-console'
    Start-Sleep -Milliseconds 500
    Invoke-GameInput -InputAction 'custom-stage' `
        -InputCommand $(if ($CapabilityOnly) {
            "require('tpf2_mp_probe/live_console_probe').capabilities()"
        } elseif ($BuildGateTest) {
            "require('tpf2_mp_probe/live_console_probe').runGateTest()"
        } elseif ($CommandGateTest) {
            "require('tpf2_mp_probe/live_console_probe').runCommandGateTest()"
        } elseif ($TrackBuildTest) {
            "require('tpf2_mp_probe/live_console_probe').runTrackTest()"
        } elseif ($SignalTest) {
            "require('tpf2_mp_probe/live_console_probe').runSignalTest()"
        } elseif ($SignalGuiCaptureTest) {
            "require('tpf2_mp_probe/live_console_probe').runSignalGuiSetup()"
        } elseif ($OwnershipTransferTest) {
            "require('tpf2_mp_probe/live_console_probe').runOwnershipTest()"
        } elseif ($ProposalOwnershipTest) {
            "require('tpf2_mp_probe/live_console_probe').runProposalOwnershipTest()"
        } elseif ($StationUpgradeCodecTest) {
            "require('tpf2_mp_probe/live_console_probe').runStationUpgradeCodecTest()"
        } elseif ($VehiclePurchaseTest) {
            "require('tpf2_mp_probe/live_console_probe').runVehiclePurchaseTest()"
        } else {
            "require('tpf2_mp_probe/live_console_probe').run({followup=false})"
        }) -SkipConsoleClick
    Invoke-GameInput -InputAction 'accept-down'
    $acceptHeld = $true
    Start-Sleep -Milliseconds 650
    Invoke-GameInput -InputAction 'accept-up'
    $acceptHeld = $false
    Start-Sleep -Milliseconds 500
    Invoke-GameInput -InputAction 'toggle-console'
    Write-Host $(if ($CapabilityOnly) {
        'Issued the isolated capability probe.'
    } elseif ($BuildGateTest) {
        'Issued the native BuildProposal gate/authorization test in the isolated disposable world.'
    } elseif ($CommandGateTest) {
        'Issued the native consequential-command visitor gate/authorization test in the isolated disposable world.'
    } elseif ($TrackBuildTest) {
        'Issued normal and electrified supported-API track proposals in the isolated disposable world.'
    } elseif ($SignalTest) {
        'Issued a typed signal add/remove sequence on a fresh track in the isolated disposable world.'
    } elseif ($SignalGuiCaptureTest) {
        'Preparing a genuine GUI signal click on a camera-focused disposable track.'
    } elseif ($OwnershipTransferTest) {
        'Issued the symmetric road ownership-transfer test in the isolated disposable world.'
    } elseif ($ProposalOwnershipTest) {
        'Issued the proposal-based road ownership round-trip in the isolated disposable world.'
    } elseif ($StationUpgradeCodecTest) {
        'Issued the canonical station-upgrade materialization test in the isolated disposable world.'
    } elseif ($VehiclePurchaseTest) {
        'Issued the exact NOHAB plus two BC4 canonical purchase test in the isolated disposable world.'
    } else {
        'Issued one supported-API road proposal in the isolated disposable world.'
    })

    if ($SignalGuiCaptureTest) {
        $railReadyLine = Wait-ForProbeMarker -Event 'signal-gui-rail-ready' -TimeoutSeconds $ProbeTimeoutSeconds
        if (-not $railReadyLine) { throw 'Timed out waiting for disposable GUI rail-menu setup' }
        Write-Host $railReadyLine
        if ($railReadyLine -notmatch '"success":true') {
            Invoke-GameInput -InputAction 'inspect' -ScreenshotPath (Join-Path $runDirectory 'signal-tool-selection.png')
            throw 'Disposable GUI rail-menu setup completed with success=false'
        }
        Start-Sleep -Milliseconds 750
        Invoke-StagedConsoleCommand -Command "require('tpf2_mp_probe/live_console_probe').selectSignalGuiCategory()"
        $categoryReadyLine = Wait-ForProbeMarker -Event 'signal-gui-category-ready' -TimeoutSeconds $ProbeTimeoutSeconds
        if (-not $categoryReadyLine) { throw 'Timed out waiting for disposable GUI signal-category setup' }
        Write-Host $categoryReadyLine
        if ($categoryReadyLine -notmatch '"success":true') {
            Invoke-GameInput -InputAction 'inspect' -ScreenshotPath (Join-Path $runDirectory 'signal-category-selection.png')
            throw 'Disposable GUI signal-category setup completed with success=false'
        }
        $categoryPayload = ConvertFrom-ProbeMarker -Line $categoryReadyLine
        if ($categoryPayload.physicalClickRequired) {
            Invoke-ProbeLogicalClick -Payload $categoryPayload -Label 'the stock signal category'
        }
        Start-Sleep -Milliseconds 750
        Invoke-StagedConsoleCommand -Command "require('tpf2_mp_probe/live_console_probe').selectSignalGuiItem()"
        $readyLine = Wait-ForProbeMarker -Event 'signal-gui-ready' -TimeoutSeconds $ProbeTimeoutSeconds
        if (-not $readyLine) { throw 'Timed out waiting for disposable GUI signal-item setup' }
        Write-Host $readyLine
        if ($readyLine -notmatch '"success":true') {
            Invoke-GameInput -InputAction 'inspect' -ScreenshotPath (Join-Path $runDirectory 'signal-item-selection.png')
            throw 'Disposable GUI signal-item setup completed with success=false'
        }
        $itemPayload = ConvertFrom-ProbeMarker -Line $readyLine
        if ($itemPayload.physicalClickRequired) {
            Invoke-ProbeLogicalClick -Payload $itemPayload -Label 'the stock signal item'
        }
        Start-Sleep -Milliseconds 750
        Invoke-GameInput -InputAction 'click-ui' -ClientX 960 -ClientY 500 -UiWidth 1920 -UiHeight 1080
        Write-Host 'Clicked the camera-focused track through the selected stock signal tool.'
    }

    $probeDeadline = (Get-Date).AddSeconds($ProbeTimeoutSeconds)
    while ((Get-Date) -lt $probeDeadline -and -not $process.HasExited) {
        $capabilitiesLine = Find-LatestMarker -Event 'capabilities'
        $probeLine = Find-LatestMarker -Event $(if ($BuildGateTest) {
            'gate-test-complete'
        } elseif ($CommandGateTest) {
            'command-gate-test-complete'
        } elseif ($TrackBuildTest) {
            'track-build-complete'
        } elseif ($SignalTest) {
            'signal-build-complete'
        } elseif ($SignalGuiCaptureTest) {
            # The exact pre-commit proposal is sufficient evidence. A physical
            # click may legitimately be rejected by terrain validation in the
            # disposable world after proposalCreate has already exposed every
            # serialization field we need.
            'signal-gui-proposal'
        } elseif ($OwnershipTransferTest) {
            'ownership-test-complete'
        } elseif ($ProposalOwnershipTest) {
            'proposal-ownership-test-complete'
        } elseif ($StationUpgradeCodecTest) {
            'station-upgrade-codec-complete'
        } elseif ($VehiclePurchaseTest) {
            'vehicle-purchase-codec-complete'
        } else {
            'build-complete'
        })
        if ($CapabilityOnly -and $capabilitiesLine) { break }
        if (-not $CapabilityOnly -and $probeLine) { break }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    if ($CapabilityOnly -and -not $capabilitiesLine) {
        if ($process.HasExited) { throw 'Transport Fever 2 exited before capability-probe completion' }
        throw "Timed out after $ProbeTimeoutSeconds seconds waiting for capability-probe completion"
    }
    if (-not $CapabilityOnly -and -not $probeLine) {
        if ($process.HasExited) { throw 'Transport Fever 2 exited before build-probe completion' }
        throw "Timed out after $ProbeTimeoutSeconds seconds waiting for probe completion"
    }
    $probePassed = if ($CapabilityOnly) { [bool]$capabilitiesLine } else { $probeLine -match '"success":true' }
    Write-Host $capabilitiesLine
    if ($probeLine) { Write-Host $probeLine }
    if ($NativeHook) {
        $nativeStatusSource = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native') "status-$($process.Id).json"
        if (-not (Test-Path -LiteralPath $nativeStatusSource)) {
            throw "Native hook status is missing: $nativeStatusSource"
        }
        $nativeEvidenceDeadline = (Get-Date).AddSeconds(5)
        $nativeCommandCalls = 0
        do {
            $nativeHookStatus = Get-Content -Raw -LiteralPath $nativeStatusSource | ConvertFrom-Json
            $nativeCommandCalls = (@($nativeHookStatus.luaStates) |
                Measure-Object -Property commandCalls -Sum).Sum
            $nativeGateReady = (-not $BuildGateTest -or (
                    $nativeHookStatus.gates.buildProposal.suppressed -gt 0 -and
                    $nativeHookStatus.gates.buildProposal.allowed -gt 0 -and
                    $nativeHookStatus.gates.buildProposal.enabled -eq $false
                )) -and (-not $CommandGateTest -or (
                    $nativeHookStatus.gates.commandVisitors.suppressedTotal -gt 0 -and
                    $nativeHookStatus.gates.commandVisitors.allowedTotal -gt 0 -and
                    $nativeHookStatus.gates.commandVisitors.enabled -eq $false
                ))
            if ($nativeCommandCalls -gt 0 -and $nativeHookStatus.commandList.commands -gt 0 -and
                $nativeHookStatus.applyCommand.calls -gt 0 -and $nativeGateReady) { break }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $nativeEvidenceDeadline)
        Copy-Item -LiteralPath $nativeStatusSource -Destination (Join-Path $runDirectory 'native-hook-status.json') -Force
        $nativeHookPassed = $nativeHookStatus.hookVersion -eq '0.14.0' -and
            $nativeHookStatus.active -eq $true -and
            $nativeHookStatus.hooks.enabled -eq $true -and
            $nativeHookStatus.hooks.commandListSwap -eq $true -and
            $nativeHookStatus.hooks.applyCommand -eq $true -and
            $nativeHookStatus.hooks.buildProposalVisitor -eq $true -and
            $nativeHookStatus.hooks.authorityCommandVisitors -eq 23 -and
            @($nativeHookStatus.luaStates).Count -gt 0 -and
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
            @($nativeHookStatus.commandEvents).Count -gt 0 -and
            $capabilitiesLine -match '"nativeStatusApi":true' -and
            $capabilitiesLine -match '"nativeStatusOk":true' -and
            $capabilitiesLine -match '"nativeCommandObserverApi":true' -and
            $capabilitiesLine -match '"nativeGameSpeedCaptureApi":true' -and
            $capabilitiesLine -match '"nativeCommandGateApi":true' -and
            $capabilitiesLine -match '"sendCommandNilRejected":true'
        if ($BuildGateTest) {
            $nativeHookPassed = $nativeHookPassed -and
                $nativeHookStatus.gates.buildProposal.suppressed -gt 0 -and
                $nativeHookStatus.gates.buildProposal.allowed -gt 0 -and
                $nativeHookStatus.gates.buildProposal.enabled -eq $false
        }
        if ($CommandGateTest) {
            $nativeHookPassed = $nativeHookPassed -and
                $nativeHookStatus.gates.commandVisitors.hooked -eq 23 -and
                $nativeHookStatus.gates.commandVisitors.suppressedTotal -gt 0 -and
                $nativeHookStatus.gates.commandVisitors.allowedTotal -gt 0 -and
                $nativeHookStatus.gates.commandVisitors.pendingTotal -eq 0 -and
                $nativeHookStatus.gates.commandVisitors.tagMismatches -eq 0 -and
                $nativeHookStatus.gates.commandVisitors.enabled -eq $false
        }
        if (-not $nativeHookPassed) { throw 'Native hook did not produce active, callable, call-through Lua evidence.' }
        Write-Host "Native hook live evidence passed; Lua states=$(@($nativeHookStatus.luaStates).Count), setup calls=$($nativeHookStatus.setupCommandInterface.calls), wrapped calls=$nativeCommandCalls, queued=$($nativeHookStatus.commandList.commands), applied=$($nativeHookStatus.applyCommand.calls)"
    }
    Invoke-GameInput -InputAction 'inspect' -ScreenshotPath (Join-Path $runDirectory 'world-after-probe.png')
    if (-not $probePassed) { throw 'The isolated supported-API probe completed with success=false.' }
}
catch {
    $failure = $_.Exception.Message
    Write-Warning $failure
}
finally {
    if ($acceptHeld -and $process -and -not $process.HasExited) {
        try { Invoke-GameInput -InputAction 'accept-up' } catch { Write-Warning "Could not release Return: $($_.Exception.Message)" }
    }
    if ($process -and -not $process.HasExited) {
        try {
            Stop-Process -Id $process.Id -Force
            $process.WaitForExit(10000) | Out-Null
        }
        catch { Write-Warning "Could not stop disposable game process $($process.Id): $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $gameLog) {
        Copy-Item -LiteralPath $gameLog -Destination (Join-Path $runDirectory 'stdout.txt') -Force
    }
    if ($bootstrapInjected -and (Test-Path -LiteralPath $bootstrapTarget)) {
        Remove-Item -LiteralPath $bootstrapTarget -Force
    }
    if ($libraryInjected -and (Test-Path -LiteralPath $libraryTarget)) {
        $verifiedTarget = [IO.Path]::GetFullPath($libraryTarget)
        if ($verifiedTarget -ne [IO.Path]::GetFullPath((Join-Path $scriptsRoot 'tpf2_mp_probe'))) {
            throw "Refusing recursive cleanup of unexpected path: $verifiedTarget"
        }
        Remove-Item -LiteralPath $verifiedTarget -Recurse -Force
    }

    [ordered]@{
        schemaVersion = 1
        capturedAt = (Get-Date).ToString('o')
        mode = if ($CapabilityOnly) {
            'capability-only'
        } elseif ($BuildGateTest) {
            'build-gate'
        } elseif ($CommandGateTest) {
            'command-gate'
        } elseif ($TrackBuildTest) {
            'track-build'
        } elseif ($SignalTest) {
            'signal-build'
        } elseif ($SignalGuiCaptureTest) {
            'signal-gui-capture'
        } elseif ($OwnershipTransferTest) {
            'ownership-transfer'
        } elseif ($ProposalOwnershipTest) {
            'proposal-ownership'
        } elseif ($StationUpgradeCodecTest) {
            'station-upgrade-codec'
        } elseif ($VehiclePurchaseTest) {
            'vehicle-purchase-codec'
        } else {
            'build-proposal'
        }
        passed = $probePassed
        nativeHookRequested = [bool]$NativeHook
        nativeHookPassed = $nativeHookPassed
        nativeHookStatus = $nativeHookStatus
        failure = $failure
        worldReadyLine = $worldReadyLine
        capabilitiesLine = $capabilitiesLine
        probeLine = $probeLine
        gameProcessStopped = -not [bool](Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue)
        bootstrapRemoved = -not (Test-Path -LiteralPath $bootstrapTarget)
        libraryRemoved = -not (Test-Path -LiteralPath $libraryTarget)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

Write-Host "runStatus=$statusPath"
if ($failure) { throw $failure }
