[CmdletBinding()]
param(
    [string]$BundleRoot,
    [ValidateRange(1024, 65535)][int]$Port = 29742,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [switch]$SkipTests,
    [switch]$SkipInstall,
    [switch]$SkipNativeBuild,
    [switch]$RequireVehicleSyncRound,
    [switch]$DiscoveryOnly,
    [ValidateRange(1, 5)][int]$MaxAttempts = 3
)

$ErrorActionPreference = 'Stop'
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = [IO.Path]::GetFullPath($BundleRoot)
. (Join-Path $PSScriptRoot 'network_common.ps1')

$pair = Get-Tpf2mpLatestLocalRestorePair -BundleRoot $bundle
$plan = Get-Content -LiteralPath ([string]$pair.planPath) -Raw | ConvertFrom-Json
if ([string]$plan.checksum -ne [string]$pair.planChecksum `
        -or [string]$plan.resumeSession -ne [string]$pair.resumeSession `
        -or [int]$plan.boundarySeq -ne [int]$pair.boundarySeq) {
    throw 'Discovered restore pair does not match its verified host plan.'
}
foreach ($peer in @('player1', 'player2')) {
    $candidate = $pair.peers.$peer
    if ([string]$candidate.peer -ne $peer `
            -or [string]$candidate.planChecksum -ne [string]$pair.planChecksum `
            -or -not (Test-Path -LiteralPath ([string]$candidate.savePath) -PathType Leaf)) {
        throw "Discovered restore pair has an invalid $peer archive."
    }
}
if ($DiscoveryOnly) {
    $pair | ConvertTo-Json -Depth 10
    exit 0
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$arguments = @{
    Session = [string]$pair.resumeSession
    RestorePlan = [string]$pair.planPath
    Player1StartingSave = [string]$pair.peers.player1.savePath
    Player2StartingSave = [string]$pair.peers.player2.savePath
    Port = $Port
    ManualOnly = $true
}
if ($GameExecutable) { $arguments.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $arguments.LocalModsPath = $LocalModsPath }
if ($SkipTests) { $arguments.SkipTests = $true }
if ($SkipInstall) { $arguments.SkipInstall = $true }
if ($SkipNativeBuild) { $arguments.SkipNativeBuild = $true }
if ($RequireVehicleSyncRound) { $arguments.RequireVehicleSyncRound = $true }

$statusPath = $null
$lastFailure = $null
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    $evidenceTag = "restore-acceptance-$stamp-attempt-{0:D2}" -f $attempt
    $arguments.EvidenceTag = $evidenceTag
    $candidateStatus = Join-Path $bundle `
        "runtime\localhost-live\$($pair.resumeSession)--$evidenceTag\run-status.json"
    try {
        & (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @arguments
        $statusPath = $candidateStatus
        break
    }
    catch {
        $lastFailure = $_
        $message = [string]$_.Exception.Message
        $transientNativeMenu = $message -match 'native Load Game page' `
            -or $message -match 'menu stage .+ready-to-click-pinned-save' `
            -or $message -match 'stable native row' `
            -or $message -match 'source session or peer does not match the attested save'
        if (-not $transientNativeMenu -or $attempt -ge $MaxAttempts) { throw }
        Write-Warning "Native save manager attempt $attempt/$MaxAttempts failed safely; retrying the complete cleaned run: $message"
        Start-Sleep -Seconds 3
    }
}
if (-not $statusPath -and $lastFailure) { throw $lastFailure }
if (-not (Test-Path -LiteralPath $statusPath -PathType Leaf)) {
    throw 'Restore acceptance did not produce its run-status evidence.'
}
$status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
$hostStatus = $status.finalHostStatus
if ($status.passed -ne $true -or $status.restoreBoundarySeq -ne $pair.boundarySeq `
        -or $hostStatus.restoreStatus -ne 'complete' -or [int64]$hostStatus.restoreCommitSeq -lt 1 `
        -or [string]$hostStatus.sessionFault) {
    throw 'Restore acceptance did not converge without a consensus fault.'
}
if ($RequireVehicleSyncRound -and (
        [int]$hostStatus.vehicleSync.releases -lt 1 `
        -or [int]$hostStatus.vehicleSync.faults -ne 0)) {
    throw 'Restore acceptance did not complete a fresh synchronized vehicle round.'
}

$outputRoot = Join-Path $bundle 'runtime\restore-acceptance'
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$receiptPath = Join-Path $outputRoot "$stamp.json"
[ordered]@{
    schemaVersion = 1
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
    sourceSession = [string]$pair.session
    resumeSession = [string]$pair.resumeSession
    boundarySeq = [int]$pair.boundarySeq
    planChecksum = [string]$pair.planChecksum
    restoreCommitSeq = [int64]$hostStatus.restoreCommitSeq
    agreedCheckpointSeq = [int64]$hostStatus.lastAgreedCheckpointSeq
    vehicleSyncReleases = [int]$hostStatus.vehicleSync.releases
    runStatus = $statusPath
    result = 'passed-and-cleaned-up'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "PASS latest two-peer restore acceptance: $receiptPath"
