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
$versionRoot = Join-Path $installRoot 'versions\0.37.0-alpha'
$currentPath = Join-Path $installRoot 'current.json'

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
foreach ($name in @('install_release.ps1', 'verify_install.ps1', 'uninstall.ps1', 'release_common.ps1')) {
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
    version = '0.37.0-alpha'
    modMinorVersion = 37
    stateSchemaVersion = 29
    checkpointSchemaVersion = 5
    proposalSchemaVersion = 5
    passengerPresentationSchemaVersion = 2
    cargoPresentationSchemaVersion = 1
    deliverySchemaVersion = 2
    freightIndustrySchemaVersion = 2
    companionVersion = '0.11.0'
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
if (@(Get-ChildItem -LiteralPath (Join-Path $installRoot 'backups') -Force).Count -gt 0) {
    throw 'Failed install left a detached prior bundle in backups after rollback.'
}

& (Join-Path $ProjectRoot 'tools\install_release.ps1') `
    -BundleRoot $bundle -InstallRoot $installRoot -LocalModsPath $modsRoot -SkipVerification
$installedCurrent = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
if ([int]$installedCurrent.schemaVersion -ne 2 `
        -or [int]$installedCurrent.manifestFormat -ne 2 `
        -or [string]$installedCurrent.sourceCommit -ne $manifest.source.commit `
        -or $installedCurrent.sourceDirty -isnot [bool] `
        -or [bool]$installedCurrent.sourceDirty) {
    throw 'Successful install current pointer did not retain exact source provenance.'
}
if ((Get-Content -LiteralPath (Join-Path $versionRoot 'tpf2_mp_1\mod.lua') -Raw) -ne 'new-mod' `
        -or (Get-Content -LiteralPath (Join-Path $targetMod 'mod.lua') -Raw) -ne 'new-mod') {
    throw 'Successful install did not commit identical support and active mod copies.'
}
$successfulBackups = @(Get-ChildItem -LiteralPath (Join-Path $installRoot 'backups') -Directory)
if ($successfulBackups.Count -ne 2 `
        -or -not (Test-Path -LiteralPath ([string]$installedCurrent.priorModBackup) -PathType Container)) {
    throw 'Successful replacement did not retain both recoverable prior-install backups.'
}

Write-Host 'PASS release install rolls back verification failure and commits provenance atomically on success'
