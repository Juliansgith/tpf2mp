[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CredentialsPath,
    [Parameter(Mandatory)][string]$GameExecutable,
    [Parameter(Mandatory)][string]$ModDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$ConfigDigest,
    [string]$StartingSave,
    [string]$BundleRoot,
    [string]$NativeBuildDirectory,
    [switch]$AllowInsecureLoopback,
    # Acceptance harness: qualify generation using the same worker, then own
    # both local game processes under one autosave lease. Not a player option.
    [switch]$PrepareOnly,
    [ValidateRange(60,1800)][int]$TimeoutSeconds = 900
)
$ErrorActionPreference = 'Stop'
# PowerShell 5.1 can first autoload Utility inside Invoke-Lobby's function
# scope; its script functions (Get-FileHash) then disappear outside that scope.
Import-Module Microsoft.PowerShell.Utility -Scope Global -ErrorAction Stop
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Get-Tpf2mpCompanionCommand $bundle
$credentials = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
$session = Assert-Tpf2mpSessionId ([string]$credentials.sessionId)
$role = if ($credentials.role -eq 'host') { 'Host' } elseif ($credentials.role -eq 'join') { 'Join' } else { throw 'Invalid role.' }
$credentials = $null
$localRoot = Split-Path -Parent (Split-Path -Parent (Resolve-Tpf2mpFullPath $ModDirectory))
$saveDirectory = Join-Path $localRoot 'save'
$peer = if ($role -eq 'Host') { 'player1' } else { 'player2' }
$sessionRoot = Get-Tpf2mpSessionRoot $session $peer
[void](New-Item -ItemType Directory -Force -Path $sessionRoot)
# An OS lock prevents two launcher windows from generating/launching one role.
$lock = [IO.File]::Open((Join-Path $sessionRoot 'lobby-start.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
$previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
$failureCode = 'generation-failed'
$launchReceipt = Join-Path $sessionRoot 'lobby-launched.json'
function Invoke-Lobby([string]$Operation, [string[]]$Extra = @()) {
    $arguments = @($companion.Prefix) + @('relay-lobby', $Operation, '--credentials', $CredentialsPath,
        '--game-executable', $GameExecutable, '--mod-directory', $ModDirectory) + $Extra
    $result = & $companion.FilePath @arguments
    if ($LASTEXITCODE -ne 0) { throw "Lobby $Operation failed." }
    return ($result -join "`n" | ConvertFrom-Json)
}
try {
    if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
    if (Test-Path -LiteralPath $launchReceipt) {
        $completed = Get-Content -LiteralPath $launchReceipt -Raw | ConvertFrom-Json
        if ($completed.configDigest -ceq $ConfigDigest -and $completed.session -ceq $session) {
            Write-Host "This role already launched $session. Return to its game, or create a new room after stopping it."
            Write-Host "lobby_match_existing=$session/$peer"
            return
        }
        throw 'This role has a launch receipt for another configuration.'
    }
    $state = Invoke-Lobby 'status'
    if ($state.configDigest -cne $ConfigDigest -or $state.phase -notin @('generating','preparing-save','save-ready')) {
        throw 'Start requires the locked, reviewed lobby configuration.'
    }
    if ($role -eq 'Host' -and $state.phase -eq 'save-ready' -and -not $StartingSave) {
        $prepared = Get-Content -LiteralPath (Join-Path $sessionRoot 'lobby-prepared-world.json') -Raw | ConvertFrom-Json
        if ($prepared.configDigest -cne $ConfigDigest -or $prepared.session -cne $session) {
            throw 'The prepared host world belongs to another lobby configuration.'
        }
        $StartingSave = [string]$prepared.savePath
        [void](Invoke-Lobby 'verify-launch' @('--config-digest',$ConfigDigest,'--save',$StartingSave))
    }
    $evidence = $null
    if ($role -eq 'Host' -and $state.phase -eq 'generating') {
        if (-not $NativeBuildDirectory) {
            $NativeBuildDirectory = Join-Path $bundle 'bin\native'
            if (-not (Test-Path -LiteralPath (Join-Path $NativeBuildDirectory 'tpf2mp_worldgen_lab.dll'))) {
                $NativeBuildDirectory = Join-Path $bundle 'runtime\native-worldgen-build\Release'
            }
        }
        $job = Join-Path $sessionRoot ('world-generation-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $job)
        $requestPath = Join-Path $job 'native-request.txt'
        [void](Invoke-Lobby 'generation-request' @('--config-digest',$ConfigDigest,'--native-request',$requestPath))
        $evidence = Join-Path $job 'native'
        Write-Host 'Generating the agreed native world. No manual menu or save steps are needed.'
        & (Join-Path $PSScriptRoot 'run_native_worldgen_lab.ps1') -GameExecutable $GameExecutable `
            -LocalDirectory $localRoot -NativeBuildDirectory $NativeBuildDirectory -OutputDirectory $evidence `
            -RequestPath $requestPath -SaveGeneratedWorld -TimeoutSeconds 600
        $generated = Get-Content -LiteralPath (Join-Path $evidence 'report.json') -Raw | ConvertFrom-Json
        if ($generated.complete -ne $true -or -not $generated.savePath) { throw 'Native generation did not produce a verified save.' }
        $StartingSave = [string]$generated.savePath
        $failureCode = 'save-verification-failed'
        [void](Invoke-Lobby 'generation-verify' @('--config-digest',$ConfigDigest,'--save',$StartingSave,'--evidence',$evidence))
    }
    if ($role -eq 'Host' -and $state.phase -ne 'save-ready') {
        if (-not $StartingSave) { throw 'The host must select the agreed existing save.' }
        $state = Invoke-Lobby 'status'
        $arguments = @('--revision',[string]$state.revision,'--config-digest',$ConfigDigest,'--save',$StartingSave)
        if ($evidence) { $arguments += @('--evidence',$evidence) }
        $state = Invoke-Lobby 'save-ready' $arguments
    }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($state.phase -ne 'save-ready') {
        if ($state.phase -eq 'failed' -or $state.configDigest -cne $ConfigDigest) { throw 'Host generation failed or lobby changed.' }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Timed out waiting for the host world.' }
        Start-Sleep -Seconds 3
        $state = Invoke-Lobby 'presence'
    }
    if ($role -eq 'Host') {
        @{schemaVersion=1; session=$session; configDigest=$ConfigDigest; savePath=$StartingSave; evidence=$evidence} |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $sessionRoot 'lobby-prepared-world.json') -Encoding UTF8
    }
    if ($PrepareOnly) { Write-Host "lobby_world_prepared=$session"; return }
    $failureCode = 'launch-failed'
    $launch = @{ Role=$role; Session=$session; RelayCredentials=$CredentialsPath; BundleRoot=$bundle
        GameExecutable=$GameExecutable; LocalModsPath=(Split-Path -Parent $ModDirectory); SaveDirectory=$saveDirectory
        AutomaticWorldLoad=$true; LobbyConfigDigest=$ConfigDigest; AllowInsecureLoopback=$AllowInsecureLoopback }
    if ($role -eq 'Host') { $launch.StartingSave = $StartingSave }
    if ($state.config.world) {
        $launch.AgentMode = [string]$state.config.world.agentMode
        $launch.TownDevelopment = [bool]$state.config.world.townDevelopment
    }
    Write-Host 'World verified. Transferring the host save and loading directly into multiplayer.'
    & (Join-Path $PSScriptRoot 'start_relay_network_session.ps1') @launch
    $launched = Read-Tpf2mpSessionState $session $peer
    if (-not $launched.gamePid) { throw 'Launch completed without a game process receipt.' }
    @{schemaVersion=1; session=$session; peer=$peer; configDigest=$ConfigDigest; gamePid=$launched.gamePid} |
        ConvertTo-Json | Set-Content -LiteralPath $launchReceipt -Encoding UTF8
    Write-Host "lobby_match_launched=$session/$peer"
} catch {
    $failure = $_
    if ($role -eq 'Host') {
        try {
            $failedState = Invoke-Lobby 'status'
            if ($failedState.configDigest -ceq $ConfigDigest -and $failedState.phase -ne 'failed') {
                [void](Invoke-Lobby 'failed' @('--revision',[string]$failedState.revision,
                    '--config-digest',$ConfigDigest,'--failure-code',$failureCode))
            }
        } catch { Write-Warning 'Could not publish the lobby failure; local diagnostics are retained.' }
    }
    throw $failure
} finally {
    $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback
    $lock.Dispose()
}
