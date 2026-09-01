[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\runtime_overlay_common.ps1')

$caseRoot = Join-Path $TemporaryRoot 'runtime-overlay-cleanup'
$gameRoot = Join-Path $caseRoot 'game'
$game = Join-Path $gameRoot 'TransportFever2.exe'
$mods = Join-Path $caseRoot 'Steam\userdata\12345\1066780\local\mods'
$install = Join-Path $caseRoot 'support'
New-Item -ItemType Directory -Force -Path $gameRoot, $mods, $install | Out-Null
[IO.File]::WriteAllBytes($game, [byte[]]@(77, 90))

function Install-TestOverlay {
    $inventory = @(Get-Tpf2mpRuntimeOverlayInventory `
        -BundleRoot $ProjectRoot -GameExecutable $game)
    foreach ($entry in $inventory) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $entry.target) | Out-Null
        Copy-Item -LiteralPath $entry.source -Destination $entry.target `
            -Recurse:([bool]$entry.directory) -Force
    }
    return $inventory
}

$inventory = @(Install-TestOverlay)
if ($inventory.Count -ne 4) { throw 'Runtime-overlay fixture did not contain four managed targets.' }

# Reproduce the field report exactly: the normal local-mod directory is absent
# before uninstall runs, while all launcher-injected base-game files remain.
& (Join-Path $ProjectRoot 'tools\uninstall.ps1') -LocalModsPath $mods `
    -InstallRoot $install -GameExecutable $game
foreach ($entry in $inventory) {
    if (Test-Path -LiteralPath $entry.target) {
        throw "Uninstall left orphan runtime overlay active: $($entry.target)"
    }
}
$cleanupManifests = @(Get-ChildItem -LiteralPath (Join-Path $install 'backups') `
    -Recurse -File -Filter 'overlay-cleanup.json')
if ($cleanupManifests.Count -ne 1) {
    throw 'Uninstall did not create one recoverable runtime-overlay archive.'
}
$cleanup = Get-Content -LiteralPath $cleanupManifests[0].FullName -Raw | ConvertFrom-Json
if (@($cleanup.entries).Count -ne 4) {
    throw 'Runtime-overlay archive did not inventory all four managed targets.'
}

# Cleanup is intentionally marker-bound. A foreign file at the reserved path
# must survive and produce an error instead of becoming a broad base-game wipe.
$foreign = ($inventory | Where-Object { $_.kind -eq 'game-script' }).target
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $foreign) | Out-Null
[IO.File]::WriteAllText($foreign, 'function data() return {} end', [Text.UTF8Encoding]::new($false))
$refused = $false
try {
    [void](Remove-Tpf2mpManagedRuntimeOverlay -BundleRoot $ProjectRoot `
        -GameExecutable $game -ArchiveRoot (Join-Path $caseRoot 'foreign-backup'))
}
catch { $refused = $_.Exception.Message -match 'not recognizably managed' }
if (-not $refused -or -not (Test-Path -LiteralPath $foreign -PathType Leaf)) {
    throw 'Runtime-overlay cleanup did not preserve an unrecognized base-game file.'
}

Write-Host 'PASS uninstall removes an orphan overlay without the mod and refuses foreign base-game files'
