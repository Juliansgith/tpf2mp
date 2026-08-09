[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [string]$AuditPath,
    [string]$OutputPath,
    [string]$BundleRoot,
    [ValidateSet('ready', 'local-service', 'corridor-service', 'benefit', 'aboard', 'delivered', 'settled')]
    [string]$RequireStage = 'settled',
    [ValidateSet('ANY', 'ROAD', 'TRAM')][string]$Carrier = 'ANY',
    [switch]$RequireObservedAboard
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
if (-not $AuditPath) {
    $AuditPath = Join-Path ([IO.Path]::GetTempPath()) `
        "tpf2mp_bridge\$safeSession\player1\audit\$safeSession.ndjson"
}
$audit = Resolve-Tpf2mpFullPath $AuditPath
if (-not (Test-Path -LiteralPath $audit -PathType Leaf)) {
    throw "Passenger-feeder audit is missing: $audit"
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $bundle `
        "runtime\passenger-feeder-live-evidence\$safeSession-$stamp.json"
}
$output = Resolve-Tpf2mpFullPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null

$companion = Get-Tpf2mpCompanionCommand $bundle
$arguments = @($companion.Prefix) + @(
    'passenger-feeder-live-report', $audit, '--session', $safeSession,
    '--require-stage', $RequireStage, '--carrier', $Carrier, '--output', $output
)
if ($RequireObservedAboard) { $arguments += '--require-observed-aboard' }
& $companion.FilePath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Passenger-feeder evidence analyzer exited $LASTEXITCODE"
}
$report = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
if ($report.passed -ne $true) {
    throw "Passenger-feeder evidence failed: $($report.problems -join '; ')"
}
Write-Host "PASS authoritative passenger-feeder evidence: stage=$RequireStage, carrier=$Carrier, checkpoints=$($report.completedCheckpointCount)"
Write-Host ("localServices={0} corridors={1} links={2} aboard={3} witnessedAboard={4} delivered={5} settledRevenueCents={6}" -f `
    $report.maxima.localServices, $report.maxima.corridorServices,
    $report.maxima.feederLinks, $report.maxima.localAboard,
    $report.maxima.localWitnessedAboard, $report.maxima.localDeliveredPassengers,
    $report.maxima.localSettledRevenueCents)
Write-Host "report=$output"
