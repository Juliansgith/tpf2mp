[CmdletBinding()]
param(
    [string]$Session = 'local-dev',
    [string]$BundleRoot,
    [string]$LocalModsPath,
    [string]$GameExecutable,
    [string]$SavePath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Join-Path $bundle 'bin\tpf2mp.exe'
if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) { throw "Companion executable is missing: $companion" }
$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered; pass -GameExecutable.' }
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$mod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
if (-not (Test-Path -LiteralPath $mod -PathType Container)) { throw "Installed mod is missing: $mod" }
$companionSource = Join-Path $bundle 'companion\tpf2mp'
if (-not (Test-Path -LiteralPath $companionSource -PathType Container)) {
    throw "Companion fingerprint source is missing: $companionSource"
}
if (-not $OutputPath) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -OutputPath.' }
    $OutputPath = Join-Path $env:LOCALAPPDATA "TPF2MP\matches\$Session-manifest.json"
}
$output = Resolve-Tpf2mpFullPath $OutputPath
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $output) | Out-Null
$arguments = @(
    'fingerprint', '--game-exe', $game, '--mod-dir', $mod,
    '--companion-dir', $companionSource, '--extra', (Join-Path $bundle 'bin\native'), '--output', $output
)
if ($SavePath) { $arguments += @('--save', (Resolve-Tpf2mpFullPath $SavePath)) }
& $companion @arguments
if ($LASTEXITCODE -ne 0) { throw "Manifest generation failed with exit code $LASTEXITCODE" }
Write-Host "Match manifest written: $output"
Write-Host 'Each peer must generate the same fingerprint from identical game/mod/companion/native files.'
