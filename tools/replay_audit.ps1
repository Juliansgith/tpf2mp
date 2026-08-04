[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AuditPath,
    [string]$Session
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
$env:PYTHONPATH = Join-Path $projectRoot 'companion'
$arguments = @('-m', 'tpf2mp', 'replay', $AuditPath)
if ($Session) { $arguments += @('--session', $Session) }
& $python @arguments
exit $LASTEXITCODE
