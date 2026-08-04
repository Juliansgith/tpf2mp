[CmdletBinding()]
param(
    [string]$Session = 'local-dev',
    [string]$Peer = 'player1',
    [string]$BindAddress = '127.0.0.1',
    [int]$Port = 29742,
    [string]$BridgePath,
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
if (-not $BridgePath) { $BridgePath = Join-Path ([System.IO.Path]::GetTempPath()) "tpf2mp_bridge\$Peer" }
$env:PYTHONPATH = Join-Path $projectRoot 'companion'

$arguments = @('-m', 'tpf2mp', 'host', '--session', $Session, '--peer', $Peer, '--bind', $BindAddress, '--port', $Port, '--bridge', $BridgePath)
if ($ManifestPath) { $arguments += @('--manifest', $ManifestPath) }
& $python @arguments
exit $LASTEXITCODE
