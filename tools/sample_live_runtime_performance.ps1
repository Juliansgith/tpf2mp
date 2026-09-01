[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][int]$Player1GameProcessId,
    [Parameter(Mandatory = $true)][int]$Player2GameProcessId,
    [ValidateRange(10, 600)][int]$DurationSeconds = 30,
    [ValidateRange(250, 5000)][int]$IntervalMilliseconds = 1000,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
if ($Session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Unsafe session name: $Session" }
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$bridgeRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$Session"))
if (-not (Test-Path -LiteralPath $bridgeRoot -PathType Container)) {
    throw "Live bridge is missing: $bridgeRoot"
}
if (-not $OutputPath) {
    $directory = Join-Path $projectRoot 'runtime\performance'
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $OutputPath = Join-Path $directory ("{0}-{1}.json" -f $Session, (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
else {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
}

$logicalProcessors = [Environment]::ProcessorCount
$targets = [ordered]@{
    player1 = [ordered]@{ ProcessId = $Player1GameProcessId; Process = Get-Process -Id $Player1GameProcessId -ErrorAction Stop }
    player2 = [ordered]@{ ProcessId = $Player2GameProcessId; Process = Get-Process -Id $Player2GameProcessId -ErrorAction Stop }
}
foreach ($peer in $targets.Keys) {
    $target = $targets[$peer]
    if ($target.Process.ProcessName -ne 'TransportFever2') {
        throw "$peer PID $($target.ProcessId) is not TransportFever2."
    }
    $target.MenuPath = Join-Path $bridgeRoot "$peer\launcher\menu_status.json"
    $target.CompanionPath = Join-Path $bridgeRoot "$peer\companion_state\companion_status.json"
    if (-not (Test-Path -LiteralPath $target.MenuPath -PathType Leaf) `
        -or -not (Test-Path -LiteralPath $target.CompanionPath -PathType Leaf)) {
        throw "$peer has no live menu/companion telemetry under $bridgeRoot."
    }
    $target.Samples = [Collections.Generic.List[object]]::new()
    $target.FrameIntervals = [Collections.Generic.List[double]]::new()
    $target.LastFrame = $null
    $target.LastFrameAt = $null
    $target.StartCpu = $target.Process.TotalProcessorTime.TotalSeconds
    $target.StartAt = [DateTime]::UtcNow
}

$deadline = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $deadline) {
    foreach ($peer in $targets.Keys) {
        $target = $targets[$peer]
        $target.Process.Refresh()
        if ($target.Process.HasExited) { throw "$peer game PID $($target.ProcessId) exited during performance sampling." }
        try { $menu = Get-Content -LiteralPath $target.MenuPath -Raw | ConvertFrom-Json }
        catch { throw "$peer menu telemetry became unreadable: $($_.Exception.Message)" }
        try { $status = Get-Content -LiteralPath $target.CompanionPath -Raw | ConvertFrom-Json }
        catch { throw "$peer companion telemetry became unreadable: $($_.Exception.Message)" }
        if ($status.status -eq 'faulted' -or $status.auditFaulted -eq $true -or [string]$status.sessionFault) {
            throw "$peer session faulted during performance sampling: $($status.sessionFault)"
        }
        $sampleAt = [DateTime]::UtcNow
        $frames = [int64]$menu.frames
        if ($null -ne $target.LastFrame -and $frames -gt $target.LastFrame) {
            $frameSeconds = ($sampleAt - $target.LastFrameAt).TotalSeconds
            if ($frameSeconds -gt 0) {
                $target.FrameIntervals.Add(($frames - $target.LastFrame) / $frameSeconds)
            }
        }
        if ($null -eq $target.LastFrame -or $frames -ne $target.LastFrame) {
            $target.LastFrame = $frames
            $target.LastFrameAt = $sampleAt
        }
        $target.Samples.Add([ordered]@{
            atUtc = $sampleAt.ToString('o')
            frames = $frames
            cpuSeconds = $target.Process.TotalProcessorTime.TotalSeconds
            workingSetBytes = [int64]$target.Process.WorkingSet64
            privateBytes = [int64]$target.Process.PrivateMemorySize64
            threads = [int]$target.Process.Threads.Count
            handles = [int]$target.Process.HandleCount
            requestedSpeed = if ($status.clock) { [int]$status.clock.requestedSpeed } else { $null }
            effectiveSpeed = if ($status.clock) { [int]$status.clock.effectiveSpeed } else { $null }
            gameTimeSkew = if ($status.clock) { [double]$status.clock.gameTimeSkew } else { $null }
            vehiclePending = if ($status.vehicleSync) { [int]$status.vehicleSync.pendingRounds } else { $null }
        })
    }
    Start-Sleep -Milliseconds $IntervalMilliseconds
}

$peers = [ordered]@{}
foreach ($peer in $targets.Keys) {
    $target = $targets[$peer]
    $target.Process.Refresh()
    $samples = @($target.Samples)
    $elapsed = ([DateTime]::UtcNow - $target.StartAt).TotalSeconds
    $cpuDelta = $target.Process.TotalProcessorTime.TotalSeconds - [double]$target.StartCpu
    $rates = @($target.FrameIntervals)
    $peers[$peer] = [ordered]@{
        processId = $target.ProcessId
        elapsedSeconds = [Math]::Round($elapsed, 3)
        samples = $samples.Count
        observedFrameIntervals = $rates.Count
        averageFps = if ($rates.Count) { [Math]::Round(($rates | Measure-Object -Average).Average, 3) } else { $null }
        minimumObservedFps = if ($rates.Count) { [Math]::Round(($rates | Measure-Object -Minimum).Minimum, 3) } else { $null }
        maximumObservedFps = if ($rates.Count) { [Math]::Round(($rates | Measure-Object -Maximum).Maximum, 3) } else { $null }
        oneCoreCpuPercent = [Math]::Round(($cpuDelta / $elapsed) * 100, 3)
        machineCpuPercent = [Math]::Round((($cpuDelta / $elapsed) * 100) / $logicalProcessors, 3)
        maximumWorkingSetBytes = [int64](($samples.workingSetBytes | Measure-Object -Maximum).Maximum)
        maximumPrivateBytes = [int64](($samples.privateBytes | Measure-Object -Maximum).Maximum)
        maximumThreads = [int](($samples.threads | Measure-Object -Maximum).Maximum)
        maximumHandles = [int](($samples.handles | Measure-Object -Maximum).Maximum)
        maximumAbsoluteGameTimeSkew = [Math]::Round((@($samples.gameTimeSkew | ForEach-Object { [Math]::Abs([double]$_) }) | Measure-Object -Maximum).Maximum, 6)
        maximumPendingVehicleRounds = [int](($samples.vehiclePending | Measure-Object -Maximum).Maximum)
    }
}
$report = [ordered]@{
    schemaVersion = 1
    session = $Session
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    requestedSeconds = $DurationSeconds
    intervalMilliseconds = $IntervalMilliseconds
    logicalProcessors = $logicalProcessors
    source = 'read-only-process-and-existing-menu-telemetry'
    peers = $peers
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "performance_report=$OutputPath"
$report.peers.GetEnumerator() | ForEach-Object {
    Write-Host ("{0}: avg {1} FPS, one-core CPU {2}%, machine CPU {3}%, max working set {4:n0} bytes" -f `
        $_.Key, $_.Value.averageFps, $_.Value.oneCoreCpuPercent,
        $_.Value.machineCpuPercent, $_.Value.maximumWorkingSetBytes)
}
