[CmdletBinding()]
param(
    [string]$GameExecutable,
    [switch]$AllowStaleDevelopmentOverlay
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'runtime_overlay_common.ps1')

$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered.' }
$archiveRoot = if ($env:LOCALAPPDATA) {
    Join-Path $env:LOCALAPPDATA 'TPF2MP\backups'
} else { Join-Path $projectRoot '.runtime-overlay-backups' }
$result = Remove-Tpf2mpManagedRuntimeOverlay -BundleRoot $projectRoot `
    -GameExecutable $game -ArchiveRoot $archiveRoot
if ($result.status -eq 'archived') {
    Write-Host "Archived $($result.removed) verified disposable runtime overlay target(s): $($result.archive)"
}
else {
    Write-Host 'No managed TPF2MP runtime overlay was present.'
}
