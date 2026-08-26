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
    [switch]$AllowInsecureLoopback,
    [ValidateRange(0, [int]::MaxValue)][int]$OwnerLauncherProcessId = 0,
    [string]$OwnerLauncherExecutable,
    [string]$OwnerLauncherStartedAtUtc,
    [switch]$ReplaceExistingSession
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
. (Join-Path $PSScriptRoot 'relay_port_common.ps1')
. (Join-Path $PSScriptRoot 'relay_diagnostic_process.ps1')
. (Join-Path $PSScriptRoot 'session_lifecycle.ps1')
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

$requestedPort = $Port
if ($Role -eq 'Join') {
    $Port = Find-Tpf2mpFreeLoopbackPortPair -PreferredPort $requestedPort
    if ($Port -ne $requestedPort) {
        Write-Host "Relay Join remapped occupied local ports $requestedPort/$($requestedPort + 1) to $Port/$($Port + 1)."
    }
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
$startupDiagnosticStatus = Join-Path $sessionRoot 'relay-startup-diagnostics-status.json'
$startupDiagnosticStdout = Join-Path $sessionRoot 'relay-startup-diagnostics.stdout.log'
$startupDiagnosticStderr = Join-Path $sessionRoot 'relay-startup-diagnostics.stderr.log'
$manifest = Join-Path $sessionRoot 'match-manifest.json'
$relayProcess = $null
$startupDiagnostic = $null
$diagnostic = $null
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

    # Capture menu/bootstrap failures before start_network_session reaches its
    # world-ready return. Missing source files are intentionally followed when
    # they appear, so the reporter can start before the game and companion.
    $startupBridge = Resolve-Tpf2mpFullPath `
        (Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$safeSession\$peer")
    $startupSources = New-Tpf2mpRelayDiagnosticSources -SessionRoot $sessionRoot `
        -BridgePath $startupBridge -RelayStatusPath $relayStatus `
        -LocalModsPath $LocalModsPath -Startup
    $startupDiagnostic = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $credentialsPath -Sources $startupSources `
        -StatusPath $startupDiagnosticStatus -StdoutPath $startupDiagnosticStdout `
        -StderrPath $startupDiagnosticStderr -ExpectedSessionId $safeSession `
        -ExpectedRole $expectedRole -AllowInsecureLoopback:$AllowInsecureLoopback

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
        OwnerLauncherProcessId = $OwnerLauncherProcessId
        OwnerLauncherExecutable = $OwnerLauncherExecutable
        OwnerLauncherStartedAtUtc = $OwnerLauncherStartedAtUtc
        ReplaceExistingSession = $ReplaceExistingSession
        DeferLifecycleSupervisor = -not $NoLaunchGame
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

    $relayState = Get-Content -LiteralPath $relayStatus -Raw | ConvertFrom-Json
    $state = Read-Tpf2mpSessionState $safeSession $peer
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $startupDiagnostic -Companion $companion `
        -CredentialsPath $credentialsPath
    $startupDiagnostic = $null
    $diagnosticSources = New-Tpf2mpRelayDiagnosticSources -SessionRoot $sessionRoot `
        -BridgePath ([string]$state.bridgePath) -RelayStatusPath $relayStatus `
        -LocalModsPath $LocalModsPath -SessionState $state
    $diagnostic = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $credentialsPath -Sources $diagnosticSources `
        -StatusPath $diagnosticStatus -StdoutPath $diagnosticStdout `
        -StderrPath $diagnosticStderr -ExpectedSessionId $safeSession `
        -ExpectedRole $expectedRole -AllowInsecureLoopback:$AllowInsecureLoopback
    $state | Add-Member -NotePropertyName transportMode -NotePropertyValue 'secure-relay' -Force
    $state | Add-Member -NotePropertyName relayUrl -NotePropertyValue ([string]$credentialData.relayUrl) -Force
    $state | Add-Member -NotePropertyName relayAllowInsecureLoopback -NotePropertyValue ([bool]$AllowInsecureLoopback) -Force
    $state | Add-Member -NotePropertyName relaySessionId -NotePropertyValue ([string]$credentialData.sessionId) -Force
    $state | Add-Member -NotePropertyName relayRequestedPort -NotePropertyValue $requestedPort -Force
    $state | Add-Member -NotePropertyName relayLocalPort -NotePropertyValue $Port -Force
    $state | Add-Member -NotePropertyName supportId -NotePropertyValue ([string]$credentialData.sessionId) -Force
    $state | Add-Member -NotePropertyName relayCredentials -NotePropertyValue $credentialsPath -Force
    $state | Add-Member -NotePropertyName relayTunnelLauncherPid -NotePropertyValue $relayProcess.Id -Force
    $state | Add-Member -NotePropertyName relayTunnelPid -NotePropertyValue ([int]$relayState.pid) -Force
    $state | Add-Member -NotePropertyName relayTunnelStatusPath -NotePropertyValue $relayStatus -Force
    $state | Add-Member -NotePropertyName relayTunnelStdout -NotePropertyValue $relayStdout -Force
    $state | Add-Member -NotePropertyName relayTunnelStderr -NotePropertyValue $relayStderr -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsLauncherPid -NotePropertyValue $diagnostic.LauncherPid -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsPid -NotePropertyValue $diagnostic.ServicePid -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStatusPath -NotePropertyValue $diagnosticStatus -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStdout -NotePropertyValue $diagnosticStdout -Force
    $state | Add-Member -NotePropertyName relayDiagnosticsStderr -NotePropertyValue $diagnosticStderr -Force
    [void](Write-Tpf2mpSessionState $safeSession $peer $state)
    if (-not $NoLaunchGame -and $state.gamePid) {
        [void](Start-Tpf2mpSessionLifecycleSupervisor -Session $safeSession -Peer $peer `
            -State $state -BundleRoot $bundle `
            -OwnerLauncherProcessId $OwnerLauncherProcessId `
            -OwnerLauncherExecutable $OwnerLauncherExecutable `
            -OwnerLauncherStartedAtUtc $OwnerLauncherStartedAtUtc)
    }
    Write-Host "secure_relay_ready=$($credentialData.sessionId)"
    Write-Host "support_id=$($credentialData.sessionId)"
    Write-Host "relay_tunnel_status=$relayStatus"
    Write-Host 'Structured diagnostics are enabled; native crash dumps are never uploaded automatically.'
}
catch {
    if ($startupDiagnostic -and -not $baseStarted `
            -and (Test-Path -LiteralPath (Join-Path $sessionRoot 'session-state.json'))) {
        # Give the two-second reporter one final opportunity to publish the
        # launcher's fail-closed state before cleaning up its process.
        Start-Sleep -Milliseconds 2200
    }
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $startupDiagnostic -Companion $companion `
        -CredentialsPath $credentialsPath
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $diagnostic -Companion $companion `
        -CredentialsPath $credentialsPath
    Stop-Tpf2mpVerifiedRelayProcesses -Companion $companion `
        -CredentialsPath $credentialsPath -CommandName relay-tunnel
    if ($baseStarted) {
        try {
            & (Join-Path $PSScriptRoot 'stop_network_session.ps1') `
                -Session $safeSession -Peer $peer -StopGame
        }
        catch { }
    }
    throw
}
