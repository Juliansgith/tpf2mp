[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuditPath,
    [string]$Session,
    [string]$OutputPath,
    [string]$BundleRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Join-Path $bundle 'bin\tpf2mp.exe'
if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) {
    throw "Companion executable is missing: $companion"
}
$audit = Resolve-Tpf2mpFullPath $AuditPath
if (-not (Test-Path -LiteralPath $audit -PathType Leaf)) { throw "Audit log is missing: $audit" }
if (-not $OutputPath) { $OutputPath = $audit + '.recovery.json' }
$output = Resolve-Tpf2mpFullPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
$arguments = @('recovery-plan', $audit, '--output', $output)
if ($Session) { $arguments += @('--session', $Session) }
& $companion @arguments
if ($LASTEXITCODE -ne 0) { throw "Recovery-plan generation failed with exit code $LASTEXITCODE" }
Write-Host "Checksummed recovery plan written: $output"
Write-Host 'This plan identifies a verified restart boundary; it does not patch divergent live native geometry.'
