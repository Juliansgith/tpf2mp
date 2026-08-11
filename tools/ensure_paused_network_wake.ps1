[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [string]$Session,
    [ValidateSet('', 'player1', 'player2')][string]$Peer = '',
    [ValidateRange(1, 30)][int]$NativeWaitSeconds = 8,
    [switch]$RequireRestoreValidated,
    [switch]$RequirePersistentMenuPump
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
$expectedExecutable = Resolve-Tpf2mpFullPath $GameExecutable
$expectedStarted = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
$game = Get-Process -Id $GameProcessId -ErrorAction Stop
$actualExecutable = Resolve-Tpf2mpFullPath $game.Path
if (-not [string]::Equals($actualExecutable, $expectedExecutable,
        [StringComparison]::OrdinalIgnoreCase) `
        -or [Math]::Abs(($game.StartTime.ToUniversalTime() - $expectedStarted).TotalSeconds) -gt 1) {
    throw 'Paused-network wake refused a reused or foreign game PID.'
}
$bridge = Resolve-Tpf2mpFullPath $BridgePath
$evidence = [IO.Path]::GetFullPath($EvidenceDirectory)
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$outbox = Join-Path $bridge 'game_outbox'
$pump = Request-Tpf2mpPersistentPausedPump -GameProcess $game -BridgePath $bridge `
    -WaitSeconds $NativeWaitSeconds
$pumpGeneration = $pump.generation
$persistentReceipt = $pump.receipt
$nativeReceipt = $pump.path
$observed = Find-Tpf2mpPausedWakeEvidence -OutboxPath $outbox `
    -Session $Session -Peer $Peer
if ($persistentReceipt) {
    $method = 'native-menu-bootstrap'
    $observed = $nativeReceipt
}
elseif ($RequirePersistentMenuPump) {
    $menuDiagnostic = $null
    $menuStatusPath = Join-Path $bridge 'launcher\menu_status.json'
    if (Test-Path -LiteralPath $menuStatusPath -PathType Leaf) {
        try { $menuDiagnostic = ([IO.File]::ReadAllText($menuStatusPath) | ConvertFrom-Json).launcherPump }
        catch { }
    }
    $diagnosticJson = if ($menuDiagnostic) {
        $menuDiagnostic | ConvertTo-Json -Depth 5 -Compress
    }
    else { 'unavailable' }
    throw "Persistent paused-network menu pump did not acknowledge generation '$pumpGeneration'; launcher diagnostic: $diagnosticJson"
}
elseif ($observed) {
    # Fresh signed game-script progress is stronger than the optional marker.
    $method = 'existing-game-script-progress'
}
else {
    $method = 'exact-process-console-fallback'
    $before = @(Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' `
        -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $command = "tpf2mp_native_authorize_command('0');api.cmd.sendCommand(api.cmd.make.setGameSpeed(1));tpf2mp_native_revoke_command('0');api.cmd.sendCommand(api.cmd.make.sendScriptEvent('tpf2_mp.lua','tpf2mp','snapshot.request',{launcherReady=true}))"
    $inputReceipt = Join-Path $evidence 'console-wake.json'
    & (Join-Path $PSScriptRoot 'send_game_console.ps1') -GameProcessId $GameProcessId `
        -Action custom -Command $command -DelayMilliseconds 350 -SkipConsoleClick `
        -ResultPath $inputReceipt
    if (-not $?) { throw 'Exact-process paused-network console wake failed.' }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $observed = Find-Tpf2mpPausedWakeEvidence -OutboxPath $outbox `
            -Session $Session -Peer $Peer -ExcludeNames $before
        if (-not $observed) { Start-Sleep -Milliseconds 100 }
    } while (-not $observed -and (Get-Date) -lt $deadline)
    if (-not $observed) { throw 'Paused-network console wake produced no game-script evidence.' }
}
$restoreDiagnostic = $null
if ($RequireRestoreValidated) {
    $restoreDeadline = (Get-Date).AddSeconds(20)
    do {
        foreach ($file in Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' `
                -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
            try {
                $message = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if ($message.payload.event -eq 'launcher-bootstrap-state') {
                    $restoreDiagnostic = $message.payload
                    break
                }
            }
            catch { }
        }
        if (-not $restoreDiagnostic) { Start-Sleep -Milliseconds 100 }
    } while (-not $restoreDiagnostic -and (Get-Date) -lt $restoreDeadline)
    if (-not $restoreDiagnostic) {
        throw 'Paused-network wake produced no restore bootstrap diagnostic.'
    }
    $restoreStatus = [string]$restoreDiagnostic.restoreStatus
    if ($restoreDiagnostic.restoreRequested -ne $true `
            -or $restoreDiagnostic.restoreConfigValid -ne $true `
            -or $restoreStatus -notin @('validated', 'committed')) {
        $errorProperty = $restoreDiagnostic.PSObject.Properties['restoreError']
        $detail = if ($errorProperty) { [string]$errorProperty.Value } else { '' }
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = 'loaded save is not the attested restore source' }
        throw "Restore bootstrap validation failed: $detail"
    }
}
$receipt = [ordered]@{
    schemaVersion = 1
    processId = $GameProcessId
    method = $method
    observedEvidence = $observed
    pumpGeneration = $pumpGeneration
    persistentPumpCount = if ($persistentReceipt) { $persistentReceipt.count } else { $null }
    restoreStatus = if ($restoreDiagnostic) { [string]$restoreDiagnostic.restoreStatus } else { $null }
    restoreBoundarySeq = if ($restoreDiagnostic -and $restoreDiagnostic.PSObject.Properties['restoreBoundarySeq']) {
        $restoreDiagnostic.restoreBoundarySeq
    } else { $null }
    completedAtUtc = [DateTime]::UtcNow.ToString('o')
}
$receiptPath = Join-Path $evidence 'paused-network-wake.json'
$receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
Write-Host "Paused network wake ready via ${method}: $receiptPath"
