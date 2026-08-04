[CmdletBinding()]
param(
    [string]$LocalModsPath,
    [switch]$ResetBridge
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
$projectRoot = Resolve-Tpf2mpFullPath (Join-Path $PSScriptRoot '..')
$source = Join-Path $projectRoot 'tpf2_mp_1'
if (-not (Test-Path -LiteralPath (Join-Path $source 'mod.lua') -PathType Leaf)) {
    throw "Mod source is missing: $source"
}
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
New-Item -ItemType Directory -Force -Path $mods | Out-Null
$target = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
$staging = Resolve-Tpf2mpFullPath (Join-Path $mods ('.tpf2_mp_1-dev-' + [guid]::NewGuid().ToString('N')))
$modsPrefix = $mods.TrimEnd('\') + '\'
if (-not $staging.StartsWith($modsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing staging path outside $mods"
}
New-Item -ItemType Directory -Path $staging | Out-Null
foreach ($item in Get-ChildItem -LiteralPath $source -Force) {
    Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
}
$backup = $null
try {
    if (Test-Path -LiteralPath $target) {
        $backupRoot = Join-Path $projectRoot 'runtime\install-backups'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $backup = Join-Path $backupRoot ('tpf2_mp_1-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $target -Destination $backup
    }
    Move-Item -LiteralPath $staging -Destination $target
}
catch {
    if (-not (Test-Path -LiteralPath $target) -and $backup -and (Test-Path -LiteralPath $backup)) {
        Move-Item -LiteralPath $backup -Destination $target
    }
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    throw
}
$bridgeBase = Initialize-Tpf2mpBridge -Reset:$ResetBridge
Write-Host "Installed TPF2MP development tree to: $target"
Write-Host "Bridge roots prepared under: $bridgeBase"
if ($backup) { Write-Host "Previous install archived at: $backup" }
