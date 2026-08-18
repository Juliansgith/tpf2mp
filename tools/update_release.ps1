[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$InstallRoot,
    [string]$LocalModsPath,
    [string]$Repository,
    [ValidateSet('alpha', 'stable')][string]$Channel,
    [switch]$CheckOnly,
    [string]$ArchivePath,
    [string]$ExpectedSha256,
    [switch]$Force,
    [switch]$AllowDirtyRelease,
    [switch]$NoCredentialPrompt
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
. (Join-Path $PSScriptRoot 'update_common.ps1')
. (Join-Path $PSScriptRoot 'github_release_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$bundleManifest = Test-Tpf2mpReleaseManifest $bundle
if (-not $InstallRoot) {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -InstallRoot explicitly.' }
    $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
}
$install = Resolve-Tpf2mpFullPath $InstallRoot
$currentPath = Join-Path $install 'current.json'
$currentVersion = [string]$bundleManifest.version
if (Test-Path -LiteralPath $currentPath -PathType Leaf) {
    $current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
    if ([string]$current.version) { $currentVersion = [string]$current.version }
}
$updateMetadata = $bundleManifest.PSObject.Properties['update']
if (-not $Repository) {
    if ($null -eq $updateMetadata -or -not [string]$updateMetadata.Value.repository) {
        throw 'Release manifest does not declare an update repository; pass -Repository explicitly.'
    }
    $Repository = [string]$updateMetadata.Value.repository
}
[void](Assert-Tpf2mpGitHubRepository $Repository)
if (-not $Channel) {
    $Channel = if ($null -ne $updateMetadata -and [string]$updateMetadata.Value.channel -eq 'stable') {
        'stable'
    } else { 'alpha' }
}

function Invoke-Tpf2mpReleaseQuery([string]$Token) {
    $uri = "https://api.github.com/repos/$Repository/releases?per_page=50"
    return @(Invoke-RestMethod -Uri $uri -Headers (New-Tpf2mpGitHubHeaders $Token) -Method Get)
}

function Save-Tpf2mpGitHubAsset($Asset, [string]$Destination, [string]$Token) {
    $uri = if ($Token -and [string]$Asset.url) { [string]$Asset.url } else { [string]$Asset.browser_download_url }
    if (-not $uri -or $uri -notmatch '^https://') { throw "Release asset has no safe download URL: $($Asset.name)" }
    $accept = if ($Token -and [string]$Asset.url) { 'application/octet-stream' } else { 'application/vnd.github+json' }
    Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers (New-Tpf2mpGitHubHeaders $Token $accept) `
        -OutFile $Destination
}

function Get-Tpf2mpOnlineRelease {
    $token = $null
    try { $releases = Invoke-Tpf2mpReleaseQuery $null }
    catch {
        $token = Get-Tpf2mpGitHubToken -NoCredentialPrompt:$NoCredentialPrompt
        if (-not $token) {
            throw "GitHub could not read $Repository anonymously and no user credential is available. Sign in with GitHub CLI, Git Credential Manager, or TPF2MP_GITHUB_TOKEN."
        }
        $releases = Invoke-Tpf2mpReleaseQuery $token
    }
    $selected = Select-Tpf2mpGitHubRelease -Releases $releases -CurrentVersion $currentVersion -Channel $Channel
    return [pscustomobject]@{ selected = $selected; token = $token }
}

if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Close every Transport Fever 2 instance before installing an update.'
}

$temporaryRoot = $null
try {
    $selectedVersion = $null
    $sourceArchive = $null
    $expectedHash = $null
    if ($ArchivePath) {
        $sourceArchive = Resolve-Tpf2mpFullPath $ArchivePath
        if (-not (Test-Path -LiteralPath $sourceArchive -PathType Leaf)) {
            throw "Local update archive is missing: $sourceArchive"
        }
        if ($ExpectedSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            throw 'A local update requires -ExpectedSha256 with exactly 64 hexadecimal characters.'
        }
        $expectedHash = $ExpectedSha256.ToLowerInvariant()
    }
    else {
        $online = Get-Tpf2mpOnlineRelease
        if ($null -eq $online.selected) {
            Write-Host "TPF2MP $currentVersion is current on the $Channel channel."
            exit 0
        }
        $selectedVersion = [string]$online.selected.version
        Write-Host "TPF2MP $selectedVersion is available (installed: $currentVersion)."
        if ($CheckOnly) { exit 0 }
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-update-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
        $sourceArchive = Join-Path $temporaryRoot ([string]$online.selected.archiveName)
        Save-Tpf2mpGitHubAsset $online.selected.archiveAsset $sourceArchive $online.token
        if ($online.selected.assetDigest) {
            $expectedHash = [string]$online.selected.assetDigest
        }
        else {
            $sidecar = Join-Path $temporaryRoot (([string]$online.selected.archiveName) + '.sha256')
            Save-Tpf2mpGitHubAsset $online.selected.checksumAsset $sidecar $online.token
            $expectedHash = Read-Tpf2mpSha256File $sidecar ([string]$online.selected.archiveName)
        }
    }

    $actualHash = (Get-FileHash -LiteralPath $sourceArchive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) { throw 'Downloaded release ZIP failed SHA-256 verification.' }
    if (-not $temporaryRoot) {
        $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-update-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    }
    $extractedRoot = Join-Path $temporaryRoot 'extracted'
    $newBundle = Expand-Tpf2mpReleaseArchive $sourceArchive $extractedRoot
    $newManifest = Test-Tpf2mpReleaseManifest $newBundle
    $newVersion = [string]$newManifest.version
    if ($selectedVersion -and $newVersion -cne $selectedVersion) {
        throw "Release tag/archive version mismatch: selected $selectedVersion, archive $newVersion."
    }
    $comparison = Compare-Tpf2mpSemanticVersion $newVersion $currentVersion
    if ($comparison -lt 0 -and -not $Force) { throw "Refusing downgrade from $currentVersion to $newVersion." }
    if ($comparison -eq 0 -and -not $Force) {
        Write-Host "TPF2MP $currentVersion is already installed."
        exit 0
    }
    if ([int]$newManifest.format -lt 2 -or [bool]$newManifest.source.dirty) {
        if (-not $AllowDirtyRelease) { throw 'Automatic updates require a clean format-2 release build.' }
    }
    if ($CheckOnly) {
        Write-Host "TPF2MP $newVersion is a verified local update (installed: $currentVersion)."
        exit 0
    }

    $installArguments = @{
        BundleRoot = $newBundle
        InstallRoot = $install
    }
    if ($LocalModsPath) { $installArguments.LocalModsPath = $LocalModsPath }
    & (Join-Path $newBundle 'tools\install_release.ps1') @installArguments
    if ($LASTEXITCODE -ne 0) { throw "Update installer failed with exit code $LASTEXITCODE." }
    Write-Host "TPF2MP updated successfully: $currentVersion -> $newVersion"
}
finally {
    if ($temporaryRoot -and (Test-Path -LiteralPath $temporaryRoot)) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
