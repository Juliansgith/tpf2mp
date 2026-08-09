[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$LocalModsPath,
    [string]$GameExecutable,
    [switch]$SkipCompanionRun,
    [switch]$StrictNative,
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$manifest = Test-Tpf2mpReleaseManifest $bundle
$mods = Find-Tpf2mpLocalModsPath $LocalModsPath
$installedMod = Assert-Tpf2mpModTarget (Join-Path $mods 'tpf2_mp_1') $mods
if (-not (Test-Path -LiteralPath $installedMod -PathType Container)) { throw "Installed mod is missing: $installedMod" }

$modFiles = @($manifest.files | Where-Object { ([string]$_.path).StartsWith('tpf2_mp_1/') })
foreach ($file in $modFiles) {
    $relative = ([string]$file.path).Substring('tpf2_mp_1/'.Length) -replace '/', '\'
    $path = Join-Path $installedMod $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Installed mod file is missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne ([string]$file.sha256).ToLowerInvariant()) { throw "Installed mod checksum mismatch: $relative" }
}

$companion = Join-Path $bundle 'bin\tpf2mp.exe'
$companionOk = Test-Path -LiteralPath $companion -PathType Leaf
if ($companionOk -and -not $SkipCompanionRun) {
    & $companion --help *> $null
    $companionOk = $LASTEXITCODE -eq 0
}
if (-not $companionOk) { throw 'Packaged companion executable is missing or did not start successfully.' }

$game = Find-Tpf2mpGameExecutable $GameExecutable
$gameHash = $null
$nativeCompatible = $false
$nativeVerified = $false
if ($game) {
    $gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash.ToLowerInvariant()
    $nativeCompatible = $gameHash -eq $script:Tpf2ExeHash
    if ($nativeCompatible) {
        $injector = Join-Path $bundle 'bin\native\tpf2mp_injector.exe'
        if (Test-Path -LiteralPath $injector -PathType Leaf) {
            & $injector --verify $game *> $null
            $nativeVerified = $LASTEXITCODE -eq 0
        }
    }
}
if ($StrictNative -and -not ($nativeCompatible -and $nativeVerified)) {
    throw 'Installed game does not pass the exact Build 35924 native-hook profile.'
}

$result = [ordered]@{
    valid = $true
    version = [string]$manifest.version
    stateSchemaVersion = [int]$manifest.stateSchemaVersion
    checkpointSchemaVersion = [int]$manifest.checkpointSchemaVersion
    passengerPresentationSchemaVersion = [int]$manifest.passengerPresentationSchemaVersion
    cargoPresentationSchemaVersion = [int]$manifest.cargoPresentationSchemaVersion
    freightIndustrySchemaVersion = [int]$manifest.freightIndustrySchemaVersion
    bundle = $bundle
    modPath = $installedMod
    modFileCount = $modFiles.Count
    companion = $companion
    companionValid = $companionOk
    gameExecutable = $game
    gameSha256 = $gameHash
    nativeBuild35924Compatible = $nativeCompatible
    nativeProfileVerified = $nativeVerified
}
if ($AsJson) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Host "TPF2MP install valid: version $($result.version), state $($result.stateSchemaVersion), checkpoint $($result.checkpointSchemaVersion), passenger $($result.passengerPresentationSchemaVersion), cargo $($result.cargoPresentationSchemaVersion), freight $($result.freightIndustrySchemaVersion); $($result.modFileCount) mod files verified."
    Write-Host "Companion executable: OK ($companion)"
    if (-not $game) { Write-Warning 'Transport Fever 2 executable was not discovered; native hook was not checked.' }
    elseif ($nativeCompatible -and $nativeVerified) { Write-Host 'Native hook compatibility: Build 35924 exact profile verified.' }
    else { Write-Warning "Native hook disabled for this game build (SHA-256 $gameHash); standalone mod remains installed." }
}
