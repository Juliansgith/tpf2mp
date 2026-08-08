[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $ProjectRoot 'tools\network_common.ps1')

$session = 'fault-watch-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$sessionRoot = Get-Tpf2mpSessionRoot $session 'player1'
$supportRoot = Get-Tpf2mpSupportRoot
$supportPrefix = $supportRoot.TrimEnd('\') + '\'
if (-not $sessionRoot.StartsWith($supportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Fault-watcher test resolved a session outside the TPF2MP support root.'
}

$bridge = Join-Path $TemporaryRoot 'fault-watcher-bridge'
$statusRoot = Join-Path $bridge 'companion_state'
$saveRoot = Join-Path $TemporaryRoot 'fault-watcher\1066780\local\save'
$fakeGame = Join-Path $TemporaryRoot 'fault-watcher\TransportFever2.exe'
$fakeCollector = Join-Path $TemporaryRoot 'fake-evidence-collector.ps1'
New-Item -ItemType Directory -Force -Path $statusRoot, $saveRoot, (Split-Path -Parent $fakeGame) | Out-Null
[IO.File]::WriteAllBytes($fakeGame, [byte[]](0))
[IO.File]::WriteAllText((Join-Path $statusRoot 'companion_status.json'),
    ([ordered]@{
        schemaVersion = 1
        session = $session
        peer = 'player1'
        sessionFault = 'first-fault-test:physical-digest-mismatch'
    } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

$collectorSource = @'
[CmdletBinding()]
param(
    [string]$Session, [string]$Peer, [string]$BridgePath,
    [string]$OutputDirectory, [string]$BundleRoot, [string]$GameExecutable
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
[ordered]@{
    session = $Session
    peer = $Peer
    bridge = [IO.Path]::GetFullPath($BridgePath)
    bundle = [IO.Path]::GetFullPath($BundleRoot)
    game = [IO.Path]::GetFullPath($GameExecutable)
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'evidence.json') -Encoding UTF8
'@
[IO.File]::WriteAllText($fakeCollector, $collectorSource, [Text.UTF8Encoding]::new($false))

try {
    & (Join-Path $ProjectRoot 'tools\watch_recovery_saves.ps1') `
        -Session $session -Peer player1 -BridgePath $bridge -SaveDirectory $saveRoot `
        -GameProcessId 2147483000 -GameExecutable $fakeGame `
        -GameStartedAtUtc ([DateTime]::UtcNow.ToString('o')) -BundleRoot $ProjectRoot `
        -EvidenceCollectorPath $fakeCollector -OneShot
    if (-not $?) { throw 'Fault-watcher fixture returned failure.' }

    $watcherStatusPath = Join-Path $sessionRoot 'recovery-watcher-status.json'
    $watcher = Get-Content -LiteralPath $watcherStatusPath -Raw | ConvertFrom-Json
    if ($watcher.schemaVersion -ne 3 -or $watcher.status -ne 'stopped-game-exited') {
        throw 'Fault watcher did not preserve its terminal status after capturing evidence.'
    }
    if ($watcher.firstFaultEvidenceAttempted -ne $true `
        -or $watcher.firstFault -ne 'first-fault-test:physical-digest-mismatch' `
        -or $watcher.firstFaultEvidenceError) {
        throw 'Fault watcher did not record the first session fault exactly once.'
    }
    if (-not (Test-Path -LiteralPath $watcher.firstFaultEvidenceSummary -PathType Leaf)) {
        throw 'Fault watcher did not retain its evidence summary.'
    }
    $evidence = Get-Content -LiteralPath $watcher.firstFaultEvidenceSummary -Raw | ConvertFrom-Json
    if ($evidence.session -ne $session -or $evidence.peer -ne 'player1' `
        -or $evidence.bridge -ne [IO.Path]::GetFullPath($bridge)) {
        throw 'Fault watcher passed the wrong session identity to its evidence collector.'
    }
    Write-Host 'PASS first session fault is captured even after the game process exits'

    $logRoot = Join-Path $TemporaryRoot 'fault-watcher\logs'
    $companionLog = Join-Path $logRoot 'companion.stdout.log'
    New-Item -ItemType Directory -Force -Path $logRoot, $sessionRoot | Out-Null
    [IO.File]::WriteAllText($companionLog, "before-fault`nafter-fault`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $sessionRoot 'session-state.json'),
        ([ordered]@{
            schemaVersion = 3
            session = $session
            peer = 'player1'
            bridgePath = $bridge
            stdout = $companionLog
            stderr = $null
            gamePid = $null
        } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

    $fakeMods = Join-Path $TemporaryRoot 'fault-watcher\steam\userdata\1\1066780\local\mods'
    $installedMod = Join-Path $fakeMods 'tpf2_mp_1'
    New-Item -ItemType Directory -Force -Path $fakeMods | Out-Null
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tpf2_mp_1') -Destination $installedMod -Recurse
    $crashRoot = Join-Path (Split-Path -Parent $fakeMods) 'crash_dump'
    New-Item -ItemType Directory -Force -Path $crashRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $crashRoot 'stdout.txt'),
        "[TPF2MP] fixture first fault`n", [Text.UTF8Encoding]::new($false))

    $realEvidenceRoot = Join-Path $TemporaryRoot 'real-fault-evidence'
    & (Join-Path $ProjectRoot 'tools\collect_live_evidence.ps1') `
        -Session $session -Peer player1 -BridgePath $bridge `
        -OutputDirectory $realEvidenceRoot -BundleRoot $ProjectRoot `
        -GameExecutable $fakeGame -LocalModsPath $fakeMods
    if (-not $?) { throw 'Real evidence collector fixture returned failure.' }
    $realEvidence = Get-Content -LiteralPath (Join-Path $realEvidenceRoot 'evidence.json') -Raw | ConvertFrom-Json
    if ($realEvidence.schemaVersion -ne 3) { throw 'Evidence collector wrote an obsolete summary schema.' }
    $logArtifact = @($realEvidence.peers.player1.sessionArtifacts | Where-Object {
        $_.source -eq [IO.Path]::GetFullPath($companionLog)
    }) | Select-Object -First 1
    if (-not $logArtifact -or $logArtifact.tailTruncated -ne $false `
        -or (Get-Content -LiteralPath $logArtifact.copy -Raw) -ne "before-fault`nafter-fault`n") {
        throw 'Evidence collector did not preserve the exact bounded session log.'
    }
    if ($realEvidence.mod.matches -ne $true -or -not $realEvidence.gameLog.copy) {
        throw 'Evidence collector omitted its source/install or game-log proof.'
    }
    Write-Host 'PASS first-fault bundle contains exact session and game diagnostics'
}
finally {
    if (Test-Path -LiteralPath $sessionRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($sessionRoot)
        if (-not $resolved.StartsWith($supportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a fault-watcher fixture outside the support root.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
