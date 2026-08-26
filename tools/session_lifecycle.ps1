Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')
. (Join-Path $PSScriptRoot 'network_autosave_guard.ps1')

function Test-Tpf2mpExactProcessIdentity {
    param(
        [ValidateRange(1, [int]::MaxValue)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$StartedAtUtc
    )
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process -or $process.HasExited) { return $false }
    try {
        $expectedExecutable = Resolve-Tpf2mpFullPath $ExecutablePath
        $observedExecutable = Resolve-Tpf2mpFullPath ([string]$process.Path)
        $expectedStart = [DateTime]::Parse($StartedAtUtc).ToUniversalTime()
        $observedStart = $process.StartTime.ToUniversalTime()
        return [string]::Equals(
                $expectedExecutable, $observedExecutable,
                [StringComparison]::OrdinalIgnoreCase
            ) -and [Math]::Abs(($observedStart - $expectedStart).TotalSeconds) -lt 2
    }
    catch { return $false }
}

function Invoke-Tpf2mpReplaceManagedSessionConflicts {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [ValidateRange(0, 65535)][int]$HostPort = 0,
        [string]$AutosaveGuardLeasePath,
        [Parameter(Mandatory = $true)][string]$StopScriptPath
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $stopScript = Resolve-Tpf2mpFullPath $StopScriptPath
    if (-not (Test-Path -LiteralPath $stopScript -PathType Leaf)) {
        throw "Managed-session stop script is missing: $stopScript"
    }
    $candidates = [Collections.Generic.List[object]]::new()
    if ($HostPort -gt 0) {
        foreach ($owner in @(Get-Tpf2mpTcpListenerOwners -Port $HostPort)) {
            if ($owner.tpf2mpCompanion -and $owner.session `
                    -and $owner.peer -in @('player1', 'player2')) {
                $candidates.Add([pscustomobject]@{
                    session = [string]$owner.session
                    peer = [string]$owner.peer
                    source = "TCP $HostPort"
                })
            }
        }
    }
    if ($AutosaveGuardLeasePath -and (Test-Path -LiteralPath $AutosaveGuardLeasePath -PathType Leaf)) {
        $lease = Read-Tpf2mpAutosaveGuardLease $AutosaveGuardLeasePath
        if ($lease -and [string]$lease.status -eq 'active' `
                -and (Test-Tpf2mpAutosaveGuardProcess $lease) `
                -and [string]$lease.session `
                -and [string]$lease.peer -in @('player1', 'player2')) {
            $candidates.Add([pscustomobject]@{
                session = [string]$lease.session
                peer = [string]$lease.peer
                source = 'autosave guard'
            })
        }
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($candidate in $candidates) {
        $identity = "$($candidate.session)/$($candidate.peer)"
        if (-not $seen.Add($identity)) { continue }
        $state = Read-Tpf2mpSessionState $candidate.session $candidate.peer
        if (-not $state) {
            throw (
                "A prior TPF2MP process for $identity still owns $($candidate.source), " `
                + 'but its verified launcher state is missing. Close that Transport Fever 2 process once or reboot; no unknown PID was terminated.'
            )
        }
        Write-Host "Replacing prior managed TPF2MP session $identity ($($candidate.source))."
        & $stopScript -Session $candidate.session -Peer $candidate.peer -StopGame `
            -StopReason "replaced-by-$safeSession/$Peer"
        if (-not $?) { throw "Could not stop prior managed TPF2MP session $identity." }
    }
}

function Start-Tpf2mpSessionLifecycleSupervisor {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [ValidateRange(0, [int]::MaxValue)][int]$OwnerLauncherProcessId = 0,
        [string]$OwnerLauncherExecutable,
        [string]$OwnerLauncherStartedAtUtc
    )
    if (-not $State.gamePid -or -not $State.gameExecutable -or -not $State.gameStartedAtUtc) {
        throw 'A lifecycle supervisor requires the exact launched game identity.'
    }
    if ($OwnerLauncherProcessId -gt 0 `
            -and (-not $OwnerLauncherExecutable -or -not $OwnerLauncherStartedAtUtc)) {
        throw 'A launcher-owned session requires the launcher executable and start time.'
    }
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $scriptPath = Join-Path $PSScriptRoot 'watch_network_session_lifecycle.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Session lifecycle watcher is missing: $scriptPath"
    }
    $sessionRoot = Get-Tpf2mpSessionRoot $Session $Peer
    $statusPath = Join-Path $sessionRoot 'session-lifecycle-status.json'
    $stdoutPath = Join-Path $sessionRoot 'session-lifecycle.stdout.log'
    $stderrPath = Join-Path $sessionRoot 'session-lifecycle.stderr.log'
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
        '-Session', $Session, '-Peer', $Peer,
        '-GameProcessId', [string]$State.gamePid,
        '-GameExecutable', [string]$State.gameExecutable,
        '-GameStartedAtUtc', [string]$State.gameStartedAtUtc,
        '-BundleRoot', $bundle, '-StatusPath', $statusPath
    )
    if ($OwnerLauncherProcessId -gt 0) {
        $arguments += @(
            '-OwnerLauncherProcessId', [string]$OwnerLauncherProcessId,
            '-OwnerLauncherExecutable', $OwnerLauncherExecutable,
            '-OwnerLauncherStartedAtUtc', $OwnerLauncherStartedAtUtc
        )
    }
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    Start-Sleep -Milliseconds 300
    $process.Refresh()
    if ($process.HasExited) {
        $errorText = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
            Get-Content -LiteralPath $stderrPath -Raw
        } else { '' }
        throw "Session lifecycle supervisor exited during startup: $errorText"
    }
    $State | Add-Member -NotePropertyName lifecycleSupervisorPid -NotePropertyValue $process.Id -Force
    $State | Add-Member -NotePropertyName lifecycleStatusPath -NotePropertyValue $statusPath -Force
    $State | Add-Member -NotePropertyName lifecycleStdout -NotePropertyValue $stdoutPath -Force
    $State | Add-Member -NotePropertyName lifecycleStderr -NotePropertyValue $stderrPath -Force
    $State | Add-Member -NotePropertyName ownerLauncherPid -NotePropertyValue $OwnerLauncherProcessId -Force
    $State | Add-Member -NotePropertyName ownerLauncherExecutable -NotePropertyValue $OwnerLauncherExecutable -Force
    $State | Add-Member -NotePropertyName ownerLauncherStartedAtUtc -NotePropertyValue $OwnerLauncherStartedAtUtc -Force
    [void](Write-Tpf2mpSessionState $Session $Peer $State)
    return $process
}
