[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HostAddress,
    [string]$Session = 'local-dev',
    [string]$Peer = 'player2',
    [int]$Port = 29742,
    [string]$BridgePath,
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
if (-not $BridgePath) { $BridgePath = Join-Path ([System.IO.Path]::GetTempPath()) "tpf2mp_bridge\$Peer" }
$env:PYTHONPATH = Join-Path $projectRoot 'companion'

$arguments = @('-m', 'tpf2mp', 'client', $HostAddress, '--session', $Session, '--peer', $Peer, '--port', $Port, '--bridge', $BridgePath)
if ($ManifestPath) { $arguments += @('--manifest', $ManifestPath) }
& $python @arguments
exit $LASTEXITCODE
