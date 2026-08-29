[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$caseRoot = Join-Path $TemporaryRoot 'network-session-retry'
$localAppData = Join-Path $caseRoot 'local-app-data'
$temporary = Join-Path $caseRoot 'temp'
New-Item -ItemType Directory -Force -Path $localAppData, $temporary | Out-Null
$previousLocalAppData = $env:LOCALAPPDATA
$previousTemp = $env:TEMP
$previousTmp = $env:TMP
$env:LOCALAPPDATA = $localAppData
$env:TEMP = $temporary
$env:TMP = $temporary

try {
    . (Join-Path $ProjectRoot 'tools\network_session_retry_cleanup.ps1')
    foreach ($message in @(
        "Game PID 43948 did not reach menu stage 'ready-to-click-load-game' within 600 seconds.",
        'Companion did not publish a ready status within 12 seconds.',
        'Native hook injection failed for game PID 2560 with exit code 6',
        "Persistent paused-network menu pump did not acknowledge generation 'wake-1'"
    )) {
        if (-not (Test-Tpf2mpTransientPreAuthorityLaunchFailure $message)) {
            throw "Known pre-authority launch race was not retryable: $message"
        }
    }
    foreach ($message in @(
        'match fingerprint mismatch',
        'Relay credentials do not match this role',
        'Session is already carrying authored bridge traffic'
    )) {
        if (Test-Tpf2mpTransientPreAuthorityLaunchFailure $message) {
            throw "Unsafe/configuration failure was incorrectly made retryable: $message"
        }
    }
    $session = 'connected-client-menu-retry'
    $peer = 'player2'
    $sessionRoot = Get-Tpf2mpSessionRoot $session $peer
    $bridge = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$session\$peer"
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $bridge 'game_inbox'), (Join-Path $bridge 'game_outbox'), `
        (Join-Path $bridge 'launcher'), $sessionRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $bridge 'game_inbox\000000000001.json'),
        '{"type":"commit","seq":1}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $bridge 'game_outbox\000000000001.json'),
        '{"type":"intent","localSeq":1}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $bridge 'launcher\menu_status.json'),
        '{"stage":"ready-to-click-load-game","frames":3330}', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sessionRoot 'companion.stderr.log'),
        'first attempt evidence', [Text.UTF8Encoding]::new($false))
    [void](Write-Tpf2mpSessionState $session $peer ([ordered]@{
        schemaVersion = 3
        session = $session
        peer = $peer
        status = 'failed'
        bridgePath = $bridge
        error = 'Native Load Game page did not open within 45 seconds after click attempt 1.'
    }))

    $unrelated = Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_bridge\unrelated-session\player2'
    New-Item -ItemType Directory -Force -Path $unrelated | Out-Null
    [IO.File]::WriteAllText((Join-Path $unrelated 'keep.txt'), 'keep')
    $stopReceipt = Join-Path $caseRoot 'stop-receipt.json'
    $env:TPF2MP_RETRY_TEST_STOP_RECEIPT = $stopReceipt
    $fakeStop = Join-Path $caseRoot 'fake-stop.ps1'
    [IO.File]::WriteAllText($fakeStop, @'
param([string]$Session, [string]$Peer, [switch]$StopGame, [string]$StopReason)
[IO.File]::WriteAllText($env:TPF2MP_RETRY_TEST_STOP_RECEIPT,
    ([pscustomobject]@{ session=$Session; peer=$Peer; stopGame=[bool]$StopGame; reason=$StopReason } |
        ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))

    $cleanup = Reset-Tpf2mpFailedNativeMenuAttempt -Session $session -Peer $peer `
        -Attempt 1 -StopScriptPath $fakeStop
    if (Test-Path -LiteralPath $bridge) {
        throw 'Transient retry left the connected client bridge active.'
    }
    if (-not $cleanup.archivedBridge `
            -or -not (Test-Path -LiteralPath (Join-Path $cleanup.archivedBridge 'game_inbox\000000000001.json')) `
            -or -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $cleanup.archivedBridge) 'session-state.failed.json')) `
            -or -not (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $cleanup.archivedBridge) 'companion.stderr.log'))) {
        throw 'Transient retry did not preserve first-attempt network and launcher evidence.'
    }
    $stopped = Get-Content -LiteralPath $stopReceipt -Raw | ConvertFrom-Json
    if (-not $stopped.stopGame -or $stopped.reason -cne 'native-menu-retry-attempt-1') {
        throw 'Transient retry did not retire the exact managed game/companion boundary.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $unrelated 'keep.txt'))) {
        throw 'Transient retry touched another session bridge.'
    }

    New-Item -ItemType Directory -Force -Path `
        (Join-Path $bridge 'game_inbox'), (Join-Path $bridge 'game_outbox') | Out-Null
    $staleTraffic = @(Get-ChildItem -LiteralPath (Join-Path $bridge 'game_inbox') -Filter '*.json').Count `
        + @(Get-ChildItem -LiteralPath (Join-Path $bridge 'game_outbox') -Filter '*.json').Count
    if ($staleTraffic -ne 0) {
        throw 'Replacement client bridge was not clean for host-history replay.'
    }
}
finally {
    $env:TPF2MP_RETRY_TEST_STOP_RECEIPT = $null
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:TEMP = $previousTemp
    $env:TMP = $previousTmp
}

Write-Host 'PASS pre-authority launch retry is clean, bounded, and evidence-preserving'
