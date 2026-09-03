[CmdletBinding()]
param(
    [string]$GameExecutable = 'F:\SteamLibrary\steamapps\common\Transport Fever 2\TransportFever2.exe',
    [string]$InstalledModPath = 'C:\Program Files (x86)\Steam\userdata\63389028\1066780\local\mods\tpf2_mp_1',
    [string]$SavePath,
    [string]$OutputPath,
    [string[]]$ExtraPath = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
$env:PYTHONPATH = Join-Path $projectRoot 'companion'
if (-not $OutputPath) {
    $runtime = Join-Path $projectRoot 'runtime'
    New-Item -ItemType Directory -Force -Path $runtime | Out-Null
    $OutputPath = Join-Path $runtime 'match-manifest.json'
}
$arguments = @(
    '-m', 'tpf2mp', 'fingerprint',
    '--game-exe', $GameExecutable,
    '--mod-dir', $InstalledModPath,
    '--companion-dir', (Join-Path $projectRoot 'companion\tpf2mp'),
    '--output', $OutputPath
)
if ($SavePath) {
    $arguments += @(
        '--save', $SavePath, '--active-mod-save', $SavePath,
        '--content-cache', (Join-Path $env:LOCALAPPDATA 'TPF2MP\cache\active-content-v1.json')
    )
}
foreach ($path in $ExtraPath) { $arguments += @('--extra', $path) }
& $python @arguments
exit $LASTEXITCODE
