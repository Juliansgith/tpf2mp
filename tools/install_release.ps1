[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$LocalModsPath,
    [string]$InstallRoot,
    [switch]$ResetBridge,
    [switch]$SkipVerification,
    [switch]$NoDesktopShortcut,
    [Parameter(ValueFromRemainingArguments = $true)][object[]]$LegacyArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')

# 0.38.0/0.38.1 array-splatted the named installer arguments. Windows
# PowerShell 5.1 binds those tokens positionally, so a corrected release must
# understand that one historical shape long enough to update the updater
# itself. Keep the grammar exact and fail closed for every other residue.
$legacyTail = @($LegacyArguments | Where-Object { $null -ne $_ })
if ($BundleRoot -ceq '-BundleRoot' -and $InstallRoot -ceq '-InstallRoot' `
        -and $legacyTail.Count -ge 1) {
    $legacyBundleRoot = [string]$LocalModsPath
    $legacyInstallRoot = [string]$legacyTail[0]
    $LocalModsPath = $null
    $seenLegacy = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $index = 1
    while ($index -lt $legacyTail.Count) {
        $token = [string]$legacyTail[$index]
        if (-not $seenLegacy.Add($token)) { throw "Duplicate legacy installer argument: $token" }
        switch -CaseSensitive ($token) {
            '-LocalModsPath' {
                if ($index + 1 -ge $legacyTail.Count) { throw 'Legacy -LocalModsPath has no value.' }
                $LocalModsPath = [string]$legacyTail[$index + 1]
                $index += 2
            }
            '-ResetBridge' { $ResetBridge = $true; $index += 1 }
            '-SkipVerification' { $SkipVerification = $true; $index += 1 }
            '-NoDesktopShortcut' { $NoDesktopShortcut = $true; $index += 1 }
            default { throw "Unexpected legacy installer argument: $token" }
        }
    }
    $BundleRoot = $legacyBundleRoot
    $InstallRoot = $legacyInstallRoot
}
elseif ($legacyTail.Count -gt 0) {
    throw 'Unexpected positional installer arguments.'
}

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$manifest = Test-Tpf2mpReleaseManifest $bundle
if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Close every Transport Fever 2 instance before installing or updating TPF2MP.'
}
if (Get-Process -Name tpf2mp -ErrorAction SilentlyContinue) {
    throw 'Stop the active TPF2MP session/companion before installing or updating.'
}
$version = [string]$manifest.version
if (-not $version -or $version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$') {
    throw "Release manifest contains an unsafe version: $version"
}
$sourceMod = Join-Path $bundle 'tpf2_mp_1'
if (-not (Test-Path -LiteralPath (Join-Path $sourceMod 'mod.lua') -PathType Leaf)) {
    throw "Bundle mod source is missing: $sourceMod"
}

$defaultInstallRoot = -not [bool]$InstallRoot
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
$entrypointTransactions = [Collections.Generic.List[object]]::new()
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

    $entrypointSources = [ordered]@{}
    if ($null -ne $manifest.PSObject.Properties['update']) {
        $entrypointSources = [ordered]@{
            'installed_entrypoint.ps1' = 'tools\installed_entrypoint.ps1'
            'LAUNCH_TPF2MP.cmd' = 'tools\installed_command.cmd'
            'UPDATE_TPF2MP.cmd' = 'tools\installed_command.cmd'
            'VERIFY_TPF2MP.cmd' = 'tools\installed_command.cmd'
            'UNINSTALL_TPF2MP.cmd' = 'tools\installed_command.cmd'
        }
    }
    foreach ($entrypointName in $entrypointSources.Keys) {
        $entrypointSource = Join-Path $versionRoot $entrypointSources[$entrypointName]
        if (-not (Test-Path -LiteralPath $entrypointSource -PathType Leaf)) {
            throw "Installed bundle is missing stable entrypoint source: $entrypointSource"
        }
        $entrypointTarget = Join-Path $install $entrypointName
        $entrypointTemporary = Join-Path $install ('.entry-' + [guid]::NewGuid().ToString('N'))
        $entrypointRollback = Join-Path $install ('.entry-rollback-' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $entrypointSource -Destination $entrypointTemporary -Force
        $transaction = [pscustomobject]@{
            target = $entrypointTarget
            temporary = $entrypointTemporary
            rollback = $entrypointRollback
            priorExisted = Test-Path -LiteralPath $entrypointTarget -PathType Leaf
            applied = $false
        }
        $entrypointTransactions.Add($transaction)
        if ($transaction.priorExisted) {
            [IO.File]::Replace($entrypointTemporary, $entrypointTarget, $entrypointRollback)
        }
        else {
            Move-Item -LiteralPath $entrypointTemporary -Destination $entrypointTarget
        }
        $transaction.applied = $true
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
    for ($entrypointIndex = $entrypointTransactions.Count - 1; $entrypointIndex -ge 0; $entrypointIndex--) {
        $transaction = $entrypointTransactions[$entrypointIndex]
        if (-not $transaction.applied) { continue }
        try {
            if (Test-Path -LiteralPath $transaction.target -PathType Leaf) {
                Remove-Item -LiteralPath $transaction.target -Force
            }
            if ($transaction.priorExisted -and (Test-Path -LiteralPath $transaction.rollback -PathType Leaf)) {
                Move-Item -LiteralPath $transaction.rollback -Destination $transaction.target
            }
        }
        catch { $rollbackErrors.Add("stable entrypoint $($transaction.target): $($_.Exception.Message)") }
    }
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
    foreach ($transaction in $entrypointTransactions) {
        foreach ($entrypointTemporary in @($transaction.temporary, $transaction.rollback)) {
            if ($entrypointTemporary -and (Test-Path -LiteralPath $entrypointTemporary -PathType Leaf)) {
                Remove-Item -LiteralPath $entrypointTemporary -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($defaultInstallRoot -and -not $NoDesktopShortcut `
        -and (Test-Path -LiteralPath (Join-Path $install 'LAUNCH_TPF2MP.cmd') -PathType Leaf)) {
    try {
        $desktop = [Environment]::GetFolderPath([Environment+SpecialFolder]::DesktopDirectory)
        if ($desktop) {
            $shortcutPath = Join-Path $desktop 'TPF2MP Multiplayer.lnk'
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = Join-Path $install 'LAUNCH_TPF2MP.cmd'
            $shortcut.WorkingDirectory = $install
            $shortcut.Description = 'Launch TPF2MP trusted-LAN multiplayer'
            $shortcut.Save()
            Write-Host "Desktop shortcut: $shortcutPath"
        }
    }
    catch { Write-Warning "Could not create the optional desktop shortcut: $($_.Exception.Message)" }
}

Write-Host "TPF2MP $version installed successfully."
Write-Host "Game mod: $targetMod"
Write-Host "Support bundle: $versionRoot"
if (Test-Path -LiteralPath (Join-Path $install 'LAUNCH_TPF2MP.cmd') -PathType Leaf) {
    Write-Host "Multiplayer launcher: $(Join-Path $install 'LAUNCH_TPF2MP.cmd')"
    Write-Host "Update checker: $(Join-Path $install 'UPDATE_TPF2MP.cmd')"
}
elseif (Test-Path -LiteralPath (Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd') -PathType Leaf) {
    Write-Host "Multiplayer launcher: $(Join-Path $versionRoot 'LAUNCH_TPF2MP.cmd')"
}
Write-Host "Bridge roots: $bridge"
if ($supportBackup) { Write-Host "Previous same-version support bundle archived at: $supportBackup" }
if ($modBackup) { Write-Host "Previous mod backup: $modBackup" }
Write-Host 'For network experiments, open LAUNCH_TPF2MP.cmd; for hot-seat, enable the mod in a fresh free-game setup.'
