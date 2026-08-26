[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Host', 'Join')][string]$Role,
    [Parameter(Mandatory = $true)][string]$Session,
    [string]$HostAddress = '127.0.0.1',
    [string]$BindAddress = '0.0.0.0',
    [ValidateRange(1, 65535)][int]$Port = 29742,
    [string]$StartingSave,
    [string]$RestorePlan,
    [string]$ManifestPath,
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$SaveDirectory,
    [ValidateRange(5, 600)][int]$CompletionTimeoutSeconds = 45,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [switch]$TownDevelopment,
    [switch]$NoLaunchGame,
    [ValidateRange(0, [int]::MaxValue)][int]$OwnerLauncherProcessId = 0,
    [string]$OwnerLauncherExecutable,
    [string]$OwnerLauncherStartedAtUtc,
    [switch]$ReplaceExistingSession,
    [switch]$DeferLifecycleSupervisor,
    [ValidateRange(1, 3)][int]$MaxAttempts = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_session_retry_cleanup.ps1')
$sessionScript = Join-Path $PSScriptRoot 'start_network_session.ps1'
if (-not (Test-Path -LiteralPath $sessionScript -PathType Leaf)) {
    throw "Network-session launcher is missing: $sessionScript"
}

$forward = @{}
foreach ($key in $PSBoundParameters.Keys) {
    if ($key -ne 'MaxAttempts') { $forward[$key] = $PSBoundParameters[$key] }
}

$lastFailure = $null
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    try {
        if ($attempt -gt 1) {
            Write-Host "Retrying $Role launch for $Session (attempt $attempt/$MaxAttempts)."
        }
        & $sessionScript @forward
        return
    }
    catch {
        $lastFailure = $_
        $message = [string]$_.Exception.Message
        $transientNativeMenu = $message -match 'native Load Game page' `
            -or $message -match 'ready-to-click-pinned-save' `
            -or $message -match 'stable native row' `
            -or $message -match 'Pinned save .+ is not visible'
        if (-not $transientNativeMenu -or $attempt -ge $MaxAttempts) { throw }
        Write-Warning (
            "Native save manager attempt $attempt/$MaxAttempts failed safely; " `
            + "the exact role/session/save will be retried automatically: $message"
        )
        $peer = if ($Role -eq 'Host') { 'player1' } else { 'player2' }
        $cleanup = Reset-Tpf2mpFailedNativeMenuAttempt -Session $Session -Peer $peer `
            -Attempt $attempt -StopScriptPath (Join-Path $PSScriptRoot 'stop_network_session.ps1')
        Write-Host "Failed attempt evidence archived at $($cleanup.evidenceRoot)."
        Start-Sleep -Seconds 2
    }
}

if ($lastFailure) { throw $lastFailure }
