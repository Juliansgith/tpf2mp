[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Host', 'Join')][string]$Role,
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][string]$RelayCredentials,
    [ValidateRange(1, 65534)][int]$Port = 29742,
    [string]$StartingSave,
    [string]$RestorePlan,
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string]$SaveDirectory,
    [ValidateRange(5, 600)][int]$CompletionTimeoutSeconds = 45,
    [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
    [switch]$TownDevelopment,
    [switch]$NoLaunchGame,
    [switch]$AllowInsecureLoopback
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
$peer = if ($Role -eq 'Host') { 'player1' } else { 'player2' }
$credentialsPath = Protect-Tpf2mpPrivateFile $RelayCredentials
$credentialData = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
$expectedRole = if ($Role -eq 'Host') { 'host' } else { 'join' }
if ([int]$credentialData.schemaVersion -ne 1 `
        -or [string]$credentialData.role -cne $expectedRole `
        -or [string]$credentialData.sessionId -notmatch '^mp-[0-9a-f]{16}$') {
    throw 'Relay credentials do not match this role or have an invalid schema/session.'
}
$secureRelay = [string]$credentialData.relayUrl -match '^https://'
$loopbackAllowed = $AllowInsecureLoopback `
    -and [string]$credentialData.relayUrl -match '^http://(?:127\.0\.0\.1|localhost|\[?::1\]?):\d+(?:/|$)'
if (-not $secureRelay -and -not $loopbackAllowed) {
    throw 'Relay credentials must use secure HTTPS outside an explicit loopback test.'
}

$companion = Get-Tpf2mpCompanionCommand $bundle
$sessionRoot = Get-Tpf2mpSessionRoot $safeSession $peer
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
$relayStatus = Join-Path $sessionRoot 'relay-tunnel-status.json'
$relayStdout = Join-Path $sessionRoot 'relay-tunnel.stdout.log'
$relayStderr = Join-Path $sessionRoot 'relay-tunnel.stderr.log'
$diagnosticStatus = Join-Path $sessionRoot 'relay-diagnostics-status.json'
$diagnosticStdout = Join-Path $sessionRoot 'relay-diagnostics.stdout.log'
$diagnosticStderr = Join-Path $sessionRoot 'relay-diagnostics.stderr.log'
$manifest = Join-Path $sessionRoot 'match-manifest.json'
$relayProcess = $null
$diagnosticProcess = $null
$baseStarted = $false

function Start-RelayTunnelProcess([bool]$IncludeSave) {
    $arguments = @(
        'relay-tunnel', '--credentials', $credentialsPath,
        '--gameplay-port', $Port,
        '--match-manifest', $manifest,
        '--status', $relayStatus
    )
    if ($IncludeSave) { $arguments += @('--save-port', ($Port + 1)) }
    $commandLine = ConvertTo-Tpf2mpCommandLine (@($companion.Prefix) + $arguments)
    $previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
    try {
        if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
        return Start-Process -FilePath $companion.FilePath -ArgumentList $commandLine `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $relayStdout `
            -RedirectStandardError $relayStderr
    }
    finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
}

function Wait-RelayTunnelReady($Process, [bool]$IncludeSave) {
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $Process.Refresh()
        if ($Process.HasExited) {
            $errorText = if (Test-Path -LiteralPath $relayStderr) {
                Get-Content -LiteralPath $relayStderr -Raw
            } else { '' }
            throw "Relay tunnel exited during startup (code $($Process.ExitCode)): $errorText"
        }
        $status = $null
        if (Test-Path -LiteralPath $relayStatus -PathType Leaf) {
            try { $status = Get-Content -LiteralPath $relayStatus -Raw | ConvertFrom-Json }
            catch { }
        }
        if ($status -and [string]$status.sessionId -ceq [string]$credentialData.sessionId `
                -and [string]$status.role -ceq $expectedRole) {
            $gameState = [string]$status.channels.gameplay.state
            $saveState = if ($IncludeSave) { [string]$status.channels.save.state } else { 'not-needed' }
            $roleReady = if ($Role -eq 'Host') {
                $gameState -in @('waiting-peer', 'paired') `
                    -and $saveState -in @('waiting-peer', 'paired', 'not-needed')
            } else {
                $gameState -in @('listening-local', 'paired') `
                    -and $saveState -in @('listening-local', 'paired', 'not-needed')
            }
            if ($roleReady) { return $status }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    $last = if (Test-Path -LiteralPath $relayStatus) {
        Get-Content -LiteralPath $relayStatus -Raw
    } else { 'no relay status' }
    throw "Secure relay tunnel did not become ready within 20 seconds: $last"
}

function Start-RelayDiagnostics {
    $state = Read-Tpf2mpSessionState $safeSession $peer
    if (-not $state) { throw 'Base network session state disappeared before diagnostics startup.' }
    $resolvedMods = Find-Tpf2mpLocalModsPath $LocalModsPath
    $localGameData = Split-Path -Parent $resolvedMods
    $gameLog = Join-Path $localGameData 'crash_dump\stdout.txt'
    $sourceArguments = @()
    foreach ($source in @(
        [pscustomobject]@{ Name = 'companion.stdout'; Path = [string]$state.stdout },
        [pscustomobject]@{ Name = 'companion.stderr'; Path = [string]$state.stderr },
        [pscustomobject]@{ Name = 'companion.status'; Path = (Join-Path ([string]$state.bridgePath) 'companion_state\companion_status.json') },
        [pscustomobject]@{ Name = 'game.stdout'; Path = $gameLog },
        [pscustomobject]@{ Name = 'native.status'; Path = if ($state.PSObject.Properties['nativeStatusPath']) { [string]$state.nativeStatusPath } else { $null } },
        [pscustomobject]@{ Name = 'launcher.menu'; Path = (Join-Path ([string]$state.bridgePath) 'launcher\menu_status.json') },
        [pscustomobject]@{ Name = 'recovery.status'; Path = if ($state.PSObject.Properties['recoveryWatcherStatusPath']) { [string]$state.recoveryWatcherStatusPath } else { $null } },
        [pscustomobject]@{ Name = 'relay.tunnel'; Path = $relayStatus }
    )) {
        if ($source.Path) { $sourceArguments += @('--source', ($source.Name + '=' + $source.Path)) }
    }
    $arguments = @(
        'relay-diagnostics', '--credentials', $credentialsPath,
        '--status', $diagnosticStatus, '--interval', '2'
    ) + $sourceArguments
    $commandLine = ConvertTo-Tpf2mpCommandLine (@($companion.Prefix) + $arguments)
    $previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
    try {
        if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
        return Start-Process -FilePath $companion.FilePath -ArgumentList $commandLine `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $diagnosticStdout `
            -RedirectStandardError $diagnosticStderr
    }
    finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
}

try {
    $includeSave = -not $RestorePlan -and ($Role -eq 'Host' -or -not $StartingSave)
    if ($Role -eq 'Join') {
        # Local listeners exist before save download or CommitClient startup.
        # The gameplay connection reads the manifest generated by the base
        # launcher immediately before it opens WSS, so both peers still attest
        # the final content fingerprint at the relay.
        $relayProcess = Start-RelayTunnelProcess $includeSave
        [void](Wait-RelayTunnelReady $relayProcess $includeSave)
        if (-not $StartingSave -and -not $RestorePlan) {
            & (Join-Path $PSScriptRoot 'sync_starting_save.ps1') `
                -Session $safeSession -HostAddress '127.0.0.1' -Port $Port `
                -BundleRoot $bundle -LocalModsPath $LocalModsPath -SaveDirectory $SaveDirectory
            if ($LASTEXITCODE -ne 0) {
                throw "Relay starting-save sync failed with exit code $LASTEXITCODE"
            }
            $syncReceipt = Join-Path $sessionRoot 'received-starting-save.json'
            if (-not (Test-Path -LiteralPath $syncReceipt -PathType Leaf)) {
                throw 'Relay save transfer completed without its verified receipt.'
            }
            $StartingSave = [string](Get-Content -LiteralPath $syncReceipt -Raw | ConvertFrom-Json).savePath
        }
    }

    $launchArguments = @{
        Role = $Role
        Session = $safeSession
        Port = $Port
        StartingSave = $StartingSave
        RestorePlan = $RestorePlan
        BundleRoot = $bundle
        GameExecutable = $GameExecutable
        LocalModsPath = $LocalModsPath
        SaveDirectory = $SaveDirectory
        CompletionTimeoutSeconds = $CompletionTimeoutSeconds
        AgentMode = $AgentMode
        TownDevelopment = $TownDevelopment
        NoLaunchGame = $NoLaunchGame
    }
    foreach ($key in @($launchArguments.Keys)) {
        if ($null -eq $launchArguments[$key] -or $launchArguments[$key] -eq '') {
            $launchArguments.Remove($key)
        }
    }
    if ($Role -eq 'Host') { $launchArguments.BindAddress = '127.0.0.1' }
    else { $launchArguments.HostAddress = '127.0.0.1' }
    & (Join-Path $PSScriptRoot 'start_network_session_retry.ps1') @launchArguments
    $baseStarted = $true

    if ($Role -eq 'Host') {
        $relayProcess = Start-RelayTunnelProcess $includeSave
        [void](Wait-RelayTunnelReady $relayProcess $includeSave)
    }

    $diagnosticProcess = Start-RelayDiagnostics
    $diagnosticDeadline = (Get-Date).AddSeconds(10)
    $diagnosticServicePid = $null
    do {
        $diagnosticProcess.Refresh()
        if ($diagnosticProcess.HasExited) {
            $errorText = if (Test-Path -LiteralPath $diagnosticStderr) {
                Get-Content -LiteralPath $diagnosticStderr -Raw
            } else { '' }
            throw "Relay diagnostics exited during startup: $errorText"
        }
        if (Test-Path -LiteralPath $diagnosticStatus -PathType Leaf) {
            try {
                $diagnosticState = Get-Content -LiteralPath $diagnosticStatus -Raw | ConvertFrom-Json
                if ([string]$diagnosticState.sessionId -ceq [string]$credentialData.sessionId `
                        -and [string]$diagnosticState.role -ceq $expectedRole `
                        -and [string]$diagnosticState.state -in @('running', 'retrying')) {
                    $diagnosticServicePid = [int]$diagnosticState.pid
                    break
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $diagnosticDeadline)
    if (-not $diagnosticServicePid) {
        throw 'Relay diagnostics did not publish a valid status within 10 seconds.'
    }

    $relayState = Get-Content -LiteralPath $relayStatus -Raw | ConvertFrom-Json
    $state = Read-Tpf2mpSessionState $safeSession $peer
    $state | Add-Member -NotePropertyName transportMode -NotePropertyValue 'secure-relay' -Force
    $state | Add-Member -NotePropertyName relayUrl -NotePropertyValue ([string]$credentialData.relayUrl) -Force
    $state | Add-Member -NotePropertyName relayAllowInsecureLoopback -NotePropertyValue ([bool]$AllowInsecureLoopback) -Force
    $state | Add-Member -NotePropertyName relaySessionId -NotePropertyValue ([string]$credentialData.sessionId) -Force
    $state | Add-Member -NotePropertyName supportId -NotePropertyValue ([string]$credentialData.sessionId) -Force
    $state | Add-Member -NotePropertyName relayCredentials -NotePropertyValue $credentialsPath -Force
    $state | Add-Member -NotePropertyName relayTunnelLauncherPid -NotePropertyValue $relayProcess.Id -Force
    $state | Add-Member -NotePropertyName relayTunnelPid -NotePropertyValue ([int]$relayState.pid) -Force
    $state | Add-Member -NotePropertyName relayTunnelStatusPath -NotePropertyValue $relayStatus -Force
    $state | Add-Member -NotePropertyName relayTunnelStdout -NotePropertyValue $relayStdout -Force
    $state | Add-Member -NotePropertyName relayTunnelStderr -NotePropertyValue $relayStderr -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsLauncherPid -NotePropertyValue $diagnosticProcess.Id -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsPid -NotePropertyValue $diagnosticServicePid -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStatusPath -NotePropertyValue $diagnosticStatus -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStdout -NotePropertyValue $diagnosticStdout -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStderr -NotePropertyValue $diagnosticStderr -Force
    [void](Write-Tpf2mpSessionState $safeSession $peer $state)
    Write-Host "secure_relay_ready=$($credentialData.sessionId)"
    Write-Host "support_id=$($credentialData.sessionId)"
    Write-Host "relay_tunnel_status=$relayStatus"
    Write-Host 'Structured diagnostics are enabled; native crash dumps are never uploaded automatically.'
}
catch {
    foreach ($process in @($diagnosticProcess, $relayProcess)) {
        if ($process) {
            try {
                $process.Refresh()
                if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
            }
            catch { }
        }
    }
    if ($baseStarted) {
        try {
            & (Join-Path $PSScriptRoot 'stop_network_session.ps1') `
                -Session $safeSession -Peer $peer -StopGame
        }
        catch { }
    }
    throw
}
