[CmdletBinding()]
param(
    [string]$LocalModsPath,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
if (-not $InstallRoot) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -InstallRoot explicitly.' }
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
}
$install = Resolve-Tpf2mpFullPath $InstallRoot
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$target = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "TPF2MP mod is not installed at: $target"
    exit 0
}
$archiveRoot = Resolve-Tpf2mpFullPath (Join-Path $install 'backups')
New-Item -ItemType Directory -Force -Path $archiveRoot | Out-Null
$archive = Join-Path $archiveRoot ('uninstalled-tpf2_mp_1-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
Move-Item -LiteralPath $target -Destination $archive
Write-Host 'TPF2MP has been removed from the game mod directory.'
Write-Host "Recoverable archive: $archive"
Write-Host "Support tools remain at: $install"
