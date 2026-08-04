[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$lua = 'C:\Program Files (x86)\Lua\5.1\lua.exe'
$python = 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe'

if (-not (Test-Path -LiteralPath $lua)) { throw "Lua 5.1 not found at $lua" }
if (-not (Test-Path -LiteralPath $python)) { throw "Python not found at $python" }

$temporary = Join-Path ([System.IO.Path]::GetTempPath()) ("tpf2mp-tests-" + [guid]::NewGuid().ToString('N'))
$gameOutbox = Join-Path $temporary 'game_outbox'
$gameInbox = Join-Path $temporary 'game_inbox'
$mainBridge = Join-Path $temporary 'main'
$mainOutbox = Join-Path $mainBridge 'game_outbox'
$mainInbox = Join-Path $mainBridge 'game_inbox'
$hotseatBridge = Join-Path $temporary 'hotseat'
$hotseatOutbox = Join-Path $hotseatBridge 'game_outbox'
$hotseatInbox = Join-Path $hotseatBridge 'game_inbox'
$networkMapBridge = Join-Path $temporary 'network-company-map'
$networkMapOutbox = Join-Path $networkMapBridge 'game_outbox'
$networkMapInbox = Join-Path $networkMapBridge 'game_inbox'
$traceBridge = Join-Path $temporary 'replay-trace'
$traceOutbox = Join-Path $traceBridge 'game_outbox'
$traceInbox = Join-Path $traceBridge 'game_inbox'
New-Item -ItemType Directory -Force -Path $gameOutbox, $gameInbox, $mainOutbox, $mainInbox, $hotseatOutbox, $hotseatInbox, $networkMapOutbox, $networkMapInbox, $traceOutbox, $traceInbox | Out-Null

try {
    & (Join-Path $projectRoot 'tools\check_source_boundaries.ps1') -ProjectRoot $projectRoot
    if (-not $?) { throw 'Architecture boundary checks failed' }

    & $lua (Join-Path $projectRoot 'tests\run_lua_tests.lua') $projectRoot $temporary
    if ($LASTEXITCODE -ne 0) { throw "Lua tests failed with exit code $LASTEXITCODE" }

    $economyParity = Join-Path $temporary 'economy-v2-v3-parity.json'
    & $lua (Join-Path $projectRoot 'tests\run_economy_parity_vectors.lua') $projectRoot $economyParity
    if ($LASTEXITCODE -ne 0) { throw "Lua economy parity vector generation failed with exit code $LASTEXITCODE" }
    & $python (Join-Path $projectRoot 'tests\check_economy_parity.py') $projectRoot $economyParity
    if ($LASTEXITCODE -ne 0) { throw "Cross-language economy parity failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_runtime_module_tests.lua') $projectRoot
    if ($LASTEXITCODE -ne 0) { throw "Runtime module tests failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_edge_ownership_tests.lua') $projectRoot
    if ($LASTEXITCODE -ne 0) { throw "Edge ownership tests failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_game_script_tests.lua') $projectRoot $mainBridge
    if ($LASTEXITCODE -ne 0) { throw "Game-script integration tests failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_network_company_mapping_tests.lua') $projectRoot $networkMapBridge
    if ($LASTEXITCODE -ne 0) { throw "Network company-mapping integration tests failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_hotseat_tests.lua') $projectRoot $hotseatBridge
    if ($LASTEXITCODE -ne 0) { throw "Hot-seat integration tests failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_replay_trace.lua') $projectRoot $traceBridge
    if ($LASTEXITCODE -ne 0) { throw "Long replay trace generation failed with exit code $LASTEXITCODE" }

    & $lua (Join-Path $projectRoot 'tests\run_gui_tests.lua') $projectRoot
    if ($LASTEXITCODE -ne 0) { throw "GUI-state integration tests failed with exit code $LASTEXITCODE" }

    $launcherTemp = Join-Path $temporary 'launcher-environment'
    $launcherConfigRoot = Join-Path $launcherTemp 'tpf2mp_launcher'
    New-Item -ItemType Directory -Force -Path $launcherConfigRoot | Out-Null
    [IO.File]::WriteAllLines((Join-Path $launcherConfigRoot 'active.ini'), @(
        'schemaVersion=1',
        'expiresAtUnix=4102444800',
        'sessionId=launcher-test',
        'peerId=player2',
        'bridgeDir=C:/bridge/launcher-test/player2',
        'startNetwork=true'
    ), [Text.UTF8Encoding]::new($false))
    $previousTemp = $env:TEMP
    $previousStartingCash = $env:TPF2MP_STARTING_CASH
    try {
        $env:TEMP = $launcherTemp
        $env:TPF2MP_STARTING_CASH = '50000000'
        & $lua (Join-Path $projectRoot 'tests\run_mod_launcher_config_tests.lua') $projectRoot
        if ($LASTEXITCODE -ne 0) { throw "Launcher-config mod test failed with exit code $LASTEXITCODE" }
    }
    finally {
        $env:TEMP = $previousTemp
        $env:TPF2MP_STARTING_CASH = $previousStartingCash
    }

    $luaFiles = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1') -Recurse -File -Filter '*.lua'
    foreach ($file in $luaFiles) {
        & $lua -e "assert(loadfile([[$($file.FullName)]]))"
        if ($LASTEXITCODE -ne 0) { throw "Lua syntax check failed: $($file.FullName)" }
    }
    Write-Host "Lua syntax: $($luaFiles.Count) files passed"

    $probeLuaFiles = @(
        (Get-ChildItem -LiteralPath (Join-Path $projectRoot 'investigation') -File -Filter '*.lua').FullName
        (Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tools') -File -Filter '*.lua').FullName
    )
    foreach ($file in $probeLuaFiles) {
        & $lua -e "assert(loadfile([[$file]]))"
        if ($LASTEXITCODE -ne 0) { throw "Investigation Lua syntax check failed: $file" }
    }
    Write-Host "Investigation Lua syntax: $($probeLuaFiles.Count) files passed"

    $powerShellFiles = Get-ChildItem -LiteralPath (Join-Path $projectRoot 'tools') -File -Filter '*.ps1'
    foreach ($file in $powerShellFiles) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw "PowerShell syntax check failed: $($file.FullName): $($parseErrors.Message -join '; ')"
        }
    }
    Write-Host "PowerShell syntax: $($powerShellFiles.Count) files passed"

    . (Join-Path $projectRoot 'tools\network_common.ps1')
    $identityCases = @(
        @('tpf2mp.exe host --session match-1 --peer player1 --port 29742', 'match-1', 'player1', $true),
        @('tpf2mp.exe host --session match-10 --peer player1 --port 29742', 'match-1', 'player1', $false),
        @('tpf2mp.exe client 127.0.0.1 --session=match-1 --peer=player2', 'match-1', 'player2', $true),
        @('tpf2mp.exe client 127.0.0.1 --session match-1 --peer player2', 'match-1', 'player1', $false)
    )
    foreach ($case in $identityCases) {
        $actual = Test-Tpf2mpCompanionCommandLine -CommandLine $case[0] -Session $case[1] -Peer $case[2]
        if ($actual -ne $case[3]) { throw "Launcher process identity test failed: $($case[0])" }
    }
    $emptyPeersJson = [pscustomobject][ordered]@{ connectedPeers = @() } | ConvertTo-Json -Compress
    if ($emptyPeersJson -ne '{"connectedPeers":[]}') { throw 'Launcher status empty peer list is not a JSON array.' }
    Write-Host 'PASS launcher process identity boundaries and status array encoding'

    . (Join-Path $projectRoot 'tools\native_load_common.ps1')

    $statusBridge = Join-Path $temporary 'menu-status-reader'
    $statusLauncher = Join-Path $statusBridge 'launcher'
    New-Item -ItemType Directory -Force -Path $statusLauncher | Out-Null
    foreach ($partialStatus in @('', 'null', '{}', '{"session":"test"}')) {
        [IO.File]::WriteAllText((Join-Path $statusLauncher 'menu_status.json'), $partialStatus)
        if ($null -ne (Read-Tpf2mpMenuStatus -BridgePath $statusBridge -Session 'test' -Peer 'player1')) {
            throw "Incomplete menu status was accepted: $partialStatus"
        }
    }
    [IO.File]::WriteAllText((Join-Path $statusLauncher 'menu_status.json'),
        '{"schemaVersion":2,"session":"test","peer":"player1","stage":"main-menu","components":{},"error":null}')
    if ((Read-Tpf2mpMenuStatus -BridgePath $statusBridge -Session 'test' -Peer 'player1').stage -ne 'main-menu') {
        throw 'Complete menu status was not accepted.'
    }
    $fakeInjector = Join-Path $temporary 'fake-native-injector.cmd'
    [IO.File]::WriteAllText($fakeInjector, "@echo off`r`necho profile=fake-build`r`necho hook active`r`nexit /b 0`r`n",
        [Text.ASCIIEncoding]::new())
    $hookResult = @(Add-Tpf2mpNativeHook -GameProcess ([pscustomobject]@{ Id = 424242 }) `
        -NativePaths ([pscustomobject]@{ Injector = $fakeInjector; Hook = 'fake-hook.dll' }))
    if ($hookResult.Count -ne 1 -or [string]$hookResult[0] -notmatch 'status-424242\.json$') {
        throw 'Native injector diagnostics leaked into the status-path return pipeline.'
    }
    $nativeSaveRoot = Join-Path $temporary 'native-load\userdata\1\1066780\local\save'
    New-Item -ItemType Directory -Force -Path $nativeSaveRoot | Out-Null
    $nativeSource = Join-Path $temporary 'native-load\source.sav'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $nativeSource) | Out-Null
    [IO.File]::WriteAllBytes($nativeSource, [byte[]](1, 2, 3, 4, 5))
    [IO.File]::WriteAllText($nativeSource + '.lua', 'function data() return {} end', [Text.UTF8Encoding]::new($false))
    $pinned = Copy-Tpf2mpPinnedStartingSave $nativeSource (Join-Path $temporary 'native-load\pinned')
    if (-not (Test-Path -LiteralPath $pinned.savePath -PathType Leaf) -or @($pinned.files).Count -ne 2) {
        throw 'Pinned starting-save copy test failed.'
    }
    $staged = New-Tpf2mpStagedStartingSave -SourceSave $pinned.savePath `
        -SaveDirectory $nativeSaveRoot -Session 'native-load-test' -Peer player1
    if (-not (Test-Path -LiteralPath $staged.savePath -PathType Leaf) `
        -or $staged.baseName -notmatch '^tpf2mp_native-load-test_player1_[0-9a-f]{8}$') {
        throw 'Native starting-save staging test failed.'
    }
    Remove-Tpf2mpStagedStartingSave $staged
    if (Test-Path -LiteralPath $staged.savePath) { throw 'Native staged-save cleanup test failed.' }
    $tampered = New-Tpf2mpStagedStartingSave -SourceSave $pinned.savePath `
        -SaveDirectory $nativeSaveRoot -Session 'tamper-test' -Peer player2
    [IO.File]::WriteAllBytes($tampered.savePath, [byte[]](9, 9, 9))
    $tamperRefused = $false
    try { Remove-Tpf2mpStagedStartingSave $tampered }
    catch { $tamperRefused = $_.Exception.Message -match 'changed staged-save file' }
    if (-not $tamperRefused -or -not (Test-Path -LiteralPath $tampered.savePath)) {
        throw 'Native staged-save tamper boundary did not fail closed.'
    }
    $fakeGameRoot = Join-Path $temporary 'native-load\fake-game'
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $fakeGameRoot 'res\scripts'), (Join-Path $fakeGameRoot 'res\config\game_script') | Out-Null
    $fakeGame = Join-Path $fakeGameRoot 'TransportFever2.exe'
    [IO.File]::WriteAllBytes($fakeGame, [byte[]](0))
    $bootstrapInstall = Install-Tpf2mpMenuBootstrap -BundleRoot $projectRoot -GameExecutable $fakeGame
    if (-not $bootstrapInstall.created -or -not (Test-Path -LiteralPath $bootstrapInstall.target)) {
        throw 'Native menu bootstrap install test failed.'
    }
    $bootstrapAgain = Install-Tpf2mpMenuBootstrap -BundleRoot $projectRoot -GameExecutable $fakeGame
    if ($bootstrapAgain.created -or $bootstrapAgain.updated) { throw 'Native menu bootstrap idempotency test failed.' }
    [IO.File]::WriteAllText($bootstrapAgain.target,
        "-- Console-state main-menu bootstrap for launcher-managed TPF2MP sessions.`n-- previous managed version`n")
    $bootstrapUpgrade = Install-Tpf2mpMenuBootstrap -BundleRoot $projectRoot -GameExecutable $fakeGame
    if ($bootstrapUpgrade.created -or -not $bootstrapUpgrade.updated `
        -or (Get-FileHash -LiteralPath $bootstrapUpgrade.target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $bootstrapUpgrade.sha256) {
        throw 'Managed native menu bootstrap upgrade test failed.'
    }
    $overlay = @(Install-Tpf2mpRuntimeOverlay -BundleRoot $projectRoot -GameExecutable $fakeGame)
    if ($overlay.Count -ne 2 -or @($overlay | Where-Object { $_.created -ne $true }).Count -ne 0) {
        throw 'Native runtime overlay install test failed.'
    }
    $overlayAgain = @(Install-Tpf2mpRuntimeOverlay -BundleRoot $projectRoot -GameExecutable $fakeGame)
    if (@($overlayAgain | Where-Object { $_.created -eq $true -or $_.updated -eq $true }).Count -ne 0) {
        throw 'Native runtime overlay idempotency test failed.'
    }
    [IO.File]::WriteAllText((Join-Path $fakeGameRoot 'res\config\game_script\tpf2_mp.lua'),
        "local util = require `"tpf2_mp/util`"`n-- previous managed version`n")
    [IO.File]::WriteAllText((Join-Path $fakeGameRoot 'res\scripts\tpf2_mp\world.lua'),
        "local canonical = require `"tpf2_mp/canonical`"`n-- previous managed version`n")
    $overlayUpgrade = @(Install-Tpf2mpRuntimeOverlay -BundleRoot $projectRoot -GameExecutable $fakeGame)
    if ($overlayUpgrade.Count -ne 2 `
        -or @($overlayUpgrade | Where-Object { $_.updated -eq $true }).Count -ne 2) {
        throw 'Managed native runtime overlay upgrade test failed.'
    }
    $marker = Enable-Tpf2mpDirectLaunch -GameExecutable $fakeGame
    if (-not $marker.created -or (Get-Content -LiteralPath $marker.path -Raw) -ne '1066780') {
        throw 'Native direct-launch marker test failed.'
    }
    Write-Host 'PASS native save pin/stage/tamper, bootstrap, overlay, and direct-launch boundaries'

    & (Join-Path $projectRoot 'tools\multiplayer_launcher.ps1') -BundleRoot $projectRoot -SmokeTest
    if ($LASTEXITCODE -ne 0) { throw "Multiplayer launcher smoke test failed with exit code $LASTEXITCODE" }

    $previousPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = Join-Path $projectRoot 'companion'
    try {
        & $python -m unittest discover -s (Join-Path $projectRoot 'tests') -p 'test_*.py' -v
        if ($LASTEXITCODE -ne 0) { throw "Python tests failed with exit code $LASTEXITCODE" }

        $checkpointReport = Join-Path $temporary 'cross-language-checkpoint.md'
        & $python -m tpf2mp checkpoint-report --peer player1 --session engine-test --bridge $mainBridge --anchor first --output $checkpointReport
        if ($LASTEXITCODE -ne 0) { throw "Cross-language checkpoint replay failed with exit code $LASTEXITCODE" }
        if (-not (Test-Path -LiteralPath $checkpointReport)) { throw 'Cross-language checkpoint report was not written' }

        $traceReport = Join-Path $temporary 'long-replay-trace.md'
        & $python -m tpf2mp checkpoint-report --peer player1 --session replay-trace --bridge $traceBridge --anchor first --output $traceReport
        if ($LASTEXITCODE -ne 0) { throw "Long cross-language replay failed with exit code $LASTEXITCODE" }
        if (-not (Select-String -LiteralPath $traceReport -SimpleMatch 'Event records verified after anchor: `104`' -Quiet)) {
            throw 'Long cross-language replay report did not verify all 104 post-checkpoint events'
        }
    }
    finally {
        $env:PYTHONPATH = $previousPythonPath
    }
}
finally {
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

Write-Host 'All TPF2MP tests passed.'
