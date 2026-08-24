Set-StrictMode -Version Latest

$script:Tpf2mpNetworkAutosaveMinutes = 10080
$script:Tpf2mpAutosavePattern = '(?m)^(?<prefix>[ \t]*autosaveIntervalMinutes[ \t]*=[ \t]*)(?<value>\d+)(?<suffix>[ \t]*,)'
$script:Tpf2mpAutosaveMutexName = 'Local\TPF2MP.NetworkAutosaveGuard'

function Invoke-Tpf2mpAutosaveGuardLock {
    param([Parameter(Mandatory = $true)][scriptblock]$Body)
    $mutex = [Threading.Mutex]::new($false, $script:Tpf2mpAutosaveMutexName)
    $owned = $false
    try {
        try { $owned = $mutex.WaitOne(10000) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Timed out acquiring the TPF2MP autosave guard lock.' }
        & $Body
    }
    finally {
        if ($owned) { [void]$mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Read-Tpf2mpAutosaveInterval {
    param([Parameter(Mandatory = $true)][string]$SettingsPath)
    $path = [IO.Path]::GetFullPath($SettingsPath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Transport Fever 2 settings are missing: $path"
    }
    $content = [IO.File]::ReadAllText($path)
    $matches = [regex]::Matches($content, $script:Tpf2mpAutosavePattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one autosaveIntervalMinutes setting in $path; found $($matches.Count)."
    }
    $value = [int64]$matches[0].Groups['value'].Value
    if ($value -lt 0 -or $value -gt [int]::MaxValue) {
        throw "autosaveIntervalMinutes is outside the supported integer range in $path."
    }
    return [int]$value
}

function Set-Tpf2mpAutosaveInterval {
    param(
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][ValidateRange(0, [int]::MaxValue)][int]$Minutes
    )
    $path = [IO.Path]::GetFullPath($SettingsPath)
    $content = [IO.File]::ReadAllText($path)
    $matches = [regex]::Matches($content, $script:Tpf2mpAutosavePattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one autosaveIntervalMinutes setting in $path; found $($matches.Count)."
    }
    $replacement = '${prefix}' + [string]$Minutes + '${suffix}'
    $updated = [regex]::Replace($content, $script:Tpf2mpAutosavePattern, $replacement)
    if ($updated -ceq $content) { return }

    $temporary = "$path.tpf2mp-$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$path.tpf2mp-$([guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllText($temporary, $updated, [Text.UTF8Encoding]::new($false))
        [IO.File]::Replace($temporary, $path, $backup, $true)
    }
    finally {
        foreach ($candidate in @($temporary, $backup)) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Write-Tpf2mpAutosaveGuardLease {
    param(
        [Parameter(Mandatory = $true)][string]$LeasePath,
        [Parameter(Mandatory = $true)]$Lease
    )
    $path = [IO.Path]::GetFullPath($LeasePath)
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Lease | ConvertTo-Json -Depth 8),
            [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $backup = "$path.$([guid]::NewGuid().ToString('N')).bak"
            try { [IO.File]::Replace($temporary, $path, $backup, $true) }
            finally {
                if (Test-Path -LiteralPath $backup -PathType Leaf) {
                    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
                }
            }
        }
        else { [IO.File]::Move($temporary, $path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-Tpf2mpAutosaveGuardLease {
    param([Parameter(Mandatory = $true)][string]$LeasePath)
    $path = [IO.Path]::GetFullPath($LeasePath)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    $lease = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ([int]$lease.schemaVersion -ne 1 -or -not $lease.settingsPath `
            -or $null -eq $lease.originalAutosaveIntervalMinutes `
            -or $null -eq $lease.guardedAutosaveIntervalMinutes) {
        throw "Malformed TPF2MP autosave guard lease: $path"
    }
    return $lease
}

function Test-Tpf2mpAutosaveGuardProcess {
    param([Parameter(Mandatory = $true)]$Lease)
    $pidValue = if ($Lease.PSObject.Properties['gameProcessId']) {
        [int]$Lease.gameProcessId
    } else { 0 }
    if ($pidValue -le 0) { return $false }
    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    try {
        $expectedStart = [DateTime]::Parse([string]$Lease.gameStartedAtUtc).ToUniversalTime()
        $observedStart = $process.StartTime.ToUniversalTime()
        if ([math]::Abs(($observedStart - $expectedStart).TotalSeconds) -gt 2) { return $false }
        $expectedExecutable = [IO.Path]::GetFullPath([string]$Lease.gameExecutable)
        $observedExecutable = [IO.Path]::GetFullPath([string]$process.Path)
        return [string]::Equals($expectedExecutable, $observedExecutable,
            [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Restore-Tpf2mpNetworkAutosaveGuard {
    param(
        [Parameter(Mandatory = $true)][string]$LeasePath,
        [string]$Reason = 'game-process-ended'
    )
    return Invoke-Tpf2mpAutosaveGuardLock {
        $lease = Read-Tpf2mpAutosaveGuardLease $LeasePath
        if (-not $lease) { return $null }
        if ([string]$lease.status -in @('restored', 'released-with-external-change')) {
            return $lease
        }
        $settingsPath = [IO.Path]::GetFullPath([string]$lease.settingsPath)
        $current = Read-Tpf2mpAutosaveInterval $settingsPath
        $guarded = [int]$lease.guardedAutosaveIntervalMinutes
        $original = [int]$lease.originalAutosaveIntervalMinutes
        if ($current -eq $guarded) {
            Set-Tpf2mpAutosaveInterval -SettingsPath $settingsPath -Minutes $original
            $lease.status = 'restored'
        }
        else {
            # Preserve an explicit user/game change instead of overwriting the
            # whole settings file with a stale launch-time value.
            $lease.status = 'released-with-external-change'
        }
        $lease.restoreReason = $Reason
        $lease.restoredAtUtc = [DateTime]::UtcNow.ToString('o')
        $lease.observedIntervalAtRestore = $current
        Write-Tpf2mpAutosaveGuardLease -LeasePath $LeasePath -Lease $lease
        return $lease
    }
}

function Repair-Tpf2mpNetworkAutosaveGuard {
    param([Parameter(Mandatory = $true)][string]$LeasePath)
    return Invoke-Tpf2mpAutosaveGuardLock {
        $lease = Read-Tpf2mpAutosaveGuardLease $LeasePath
        if (-not $lease) { return $null }
        if ([string]$lease.status -eq 'active' -and (Test-Tpf2mpAutosaveGuardProcess $lease)) {
            throw "A Transport Fever 2 network game already owns the autosave guard (session $($lease.session), PID $($lease.gameProcessId))."
        }
        if ([string]$lease.status -eq 'armed') {
            $updated = [DateTime]::Parse([string]$lease.updatedAtUtc).ToUniversalTime()
            if (([DateTime]::UtcNow - $updated).TotalMinutes -lt 5) {
                throw "Another TPF2MP launcher is currently arming the autosave guard for session $($lease.session)."
            }
        }
        if ([string]$lease.status -notin @('restored', 'released-with-external-change')) {
            $settingsPath = [IO.Path]::GetFullPath([string]$lease.settingsPath)
            $current = Read-Tpf2mpAutosaveInterval $settingsPath
            if ($current -eq [int]$lease.guardedAutosaveIntervalMinutes) {
                Set-Tpf2mpAutosaveInterval -SettingsPath $settingsPath `
                    -Minutes ([int]$lease.originalAutosaveIntervalMinutes)
                $lease.status = 'restored'
            }
            else { $lease.status = 'released-with-external-change' }
            $lease.restoreReason = 'stale-launch-repair'
            $lease.restoredAtUtc = [DateTime]::UtcNow.ToString('o')
            $lease.observedIntervalAtRestore = $current
            Write-Tpf2mpAutosaveGuardLease -LeasePath $LeasePath -Lease $lease
        }
        return $lease
    }
}

function Enter-Tpf2mpNetworkAutosaveGuard {
    param(
        [Parameter(Mandatory = $true)][string]$LeasePath,
        [Parameter(Mandatory = $true)][string]$SettingsPath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    [void](Repair-Tpf2mpNetworkAutosaveGuard -LeasePath $LeasePath)
    return Invoke-Tpf2mpAutosaveGuardLock {
        $path = [IO.Path]::GetFullPath($SettingsPath)
        if ([IO.Path]::GetFileName($path) -cne 'settings.lua') {
            throw "Refusing unexpected Transport Fever 2 settings filename: $path"
        }
        $original = Read-Tpf2mpAutosaveInterval $path
        $guarded = [math]::Max($original, $script:Tpf2mpNetworkAutosaveMinutes)
        $now = [DateTime]::UtcNow.ToString('o')
        $lease = [pscustomobject][ordered]@{
            schemaVersion = 1
            session = $Session
            peer = $Peer
            settingsPath = $path
            originalAutosaveIntervalMinutes = $original
            guardedAutosaveIntervalMinutes = $guarded
            gameProcessId = 0
            gameExecutable = $null
            gameStartedAtUtc = $null
            status = 'armed'
            createdAtUtc = $now
            updatedAtUtc = $now
            restoredAtUtc = $null
            restoreReason = $null
            observedIntervalAtRestore = $null
        }
        # Persist the recovery information before touching the game setting.
        Write-Tpf2mpAutosaveGuardLease -LeasePath $LeasePath -Lease $lease
        Set-Tpf2mpAutosaveInterval -SettingsPath $path -Minutes $guarded
        return $lease
    }
}

function Bind-Tpf2mpNetworkAutosaveGuard {
    param(
        [Parameter(Mandatory = $true)][string]$LeasePath,
        [Parameter(Mandatory = $true)][Diagnostics.Process]$GameProcess,
        [Parameter(Mandatory = $true)][string]$GameExecutable
    )
    return Invoke-Tpf2mpAutosaveGuardLock {
        $lease = Read-Tpf2mpAutosaveGuardLease $LeasePath
        if (-not $lease -or [string]$lease.status -ne 'armed') {
            throw 'The TPF2MP autosave guard is not armed for this launch.'
        }
        $lease.gameProcessId = $GameProcess.Id
        $lease.gameExecutable = [IO.Path]::GetFullPath($GameExecutable)
        $lease.gameStartedAtUtc = $GameProcess.StartTime.ToUniversalTime().ToString('o')
        $lease.status = 'active'
        $lease.updatedAtUtc = [DateTime]::UtcNow.ToString('o')
        Write-Tpf2mpAutosaveGuardLease -LeasePath $LeasePath -Lease $lease
        return $lease
    }
}

