[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [string]$ClientEvidenceDirectory,
    [ValidateSet('core', 'playable', 'alpha')][string]$Profile = 'alpha',
    [string]$BundleRoot,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$evidenceRoot = Resolve-Tpf2mpFullPath $EvidenceDirectory
$evidencePath = Join-Path $evidenceRoot 'evidence.json'
if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    throw "Collected evidence manifest is missing: $evidencePath"
}
$hostEvidence = Get-Content -LiteralPath $evidencePath -Raw | ConvertFrom-Json
$session = Assert-Tpf2mpSessionId ([string]$hostEvidence.session)
$clientEvidence = $hostEvidence
if ($ClientEvidenceDirectory) {
    $clientRoot = Resolve-Tpf2mpFullPath $ClientEvidenceDirectory
    $clientManifest = Join-Path $clientRoot 'evidence.json'
    if (-not (Test-Path -LiteralPath $clientManifest -PathType Leaf)) {
        throw "Client evidence manifest is missing: $clientManifest"
    }
    $clientEvidence = Get-Content -LiteralPath $clientManifest -Raw | ConvertFrom-Json
    if ([string]$clientEvidence.session -ne $session) {
        throw 'Host and client evidence name different sessions.'
    }
}

function Get-CopiedBridge($Manifest, [string]$Peer) {
    $entry = $Manifest.peers.PSObject.Properties[$Peer]
    if (-not $entry -or -not $entry.Value.copiedBridge) {
        throw "Evidence does not contain a copied $Peer bridge. Collect both peers."
    }
    $path = Resolve-Tpf2mpFullPath ([string]$entry.Value.copiedBridge)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "Copied $Peer bridge is missing: $path"
    }
    return $path
}

$hostBridge = Get-CopiedBridge $hostEvidence 'player1'
$clientBridge = Get-CopiedBridge $clientEvidence 'player2'
$audit = Join-Path $hostBridge "audit\$session.ndjson"
$hostStatus = Join-Path $hostBridge 'companion_state\companion_status.json'
$clientStatus = Join-Path $clientBridge 'companion_state\companion_status.json'
foreach ($required in @($audit, $hostStatus, $clientStatus)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Alpha evidence input is missing: $required"
    }
}

$restorePlan = Join-Path $hostBridge 'companion_state\published_restore_plan.json'
if (-not (Test-Path -LiteralPath $restorePlan -PathType Leaf)) { $restorePlan = $null }
if (-not $Output) { $Output = Join-Path $evidenceRoot "alpha-$Profile-report.json" }
$report = Resolve-Tpf2mpFullPath $Output
$arguments = @(
    'alpha-live-report', $audit, '--session', $session, '--profile', $Profile,
    '--host-status', $hostStatus, '--client-status', $clientStatus, '--output', $report
)
if ($restorePlan) { $arguments += @('--restore-plan', $restorePlan) }
$companion = Get-Tpf2mpCompanionCommand $bundle
$allArguments = @($companion.Prefix) + $arguments
& $companion.FilePath @allArguments
if ($LASTEXITCODE -ne 0) {
    throw "Alpha $Profile evidence gate failed; inspect $report"
}
Write-Host "alphaEvidence=$report"
