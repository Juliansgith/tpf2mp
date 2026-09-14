[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [Parameter(Mandatory)][string]$OutputPath,
    [ValidateRange(1, 600)][int]$DurationSeconds = 60,
    [ValidateRange(250, 5000)][int]$IntervalMilliseconds = 1000,
    [string]$Label = 'unlabelled'
)

# Works without multiplayer telemetry, UI automation, hooks, or game mutations.
# CPU is process CPU, not FPS or simulated seconds. Registry is not heap proof.
$ErrorActionPreference = 'Stop'
$target = Get-Process -Id $ProcessId -ErrorAction Stop
$started = $target.StartTime.ToUniversalTime().ToString('o')
$executable = $target.Path
$logicalProcessors = [Environment]::ProcessorCount
$destination = [IO.Path]::GetFullPath($OutputPath)
$stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew,
    [IO.FileAccess]::Write, [IO.FileShare]::Read)
$writer = New-Object IO.StreamWriter($stream)
try {
    $heapValue = $null
    if ([IO.Path]::GetFileName($executable) -ieq 'TransportFever2.exe') {
        $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\TransportFever2.exe'
        $entry = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
        if ($entry) { $heapValue = $entry.FrontEndHeapDebugOptions }
    }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $complete = $false
    $failure = $null
    try {
        do {
            $target.Refresh()
            if ($target.HasExited) { throw 'Target process exited during capture.' }
            $rows.Add([ordered]@{
                seconds = $timer.Elapsed.TotalSeconds
                cpuSeconds = $target.TotalProcessorTime.TotalSeconds
                privateBytes = $target.PrivateMemorySize64
                workingSetBytes = $target.WorkingSet64
                handles = $target.HandleCount
                threads = $target.Threads.Count
            })
            if ($timer.Elapsed.TotalSeconds -ge $DurationSeconds) { break }
            Start-Sleep -Milliseconds $IntervalMilliseconds
        } while ($true)
        $complete = $true
    } catch { $failure = $_.Exception.Message }
    $elapsed = if ($rows.Count -gt 1) { $rows[$rows.Count - 1].seconds - $rows[0].seconds } else { 0 }
    $cpuDelta = if ($rows.Count -gt 1) { $rows[$rows.Count - 1].cpuSeconds - $rows[0].cpuSeconds } else { 0 }
    $report = [ordered]@{
        schemaVersion = 1
        label = $Label
        processId = $ProcessId
        processStartedUtc = $started
        executable = $executable
        complete = $complete
        error = $failure
        elapsedSeconds = $elapsed
        logicalProcessors = $logicalProcessors
        oneCoreCpuPercent = if ($elapsed -gt 0) { 100 * $cpuDelta / $elapsed } else { $null }
        machineCpuPercent = if ($elapsed -gt 0) { 100 * $cpuDelta / $elapsed / $logicalProcessors } else { $null }
        frontEndHeapDebugOptionsConfigured = $heapValue
        nativeHeapTypeVerified = $false
        fps = $null
        simulationThroughput = $null
        measurementScope = 'OS process counters only; no GPU, frame-time, or simulation-speed measurement'
        samples = @($rows.ToArray())
    }
    $writer.Write(($report | ConvertTo-Json -Depth 8))
    $writer.Flush()
    if (-not $complete) { throw $failure }
    Write-Output "process_performance_report=$destination"
} finally {
    $writer.Dispose()
    $target.Dispose()
}
