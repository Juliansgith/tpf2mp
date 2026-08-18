[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [ValidateSet('core', 'playable', 'alpha')][string]$Profile = 'alpha',
    [string]$BundleRoot,
    [string]$OutputDirectory,
    [string]$GameExecutable,
    [string]$LocalModsPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
if (-not $OutputDirectory) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputDirectory = Join-Path $bundle "runtime\manual-network-evidence\$safeSession-$stamp-alpha"
}
$output = Resolve-Tpf2mpFullPath $OutputDirectory

& (Join-Path $PSScriptRoot 'collect_live_evidence.ps1') -Session $safeSession -Peer both `
    -OutputDirectory $output -BundleRoot $bundle -GameExecutable $GameExecutable `
    -LocalModsPath $LocalModsPath
if ($LASTEXITCODE -ne 0) { throw "Evidence collection exited $LASTEXITCODE" }

& (Join-Path $PSScriptRoot 'analyze_alpha_live_evidence.ps1') `
    -EvidenceDirectory $output -Profile $Profile -BundleRoot $bundle
if ($LASTEXITCODE -ne 0) { throw "Alpha evidence analysis exited $LASTEXITCODE" }
Write-Host "alphaAcceptance=$output"

