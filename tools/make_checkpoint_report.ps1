[CmdletBinding()]
param(
    [string]$Peer = 'player1',
    [string]$Session = 'local-dev',
    [string]$BridgePath,
    [ValidateSet('first', 'latest')]
    [string]$Anchor = 'latest',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
if (-not (Test-Path -LiteralPath $python)) { throw "Python not found at $python" }

if (-not $BridgePath) {
    $BridgePath = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$Peer"
}
if (-not $OutputPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $projectRoot "runtime\checkpoint-$Session-$Peer-$stamp.md"
}

$resolvedBridge = [IO.Path]::GetFullPath($BridgePath)
$resolvedOutput = [IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $resolvedOutput
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$previousPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = Join-Path $projectRoot 'companion'
try {
    & $python -m tpf2mp checkpoint-report --peer $Peer --session $Session --bridge $resolvedBridge --anchor $Anchor --output $resolvedOutput
    if ($LASTEXITCODE -ne 0) { throw "Checkpoint report failed with exit code $LASTEXITCODE" }
}
finally {
    $env:PYTHONPATH = $previousPythonPath
}
