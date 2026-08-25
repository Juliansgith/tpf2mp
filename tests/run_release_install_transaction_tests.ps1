[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

$caseRoot = Join-Path $TemporaryRoot 'release-install-transaction'
$bundle = Join-Path $caseRoot 'bundle'
$installRoot = Join-Path $caseRoot 'support'
$modsRoot = Join-Path $caseRoot 'Steam\userdata\12345\1066780\local\mods'
$targetMod = Join-Path $modsRoot 'tpf2_mp_1'
$versionRoot = Join-Path $installRoot 'versions\0.38.0-alpha'
$currentPath = Join-Path $installRoot 'current.json'
$desktopRoot = Join-Path $caseRoot 'desktop'

New-Item -ItemType Directory -Force -Path `
    (Join-Path $bundle 'tpf2_mp_1'),
    (Join-Path $bundle 'bin\native'),
    (Join-Path $bundle 'tools'),
    (Join-Path $bundle 'docs'),
    $targetMod,
    $versionRoot | Out-Null

[IO.File]::WriteAllText((Join-Path $bundle 'tpf2_mp_1\mod.lua'), 'new-mod', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bundle 'bin\tpf2mp.exe'), 'not-a-Windows-executable', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bundle 'bin\native\tpf2mp_injector.exe'), 'fixture', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bundle 'bin\native\tpf2mp_hook_build35924.dll'), 'fixture', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bundle 'docs\README.md'), 'fixture', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $bundle 'QUICK_START.md'), 'fixture', [Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $ProjectRoot 'UPDATE_TPF2MP.cmd') -Destination (Join-Path $bundle 'UPDATE_TPF2MP.cmd')
foreach ($name in @(
        'install_release.ps1', 'verify_install.ps1', 'uninstall.ps1', 'release_common.ps1',
        'update_release.ps1', 'update_common.ps1', 'github_release_common.ps1',
        'installed_entrypoint.ps1', 'installed_command.cmd')) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "tools\$name") -Destination (Join-Path $bundle "tools\$name")
}

$records = @()
foreach ($file in Get-ChildItem -LiteralPath $bundle -File -Recurse | Sort-Object FullName) {
    $relative = $file.FullName.Substring($bundle.Length + 1).Replace('\', '/')
    $records += [pscustomobject][ordered]@{
        path = $relative
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$manifest = [pscustomobject][ordered]@{
    format = 2
    name = 'TPF2MP Competitive Prototype'
    version = '0.38.0-alpha'
    modMinorVersion = 38
    stateSchemaVersion = 31
    checkpointSchemaVersion = 5
    proposalSchemaVersion = 5
    operationSchemaVersion = 4
    passengerPresentationSchemaVersion = 2
    cargoPresentationSchemaVersion = 2
    deliverySchemaVersion = 3
    freightIndustrySchemaVersion = 3
    companionVersion = '0.38.0-alpha'
    update = [pscustomobject][ordered]@{
        provider = 'github-releases'
        repository = 'Juliansgith/tpf2mp'
        channel = 'alpha'
    }
    source = [pscustomobject][ordered]@{
        commit = 'fedcba9876543210fedcba9876543210fedcba98'
        dirty = $false
    }
    files = $records
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'release-manifest.json') -Encoding UTF8

[IO.File]::WriteAllText((Join-Path $versionRoot 'old-support.txt'), 'old-support', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $targetMod 'old-mod.txt'), 'old-mod', [Text.UTF8Encoding]::new($false))
$oldCurrent = '{"schemaVersion":1,"version":"old","sentinel":"keep-exactly"}'
[IO.File]::WriteAllText($currentPath, $oldCurrent, [Text.UTF8Encoding]::new($false))

$failed = $false
try {
    & (Join-Path $ProjectRoot 'tools\install_release.ps1') `
        -BundleRoot $bundle -InstallRoot $installRoot -LocalModsPath $modsRoot
}
catch {
    $failed = $true
}
if (-not $failed) { throw 'Checksum-valid bundle with a non-runnable companion unexpectedly installed.' }

$supportFiles = @(Get-ChildItem -LiteralPath $versionRoot -File -Recurse)
if ($supportFiles.Count -ne 1 -or $supportFiles[0].Name -ne 'old-support.txt' `
        -or (Get-Content -LiteralPath $supportFiles[0].FullName -Raw) -ne 'old-support') {
    throw 'Failed install did not restore the prior support bundle exactly.'
}
$modFiles = @(Get-ChildItem -LiteralPath $targetMod -File -Recurse)
if ($modFiles.Count -ne 1 -or $modFiles[0].Name -ne 'old-mod.txt' `
        -or (Get-Content -LiteralPath $modFiles[0].FullName -Raw) -ne 'old-mod') {
    throw 'Failed install did not restore the prior game mod exactly.'
}
if ((Get-Content -LiteralPath $currentPath -Raw) -ne $oldCurrent) {
    throw 'Failed install changed the prior current-version pointer.'
}
if (@(Get-ChildItem -LiteralPath $installRoot -Force -Recurse | Where-Object {
            $_.Name -like '.staging-*' -or $_.Name -like '.current-*'
        }).Count -gt 0) {
    throw 'Failed install left support/current staging residue.'
}
if (@(Get-ChildItem -LiteralPath $modsRoot -Force | Where-Object {
            $_.Name -like '.tpf2_mp_1-install-*'
        }).Count -gt 0) {
    throw 'Failed install left mod staging residue.'
}
$failedBackupRoot = Join-Path $installRoot 'backups'
if ((Test-Path -LiteralPath $failedBackupRoot) `
        -and @(Get-ChildItem -LiteralPath $failedBackupRoot -Force).Count -gt 0) {
    throw 'Failed install left a detached prior bundle in backups after rollback.'
}
foreach ($name in @('installed_entrypoint.ps1', 'LAUNCH_TPF2MP.cmd', 'UPDATE_TPF2MP.cmd',
        'VERIFY_TPF2MP.cmd', 'UNINSTALL_TPF2MP.cmd')) {
    if (Test-Path -LiteralPath (Join-Path $installRoot $name)) {
        throw "Failed install left stable entrypoint residue: $name"
    }
}

$previousDesktopOverride = $env:TPF2MP_DESKTOP_DIRECTORY_OVERRIDE
try {
    $env:TPF2MP_DESKTOP_DIRECTORY_OVERRIDE = $desktopRoot
    & (Join-Path $ProjectRoot 'tools\install_release.ps1') `
        -BundleRoot $bundle -InstallRoot $installRoot -LocalModsPath $modsRoot -SkipVerification `
        -CreateDesktopShortcut
}
finally { $env:TPF2MP_DESKTOP_DIRECTORY_OVERRIDE = $previousDesktopOverride }
$installedCurrent = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
if ([int]$installedCurrent.schemaVersion -ne 2 `
        -or [int]$installedCurrent.manifestFormat -ne 2 `
        -or [string]$installedCurrent.sourceCommit -ne $manifest.source.commit `
        -or $installedCurrent.sourceDirty -isnot [bool] `
        -or [bool]$installedCurrent.sourceDirty `
        -or [int]$installedCurrent.operationSchemaVersion -ne 4) {
    throw 'Successful install current pointer did not retain exact source provenance.'
}
if ((Get-Content -LiteralPath (Join-Path $versionRoot 'tpf2_mp_1\mod.lua') -Raw) -ne 'new-mod' `
        -or (Get-Content -LiteralPath (Join-Path $targetMod 'mod.lua') -Raw) -ne 'new-mod') {
    throw 'Successful install did not commit identical support and active mod copies.'
}
foreach ($name in @('installed_entrypoint.ps1', 'LAUNCH_TPF2MP.cmd', 'UPDATE_TPF2MP.cmd',
        'VERIFY_TPF2MP.cmd', 'UNINSTALL_TPF2MP.cmd')) {
    if (-not (Test-Path -LiteralPath (Join-Path $installRoot $name) -PathType Leaf)) {
        throw "Successful install did not publish stable entrypoint: $name"
    }
}
$shortcutPath = Join-Path $desktopRoot 'TPF2MP Multiplayer.lnk'
if (-not (Test-Path -LiteralPath $shortcutPath -PathType Leaf)) {
    throw 'Explicit first-install desktop-shortcut request did not create the stable shortcut.'
}
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
if ([IO.Path]::GetFullPath([string]$shortcut.TargetPath) `
        -ne [IO.Path]::GetFullPath((Join-Path $installRoot 'LAUNCH_TPF2MP.cmd')) `
        -or [IO.Path]::GetFullPath([string]$shortcut.WorkingDirectory) `
        -ne [IO.Path]::GetFullPath($installRoot)) {
    throw 'Desktop shortcut does not target the version-stable installed launcher.'
}
$successfulBackups = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'backups') -Directory)
if ($successfulBackups.Count -ne 2 `
        -or -not (Test-Path -LiteralPath ([string]$installedCurrent.priorModBackup) -PathType Container)) {
    throw 'Successful replacement did not retain both recoverable prior-install backups.'
}

# Releases 0.38.0 and 0.38.1 passed named tokens through array splatting. A
# newer installer must accept that exact historical binding once so those
# versions can bootstrap into the fixed updater without a manual reinstall.
$legacyInstallRoot = Join-Path $caseRoot 'legacy updater support'
$legacyModsRoot = Join-Path $caseRoot 'legacy updater Steam\userdata\12345\1066780\local\mods'
$legacyArguments = @(
    '-BundleRoot', $bundle,
    '-InstallRoot', $legacyInstallRoot,
    '-LocalModsPath', $legacyModsRoot,
    '-SkipVerification', '-NoDesktopShortcut'
)
& (Join-Path $ProjectRoot 'tools\install_release.ps1') @legacyArguments
$legacyCurrent = Get-Content -LiteralPath (Join-Path $legacyInstallRoot 'current.json') -Raw | ConvertFrom-Json
if ([string]$legacyCurrent.version -ne '0.38.0-alpha' `
        -or (Get-Content -LiteralPath (Join-Path $legacyModsRoot 'tpf2_mp_1\mod.lua') -Raw) -ne 'new-mod') {
    throw 'Legacy array-splatted updater arguments did not bootstrap the corrected installer.'
}

Write-Host 'PASS release install rolls back failures, commits provenance, offers a stable desktop shortcut, and accepts the bounded legacy updater handoff'
