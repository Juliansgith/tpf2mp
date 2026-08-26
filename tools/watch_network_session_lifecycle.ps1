[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [Parameter(Mandatory = $true)][ValidateRange(1, [int]::MaxValue)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [Parameter(Mandatory = $true)][string]$BundleRoot,
    [Parameter(Mandatory = $true)][string]$StatusPath,
    [ValidateRange(0, [int]::MaxValue)][int]$OwnerLauncherProcessId = 0,
    [string]$OwnerLauncherExecutable,
    [string]$OwnerLauncherStartedAtUtc,
    [string]$StopScriptPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'session_lifecycle.ps1')
$safeSession = Assert-Tpf2mpSessionId $Session
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
if (-not $StopScriptPath) { $StopScriptPath = Join-Path $PSScriptRoot 'stop_network_session.ps1' }
$stopScript = Resolve-Tpf2mpFullPath $StopScriptPath

function Write-LifecycleStatus([string]$Status, [string]$Reason, [string]$ErrorText) {
    $value = [pscustomobject][ordered]@{
        schemaVersion = 1
        session = $safeSession
        peer = $Peer
        supervisorPid = $PID
        gameProcessId = $GameProcessId
        ownerLauncherProcessId = $OwnerLauncherProcessId
        status = $Status
        reason = $Reason
        error = $ErrorText
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $directory = Split-Path -Parent (Resolve-Tpf2mpFullPath $StatusPath)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

try {
    if ($OwnerLauncherProcessId -gt 0 `
            -and (-not $OwnerLauncherExecutable -or -not $OwnerLauncherStartedAtUtc)) {
        throw 'Lifecycle watcher received an incomplete launcher identity.'
    }
    Write-LifecycleStatus 'active' '' ''
    $reason = $null
    while (-not $reason) {
        $state = Read-Tpf2mpSessionState $safeSession $Peer
        if ($state -and [string]$state.status -in @('stopped', 'failed')) {
            Write-LifecycleStatus 'released' 'session-already-terminal' ''
            exit 0
        }
        $gameAlive = Test-Tpf2mpExactProcessIdentity -ProcessId $GameProcessId `
            -ExecutablePath $GameExecutable -StartedAtUtc $GameStartedAtUtc
        if (-not $gameAlive) { $reason = 'game-process-ended'; break }
        if ($OwnerLauncherProcessId -gt 0) {
            $ownerAlive = Test-Tpf2mpExactProcessIdentity -ProcessId $OwnerLauncherProcessId `
                -ExecutablePath $OwnerLauncherExecutable -StartedAtUtc $OwnerLauncherStartedAtUtc
            if (-not $ownerAlive) { $reason = 'launcher-process-ended'; break }
        }
        Start-Sleep -Milliseconds 500
    }

    Write-LifecycleStatus 'cleaning' $reason ''
    $stopArguments = @{
        Session = $safeSession
        Peer = $Peer
        StopReason = $reason
    }
    if ($reason -eq 'launcher-process-ended') { $stopArguments.StopGame = $true }
    & $stopScript @stopArguments
    if (-not $?) { throw "Session cleanup failed after $reason." }
    Write-LifecycleStatus 'cleaned' $reason ''
}
catch {
    Write-LifecycleStatus 'error' '' $_.Exception.Message
    throw
}
