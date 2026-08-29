Set-StrictMode -Version Latest

function Close-Tpf2mpFailedHostRelayRoom {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Host', 'Join')][string]$Role,
        [Parameter(Mandatory = $true)]$Companion,
        [Parameter(Mandatory = $true)][string]$CredentialsPath,
        [switch]$AllowInsecureLoopback
    )
    if ($Role -ne 'Host') { return $false }
    $previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
    try {
        if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
        $arguments = @($Companion.Prefix) + @(
            'relay-session-close', '--credentials', $CredentialsPath
        )
        & $Companion.FilePath @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Relay room cleanup exited with code $LASTEXITCODE."
            return $false
        }
        Write-Host 'Failed host launch closed its short-lived relay room.'
        return $true
    }
    catch {
        Write-Warning (
            'Failed host launch could not close its relay room immediately; ' `
            + "the server expiry remains the fallback: $($_.Exception.Message)"
        )
        return $false
    }
    finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
}
