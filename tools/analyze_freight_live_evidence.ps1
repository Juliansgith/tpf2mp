[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [string]$AuditPath,
    [string]$OutputPath,
    [string]$BundleRoot,
    [ValidateSet('ready', 'service', 'waiting', 'aboard', 'delivered', 'settled')]
    [string]$RequireStage = 'settled',
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
    throw "Freight audit is missing: $audit"
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $bundle `
        "runtime\freight-live-evidence\$safeSession-$stamp.json"
}
$output = Resolve-Tpf2mpFullPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null

$companion = Get-Tpf2mpCompanionCommand $bundle
$arguments = @($companion.Prefix) + @(
    'freight-live-report', $audit, '--session', $safeSession,
    '--require-stage', $RequireStage, '--output', $output
)
if ($RequireObservedAboard) { $arguments += '--require-observed-aboard' }
& $companion.FilePath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Freight evidence analyzer exited $LASTEXITCODE"
}
$report = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
if ($report.passed -ne $true) {
    throw "Freight evidence failed: $($report.problems -join '; ')"
}
Write-Host "PASS authoritative freight evidence: stage=$RequireStage, checkpoints=$($report.completedCheckpointCount)"
Write-Host ("waiting={0} aboard={1} witnessedAboard={2} delivered={3} settledRevenueCents={4}" -f `
    $report.maxima.waiting, $report.maxima.aboard, $report.maxima.witnessedAboard,
    $report.maxima.deliveredTotal, $report.maxima.settledRevenueCents)
Write-Host "report=$output"
