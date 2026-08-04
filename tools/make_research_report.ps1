[CmdletBinding()]
param(
    [string]$Peer = 'player1',
    [string]$Session = 'local-dev',
    [string]$BridgePath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw "Python not found at $python" }

if (-not $BridgePath) {
    $BridgePath = Join-Path ([System.IO.Path]::GetTempPath()) "tpf2mp_bridge\$Peer"
}
if (-not $OutputPath) {
    $OutputPath = Join-Path $projectRoot "runtime\research-$Session-$Peer.md"
}

$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = Join-Path $projectRoot 'companion'
try {
    & $python -m tpf2mp research-report --peer $Peer --session $Session --bridge $BridgePath --output $OutputPath
    if ($LASTEXITCODE -ne 0) { throw "Research report generation failed with exit code $LASTEXITCODE" }
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
