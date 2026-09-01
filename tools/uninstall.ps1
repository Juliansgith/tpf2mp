[CmdletBinding()]
param(
    [string]$LocalModsPath,
    [string]$InstallRoot,
    [string]$GameExecutable,
    [switch]$SkipRuntimeOverlayCleanup
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
. (Join-Path $PSScriptRoot 'runtime_overlay_common.ps1')
if (-not $InstallRoot) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -InstallRoot explicitly.' }
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
}
$install = Resolve-Tpf2mpFullPath $InstallRoot
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$target = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
$archiveRoot = Resolve-Tpf2mpFullPath (Join-Path $install 'backups')
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
$game = if (-not $SkipRuntimeOverlayCleanup) { Find-Tpf2mpGameExecutable $GameExecutable } else { $null }
if (-not $SkipRuntimeOverlayCleanup) {
    if ($game) {
        $overlay = Remove-Tpf2mpManagedRuntimeOverlay -BundleRoot (Split-Path -Parent $PSScriptRoot) `
            -GameExecutable $game -ArchiveRoot $archiveRoot
        if ($overlay.status -eq 'archived') {
            Write-Host "Removed stale base-game runtime overlay; recoverable archive: $($overlay.archive)"
        }
    }
    else {
        Write-Warning 'Transport Fever 2 was not discovered; no stale base-game runtime overlay could be checked.'
    }
}
if (Test-Path -LiteralPath $target) {
    $archive = Join-Path $archiveRoot ('uninstalled-tpf2_mp_1-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Move-Item -LiteralPath $target -Destination $archive
    Write-Host 'TPF2MP has been removed from the game mod directory.'
    Write-Host "Recoverable archive: $archive"
}
else {
    Write-Host "TPF2MP mod is not installed at: $target"
}
Write-Host "Support tools remain at: $install"
