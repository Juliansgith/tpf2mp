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
$transactionId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)

New-Item -ItemType Directory -Force -Path $install, (Join-Path $install 'versions'), $backupRoot, $mods | Out-Null
$bridge = Initialize-Tpf2mpBridge -Reset:$ResetBridge
$staging = Resolve-Tpf2mpFullPath (Join-Path $install ('.staging-' + [guid]::NewGuid().ToString('N')))
$installPrefix = $install.TrimEnd('\') + '\'
if (-not $staging.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing staging path outside install root: $staging"
}
$modStaging = Resolve-Tpf2mpFullPath (Join-Path $mods ('.tpf2_mp_1-install-' + [guid]::NewGuid().ToString('N')))
$modsPrefix = $mods.TrimEnd('\') + '\'
if (-not $modStaging.StartsWith($modsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing mod staging path outside local mods root: $modStaging"
}
$currentPath = Join-Path $install 'current.json'
$currentStaging = Join-Path $install ('.current-' + [guid]::NewGuid().ToString('N') + '.json')
$currentRollback = $null
$currentInstalled = $false
$supportBackup = $null
$supportInstalled = $false
$modBackup = $null
$modInstalled = $false
$committed = $false
try {
    New-Item -ItemType Directory -Path $staging | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $bundle -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
    }
    Test-Tpf2mpReleaseManifest $staging | Out-Null

    if (Test-Path -LiteralPath $versionRoot) {
        $supportBackup = Join-Path $backupRoot ("support-$version-$transactionId")
        Move-Item -LiteralPath $versionRoot -Destination $supportBackup
    }
    Move-Item -LiteralPath $staging -Destination $versionRoot
    $supportInstalled = $true

    New-Item -ItemType Directory -Path $modStaging | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $versionRoot 'tpf2_mp_1') -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $modStaging -Recurse -Force
    }
    if (Test-Path -LiteralPath $targetMod) {
        $modBackup = Join-Path $backupRoot ("tpf2_mp_1-$transactionId")
        Move-Item -LiteralPath $targetMod -Destination $modBackup
    }
    Move-Item -LiteralPath $modStaging -Destination $targetMod
    $modInstalled = $true

    if (-not $SkipVerification) {
        & (Join-Path $versionRoot 'tools\verify_install.ps1') -BundleRoot $versionRoot -LocalModsPath $mods
        if ($LASTEXITCODE -ne 0) { throw "Post-install verification failed with exit code $LASTEXITCODE" }
    }

    $operationProperty = $manifest.PSObject.Properties['operationSchemaVersion']
    $current = [ordered]@{
        schemaVersion = 2
        version = $version
        manifestFormat = [int]$manifest.format
        sourceCommit = $(if ([int]$manifest.format -ge 2) { [string]$manifest.source.commit } else { $null })
        sourceDirty = $(if ([int]$manifest.format -ge 2) { [bool]$manifest.source.dirty } else { $null })
        operationSchemaVersion = $(if ($null -ne $operationProperty) {
                [int]$operationProperty.Value
            } else { $null })
        installedAtUtc = [DateTime]::UtcNow.ToString('o')
        bundleRoot = $versionRoot
        modPath = $targetMod
        priorModBackup = $modBackup
    }
    [IO.File]::WriteAllText($currentStaging, ($current | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
        $currentRollback = Join-Path $install ('.current-rollback-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::Replace($currentStaging, $currentPath, $currentRollback)
    }
    else {
        Move-Item -LiteralPath $currentStaging -Destination $currentPath
    }
    $currentInstalled = $true
    $committed = $true
}
catch {
    $installError = $_
    $rollbackErrors = [System.Collections.Generic.List[string]]::new()
    try {
        if ($currentInstalled -and (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
            Remove-Item -LiteralPath $currentPath -Force
        }
        if ($currentRollback -and (Test-Path -LiteralPath $currentRollback -PathType Leaf)) {
            Move-Item -LiteralPath $currentRollback -Destination $currentPath
        }
    }
    catch { $rollbackErrors.Add("current pointer: $($_.Exception.Message)") }
    try {
        if ($modInstalled -and (Test-Path -LiteralPath $targetMod -PathType Container)) {
            Remove-Item -LiteralPath $targetMod -Recurse -Force
        }
        if ($modBackup -and (Test-Path -LiteralPath $modBackup -PathType Container)) {
            Move-Item -LiteralPath $modBackup -Destination $targetMod
        }
    }
    catch { $rollbackErrors.Add("game mod: $($_.Exception.Message)") }
    try {
        if ($supportInstalled -and (Test-Path -LiteralPath $versionRoot -PathType Container)) {
            Remove-Item -LiteralPath $versionRoot -Recurse -Force
        }
        if ($supportBackup -and (Test-Path -LiteralPath $supportBackup -PathType Container)) {
            Move-Item -LiteralPath $supportBackup -Destination $versionRoot
        }
    }
    catch { $rollbackErrors.Add("support bundle: $($_.Exception.Message)") }
    if ($rollbackErrors.Count -gt 0) {
        throw "Installation failed: $($installError.Exception.Message). Rollback incomplete: $($rollbackErrors -join '; ')"
    }
    throw $installError
}
finally {
    foreach ($temporaryPath in @($staging, $modStaging, $currentStaging)) {
        if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath)) {
            Remove-Item -LiteralPath $temporaryPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($committed -and $currentRollback -and (Test-Path -LiteralPath $currentRollback -PathType Leaf)) {
        Remove-Item -LiteralPath $currentRollback -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "TPF2MP $version installed successfully."
Write-Host "Game mod: $targetMod"
Write-Host "Support bundle: $versionRoot"
if (Test-Path -LiteralPath (Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd')) {
    Write-Host "Multiplayer launcher: $(Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd')"
}
Write-Host "Bridge roots: $bridge"
if ($supportBackup) { Write-Host "Previous same-version support bundle archived at: $supportBackup" }
if ($modBackup) { Write-Host "Previous mod backup: $modBackup" }
Write-Host 'For network experiments, open LAUNCH_TPF2MP.cmd; for hot-seat, enable the mod in a fresh free-game setup.'
