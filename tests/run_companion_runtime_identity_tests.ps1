[CmdletBinding()]
param([string]$BundleRoot)
$ErrorActionPreference='Stop'
if (-not $BundleRoot) { $BundleRoot=Split-Path -Parent $PSScriptRoot }
. (Join-Path $BundleRoot 'tools/network_common.ps1')
$command=Get-Tpf2mpCompanionCommand $BundleRoot
if ($command.PSObject.Properties['RuntimeExecutable']) {
    $expected=(& $command.FilePath -c 'import sys; print(sys._base_executable)').Trim()
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $expected -PathType Leaf) -or
        [IO.Path]::GetFullPath($expected) -ine [IO.Path]::GetFullPath($command.RuntimeExecutable)) {
        throw 'Companion process identity does not follow the Python redirector.'
    }
} elseif (-not (Test-Path -LiteralPath $command.FilePath -PathType Leaf)) {
    throw 'Packaged companion executable is missing.'
}
Write-Host 'PASS companion runtime identity (including Windows venv redirectors)'
