[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GameExecutable,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$SaveStem,
    [Parameter(Mandatory)][string]$GameLog,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateRange(5, 300)][int]$Seconds = 60,
    [ValidateRange(60, 1200)][int]$TimeoutSeconds = 600,
    [ValidateSet('steady','scaling')][string]$Workload = 'steady',
    [int]$ConcurrentPeerPid = 0,
    [ValidatePattern('^[0-9a-fA-F]{64}$')][string]$ExpectedExecutableSha256 = '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c',
    [string]$Label = 'native-save-benchmark',
    # Optional: launch through the pinned injector with this hook DLL so the
    # load runs with the native hook armed (for example to compare the terrain
    # fast paths, TPF2MP_NATIVE_TERRAIN_FAST, against "stock,timing"). The
    # hook's status JSON is copied into the evidence as native-hook-status.json.
    [string]$NativeHookDll
)

$ErrorActionPreference = 'Stop'
if ($Workload -eq 'scaling' -and $Seconds -lt 60) { throw 'Scaling requires at least 60 seconds for six measurable phases.' }
$game = (Get-Item -LiteralPath $GameExecutable).FullName
$experimental = $ExpectedExecutableSha256 -ne '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c'
if ($experimental -and (Split-Path $game -Leaf) -notlike 'TransportFever2_perf_lab*.exe') {
    throw 'Experimental hashes are allowed only for separately named performance-lab copies.'
}
if ((Get-FileHash -LiteralPath $game).Hash -ne $ExpectedExecutableSha256) {
    throw 'Native benchmark executable does not match its explicitly pinned hash.'
}
$existingGames = @(Get-Process TransportFever2* -ErrorAction SilentlyContinue)
if ($existingGames.Count) {
    if ($existingGames.Count -ne 1 -or $ConcurrentPeerPid -ne $existingGames[0].Id) { throw 'A game is already running.' }
    $peer = Get-CimInstance Win32_Process -Filter "ProcessId=$ConcurrentPeerPid"
    if ($peer.CommandLine -notmatch '--script\s+res/scripts/tpf2mp_bench_[a-f0-9]{32}\.lua') {
        throw 'Concurrent peer must be an existing disposable native benchmark, not a user game.'
    }
} elseif ($ConcurrentPeerPid) { throw 'Requested concurrent peer is absent.' }
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw 'Refusing to overwrite benchmark evidence.' }
[void](New-Item -ItemType Directory -Path $output)
$gameRoot = Split-Path $game
$scriptName = 'tpf2mp_bench_' + [guid]::NewGuid().ToString('N') + '.lua'
$scriptTarget = Join-Path $gameRoot ('res\scripts\' + $scriptName)
$savedEnvironment = @{}
foreach ($key in @('SteamAppId','SteamGameId','TPF2MP_BENCH_SAVE_STEM','TPF2MP_BENCH_SECONDS','TPF2MP_BENCH_RUN_TOKEN','TPF2MP_BENCH_WORKLOAD','TPF2MP_BENCH_MARKER_PATH')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
}
$process = $null
$rows = New-Object 'System.Collections.Generic.List[object]'
$failure = $null
$exitCode = $null
try {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'native_save_benchmark.lua') -Destination $scriptTarget
    $env:SteamAppId = '1066780'
    $env:SteamGameId = '1066780'
    $env:TPF2MP_BENCH_SAVE_STEM = $SaveStem
    $env:TPF2MP_BENCH_SECONDS = [string]$Seconds
    $env:TPF2MP_BENCH_RUN_TOKEN = $scriptName
    $env:TPF2MP_BENCH_WORKLOAD = $Workload
    $env:TPF2MP_BENCH_MARKER_PATH = Join-Path $output 'native-markers.log'
    if ($NativeHookDll) {
        $dll = (Get-Item -LiteralPath $NativeHookDll).FullName
        $injector = Join-Path (Split-Path $dll) 'tpf2mp_injector.exe'
        if (-not (Test-Path -LiteralPath $injector -PathType Leaf)) { throw "Injector is missing beside the hook DLL: $injector" }
        # The injector starts the game suspended, arms the hook, resumes, and
        # returns once the hook publishes an active status; the game outlives it.
        $injectorOutput = @(& $injector --launch $game --dll $dll --workdir $gameRoot --wait-ms 60000 -- '--script' ('res/scripts/' + $scriptName) 2>&1 |
            ForEach-Object { [string]$_ })
        $injectorOutput | ForEach-Object { Write-Output $_ }
        if ($LASTEXITCODE -ne 0) { throw "Native hook launch failed with exit code $LASTEXITCODE" }
        $pidLine = $injectorOutput | Where-Object { $_ -match 'launched pinned game suspended as pid (\d+)' } | Select-Object -First 1
        if (-not $pidLine) { throw 'The injector did not report the game PID.' }
        $process = Get-Process -Id ([int]$Matches[1])
        $nativeStatusPath = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native') "status-$($process.Id).json"
    } else {
        $process = Start-Process -FilePath $game -WorkingDirectory $gameRoot -WindowStyle Normal `
            -ArgumentList @('--script', ('res/scripts/' + $scriptName)) -PassThru
        $nativeStatusPath = $null
    }
    Write-Output "benchmark_pid=$($process.Id) label=$Label"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $process.HasExited) {
        $process.Refresh()
        if ($process.HasExited) { break }
        if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) { throw 'Native benchmark timed out.' }
        $rows.Add([ordered]@{
            wallSeconds = $timer.Elapsed.TotalSeconds
            atUtc = [DateTime]::UtcNow.ToString('o')
            cpuSeconds = $process.TotalProcessorTime.TotalSeconds
            workingSetBytes = $process.WorkingSet64
            privateBytes = $process.PrivateMemorySize64
            threads = @($process.Threads | ForEach-Object {
                try {
                    $threadState = [string]$_.ThreadState
                    [ordered]@{ id = $_.Id; state = $threadState
                        wait = if ($threadState -eq 'Wait') { [string]$_.WaitReason } else { $null }
                        cpuSeconds = $_.TotalProcessorTime.TotalSeconds }
                } catch { } # Threads can disappear during read-only enumeration.
            })
        })
        Start-Sleep -Milliseconds 1000
        # The hook rewrites its status at most once a second; keep the newest
        # copy so the final terrain timing survives the game's exit.
        if ($nativeStatusPath -and (Test-Path -LiteralPath $nativeStatusPath -PathType Leaf)) {
            try { Copy-Item -LiteralPath $nativeStatusPath -Destination (Join-Path $output 'native-hook-status.json') -Force } catch { }
        }
    }
    $process.WaitForExit()
    # A process adopted from the injector (Get-Process) may expose no exit
    # code; the marker log then decides completeness on its own.
    $exitCode = try { $process.ExitCode } catch { $null }
    if ($null -ne $exitCode -and $exitCode -ne 0) { throw "Game exited with code $exitCode." }
} catch { $failure = $_.Exception.Message }
finally {
    if ($process) {
        $process.Refresh()
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
    if (Test-Path -LiteralPath $scriptTarget) { Remove-Item -LiteralPath $scriptTarget }
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key], 'Process')
    }
}
$text = if (Test-Path -LiteralPath $GameLog) { Get-Content -LiteralPath $GameLog -Raw } else { '' }
if ($text) { Copy-Item -LiteralPath $GameLog -Destination (Join-Path $output 'stdout.txt') }
$markerLog = Join-Path $output 'native-markers.log'
if (Test-Path -LiteralPath $markerLog) { $text = Get-Content -LiteralPath $markerLog -Raw }
$markers = @([regex]::Matches($text, '(?m)^\[NATIVE-BENCH\].*$') |
    Where-Object { $_.Value.Contains('token=' + $scriptName) } | ForEach-Object { $_.Value.Trim() })
$complete = -not $failure -and ($markers -match 'event=world-ready ').Count -gt 0 `
    -and ($markers -match 'event=quit-request ').Count -gt 0
if (($markers -match 'event=(phase-failed-|camera-failed)').Count -gt 0) { $complete = $false }
$report = [ordered]@{
    schemaVersion = 1; label = $Label; executable = $game; saveStem = $SaveStem; workload = $Workload
    concurrentPeerPid = $ConcurrentPeerPid
    executableSha256 = $ExpectedExecutableSha256; experimentalBinary = $experimental
    complete = $complete; error = $failure; exitCode = $exitCode
    fpsMeasured = $false; markers = $markers; samples = @($rows.ToArray())
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'report.json') -Encoding UTF8
if (-not $complete) { throw "Incomplete native benchmark: $failure. Evidence: $output" }
Write-Output "benchmark_complete=$output"
