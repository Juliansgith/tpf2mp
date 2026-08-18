[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Launch', 'Update', 'Verify', 'Uninstall')]
    [string]$Action,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
if (-not $InstallRoot) { $InstallRoot = $PSScriptRoot }
$install = [IO.Path]::GetFullPath($InstallRoot)
$currentPath = Join-Path $install 'current.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
    throw "TPF2MP has no current installation pointer: $currentPath"
}
$current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
if ([int]$current.schemaVersion -lt 2 -or -not [string]$current.version) {
    throw 'TPF2MP current installation pointer is invalid.'
}
$bundle = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$current.bundleRoot))
$versionsRoot = [IO.Path]::GetFullPath((Join-Path $install 'versions')).TrimEnd('\') + '\'
if (-not $bundle.StartsWith($versionsRoot, [StringComparison]::OrdinalIgnoreCase) `
        -or -not (Test-Path -LiteralPath (Join-Path $bundle 'release-manifest.json') -PathType Leaf)) {
    throw "TPF2MP current bundle is missing or outside the versions root: $bundle"
}

$scriptPath = switch ($Action) {
    'Launch' { Join-Path $bundle 'tools\multiplayer_launcher.ps1' }
    'Update' { Join-Path $bundle 'tools\update_release.ps1' }
    'Verify' { Join-Path $bundle 'tools\verify_install.ps1' }
    'Uninstall' { Join-Path $bundle 'tools\uninstall.ps1' }
}
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Installed $Action tool is missing: $scriptPath"
}
switch ($Action) {
    'Launch' { & $scriptPath -BundleRoot $bundle }
    'Update' { & $scriptPath -BundleRoot $bundle -InstallRoot $install }
    'Verify' { & $scriptPath -BundleRoot $bundle }
    'Uninstall' { & $scriptPath -InstallRoot $install }
}
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
