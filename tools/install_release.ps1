[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$LocalModsPath,
    [string]$InstallRoot,
    [switch]$ResetBridge,
    [switch]$SkipVerification
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$manifest = Test-Tpf2mpReleaseManifest $bundle
$version = [string]$manifest.version
if (-not $version -or $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$') {
    throw "Release manifest contains an unsafe version: $version"
}
$sourceMod = Join-Path $bundle 'tpf2_mp_1'
if (-not (Test-Path -LiteralPath (Join-Path $sourceMod 'mod.lua') -PathType Leaf)) {
    throw "Bundle mod source is missing: $sourceMod"
}

if (-not $InstallRoot) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -InstallRoot explicitly.' }
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
}
$install = Resolve-Tpf2mpFullPath $InstallRoot
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$targetMod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
$versionRoot = Join-Path (Join-Path $install 'versions') $version
$backupRoot = Join-Path $install 'backups'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

New-Item -ItemType Directory -Force -Path $install, (Join-Path $install 'versions'), $backupRoot, $mods | Out-Null
$staging = Resolve-Tpf2mpFullPath (Join-Path $install ('.staging-' + [guid]::NewGuid().ToString('N')))
$installPrefix = $install.TrimEnd('\') + '\'
if (-not $staging.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing staging path outside install root: $staging"
}
New-Item -ItemType Directory -Path $staging | Out-Null
try {
    foreach ($item in Get-ChildItem -LiteralPath $bundle -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
    }
    Test-Tpf2mpReleaseManifest $staging | Out-Null

    if (Test-Path -LiteralPath $versionRoot) {
        $supportBackup = Join-Path $backupRoot ("support-$version-$stamp")
        Move-Item -LiteralPath $versionRoot -Destination $supportBackup
        Write-Host "Previous same-version support bundle archived at: $supportBackup"
    }
    Move-Item -LiteralPath $staging -Destination $versionRoot
}
catch {
    if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    throw
}

$modStaging = Resolve-Tpf2mpFullPath (Join-Path $mods ('.tpf2_mp_1-install-' + [guid]::NewGuid().ToString('N')))
$modsPrefix = $mods.TrimEnd('\') + '\'
if (-not $modStaging.StartsWith($modsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing mod staging path outside local mods root: $modStaging"
}
$modBackup = $null
try {
    New-Item -ItemType Directory -Path $modStaging | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $versionRoot 'tpf2_mp_1') -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $modStaging -Recurse -Force
    }
    if (Test-Path -LiteralPath $targetMod) {
        $modBackup = Join-Path $backupRoot ("tpf2_mp_1-$stamp")
        Move-Item -LiteralPath $targetMod -Destination $modBackup
    }
    Move-Item -LiteralPath $modStaging -Destination $targetMod
}
catch {
    if (-not (Test-Path -LiteralPath $targetMod) -and $modBackup -and (Test-Path -LiteralPath $modBackup)) {
        Move-Item -LiteralPath $modBackup -Destination $targetMod
    }
    if (Test-Path -LiteralPath $modStaging) { Remove-Item -LiteralPath $modStaging -Recurse -Force }
    throw
}

$current = [ordered]@{
    schemaVersion = 1
    version = $version
    installedAtUtc = [DateTime]::UtcNow.ToString('o')
    bundleRoot = $versionRoot
    modPath = $targetMod
    priorModBackup = $modBackup
}
$current | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $install 'current.json') -Encoding UTF8
$bridge = Initialize-Tpf2mpBridge -Reset:$ResetBridge

if (-not $SkipVerification) {
    & (Join-Path $versionRoot 'tools\verify_install.ps1') -BundleRoot $versionRoot -LocalModsPath $mods
    if ($LASTEXITCODE -ne 0) { throw "Post-install verification failed with exit code $LASTEXITCODE" }
}

Write-Host "TPF2MP $version installed successfully."
Write-Host "Game mod: $targetMod"
Write-Host "Support bundle: $versionRoot"
if (Test-Path -LiteralPath (Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd')) {
    Write-Host "Multiplayer launcher: $(Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd')"
}
Write-Host "Bridge roots: $bridge"
if ($modBackup) { Write-Host "Previous mod backup: $modBackup" }
Write-Host 'For network experiments, open LAUNCH_TPF2MP.cmd; for hot-seat, enable the mod in a fresh free-game setup.'
