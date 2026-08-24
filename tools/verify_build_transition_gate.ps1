[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [int]$MinimumAcceptedPerPeer = 3,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$failures = [Collections.Generic.List[string]]::new()
$peerReports = [ordered]@{}
$allAccepted = @()
$checkpointSequences = @()

function Read-JsonFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { return $null }
}

function Read-Tpf2mpEvents([string]$Path) {
    $events = @()
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $events }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $marker = $line.IndexOf('[TPF2MP] ')
        if ($marker -lt 0) { continue }
        $json = $line.Substring($marker + 9).Trim()
        try { $events += ($json | ConvertFrom-Json) } catch { }
    }
    return $events
}

foreach ($peer in @('player1', 'player2')) {
    $state = Read-Tpf2mpSessionState $safeSession $peer
    if (-not $state) {
        $failures.Add("$peer has no launcher session state")
        continue
    }
    $native = Read-JsonFile ([string]$state.nativeStatusPath)
    $companionPath = Join-Path ([string]$state.bridgePath) 'companion_state\companion_status.json'
    $companion = Read-JsonFile $companionPath
    $events = @(Read-Tpf2mpEvents ([string]$state.gameStdout))
    if ($events.Count -eq 0) { $events = @(Read-Tpf2mpEvents ([string]$state.stdout)) }
    $accepted = @($events | Where-Object { $_.event -eq 'build-correlation-accepted' })
    $rejected = @($events | Where-Object { $_.event -eq 'build-correlation-rejected' })
    $invalidated = @($events | Where-Object { $_.event -eq 'build-correlation-invalidated' })
    $allAccepted += @($accepted | ForEach-Object {
        [pscustomobject]@{
            peer = $peer
            correlationId = $_.correlationId
            nativeGeneration = $_.nativeGeneration
            family = [string]$_.family
            sourceId = [string]$_.sourceId
            suppressedCalls = $_.suppressedCalls
        }
    })

    if (-not $native -or $native.hookVersion -ne '0.19.0' -or $native.active -ne $true) {
        $failures.Add("$peer is not running active native hook 0.19.0")
    }
    $buildGate = if ($native -and $native.gates) { $native.gates.buildProposal } else { $null }
    $buildQueue = if ($buildGate -and $buildGate.PSObject.Properties['suppressedQueue']) {
        $buildGate.suppressedQueue
    } else { $null }
    if (-not $buildQueue) {
        $failures.Add("$peer native status has no generation-bound build queue")
    }
    else {
        if ([long]$buildQueue.dropped -ne 0) {
            $failures.Add("$peer dropped $($buildQueue.dropped) suppressed build correlations")
        }
        if ([long]$buildQueue.queued -ne 0) {
            $failures.Add("$peer still has $($buildQueue.queued) unconsumed build correlations")
        }
    }
    $sessionFault = if ($companion -and $companion.PSObject.Properties['sessionFault']) {
        $companion.sessionFault
    } else { $null }
    if (-not $companion -or $sessionFault) {
        $failures.Add("$peer companion is missing or faulted")
    }
    $checkpoint = if ($companion -and $companion.PSObject.Properties['lastAgreedCheckpointSeq']) {
        $companion.lastAgreedCheckpointSeq
    } else { $null }
    if ($null -ne $checkpoint) { $checkpointSequences += [long]$checkpoint }
    if ($accepted.Count -lt $MinimumAcceptedPerPeer) {
        $failures.Add("$peer has only $($accepted.Count) accepted correlated builds; expected at least $MinimumAcceptedPerPeer")
    }
    if ($rejected.Count -gt 0) {
        $failures.Add("$peer recorded $($rejected.Count) rejected/ambiguous build correlations")
    }
    $lastGeneration = 0L
    $seenCorrelations = @{}
    foreach ($record in $accepted) {
        $generation = 0L
        $correlation = 0L
        if (-not [long]::TryParse([string]$record.nativeGeneration, [ref]$generation) `
            -or $generation -le $lastGeneration) {
            $failures.Add("$peer accepted build generations are missing, duplicated, or reordered")
            break
        }
        if (-not [long]::TryParse([string]$record.correlationId, [ref]$correlation) `
            -or $correlation -le 0 -or $seenCorrelations.ContainsKey([string]$correlation)) {
            $failures.Add("$peer accepted an invalid or reused GUI build correlation token")
            break
        }
        $seenCorrelations[[string]$correlation] = $true
        $lastGeneration = $generation
    }
    $peerReports[$peer] = [ordered]@{
        accepted = $accepted.Count
        rejected = $rejected.Count
        invalidations = $invalidated.Count
        lastNativeGeneration = $lastGeneration
        hookVersion = if ($native) { $native.hookVersion } else { $null }
        queue = $buildQueue
        checkpoint = $checkpoint
    }
}

$familyCounts = [ordered]@{}
foreach ($record in $allAccepted) {
    $family = if ($record.family) { $record.family } else { '<missing>' }
    if (-not $familyCounts.Contains($family)) { $familyCounts[$family] = 0 }
    $familyCounts[$family]++
}
foreach ($required in @('construction', 'track', 'street', 'edge-object')) {
    if (-not $familyCounts.Contains($required) -or [int]$familyCounts[$required] -lt 1) {
        $failures.Add("transition matrix has no accepted $required build")
    }
}
$bulldozes = @($allAccepted | Where-Object {
    $_.sourceId.ToLowerInvariant().Contains('bulldoz') -or $_.sourceId.ToLowerInvariant().Contains('demol')
})
if ($bulldozes.Count -lt 1) { $failures.Add('transition matrix has no accepted bulldozer action') }
if ($checkpointSequences.Count -ne 2 -or $checkpointSequences[0] -ne $checkpointSequences[1]) {
    $failures.Add('peers do not report the same agreed checkpoint after the matrix')
}

$report = [ordered]@{
    schemaVersion = 1
    session = $safeSession
    passed = $failures.Count -eq 0
    peers = $peerReports
    familyCounts = $familyCounts
    bulldozerActions = $bulldozes.Count
    failures = @($failures)
}

if ($AsJson) { $report | ConvertTo-Json -Depth 10 }
else {
    [pscustomobject]@{
        Session = $safeSession
        Passed = $report.passed
        Player1Accepted = $peerReports.player1.accepted
        Player2Accepted = $peerReports.player2.accepted
        Families = (($familyCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ')
        BulldozerActions = $bulldozes.Count
        Failures = if ($failures.Count) { $failures -join '; ' } else { 'none' }
    } | Format-List
}
if ($failures.Count -gt 0) { exit 1 }
