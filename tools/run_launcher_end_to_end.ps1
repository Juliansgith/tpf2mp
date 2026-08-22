[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StartingSave,
    [string]$Session,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$SaveDirectory,
    [ValidateRange(120, 1800)][int]$TimeoutSeconds = 900,
    [ValidateRange(1, 3)][int]$MaxLaunchAttempts = 2,
    [switch]$KeepGamesOpen
)

$ErrorActionPreference = 'Stop'
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = [IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

if (-not $Session) { $Session = 'launcher-e2e-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
$safeSession = Assert-Tpf2mpSessionId $Session
$sourceSave = Resolve-Tpf2mpFullPath $StartingSave
if (-not (Test-Path -LiteralPath $sourceSave -PathType Leaf)) {
    throw "Starting save is missing: $sourceSave"
}
if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Transport Fever 2 is already running; refusing to mix an automated launcher acceptance with another game.'
}
Assert-Tpf2mpHostPortAvailable -Port $Port -Session $safeSession

$runRoot = Join-Path $bundle "runtime\launcher-e2e\$safeSession"
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$launcherScript = Join-Path $PSScriptRoot 'start_network_session_retry.ps1'
$stopScript = Join-Path $PSScriptRoot 'stop_network_session.ps1'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$workers = @{}
$clickedPids = @{
    player1 = [Collections.Generic.HashSet[int]]::new()
    player2 = [Collections.Generic.HashSet[int]]::new()
}
$result = [ordered]@{
    schemaVersion = 1
    session = $safeSession
    startingSave = $sourceSave
    port = $Port
    startedAtUtc = [DateTime]::UtcNow.ToString('o')
    hostLauncherAttempts = 0
    joinLauncherAttempts = 0
    player1 = $null
    player2 = $null
    passed = $false
    cleanedUp = $false
    error = $null
}
$resultPath = Join-Path $runRoot 'result.json'

function Write-LauncherE2eResult {
    $result | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resultPath -Encoding UTF8
}

function Start-RoleWorker {
    param([Parameter(Mandatory = $true)][ValidateSet('Host', 'Join')][string]$Role)
    $peer = if ($Role -eq 'Host') { 'player1' } else { 'player2' }
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherScript,
        '-Role', $Role, '-Session', $safeSession,
        '-Port', $Port, '-StartingSave', $sourceSave,
        '-BundleRoot', $bundle, '-MaxAttempts', $MaxLaunchAttempts
    )
    if ($Role -eq 'Host') { $arguments += @('-BindAddress', '0.0.0.0') }
    else { $arguments += @('-HostAddress', '127.0.0.1') }
    if ($GameExecutable) { $arguments += @('-GameExecutable', (Resolve-Tpf2mpFullPath $GameExecutable)) }
    if ($LocalModsPath) { $arguments += @('-LocalModsPath', (Resolve-Tpf2mpFullPath $LocalModsPath)) }
    if ($SaveDirectory) { $arguments += @('-SaveDirectory', (Resolve-Tpf2mpFullPath $SaveDirectory)) }
    $stdout = Join-Path $runRoot "$peer-launcher.stdout.log"
    $stderr = Join-Path $runRoot "$peer-launcher.stderr.log"
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $workers[$peer] = [pscustomobject]@{ process = $process; stdout = $stdout; stderr = $stderr }
    Write-Host "Started $Role launcher worker PID $($process.Id) for $peer."
}

function Get-RoleFailureText {
    param([Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer)
    $worker = $workers[$Peer]
    $stderr = try {
        if (Test-Path -LiteralPath $worker.stderr -PathType Leaf) {
            (Get-Content -LiteralPath $worker.stderr -Raw -ErrorAction Stop).Trim()
        } else { '' }
    } catch { '(launcher stderr was still closing)' }
    $stdout = try {
        if (Test-Path -LiteralPath $worker.stdout -PathType Leaf) {
            (Get-Content -LiteralPath $worker.stdout -Raw -ErrorAction Stop).Trim()
        } else { '' }
    } catch { '(launcher stdout was still closing)' }
    return (($stderr, $stdout | Where-Object { $_ }) -join "`n")
}

function Invoke-RoleMultiplayerEntry {
    param([Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer)
    $state = Read-Tpf2mpSessionState $safeSession $Peer
    if (-not $state -or -not $state.gamePid -or -not $state.bridgePath) { return $false }
    $pidValue = [int]$state.gamePid
    if ($clickedPids[$Peer].Contains($pidValue)) { return $false }
    $game = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $game -or $game.HasExited) { return $false }
    $menu = Read-Tpf2mpMenuStatus -BridgePath ([string]$state.bridgePath) `
        -Session $safeSession -Peer $Peer
    if (-not $menu -or $menu.stage -ne 'main-menu' -or $menu.entryInstalled -ne $true `
            -or -not $menu.components -or -not $menu.components.multiplayerRect) {
        return $false
    }
    $receipt = Join-Path $runRoot "$Peer-click-multiplayer-pid-$pidValue.json"
    Invoke-Tpf2mpUiRectangleClick -GameProcess $game `
        -Rectangle $menu.components.multiplayerRect -MenuRectangle $menu.components.menuRect `
        -ReceiptPath $receipt
    [void]$clickedPids[$Peer].Add($pidValue)
    Write-Host "Clicked the native MULTIPLAYER entry for $Peer game PID $pidValue."
    return $true
}

function Wait-RoleReady {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][ValidateSet('hosting-world-ready', 'joined-world-ready')][string]$ReadyStatus
    )
    $worker = $workers[$Peer].process
    while ((Get-Date) -lt $deadline) {
        [void](Invoke-RoleMultiplayerEntry -Peer $Peer)
        $state = Read-Tpf2mpSessionState $safeSession $Peer
        if ($state -and [string]$state.status -eq $ReadyStatus) {
            # session-state.json is the authoritative handoff.  The wrapper can
            # spend a while serializing its diagnostic object to redirected
            # output after that handoff; do not turn harmless log latency into
            # a false game failure.
            return $state
        }
        $worker.Refresh()
        if ($worker.HasExited) {
            $detail = Get-RoleFailureText -Peer $Peer
            throw "$Peer launcher exited $($worker.ExitCode) before $ReadyStatus.`n$detail"
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for $Peer to reach $ReadyStatus."
}

function Wait-RoleTitleEntry {
    param([Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer)
    $worker = $workers[$Peer].process
    while ((Get-Date) -lt $deadline) {
        $state = Read-Tpf2mpSessionState $safeSession $Peer
        if ($state -and $state.gamePid -and $state.bridgePath) {
            $game = Get-Process -Id ([int]$state.gamePid) -ErrorAction SilentlyContinue
            $menu = if ($game -and -not $game.HasExited) {
                Read-Tpf2mpMenuStatus -BridgePath ([string]$state.bridgePath) `
                    -Session $safeSession -Peer $Peer
            } else { $null }
            if ($menu -and $menu.stage -eq 'main-menu' -and $menu.entryInstalled -eq $true `
                    -and $menu.components -and $menu.components.multiplayerRect) {
                Write-Host "$Peer title screen is ready for its native MULTIPLAYER selection."
                return
            }
        }
        $worker.Refresh()
        if ($worker.HasExited) {
            throw "$Peer launcher exited before its title entry was ready.`n$(Get-RoleFailureText -Peer $Peer)"
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Timed out waiting for $Peer title-menu entry."
}

function Wait-HostListener {
    while ((Get-Date) -lt $deadline) {
        $owners = @(Get-Tpf2mpTcpListenerOwners -Port $Port)
        if (@($owners | Where-Object {
                $_.tpf2mpCompanion -and $_.session -eq $safeSession -and $_.peer -eq 'player1'
            }).Count -gt 0) { return }
        $hostWorker = $workers.player1.process
        $hostWorker.Refresh()
        if ($hostWorker.HasExited) {
            throw "Host launcher exited before opening port $Port.`n$(Get-RoleFailureText -Peer player1)"
        }
        Start-Sleep -Milliseconds 200
    }
    throw "Host companion did not listen on port $Port before the acceptance deadline."
}

function Get-VerifiedRoleStatus {
    param([Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer)
    $json = & (Join-Path $PSScriptRoot 'get_network_session_status.ps1') `
        -Session $safeSession -Peer $Peer -AsJson
    return (($json -join "`n") | ConvertFrom-Json)
}

try {
    Write-LauncherE2eResult
    Start-RoleWorker -Role Host
    Wait-HostListener
    Start-RoleWorker -Role Join

    # Reproduce the public flow exactly: both title screens exist before the
    # host enters its world, then the joiner follows.  Wait-RoleReady also
    # clicks a replacement PID if the bounded native-menu retry was needed.
    Wait-RoleTitleEntry -Peer player1
    Wait-RoleTitleEntry -Peer player2
    [void](Wait-RoleReady -Peer player1 -ReadyStatus hosting-world-ready)
    [void](Wait-RoleReady -Peer player2 -ReadyStatus joined-world-ready)

    $converged = $false
    while ((Get-Date) -lt $deadline) {
        $hostStatus = Get-VerifiedRoleStatus -Peer player1
        $joinStatus = Get-VerifiedRoleStatus -Peer player2
        if ($hostStatus.fault -or $joinStatus.fault) {
            throw "Session faulted during launcher acceptance: host=$($hostStatus.fault), join=$($joinStatus.fault)"
        }
        $hostPeerPresent = @($hostStatus.connectedPeers) -contains 'player2'
        if ($hostStatus.launcherStatus -eq 'hosting-world-ready' `
                -and $joinStatus.launcherStatus -eq 'joined-world-ready' `
                -and $hostStatus.gameRunning -and $joinStatus.gameRunning `
                -and $hostStatus.companionRunning -and $joinStatus.companionRunning `
                -and $hostStatus.nativeHookActive -and $joinStatus.nativeHookActive `
                -and $hostStatus.buildGateActive -and $joinStatus.buildGateActive `
                -and $hostStatus.commandGatesActive -and $joinStatus.commandGatesActive `
                -and $hostPeerPresent -and $joinStatus.connected -and $joinStatus.synchronized `
                -and $hostStatus.fingerprint -eq $joinStatus.fingerprint) {
            $converged = $true
            break
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $converged) { throw 'Both launcher worlds loaded, but their network/authority readiness did not converge.' }

    $result.hostLauncherAttempts = $clickedPids.player1.Count
    $result.joinLauncherAttempts = $clickedPids.player2.Count
    $result.player1 = $hostStatus
    $result.player2 = $joinStatus
    $result.passed = $true
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-LauncherE2eResult
    Write-Host "PASS launcher end-to-end acceptance: $resultPath"
}
catch {
    $result.error = $_.Exception.Message
    $result.completedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-LauncherE2eResult
    throw
}
finally {
    if (-not $KeepGamesOpen) {
        foreach ($peer in @('player2', 'player1')) {
            if (Read-Tpf2mpSessionState $safeSession $peer) {
                try { & $stopScript -Session $safeSession -Peer $peer -StopGame }
                catch { Write-Warning "Cleanup for $peer needs attention: $($_.Exception.Message)" }
            }
        }
        foreach ($worker in @($workers.Values)) {
            if (-not $worker) { continue }
            $worker.process.Refresh()
            if (-not $worker.process.HasExited) {
                if (-not $worker.process.WaitForExit(10000)) {
                    Stop-Process -Id $worker.process.Id -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $result.cleanedUp = @(Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue).Count -eq 0 `
            -and @(Get-Tpf2mpTcpListenerOwners -Port $Port).Count -eq 0
        Write-LauncherE2eResult
    }
}
