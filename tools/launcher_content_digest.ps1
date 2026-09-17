[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$ModDirectory,
    [string]$ActiveModSave
)

# Worker wrapper: the local active-content fingerprint can take seconds, so the
# launcher never calls it on its UI thread. This script runs it out of process
# and prints one parsable line the launcher reads back from the worker log. The
# digest names content only; it carries no credential and is safe to log.

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
$precheckModule = Join-Path $PSScriptRoot 'launcher_mod_precheck.ps1'
if (-not (Test-Path -LiteralPath $precheckModule -PathType Leaf)) {
    throw 'This bundle has no local content fingerprint module; the lobby still enforces content.'
}
. $precheckModule
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
if (-not $GameExecutable) { $GameExecutable = Find-Tpf2mpGameExecutable }
if (-not $GameExecutable) { throw 'Transport Fever 2 executable was not found.' }
if (-not $ModDirectory) { $ModDirectory = Join-Path (Find-Tpf2mpLocalModsPath) 'tpf2_mp_1' }

$arguments = @{
    BundleRoot = $bundle
    GameExecutable = $GameExecutable
    ModDirectory = $ModDirectory
}
if ($ActiveModSave) { $arguments['ActiveModSave'] = $ActiveModSave }
$result = Get-Tpf2mpLocalContentDigest @arguments
$digest = ''
if ($result -and $result.PSObject.Properties['Digest']) { $digest = [string]$result.Digest }
if ($digest -notmatch '^[0-9a-f]{8,128}$') {
    throw 'The local content fingerprint did not produce a usable digest.'
}
$modCount = 0
if ($result.PSObject.Properties['Mods'] -and $result.Mods) { $modCount = @($result.Mods).Count }
Write-Output "local_content_digest=$digest"
Write-Output "local_content_mods=$modCount"
