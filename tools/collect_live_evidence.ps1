[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [ValidateSet('player1', 'player2', 'both')][string]$Peer = 'both',
    [string]$BridgePath,
    [string]$OutputDirectory,
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$LocalModsPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
if ($BridgePath -and $Peer -eq 'both') { throw '-BridgePath requires one explicit peer.' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $bundle "runtime\manual-network-evidence\$safeSession-$stamp"
}
$evidenceRoot = Resolve-Tpf2mpFullPath $OutputDirectory
New-Item -ItemType Directory -Force -Path $evidenceRoot | Out-Null

function Get-TreeFingerprint([string]$Root) {
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    $rows = foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        "$relative=$((Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant())"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($rows -join "`n"))
    $stream = [IO.MemoryStream]::new($bytes)
    try { return (Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash.ToLowerInvariant() }
    finally { $stream.Dispose() }
}

function Resolve-Bridge([string]$PeerId) {
    if ($BridgePath) { return Resolve-Tpf2mpFullPath $BridgePath }
    $sessionBridge = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$safeSession\$PeerId")
    if (Test-Path -LiteralPath $sessionBridge -PathType Container) { return $sessionBridge }
    $legacyBridge = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$PeerId")
    return $legacyBridge
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Copy-DiagnosticFile([string]$Source, [string]$Destination, [long]$MaximumBytes = 8388608) {
    if (-not $Source -or -not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $null }
    $resolvedSource = Resolve-Tpf2mpFullPath $Source
    $resolvedDestination = Resolve-Tpf2mpFullPath $Destination
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $resolvedDestination) | Out-Null
    $input = [IO.File]::Open($resolvedSource, [IO.FileMode]::Open, [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $originalBytes = $input.Length
        $start = [Math]::Max(0L, $originalBytes - $MaximumBytes)
        if ($start -gt 0) { [void]$input.Seek($start, [IO.SeekOrigin]::Begin) }
        $output = [IO.File]::Open($resolvedDestination, [IO.FileMode]::Create,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $buffer = New-Object byte[] 65536
            do {
                $read = $input.Read($buffer, 0, $buffer.Length)
                if ($read -gt 0) { $output.Write($buffer, 0, $read) }
            } while ($read -gt 0)
        }
        finally { $output.Dispose() }
    }
    finally { $input.Dispose() }
    $copy = Get-Item -LiteralPath $resolvedDestination
    return [ordered]@{
        source = $resolvedSource
        copy = $resolvedDestination
        originalBytes = $originalBytes
        capturedBytes = $copy.Length
        tailTruncated = $start -gt 0
        sha256 = (Get-FileHash -LiteralPath $resolvedDestination -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$game = Find-Tpf2mpGameExecutable $GameExecutable
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$localData = Split-Path -Parent $mods
$gameLog = Join-Path $localData 'crash_dump\stdout.txt'
$installedMod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
$sourceMod = Join-Path $bundle 'tpf2_mp_1'
$peers = if ($Peer -eq 'both') { @('player1', 'player2') } else { @($Peer) }
$peerEvidence = [ordered]@{}

foreach ($peerId in $peers) {
    $bridge = Resolve-Bridge $peerId
    $copyRoot = Join-Path $evidenceRoot "bridges\$peerId"
    $bridgeExists = Test-Path -LiteralPath $bridge -PathType Container
    if ($bridgeExists) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $copyRoot) | Out-Null
        Copy-Item -LiteralPath $bridge -Destination $copyRoot -Recurse -Force
    }
    $outbox = Join-Path $bridge 'game_outbox'
    $messages = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $message = Read-JsonFile $file.FullName
        if ($message -and $message.session -eq $safeSession) {
            $messages += [pscustomobject]@{ File = $file; Message = $message }
        }
    }
    $kindCounts = [ordered]@{}
    foreach ($item in $messages) {
        $kind = [string]$item.Message.kind
        if (-not $kindCounts.Contains($kind)) { $kindCounts[$kind] = 0 }
        $kindCounts[$kind]++
    }
    $sessionState = Read-Tpf2mpSessionState $safeSession $peerId
    $companionStatus = Read-JsonFile (Join-Path $bridge 'companion_state\companion_status.json')
    $sessionArtifacts = @()
    $sessionRoot = Get-Tpf2mpSessionRoot $safeSession $peerId
    $artifactRoot = Join-Path $evidenceRoot "session\$peerId"
    $fixedArtifacts = [ordered]@{
        'session-state.json' = Join-Path $sessionRoot 'session-state.json'
        'recovery-watcher-status.json' = Join-Path $sessionRoot 'recovery-watcher-status.json'
        'save-sync-status.json' = Join-Path $sessionRoot 'save-sync-status.json'
        'relay-tunnel-status.json' = Join-Path $sessionRoot 'relay-tunnel-status.json'
        'relay-diagnostics-status.json' = Join-Path $sessionRoot 'relay-diagnostics-status.json'
    }
    foreach ($entry in $fixedArtifacts.GetEnumerator()) {
        $artifact = Copy-DiagnosticFile $entry.Value (Join-Path $artifactRoot $entry.Key)
        if ($artifact) { $sessionArtifacts += $artifact }
    }
    if ($sessionState) {
        foreach ($field in @(
            'stdout', 'stderr', 'gameStdout', 'gameStderr',
            'menuCoordinatorStdout', 'menuCoordinatorStderr',
            'recoveryWatcherStdout', 'recoveryWatcherStderr',
            'relayTunnelStdout', 'relayTunnelStderr',
            'relayDiagnosticsStdout', 'relayDiagnosticsStderr'
        )) {
            $property = $sessionState.PSObject.Properties[$field]
            if ($property -and $property.Value) {
                $extension = [IO.Path]::GetExtension([string]$property.Value)
                if (-not $extension) { $extension = '.log' }
                $artifact = Copy-DiagnosticFile ([string]$property.Value) `
                    (Join-Path $artifactRoot ($field + $extension))
                if ($artifact) { $sessionArtifacts += $artifact }
            }
        }
    }
    $latest = [ordered]@{}
    foreach ($kind in @('research', 'snapshot', 'checkpoint', 'completion', 'validation')) {
        $candidate = @($messages | Where-Object { $_.Message.kind -eq $kind } | Select-Object -Last 1)
        $latest[$kind] = if ($candidate.Count) { $candidate[0].File.FullName } else { $null }
    }
    $reportPath = Join-Path $evidenceRoot "research-$peerId.md"
    $reportError = $null
    if ($bridgeExists -and $kindCounts.Contains('research')) {
        try {
            $companion = Get-Tpf2mpCompanionCommand $bundle
            $arguments = @($companion.Prefix) + @(
                'research-report', '--peer', $peerId, '--session', $safeSession,
                '--bridge', $bridge, '--output', $reportPath
            )
            & $companion.FilePath @arguments *> (Join-Path $evidenceRoot "research-$peerId.log")
            if ($LASTEXITCODE -ne 0) { throw "research-report exited $LASTEXITCODE" }
        }
        catch { $reportError = $_.Exception.Message }
    }
    $peerEvidence[$peerId] = [ordered]@{
        bridge = $bridge
        bridgeFound = $bridgeExists
        copiedBridge = if ($bridgeExists) { $copyRoot } else { $null }
        sessionState = $sessionState
        sessionArtifacts = $sessionArtifacts
        companionStatus = $companionStatus
        messageCount = $messages.Count
        kinds = $kindCounts
        latest = $latest
        researchReport = if (Test-Path -LiteralPath $reportPath -PathType Leaf) { $reportPath } else { $null }
        researchReportError = $reportError
    }
}

$logSummary = $null
if (Test-Path -LiteralPath $gameLog -PathType Leaf) {
    $logCopy = Join-Path $evidenceRoot 'stdout.txt'
    # Transport Fever 2 keeps stdout.txt open while a live lab is running.
    # Copy-Item can obtain a stable readable snapshot, whereas hashing or
    # reading the live handle directly can fail with a sharing violation.
    # Perform all evidence analysis against the captured copy.
    Copy-Item -LiteralPath $gameLog -Destination $logCopy -Force
    $logRaw = Get-Content -LiteralPath $logCopy -Raw
    $structured = @([regex]::Matches($logRaw, '(?m)^.*\[TPF2MP\].*$') | ForEach-Object Value | Select-Object -Last 300)
    $errors = @($logRaw -split "`r?`n" | Where-Object {
        ($_ -match 'tpf2_mp|TPF2MP') -and $_ -match '(?i)error|traceback|failed|fault'
    } | Select-Object -Last 100)
    $logSummary = [ordered]@{
        source = $gameLog
        copy = $logCopy
        sha256 = (Get-FileHash -LiteralPath $logCopy -Algorithm SHA256).Hash.ToLowerInvariant()
        structuredLineCount = $structured.Count
        recentStructuredLines = $structured
        relevantErrorLineCount = $errors.Count
        recentRelevantErrors = $errors
    }
}

$nativeRoot = Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native'
$nativeCopies = @()
$candidatePids = New-Object System.Collections.Generic.HashSet[int]
foreach ($peerId in $peers) {
    $stateValue = $peerEvidence[$peerId].sessionState
    if ($stateValue -and $stateValue.PSObject.Properties['gamePid'] -and $stateValue.gamePid) {
        [void]$candidatePids.Add([int]$stateValue.gamePid)
    }
}
$localhostRunRoot = Join-Path $bundle "runtime\localhost-live\$safeSession"
foreach ($recordName in @('interactive-lab.json', 'run-status.json')) {
    $record = Read-JsonFile (Join-Path $localhostRunRoot $recordName)
    if ($record) {
        foreach ($property in @('player1GamePid', 'player2GamePid', 'peer1GamePid', 'peer2GamePid')) {
            if ($record.PSObject.Properties[$property] -and $record.$property) {
                [void]$candidatePids.Add([int]$record.$property)
            }
        }
    }
}
foreach ($process in @(Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue)) {
    [void]$candidatePids.Add([int]$process.Id)
}
foreach ($processId in $candidatePids) {
    $statusPath = Join-Path $nativeRoot "status-$processId.json"
    if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
        $destination = Join-Path $evidenceRoot "native-status-$processId.json"
        Copy-Item -LiteralPath $statusPath -Destination $destination -Force
        $nativeCopies += [ordered]@{ processId = $processId; source = $statusPath; copy = $destination }
    }
}

$auditReplay = [ordered]@{ attempted = $false; valid = $null; log = $null; error = $null }
$hostBridge = Resolve-Bridge 'player1'
$capturedHostBridge = if ($peerEvidence.Contains('player1')) {
    $peerEvidence['player1'].copiedBridge
} else { $null }
$auditPath = if ($capturedHostBridge) {
    Join-Path $capturedHostBridge "audit\$safeSession.ndjson"
} else {
    Join-Path $hostBridge "audit\$safeSession.ndjson"
}
if (Test-Path -LiteralPath $auditPath -PathType Leaf) {
    $auditReplay.attempted = $true
    $auditReplay.log = Join-Path $evidenceRoot 'audit-replay.txt'
    try {
        $companion = Get-Tpf2mpCompanionCommand $bundle
        $arguments = @($companion.Prefix) + @('replay', $auditPath, '--session', $safeSession)
        & $companion.FilePath @arguments *> $auditReplay.log
        $auditReplay.valid = $LASTEXITCODE -eq 0
        if (-not $auditReplay.valid) { $auditReplay.error = "audit replay exited $LASTEXITCODE" }
    }
    catch {
        $auditReplay.valid = $false
        $auditReplay.error = $_.Exception.Message
    }
}

$sourceFingerprint = Get-TreeFingerprint $sourceMod
$installedFingerprint = Get-TreeFingerprint $installedMod
$summary = [ordered]@{
    schemaVersion = 3
    capturedAt = (Get-Date).ToString('o')
    session = $safeSession
    requestedPeer = $Peer
    outputDirectory = $evidenceRoot
    game = if ($game) {
        [ordered]@{
            path = $game
            sha256 = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash.ToLowerInvariant()
            runningPids = @(Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue | ForEach-Object Id)
        }
    } else { $null }
    mod = [ordered]@{
        source = $sourceMod
        installed = $installedMod
        sourceFingerprint = $sourceFingerprint
        installedFingerprint = $installedFingerprint
        matches = $sourceFingerprint -and $sourceFingerprint -eq $installedFingerprint
    }
    peers = $peerEvidence
    nativeStatuses = $nativeCopies
    gameLog = $logSummary
    auditReplay = $auditReplay
}
$summaryPath = Join-Path $evidenceRoot 'evidence.json'
$summary | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "evidence=$summaryPath"
Write-Host "sourceInstalledMatch=$($summary.mod.matches)"
if ($auditReplay.attempted) { Write-Host "auditValid=$($auditReplay.valid)" }
foreach ($peerId in $peers) {
    Write-Host "$peerId messages=$($peerEvidence[$peerId].messageCount) bridge=$($peerEvidence[$peerId].bridgeFound)"
}
if ($summary.mod.matches -ne $true) { Write-Warning 'Installed mod does not match the source/bundle tree.' }
if ($auditReplay.attempted -and $auditReplay.valid -ne $true) { throw "Audit replay failed: $($auditReplay.error)" }
