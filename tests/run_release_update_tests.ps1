[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\update_common.ps1')
. (Join-Path $ProjectRoot 'tools\github_release_common.ps1')
. (Join-Path $ProjectRoot 'tools\launcher_worker_result.ps1')

function Assert-VersionOrder([string]$Older, [string]$Newer) {
    if ((Compare-Tpf2mpSemanticVersion $Older $Newer) -ge 0 `
            -or (Compare-Tpf2mpSemanticVersion $Newer $Older) -le 0) {
        throw "Semantic version order failed: $Older < $Newer"
    }
}

Assert-VersionOrder '0.38.0-alpha' '0.38.0-alpha.2'
Assert-VersionOrder '0.38.0-alpha.2' '0.38.0-alpha.10'
Assert-VersionOrder '0.38.0-alpha.10' '0.38.0-beta'
Assert-VersionOrder '0.38.0-beta' '0.38.0'
Assert-VersionOrder '0.38.1-alpha' '0.38.2-alpha'
Assert-VersionOrder '0.38.0' '0.39.0-alpha'
if ((Compare-Tpf2mpSemanticVersion 'v0.38.0-alpha+build.1' '0.38.0-alpha+build.9') -ne 0) {
    throw 'Semantic build metadata unexpectedly affected precedence.'
}
$invalidAccepted = $false
try { [void](ConvertTo-Tpf2mpSemanticVersion '0.038.0') } catch { $invalidAccepted = $true }
if (-not $invalidAccepted) { throw 'Semantic version parser accepted a leading-zero component.' }

function New-FixtureRelease {
    param(
        [string]$Tag,
        [bool]$Prerelease,
        [bool]$Draft = $false,
        [bool]$Checksum = $true,
        [string]$Digest = $null
    )
    $version = $Tag.TrimStart('v')
    $name = "TPF2MP-$version.zip"
    $archive = [pscustomobject]@{ name = $name; url = "https://api.invalid/$name"; browser_download_url = "https://download.invalid/$name" }
    if ($Digest) { $archive | Add-Member -NotePropertyName digest -NotePropertyValue $Digest }
    $assets = @($archive)
    if ($Checksum) {
        $assets += [pscustomobject]@{
            name = $name + '.sha256'
            url = "https://api.invalid/$name.sha256"
            browser_download_url = "https://download.invalid/$name.sha256"
        }
    }
    return [pscustomobject]@{
        tag_name = $Tag
        prerelease = $Prerelease
        draft = $Draft
        assets = $assets
    }
}

$releases = @(
    (New-FixtureRelease 'v0.39.0' $false),
    (New-FixtureRelease 'v0.40.0-alpha.2' $true),
    (New-FixtureRelease 'v9.0.0' $false $true),
    [pscustomobject]@{ tag_name = 'not-a-version'; prerelease = $false; draft = $false; assets = @() }
)
if ($null -ne (Select-Tpf2mpGitHubRelease @() '0.38.0-alpha' alpha)) {
    throw 'An empty GitHub release feed unexpectedly produced an update.'
}
$alpha = Select-Tpf2mpGitHubRelease $releases '0.38.0-alpha' alpha
if ($alpha.version -ne '0.40.0-alpha.2' -or $alpha.archiveName -ne 'TPF2MP-0.40.0-alpha.2.zip') {
    throw 'Alpha update selection did not choose the highest eligible semantic version.'
}
$stable = Select-Tpf2mpGitHubRelease $releases '0.38.0-alpha' stable
if ($stable.version -ne '0.39.0') { throw 'Stable update selection admitted a prerelease.' }
if ($null -ne (Select-Tpf2mpGitHubRelease $releases '0.40.0-alpha.2' alpha)) {
    throw 'Update selection offered a downgrade or reinstall.'
}
$missingIntegrityRejected = $false
try {
    [void](Select-Tpf2mpGitHubRelease @(
        (New-FixtureRelease 'v0.41.0-alpha' $true $false $false)) '0.40.0-alpha.2' alpha)
}
catch { $missingIntegrityRejected = $_.Exception.Message -match 'neither.*SHA-256' }
if (-not $missingIntegrityRejected) { throw 'Update selection accepted an asset without SHA-256 metadata.' }

$caseRoot = Join-Path $TemporaryRoot 'release-update'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
$notesPath = Join-Path $caseRoot 'release notes.md'
$notesExpected = "# Notes`r`n`r`nExact body."
[IO.File]::WriteAllText($notesPath, $notesExpected, [Text.UTF8Encoding]::new($false))
$notesBody = [ordered]@{ body = [string](Read-Tpf2mpReleaseNotesText $notesPath) } | ConvertTo-Json
$notesRoundTrip = $notesBody | ConvertFrom-Json
if ([string]$notesRoundTrip.body -cne $notesExpected `
        -or $notesBody -match 'PSPath|PSDrive|Provider') {
    throw 'Release notes did not serialize as one exact JSON string.'
}
$sidecar = Join-Path $caseRoot 'fixture.zip.sha256'
$expectedHash = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
[IO.File]::WriteAllText($sidecar, "$expectedHash  fixture.zip`n", [Text.UTF8Encoding]::new($false))
if ((Read-Tpf2mpSha256File $sidecar 'fixture.zip') -ne $expectedHash) {
    throw 'SHA-256 sidecar did not parse exactly.'
}
$wrongNameRejected = $false
try { [void](Read-Tpf2mpSha256File $sidecar 'other.zip') } catch { $wrongNameRejected = $true }
if (-not $wrongNameRejected) { throw 'SHA-256 sidecar accepted the wrong archive name.' }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$validSource = Join-Path $caseRoot 'valid-source'
$validBundle = Join-Path $validSource 'TPF2MP-0.39.0-alpha'
New-Item -ItemType Directory -Force -Path (Join-Path $validBundle 'tools') | Out-Null
[IO.File]::WriteAllText((Join-Path $validBundle 'release-manifest.json'), '{}', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $validBundle 'tools\sample.txt'), 'sample', [Text.UTF8Encoding]::new($false))
$validZip = Join-Path $caseRoot 'valid.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($validSource, $validZip)
$expanded = Expand-Tpf2mpReleaseArchive $validZip (Join-Path $caseRoot 'valid-expanded')
if ((Split-Path -Leaf $expanded) -ne 'TPF2MP-0.39.0-alpha' `
        -or -not (Test-Path -LiteralPath (Join-Path $expanded 'tools\sample.txt') -PathType Leaf)) {
    throw 'Safe release archive did not extract to its single bundle root.'
}

$unsafeZip = Join-Path $caseRoot 'unsafe.zip'
$stream = [IO.File]::Open($unsafeZip, [IO.FileMode]::CreateNew)
$zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    $entry = $zip.CreateEntry('../release-manifest.json')
    $writer = [IO.StreamWriter]::new($entry.Open())
    try { $writer.Write('{}') } finally { $writer.Dispose() }
}
finally { $zip.Dispose(); $stream.Dispose() }
$unsafeRejected = $false
try { [void](Expand-Tpf2mpReleaseArchive $unsafeZip (Join-Path $caseRoot 'unsafe-expanded')) }
catch { $unsafeRejected = $_.Exception.Message -match 'Unsafe release archive path' }
if (-not $unsafeRejected -or (Test-Path -LiteralPath (Join-Path $caseRoot 'unsafe-expanded'))) {
    throw 'Release ZIP traversal was not rejected before extraction.'
}

function New-MinimalUpdateBundle([string]$Root, [string]$Version, [string]$Commit) {
    $paths = @(
        'tpf2_mp_1/mod.lua', 'bin/tpf2mp.exe', 'bin/native/tpf2mp_injector.exe',
        'bin/native/tpf2mp_hook_build35924.dll', 'tools/install_release.ps1',
        'tools/verify_install.ps1', 'tools/uninstall.ps1', 'tools/update_release.ps1',
        'tools/update_common.ps1', 'tools/github_release_common.ps1',
        'tools/installed_entrypoint.ps1', 'tools/installed_command.cmd',
        'docs/README.md', 'QUICK_START.md', 'UPDATE_TPF2MP.cmd'
    )
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    foreach ($relative in $paths) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [IO.File]::WriteAllText($path, "fixture:$relative", [Text.UTF8Encoding]::new($false))
    }
    $installer = @'
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [string]$LocalModsPath
)
$resolvedInstall = [IO.Path]::GetFullPath($InstallRoot)
New-Item -ItemType Directory -Force -Path $resolvedInstall | Out-Null
$receipt = [ordered]@{
    bundleRoot = [IO.Path]::GetFullPath($BundleRoot)
    installRoot = $resolvedInstall
    localModsPath = if ($LocalModsPath) { [IO.Path]::GetFullPath($LocalModsPath) } else { $null }
} | ConvertTo-Json -Compress
[IO.File]::WriteAllText(
    (Join-Path $resolvedInstall 'update-install-receipt.json'),
    $receipt,
    [Text.UTF8Encoding]::new($false))
'@
    [IO.File]::WriteAllText(
        (Join-Path $Root 'tools\install_release.ps1'),
        $installer,
        [Text.UTF8Encoding]::new($false))
    $records = @()
    foreach ($relative in $paths | Sort-Object) {
        $path = Join-Path $Root ($relative -replace '/', '\')
        $file = Get-Item -LiteralPath $path
        $records += [pscustomobject][ordered]@{
            path = $relative
            size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    [pscustomobject][ordered]@{
        format = 2
        name = 'TPF2MP Competitive Prototype'
        version = $Version
        modMinorVersion = 39
        stateSchemaVersion = 31
        checkpointSchemaVersion = 5
        proposalSchemaVersion = 5
        operationSchemaVersion = 4
        passengerPresentationSchemaVersion = 4
        cargoPresentationSchemaVersion = 2
        deliverySchemaVersion = 3
        freightIndustrySchemaVersion = 3
        companionVersion = $Version
        source = [pscustomobject][ordered]@{ commit = $Commit; dirty = $false }
        update = [pscustomobject][ordered]@{
            provider = 'github-releases'; repository = 'Juliansgith/tpf2mp'; channel = 'alpha'
        }
        files = $records
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Root 'release-manifest.json') -Encoding UTF8
}

$currentFixture = Join-Path $caseRoot 'current-bundle'
$nextContainer = Join-Path $caseRoot 'next-container'
$nextFixture = Join-Path $nextContainer 'TPF2MP-0.39.0-alpha'
New-MinimalUpdateBundle $currentFixture '0.38.0-alpha' '1111111111111111111111111111111111111111'
New-MinimalUpdateBundle $nextFixture '0.39.0-alpha' '2222222222222222222222222222222222222222'
$nextZip = Join-Path $caseRoot 'TPF2MP-0.39.0-alpha.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($nextContainer, $nextZip)
$nextHash = (Get-FileHash -LiteralPath $nextZip -Algorithm SHA256).Hash.ToLowerInvariant()
$checkOutput = @(& (Join-Path $ProjectRoot 'tools\update_release.ps1') `
    -BundleRoot $currentFixture -InstallRoot (Join-Path $caseRoot 'unused-install') `
    -ArchivePath $nextZip -ExpectedSha256 $nextHash -CheckOnly 6>&1)
if (-not ($checkOutput -join "`n").Contains('0.39.0-alpha is a verified local update')) {
    throw 'End-to-end local update check did not verify the newer release archive.'
}

$sourceInstallRoot = Join-Path $caseRoot 'source-launcher-install'
$sourceInstalledBundle = Join-Path $sourceInstallRoot 'versions\0.38.0-alpha'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $sourceInstalledBundle) | Out-Null
Copy-Item -LiteralPath $currentFixture -Destination $sourceInstalledBundle -Recurse
[pscustomobject][ordered]@{
    schemaVersion = 2
    version = '0.38.0-alpha'
    bundleRoot = $sourceInstalledBundle
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sourceInstallRoot 'current.json') -Encoding UTF8
$sourceTreeFixture = Join-Path $caseRoot 'development-source-tree'
New-Item -ItemType Directory -Force -Path (Join-Path $sourceTreeFixture '.git') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $sourceTreeFixture 'companion\tpf2mp') | Out-Null
[IO.File]::WriteAllText(
    (Join-Path $sourceTreeFixture 'companion\tpf2mp\__init__.py'),
    '__version__ = "0.38.0-alpha"',
    [Text.UTF8Encoding]::new($false))
$sourceCheckOutput = @(& (Join-Path $ProjectRoot 'tools\update_release.ps1') `
    -BundleRoot $sourceTreeFixture -InstallRoot $sourceInstallRoot `
    -ArchivePath $nextZip -ExpectedSha256 $nextHash -CheckOnly 6>&1)
$sourceCheckText = $sourceCheckOutput -join "`n"
if (-not $sourceCheckText.Contains('Development source tree detected') `
        -or -not $sourceCheckText.Contains('0.39.0-alpha is a verified local update')) {
    throw 'Development launcher did not delegate update checking to the installed signed release.'
}

$installedRoot = Join-Path $caseRoot 'installed-root'
$installedMods = Join-Path $caseRoot 'installed mods'
$installOutput = @(& (Join-Path $ProjectRoot 'tools\update_release.ps1') `
    -BundleRoot $currentFixture -InstallRoot $installedRoot -LocalModsPath $installedMods `
    -ArchivePath $nextZip -ExpectedSha256 $nextHash 6>&1)
if (-not ($installOutput -join "`n").Contains('0.38.0-alpha -> 0.39.0-alpha')) {
    throw 'End-to-end local update did not complete its installer handoff.'
}
$installReceiptPath = Join-Path $installedRoot 'update-install-receipt.json'
if (-not (Test-Path -LiteralPath $installReceiptPath -PathType Leaf)) {
    throw 'End-to-end local update did not invoke the packaged installer.'
}
$installReceipt = Get-Content -LiteralPath $installReceiptPath -Raw | ConvertFrom-Json
if ([IO.Path]::GetFullPath([string]$installReceipt.installRoot) -ne [IO.Path]::GetFullPath($installedRoot) `
        -or [IO.Path]::GetFullPath([string]$installReceipt.localModsPath) -ne [IO.Path]::GetFullPath($installedMods) `
        -or (Split-Path -Leaf ([string]$installReceipt.bundleRoot)) -ne 'TPF2MP-0.39.0-alpha') {
    throw 'Updater did not pass exact named paths to the packaged installer.'
}

$workerResultRoot = Join-Path $caseRoot 'launcher-worker-result'
$workerInstallRoot = Join-Path $workerResultRoot 'install'
$workerBundle = Join-Path $workerInstallRoot 'versions\0.39.0-alpha'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $workerBundle) | Out-Null
Copy-Item -LiteralPath $nextFixture -Destination $workerBundle -Recurse
[pscustomobject][ordered]@{
    schemaVersion = 2
    version = '0.39.0-alpha'
    bundleRoot = $workerBundle
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workerInstallRoot 'current.json') -Encoding UTF8
$workerStdout = Join-Path $workerResultRoot 'update.stdout.log'
$workerStderr = Join-Path $workerResultRoot 'update.stderr.log'
[IO.File]::WriteAllText(
    $workerStdout,
    "TPF2MP updated successfully: 0.38.0-alpha -> 0.39.0-alpha`r`n",
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($workerStderr, '', [Text.UTF8Encoding]::new($false))
$verifiedWorkerResult = Get-Tpf2mpVerifiedReleaseUpdateResult `
    -StdoutPath $workerStdout -StderrPath $workerStderr -InstallRoot $workerInstallRoot
if (-not $verifiedWorkerResult -or $verifiedWorkerResult.version -cne '0.39.0-alpha') {
    throw 'Launcher did not independently verify a committed successful update.'
}
[IO.File]::WriteAllText($workerStderr, 'late failure', [Text.UTF8Encoding]::new($false))
if (Get-Tpf2mpVerifiedReleaseUpdateResult `
        -StdoutPath $workerStdout -StderrPath $workerStderr -InstallRoot $workerInstallRoot) {
    throw 'Launcher accepted update evidence with stderr residue.'
}
[IO.File]::WriteAllText($workerStderr, '', [Text.UTF8Encoding]::new($false))
$workerPointerPath = Join-Path $workerInstallRoot 'current.json'
$workerPointer = Get-Content -LiteralPath $workerPointerPath -Raw | ConvertFrom-Json
$workerPointer.version = '0.38.0-alpha'
$workerPointer | ConvertTo-Json | Set-Content -LiteralPath $workerPointerPath -Encoding UTF8
if (Get-Tpf2mpVerifiedReleaseUpdateResult `
        -StdoutPath $workerStdout -StderrPath $workerStderr -InstallRoot $workerInstallRoot) {
    throw 'Launcher accepted update evidence whose installed pointer names another version.'
}

Write-Host 'PASS semantic update selection, integrity metadata, sidecars, safe extraction, ZIP traversal refusal, end-to-end install handoff, and launcher result verification'
