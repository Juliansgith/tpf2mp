Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')

function Test-Tpf2mpTransientPreAuthorityLaunchFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    # These failures all occur before the loaded world may issue an authored
    # action. They are therefore safe to retire, archive, and retry with the
    # same role/session/save. Content, identity, and policy failures are
    # intentionally absent and remain immediate hard failures.
    $patterns = @(
        'native Load Game page',
        'ready-to-click-pinned-save',
        'ready-to-click-load-game',
        'stable native row',
        'Pinned save .+ is not visible',
        'Companion did not publish a ready status',
        'Native hook injection failed for game PID',
        'Persistent paused-network menu pump did not acknowledge'
    )
    return @($patterns | Where-Object { $Message -match $_ }).Count -gt 0
}

function Reset-Tpf2mpFailedNativeMenuAttempt {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [ValidateRange(1, 3)][int]$Attempt,
        [Parameter(Mandatory = $true)][string]$StopScriptPath
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $stopScript = Resolve-Tpf2mpFullPath $StopScriptPath
    if (-not (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
        throw "Managed-session stop script is missing: $stopScript"
    }
    $sessionRoot = Resolve-Tpf2mpFullPath (Get-Tpf2mpSessionRoot $safeSession $Peer)
    $bridge = Resolve-Tpf2mpFullPath `
        (Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$safeSession\$Peer")
    $attemptsRoot = Resolve-Tpf2mpFullPath (Join-Path $sessionRoot 'failed-launch-attempts')
    $sessionPrefix = $sessionRoot.TrimEnd('\') + '\'
    if (-not $attemptsRoot.StartsWith($sessionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing retry evidence root outside the exact session: $attemptsRoot"
    }
    $token = 'attempt-{0:d2}-{1}-{2}' -f $Attempt, `
        [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff'), `
        [guid]::NewGuid().ToString('N').Substring(0, 8)
    $attemptRoot = Resolve-Tpf2mpFullPath (Join-Path $attemptsRoot $token)
    if (-not $attemptRoot.StartsWith($attemptsRoot.TrimEnd('\') + '\', `
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing unsafe retry evidence target: $attemptRoot"
    }
    New-Item -ItemType Directory -Force -Path $attemptRoot | Out-Null

    $statePath = Join-Path $sessionRoot 'session-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        throw "Failed launch has no managed session state: $statePath"
    }
    $failedState = Read-Tpf2mpSessionState $safeSession $Peer
    if (-not $failedState -or [string]$failedState.status -cne 'failed' `
            -or [string]$failedState.session -cne $safeSession `
            -or [string]$failedState.peer -cne $Peer) {
        throw "Retry cleanup requires the exact failed session state for $safeSession/$Peer."
    }
    $recordedBridge = Resolve-Tpf2mpFullPath ([string]$failedState.bridgePath)
    if (-not [string]::Equals($recordedBridge, $bridge, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Failed launch bridge does not match the exact retry boundary: $recordedBridge"
    }
    Copy-Item -LiteralPath $statePath `
        -Destination (Join-Path $attemptRoot 'session-state.failed.json') -Force
    foreach ($file in @(Get-ChildItem -LiteralPath $sessionRoot -File -ErrorAction SilentlyContinue | `
            Where-Object { $_.Extension -in @('.json', '.log') })) {
        try { Copy-Item -LiteralPath $file.FullName -Destination $attemptRoot -Force }
        catch { Write-Warning "Could not snapshot optional retry evidence '$($file.Name)': $($_.Exception.Message)" }
    }
    foreach ($directoryName in @('native-save-load', 'main-menu-entry', 'paused-network-wake')) {
        $source = Join-Path $sessionRoot $directoryName
        if (Test-Path -LiteralPath $source -PathType Container) {
            try { Copy-Item -LiteralPath $source -Destination $attemptRoot -Recurse -Force }
            catch { Write-Warning "Could not snapshot optional retry evidence '$directoryName': $($_.Exception.Message)" }
        }
    }

    & $stopScript -Session $safeSession -Peer $Peer -StopGame `
        -StopReason "native-menu-retry-attempt-$Attempt"
    if (-not $?) { throw "Failed launch $safeSession/$Peer could not be retired before retry." }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Copy-Item -LiteralPath $statePath `
            -Destination (Join-Path $attemptRoot 'session-state.stopped.json') -Force
    }

    $archivedBridge = Join-Path $attemptRoot 'bridge'
    if (Test-Path -LiteralPath $bridge -PathType Container) {
        for ($moveAttempt = 1; $moveAttempt -le 20; $moveAttempt++) {
            try {
                Move-Item -LiteralPath $bridge -Destination $archivedBridge -ErrorAction Stop
                break
            }
            catch {
                if ($moveAttempt -eq 20) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    if (Test-Path -LiteralPath $bridge) {
        throw "Failed launch bridge remained active after retry cleanup: $bridge"
    }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        session = $safeSession
        peer = $Peer
        attempt = $Attempt
        reason = 'transient-pre-authority-launch-failure'
        evidenceRoot = $attemptRoot
        archivedBridge = if (Test-Path -LiteralPath $archivedBridge) { $archivedBridge } else { $null }
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receipt | ConvertTo-Json -Depth 4 | Set-Content `
        -LiteralPath (Join-Path $attemptRoot 'retry-cleanup.json') -Encoding UTF8
    return $receipt
}
