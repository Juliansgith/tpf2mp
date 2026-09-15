[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameExecutable,
    [Parameter(Mandatory)][string]$LocalDirectory,
    [Parameter(Mandatory)][string]$NativeBuildDirectory,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(30,600)][int]$TimeoutSeconds = 300,
    [switch]$WithMultiplayerMod,
    [switch]$SaveGeneratedWorld,
    [switch]$Configured,
    [switch]$MapPreview,
    [switch]$PreviewOnly,
    [string]$RequestPath
)
$ErrorActionPreference = 'Stop'
if ($PreviewOnly -and ($SaveGeneratedWorld -or $MapPreview)) { throw 'Preview-only never saves or loads a playable world.' }
if (@(Get-CimInstance Win32_Process -Filter "Name = 'TransportFever2.exe'").Count) {
    throw 'Close existing games before a disposable generator qualification.'
}
$game = (Get-Item -LiteralPath $GameExecutable).FullName
if ((Get-FileHash -LiteralPath $game).Hash -ne '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c') {
    throw 'Unqualified executable.'
}
$localRoot = (Get-Item -LiteralPath $LocalDirectory).FullName
$settings = Join-Path $localRoot 'settings.lua'
$settingsText = Get-Content -LiteralPath $settings -Raw
$screenSetting = '(?m)^[ \t]*screenMode[ \t]*=[ \t]*"[A-Z_]+"'
if ([regex]::Matches($settingsText, $screenSetting).Count -ne 1) { throw 'Native window mode setting is missing or ambiguous.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Refusing to overwrite qualification evidence.' }
[void](New-Item -ItemType Directory -Path $output)
$gameRoot = Split-Path $game
$name = 'tpf2mp_worldgen_lab_' + [guid]::NewGuid().ToString('N') + '.lua'
$scriptTarget = Join-Path $gameRoot ('res\scripts\' + $name)
$injector = (Get-Item -LiteralPath (Join-Path $NativeBuildDirectory 'tpf2mp_injector.exe')).FullName
$dll = (Get-Item -LiteralPath (Join-Path $NativeBuildDirectory 'tpf2mp_worldgen_lab.dll')).FullName
$savedEnvironment = @{}
$process = $null
$failure = $null
$exitCode = $null
$backups = @()
$saveStem = [IO.Path]::GetFileNameWithoutExtension($name)
$requestHash = $null
$generationMutex = New-Object Threading.Mutex($false, 'Local\TPF2MP.NativeWorldGeneration')
$ownsGeneration = $false
try {
    try { $ownsGeneration = $generationMutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $ownsGeneration = $true }
    if (-not $ownsGeneration) { throw 'Another native generation job is already running.' }
    # Generation is a new local world, not a continuation of the caller's
    # network environment. Restore every value when this worker finishes.
    foreach ($entry in @(Get-ChildItem Env: | Where-Object Name -like 'TPF2MP_*')) {
        $savedEnvironment[$entry.Name] = $entry.Value
        [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process')
    }
    foreach ($file in @('settings.lua','profile.lua')) {
        $source = Join-Path $localRoot $file
        if (Test-Path -LiteralPath $source) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $output $file)
            $backups += $file
        }
    }
    # Native preference override, not desktop/window manipulation. Restore the
    # original byte-for-byte backup on exit, including the user's display mode.
    if ($settingsText -cnotmatch '(?m)^[ \t]*screenMode[ \t]*=[ \t]*"WINDOWED"') {
        [IO.File]::WriteAllText($settings, [regex]::Replace($settingsText,$screenSetting,'screenMode = "WINDOWED"'),
            [Text.UTF8Encoding]::new($false))
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'native_worldgen_lab.lua') -Destination $scriptTarget
    foreach ($key in @('SteamAppId','SteamGameId','TPF2MP_WORLDGEN_LAB_MARKER','TPF2MP_WORLDGEN_LAB_LUA_MARKER','TPF2MP_WORLDGEN_LAB_MOD','TPF2MP_WORLDGEN_LAB_SAVE','TPF2MP_WORLDGEN_LAB_CONFIGURED','TPF2MP_WORLDGEN_REQUEST')) {
        if (-not $savedEnvironment.ContainsKey($key)) {
            $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
        }
    }
    $env:SteamAppId = '1066780'; $env:SteamGameId = '1066780'
    $env:TPF2MP_WORLDGEN_LAB_MARKER = Join-Path $output 'native.jsonl'
    $env:TPF2MP_WORLDGEN_LAB_LUA_MARKER = Join-Path $output 'script.log'
    $env:TPF2MP_WORLDGEN_LAB_MOD = if ($WithMultiplayerMod) { 'tpf2_mp' } else { '' }
    $env:TPF2MP_WORLDGEN_LAB_CONFIGURED = if ($Configured) { '1' } else { '' }
    $env:TPF2MP_WORLDGEN_PREVIEW_ONLY = if ($PreviewOnly) { '1' } else { '' }
    if (($MapPreview -or $PreviewOnly) -and -not $RequestPath) { throw 'Map preview requires a pinned generation request.' }
    $env:TPF2MP_WORLDGEN_PREVIEW_EXPORT = if ($MapPreview) { '1' } else { '' }
    if ($RequestPath) {
        $pinnedRequest = Join-Path $output 'native-request.txt'
        Copy-Item -LiteralPath $RequestPath -Destination $pinnedRequest
        $requestHash = (Get-FileHash -LiteralPath $pinnedRequest -Algorithm SHA256).Hash.ToLowerInvariant()
        $env:TPF2MP_WORLDGEN_REQUEST = $pinnedRequest
    } else { $env:TPF2MP_WORLDGEN_REQUEST = '' }
    $env:TPF2MP_WORLDGEN_LAB_SAVE = if ($SaveGeneratedWorld) { [IO.Path]::GetFileNameWithoutExtension($name) } else { '' }
    $workerStyle = if ($PreviewOnly) { 'Hidden' } else { 'Normal' }
    $process = Start-Process -FilePath $game -WorkingDirectory $gameRoot -WindowStyle $workerStyle `
        -ArgumentList @('--script', ('res/scripts/' + $name)) -PassThru
    Write-Output "worldgen_lab_pid=$($process.Id)"
    & $injector --pid $process.Id --dll $dll --wait-ms 30000 *> (Join-Path $output 'injector.log')
    if ($LASTEXITCODE -ne 0) { throw "Lab injection failed: $LASTEXITCODE" }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        if ($timer.Elapsed.TotalSeconds -gt $TimeoutSeconds) { throw 'Generator qualification timed out.' }
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    $process.WaitForExit(); $exitCode = $process.ExitCode
    if ($exitCode -ne 0) { throw "Generator exited $exitCode" }
} catch { $failure = $_.Exception.Message }
finally {
    if ($process) {
        $process.Refresh()
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $scriptTarget) { Remove-Item -LiteralPath $scriptTarget }
    # No selected save is touched. Restore incidental native menu preferences.
    if (-not @(Get-CimInstance Win32_Process -Filter "Name = 'TransportFever2.exe'").Count) {
        foreach ($file in $backups) { Copy-Item -LiteralPath (Join-Path $output $file) -Destination (Join-Path $localRoot $file) }
    }
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process') }
    if (-not $savedEnvironment.ContainsKey('TPF2MP_WORLDGEN_PREVIEW_EXPORT')) {
        [Environment]::SetEnvironmentVariable('TPF2MP_WORLDGEN_PREVIEW_EXPORT', $null, 'Process')
    }
    if (-not $savedEnvironment.ContainsKey('TPF2MP_WORLDGEN_PREVIEW_ONLY')) {
        [Environment]::SetEnvironmentVariable('TPF2MP_WORLDGEN_PREVIEW_ONLY', $null, 'Process')
    }
    $log = Join-Path $localRoot 'crash_dump\stdout.txt'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $output 'stdout.txt') }
    if ($ownsGeneration) { $generationMutex.ReleaseMutex() }
    $generationMutex.Dispose()
}
$markers = if (Test-Path -LiteralPath (Join-Path $output 'script.log')) { Get-Content -LiteralPath (Join-Path $output 'script.log') } else { @() }
$complete = -not $failure -and ($markers -contains 'world-ready') -and ($markers -contains 'quit-request')
if ($PreviewOnly) {
    $nativeEvents = @(Get-Content -LiteralPath (Join-Path $output 'native.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $complete = -not $failure -and @($nativeEvents | Where-Object event -eq 'native-preview-ready').Count -eq 1 `
        -and (Test-Path -LiteralPath (Join-Path $output 'preview-native.rgba')) `
        -and ($markers -notcontains 'world-ready')
}
if ($MapPreview -and -not (Test-Path -LiteralPath (Join-Path $output 'preview-native.rgba'))) {
    $complete = $false; $failure = 'Native terrain preview was unavailable.'
}
$generatedSave = $null
if ($complete -and $SaveGeneratedWorld) {
    $saves = @(Get-ChildItem -LiteralPath (Join-Path $localRoot 'save') -Filter "autosave_${saveStem}_*.sav")
    if ($saves.Count -ne 1 -or -not (Test-Path -LiteralPath ($saves[0].FullName + '.lua')) `
            -or -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($saves[0].FullName, '.jpg')))) {
        $complete = $false; $failure = 'Native save bundle is missing or ambiguous.'
    } else {
        $events = Get-Content -LiteralPath (Join-Path $output 'native.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
        $complete = @($events | Where-Object event -eq 'native-save-idle').Count -eq 1
        if ($complete) { $generatedSave = $saves[0].FullName }
    }
}
if ($RequestPath -and $requestHash -ne (Get-FileHash -LiteralPath (Join-Path $output 'native-request.txt')).Hash.ToLowerInvariant()) {
    $complete = $false; $failure = 'Generation request changed while running.'
}
[ordered]@{ schemaVersion=1; complete=$complete; error=$failure; exitCode=$exitCode; savePath=$generatedSave; requestSha256=$requestHash; configurable=[bool]$RequestPath } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'report.json') -Encoding UTF8
if (-not $complete) { throw "Native generator boundary not qualified: $failure. Evidence: $output" }
Write-Output "worldgen_lab_complete=$output"
