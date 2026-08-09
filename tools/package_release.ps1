[CmdletBinding()]
param(
    [string]$Version = '0.32.0-alpha',
    [string]$OutputDirectory,
    [string]$GameExecutable,
    [switch]$SkipTests,
    [switch]$SkipNativeBuild,
    [switch]$SkipPackageInstallTest
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'release_common.ps1')
$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered; pass -GameExecutable.' }
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$') { throw "Unsafe release version: $Version" }
$modSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\mod.lua') -Raw
$scriptSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\config\game_script\tpf2_mp.lua') -Raw
$proposalSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\proposal_codec.lua') -Raw
$passengerPresentationSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\passenger_presentation.lua') -Raw
$cargoPresentationSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\cargo_presentation.lua') -Raw
$deliverySource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\delivery_snapshot.lua') -Raw
$freightSource = Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_model.lua') -Raw
$projectSource = Get-Content -LiteralPath (Join-Path $projectRoot 'companion\pyproject.toml') -Raw
if ($modSource -notmatch 'local\s+minorVersion\s*=\s*(\d+)') { throw 'Could not derive the mod minor version.' }
$modMinorVersion = [int]$Matches[1]
if ($scriptSource -notmatch 'local\s+STATE_VERSION\s*=\s*(\d+)') { throw 'Could not derive the state schema version.' }
$stateSchemaVersion = [int]$Matches[1]
if ($scriptSource -notmatch 'local\s+CHECKPOINT_VERSION\s*=\s*(\d+)') { throw 'Could not derive the checkpoint schema version.' }
$checkpointSchemaVersion = [int]$Matches[1]
if ($proposalSource -notmatch 'SCHEMA_VERSION\s*=\s*(\d+)') { throw 'Could not derive the proposal schema version.' }
$proposalSchemaVersion = [int]$Matches[1]
if ($passengerPresentationSource -notmatch 'M\.SCHEMA_VERSION\s*=\s*(\d+)') { throw 'Could not derive the passenger-presentation schema version.' }
$passengerPresentationSchemaVersion = [int]$Matches[1]
if ($cargoPresentationSource -notmatch 'M\.SCHEMA_VERSION\s*=\s*(\d+)') { throw 'Could not derive the cargo-presentation schema version.' }
$cargoPresentationSchemaVersion = [int]$Matches[1]
if ($deliverySource -notmatch 'M\.SCHEMA_VERSION\s*=\s*(\d+)') { throw 'Could not derive the delivery schema version.' }
$deliverySchemaVersion = [int]$Matches[1]
if ($freightSource -notmatch 'STATE_SCHEMA_VERSION\s*=\s*(\d+)') { throw 'Could not derive the freight-industry schema version.' }
$freightIndustrySchemaVersion = [int]$Matches[1]
if ($projectSource -notmatch '(?m)^version\s*=\s*"([^"]+)"') { throw 'Could not derive the companion version.' }
$companionVersion = $Matches[1]
if ($Version -match '^0\.(\d+)' -and [int]$Matches[1] -ne $modMinorVersion) {
    throw "Release version $Version does not match mod minor version $modMinorVersion."
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'dist' }
$dist = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $dist | Out-Null

if (-not $SkipTests) {
    & (Join-Path $PSScriptRoot 'run_tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Automated suite failed with exit code $LASTEXITCODE" }
}
if (-not $SkipNativeBuild) {
    & (Join-Path $PSScriptRoot 'build_native_hook.ps1') -GameExecutable $game
    if ($LASTEXITCODE -ne 0) { throw "Native build failed with exit code $LASTEXITCODE" }
}

$pythonCandidates = @(
    'python.exe',
    'py.exe',
    'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'
)
$python = $null
foreach ($candidate in $pythonCandidates) {
    try {
        $resolved = Get-Command $candidate -ErrorAction Stop
        & $resolved.Source -c 'import PyInstaller' 2>$null
        if ($LASTEXITCODE -eq 0) { $python = $resolved.Source; break }
    }
    catch { }
}
if (-not $python) { throw 'Python with PyInstaller is required to build the dependency-free companion executable.' }

$companionDist = Join-Path $projectRoot 'runtime\companion-dist'
$companionWork = Join-Path $projectRoot 'runtime\companion-build'
$specRoot = Join-Path $projectRoot 'runtime\companion-spec'
New-Item -ItemType Directory -Force -Path $companionDist, $companionWork, $specRoot | Out-Null
& $python -m PyInstaller --noconfirm --clean --onefile --name tpf2mp `
    --paths (Join-Path $projectRoot 'companion') `
    --distpath $companionDist --workpath $companionWork --specpath $specRoot `
    (Join-Path $projectRoot 'companion\entrypoint.py')
if ($LASTEXITCODE -ne 0) { throw "Companion executable build failed with exit code $LASTEXITCODE" }

$nativeBin = Join-Path $projectRoot 'runtime\native-build\Release'
$requiredBinaries = @(
    (Join-Path $companionDist 'tpf2mp.exe'),
    (Join-Path $nativeBin 'tpf2mp_injector.exe'),
    (Join-Path $nativeBin 'tpf2mp_hook_build35924.dll')
)
foreach ($path in $requiredBinaries) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release binary is missing: $path" }
}

& (Join-Path $companionDist 'tpf2mp.exe') recovery-plan --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Packaged companion recovery-plan smoke test failed with exit code $LASTEXITCODE" }
& (Join-Path $companionDist 'tpf2mp.exe') archive-save --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Packaged companion archive-save smoke test failed with exit code $LASTEXITCODE" }
& (Join-Path $companionDist 'tpf2mp.exe') verify-recovery-archive --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Packaged companion recovery verification smoke test failed with exit code $LASTEXITCODE" }
& (Join-Path $companionDist 'tpf2mp.exe') freight-live-report --help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Packaged companion freight report smoke test failed with exit code $LASTEXITCODE" }

$releaseName = "TPF2MP-$Version"
$releaseRoot = [IO.Path]::GetFullPath((Join-Path $dist $releaseName))
$distPrefix = $dist.TrimEnd('\') + '\'
if (-not $releaseRoot.StartsWith($distPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing release path outside $dist"
}
if (Test-Path -LiteralPath $releaseRoot) { Remove-Item -LiteralPath $releaseRoot -Recurse -Force }
New-Item -ItemType Directory -Path $releaseRoot | Out-Null

function Copy-ReleaseTree {
    param([string]$Source, [string]$Destination, [string[]]$ExcludedDirectories = @())
    $sourceRoot = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
        $relative = $file.FullName.Substring($sourceRoot.Length + 1)
        $parts = $relative -split '[\\/]'
        if (@($parts | Where-Object { $ExcludedDirectories -contains $_ }).Count -gt 0) { continue }
        if ($file.Extension -in @('.pyc', '.pyo')) { continue }
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
    }
}

Copy-ReleaseTree (Join-Path $projectRoot 'tpf2_mp_1') (Join-Path $releaseRoot 'tpf2_mp_1')
Copy-ReleaseTree (Join-Path $projectRoot 'companion\tpf2mp') (Join-Path $releaseRoot 'companion\tpf2mp') @('__pycache__')
Copy-Item -LiteralPath (Join-Path $projectRoot 'companion\pyproject.toml') -Destination (Join-Path $releaseRoot 'companion\pyproject.toml')
New-Item -ItemType Directory -Force -Path (Join-Path $releaseRoot 'bin\native'), (Join-Path $releaseRoot 'tools'), (Join-Path $releaseRoot 'docs\investigation'), (Join-Path $releaseRoot 'licenses') | Out-Null
Copy-Item -LiteralPath (Join-Path $companionDist 'tpf2mp.exe') -Destination (Join-Path $releaseRoot 'bin\tpf2mp.exe')
Copy-Item -LiteralPath (Join-Path $nativeBin 'tpf2mp_injector.exe') -Destination (Join-Path $releaseRoot 'bin\native\tpf2mp_injector.exe')
Copy-Item -LiteralPath (Join-Path $nativeBin 'tpf2mp_hook_build35924.dll') -Destination (Join-Path $releaseRoot 'bin\native\tpf2mp_hook_build35924.dll')
Copy-Item -LiteralPath (Join-Path $projectRoot 'native\third_party\minhook\LICENSE.txt') -Destination (Join-Path $releaseRoot 'licenses\MinHook-BSD-2-Clause.txt')

$toolNames = @(
    'release_common.ps1', 'install_release.ps1', 'verify_install.ps1', 'uninstall.ps1',
    'new_match_manifest.ps1', 'new_recovery_plan.ps1',
    'start_host_release.ps1', 'start_client_release.ps1', 'start_hooked_game.ps1',
    'network_common.ps1', 'native_load_common.ps1', 'start_network_session.ps1', 'stop_network_session.ps1',
    'get_network_session_status.ps1', 'collect_live_evidence.ps1',
    'analyze_freight_live_evidence.ps1', 'start_freight_live_acceptance.ps1',
    'multiplayer_launcher.ps1',
    'watch_recovery_saves.ps1',
    'run_localhost_live_validation.ps1', 'start_operational_capture_lab.ps1',
    'analyze_operational_capture.ps1', 'localhost_bootstrap.lua', 'multiplayer_menu_bootstrap.lua',
    'send_game_console.ps1', 'archive_recovery_save.ps1', 'main_menu_coordinator.ps1'
)
foreach ($name in $toolNames) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $releaseRoot "tools\$name")
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release_install.cmd') -Destination (Join-Path $releaseRoot 'INSTALL_TPF2MP.cmd')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release_verify.cmd') -Destination (Join-Path $releaseRoot 'VERIFY_TPF2MP.cmd')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release_uninstall.cmd') -Destination (Join-Path $releaseRoot 'UNINSTALL_TPF2MP.cmd')
Copy-Item -LiteralPath (Join-Path $projectRoot 'LAUNCH_TPF2MP.cmd') -Destination (Join-Path $releaseRoot 'LAUNCH_TPF2MP.cmd')
$documentNames = @(
    'README.md', 'ARCHITECTURE.md', 'PROTOTYPE_STATUS.md', 'REMAINING_FROM_BRIEF.md',
    'tpf2-competitive-multiplayer-concept.md', 'tpf2-competitive-multiplayer-technical-plan.md',
    'multiplayer-companies-audit.md'
)
foreach ($name in $documentNames) {
    Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $releaseRoot "docs\$name")
}
Copy-ReleaseTree (Join-Path $projectRoot 'investigation') (Join-Path $releaseRoot 'docs\investigation')
Copy-Item -LiteralPath (Join-Path $projectRoot 'native\README.md') -Destination (Join-Path $releaseRoot 'docs\NATIVE_HOOK.md')

$quickStart = @'
# TPF2MP packaged prototype

This is an alpha research build, not finished Internet multiplayer.

Install from PowerShell:

    powershell -ExecutionPolicy Bypass -File .\tools\install_release.ps1

Then double-click `LAUNCH_TPF2MP.cmd`. Its Host / Join buttons fingerprint the
game, mod, binaries, and selected save; configure the peer and session; start
the TCP companion; and launch the exact game at its title screen. Click the new
`MULTIPLAYER` entry inside Transport Fever 2. Only that receipted selection
allows the launcher to load the byte-pinned save and continue the authority
flow. Both players must use byte-identical copies of the same starting save.

The Localhost Test button runs two real disposable game instances on one PC and
produces a convergence report automatically. Tick its manual-lab option to
leave both connected game windows open after the proof; ending the lab
automatically collects evidence from both peers before cleanup.

The Populated Capture Lab button starts two independent unrestricted hot-seat
worlds and records real line/vehicle/passenger/cargo operations. It is an
observation lab, not synchronized multiplayer.

Standalone hot-seat play does not need the launcher or native hook. Network
experiments require the exact Transport Fever 2 Build 35924 executable and
should be used only with trusted LAN/VPN peers.

Useful commands:

    .\tools\verify_install.ps1
    .\LAUNCH_TPF2MP.cmd
    .\tools\start_network_session.ps1 -Role Host -Session match-1 -StartingSave C:\saves\match.sav
    .\tools\start_network_session.ps1 -Role Join -Session match-1 -HostAddress 192.168.1.10 -StartingSave C:\saves\match.sav
    .\tools\new_match_manifest.ps1 -Session match-1
    .\tools\start_host_release.ps1 -Session match-1 -ManifestPath "$env:LOCALAPPDATA\TPF2MP\matches\match-1-manifest.json"
    .\tools\start_client_release.ps1 -HostAddress 192.168.1.10 -Session match-1 -ManifestPath "$env:LOCALAPPDATA\TPF2MP\matches\match-1-manifest.json"
    .\tools\start_hooked_game.ps1
    .\tools\start_operational_capture_lab.ps1 -Minutes 120
    .\tools\start_freight_live_acceptance.ps1 -RequireObservedAboard
    .\tools\analyze_freight_live_evidence.ps1 -Session match-1 -RequireStage settled
    .\tools\new_recovery_plan.ps1 -AuditPath "$env:TEMP\tpf2mp_bridge\player1\audit\match-1.ndjson" -Session match-1
    .\tools\archive_recovery_save.ps1 -Session match-1 -Peer player1 -SavePath C:\saves\match.sav
    .\tools\get_network_session_status.ps1 -Session match-1 -Peer player1
    .\tools\uninstall.ps1

Read `docs\README.md` and `docs\REMAINING_FROM_BRIEF.md` for implemented and
unfinished boundaries before testing.

Host sessions automatically watch for a later stable native save after an
all-peer checkpoint and archive it against a verified recovery plan. This is a
checkpoint-linked candidate, not an exact-tick snapshot or automatic rollback.
Every peer also captures one bounded local evidence bundle when the companion
first faults. The launcher and get-network-session-status command expose its
path; inspect logs for local paths or gameplay details before sharing them.
'@
$quickStart | Set-Content -LiteralPath (Join-Path $releaseRoot 'QUICK_START.md') -Encoding UTF8

$fileRecords = @()
foreach ($file in Get-ChildItem -LiteralPath $releaseRoot -File -Recurse | Sort-Object FullName) {
    if ($file.Name -eq 'release-manifest.json') { continue }
    $relative = $file.FullName.Substring($releaseRoot.Length + 1).Replace('\', '/')
    $fileRecords += [ordered]@{
        path = $relative
        size = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
$releaseManifest = [ordered]@{
    format = 1
    name = 'TPF2MP Competitive Prototype'
    version = $Version
    modMinorVersion = $modMinorVersion
    stateSchemaVersion = $stateSchemaVersion
    checkpointSchemaVersion = $checkpointSchemaVersion
    proposalSchemaVersion = $proposalSchemaVersion
    passengerPresentationSchemaVersion = $passengerPresentationSchemaVersion
    cargoPresentationSchemaVersion = $cargoPresentationSchemaVersion
    deliverySchemaVersion = $deliverySchemaVersion
    freightIndustrySchemaVersion = $freightIndustrySchemaVersion
    companionVersion = $companionVersion
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
    supportedNativeBuild = [ordered]@{
        game = 'Transport Fever 2 Build 35924 (Windows x64)'
        executableSha256 = '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c'
    }
    files = $fileRecords
}
$releaseManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $releaseRoot 'release-manifest.json') -Encoding UTF8

$archive = Join-Path $dist ($releaseName + '.zip')
if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
Compress-Archive -LiteralPath $releaseRoot -DestinationPath $archive -CompressionLevel Optimal

if (-not $SkipPackageInstallTest) {
    $testRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot ('runtime\package-install-test-' + [guid]::NewGuid().ToString('N'))))
    $testMods = Join-Path $testRoot 'Steam\userdata\12345\1066780\local\mods'
    $testSupport = Join-Path $testRoot 'support'
    New-Item -ItemType Directory -Force -Path $testMods | Out-Null
    try {
        & (Join-Path $releaseRoot 'tools\install_release.ps1') -BundleRoot $releaseRoot -LocalModsPath $testMods -InstallRoot $testSupport -SkipVerification
        & (Join-Path $releaseRoot 'tools\verify_install.ps1') -BundleRoot $releaseRoot -LocalModsPath $testMods -GameExecutable $game -StrictNative
        & (Join-Path $releaseRoot 'tools\uninstall.ps1') -LocalModsPath $testMods -InstallRoot $testSupport
        if (Test-Path -LiteralPath (Join-Path $testMods 'tpf2_mp_1')) { throw 'Package uninstall self-test left the mod active.' }
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}

Write-Host "Release directory: $releaseRoot"
Write-Host "Release archive: $archive"
Write-Host "Files: $($fileRecords.Count)"
