[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\release_common.ps1')

$bundle = Join-Path $TemporaryRoot 'release-manifest-fixture'
$requiredFiles = @(
    'tpf2_mp_1/mod.lua',
    'bin/tpf2mp.exe',
    'bin/native/tpf2mp_injector.exe',
    'bin/native/tpf2mp_hook_build35924.dll',
    'tools/install_release.ps1',
    'tools/verify_install.ps1',
    'tools/uninstall.ps1',
    'docs/README.md',
    'QUICK_START.md'
)
New-Item -ItemType Directory -Force -Path $bundle | Out-Null
foreach ($relative in $requiredFiles) {
    $path = Join-Path $bundle ($relative -replace '/', '\')
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    [IO.File]::WriteAllText($path, "fixture:$relative", [Text.UTF8Encoding]::new($false))
}

$records = @()
foreach ($relative in $requiredFiles | Sort-Object) {
    $path = Join-Path $bundle ($relative -replace '/', '\')
    $item = Get-Item -LiteralPath $path
    $records += [pscustomobject][ordered]@{
        path = $relative
        size = $item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$baseline = [pscustomobject][ordered]@{
    format = 2
    name = 'TPF2MP Competitive Prototype'
    version = '0.37.0-alpha'
    modMinorVersion = 37
    stateSchemaVersion = 29
    checkpointSchemaVersion = 5
    proposalSchemaVersion = 5
    passengerPresentationSchemaVersion = 2
    cargoPresentationSchemaVersion = 1
    deliverySchemaVersion = 2
    freightIndustrySchemaVersion = 2
    companionVersion = '0.11.0'
    source = [pscustomobject][ordered]@{
        commit = '0123456789abcdef0123456789abcdef01234567'
        dirty = $false
    }
    files = $records
}
$manifestPath = Join-Path $bundle 'release-manifest.json'

function Copy-FixtureManifest {
    return (($baseline | ConvertTo-Json -Depth 8) | ConvertFrom-Json)
}

function Write-FixtureManifest {
    param([Parameter(Mandatory = $true)]$Value)
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

function Assert-ManifestRejected {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][scriptblock]$Mutate
    )
    $candidate = Copy-FixtureManifest
    & $Mutate $candidate
    Write-FixtureManifest $candidate
    $rejected = $false
    try { Test-Tpf2mpReleaseManifest $bundle | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw "Release manifest accepted $Label." }
}

Write-FixtureManifest $baseline
$valid = Test-Tpf2mpReleaseManifest $bundle
if ([string]$valid.version -ne '0.37.0-alpha' -or @($valid.files).Count -ne $requiredFiles.Count) {
    throw 'Valid release manifest did not round-trip.'
}
if ([int]$valid.format -ne 2 -or [string]$valid.source.commit -ne $baseline.source.commit `
        -or [bool]$valid.source.dirty) {
    throw 'Valid release source provenance did not round-trip.'
}

$legacy = Copy-FixtureManifest
$legacy.format = 1
$legacy.PSObject.Properties.Remove('source')
Write-FixtureManifest $legacy
$legacyValid = Test-Tpf2mpReleaseManifest $bundle
if ([int]$legacyValid.format -ne 1) { throw 'Legacy format-1 release manifest was not accepted.' }

Write-FixtureManifest $baseline
Assert-ManifestRejected 'an unsupported manifest format' {
    param($value)
    $value.format = 3
}
Assert-ManifestRejected 'missing source provenance' {
    param($value)
    $value.PSObject.Properties.Remove('source')
}
Assert-ManifestRejected 'an invalid source commit' {
    param($value)
    $value.source.commit = 'deadbeef'
}
Assert-ManifestRejected 'a non-boolean source dirty flag' {
    param($value)
    $value.source.dirty = 'false'
}

Assert-ManifestRejected 'a missing schema version' {
    param($value)
    $value.PSObject.Properties.Remove('cargoPresentationSchemaVersion')
}
Assert-ManifestRejected 'a duplicate case-insensitive path' {
    param($value)
    $duplicate = $value.files[0] | Select-Object *
    $duplicate.path = ([string]$duplicate.path).ToUpperInvariant()
    $value.files = @($value.files) + $duplicate
}
Assert-ManifestRejected 'a parent traversal path' {
    param($value)
    $value.files[0].path = '../escape.txt'
}
Assert-ManifestRejected 'a non-canonical backslash path' {
    param($value)
    $value.files[0].path = 'docs\README.md'
}
Assert-ManifestRejected 'an invalid checksum' {
    param($value)
    $value.files[0].sha256 = 'abc'
}
Assert-ManifestRejected 'an invalid size' {
    param($value)
    $value.files[0].size = -1
}
Assert-ManifestRejected 'a missing required binary' {
    param($value)
    $value.files = @($value.files | Where-Object { $_.path -ne 'bin/tpf2mp.exe' })
}

Write-FixtureManifest $baseline
$tamperPath = Join-Path $bundle 'bin\tpf2mp.exe'
$original = [IO.File]::ReadAllBytes($tamperPath)
try {
    [IO.File]::WriteAllBytes($tamperPath, [byte[]]($original + [byte]0))
    $rejected = $false
    try { Test-Tpf2mpReleaseManifest $bundle | Out-Null }
    catch { $rejected = $true }
    if (-not $rejected) { throw 'Release manifest accepted a changed packaged file.' }
}
finally {
    [IO.File]::WriteAllBytes($tamperPath, $original)
}

Write-Host 'PASS release manifest provenance, legacy compatibility, metadata, paths, uniqueness, sizes, hashes, and required-file boundaries'
