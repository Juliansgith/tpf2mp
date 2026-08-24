[CmdletBinding()]
param(
    [string]$ProjectRoot,
    [string]$RelayProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
if (-not $RelayProjectRoot) {
    $RelayProjectRoot = Join-Path (Split-Path -Parent $ProjectRoot) 'tf2mp-relay'
}
. (Join-Path $ProjectRoot 'tools\network_common.ps1')
$main = Resolve-Tpf2mpFullPath $ProjectRoot
$relay = Resolve-Tpf2mpFullPath $RelayProjectRoot
$python = (Get-Command python.exe -ErrorAction Stop).Source
$testRoot = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) (
    'tpf2mp-relay-e2e-' + [guid]::NewGuid().ToString('N')
))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$processes = @()

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Start-TestProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$WorkingDirectory = $main
    )
    $process = Start-Process -FilePath $python `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $Arguments) `
        -WorkingDirectory $WorkingDirectory -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $testRoot "$Name.stdout.log") `
        -RedirectStandardError (Join-Path $testRoot "$Name.stderr.log")
    $script:processes += $process
    return $process
}

try {
    $relayPort = Get-FreeLoopbackPort
    $hostGameplay = Get-FreeLoopbackPort
    $hostSave = Get-FreeLoopbackPort
    $joinGameplay = Get-FreeLoopbackPort
    $joinSave = Get-FreeLoopbackPort
    $relayUrl = "http://127.0.0.1:$relayPort"

    $env:PYTHONPATH = Join-Path $relay 'src'
    $env:TPF2MP_RELAY_ALLOW_INSECURE_DEVELOPMENT = 'true'
    $env:TPF2MP_RELAY_PUBLIC_URL = $relayUrl
    $env:TPF2MP_RELAY_BIND_PORT = [string]$relayPort
    $env:TPF2MP_RELAY_DATABASE = Join-Path $testRoot 'relay.sqlite3'
    $env:TPF2MP_RELAY_ADMIN_TOKEN = 'admin-token-with-at-least-thirty-two-characters'
    $env:TPF2MP_RELAY_TOKEN_PEPPER = 'pepper-with-at-least-thirty-two-characters'
    [void](Start-TestProcess @('-m', 'tpf2mp_relay', 'serve') 'server' $relay)

    $deadline = (Get-Date).AddSeconds(10)
    $health = $null
    do {
        try { $health = Invoke-RestMethod -Uri "$relayUrl/healthz" -TimeoutSec 1 }
        catch { Start-Sleep -Milliseconds 100 }
    } while (-not $health -and (Get-Date) -lt $deadline)
    if (-not $health -or $health.status -ne 'ok') { throw 'Relay did not become healthy.' }

    $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1'
    $entry = Join-Path $main 'companion\entrypoint.py'
    $hostCredential = Join-Path $testRoot 'host.json'
    $inviteReceipt = Join-Path $testRoot 'invite.json'
    & $python $entry relay-session-create --relay-url $relayUrl `
        --credentials $hostCredential --invite-receipt $inviteReceipt `
        --allow-insecure-loopback | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Relay session creation failed.' }
    $invite = Get-Content -LiteralPath $inviteReceipt -Raw | ConvertFrom-Json
    $invitePath = Join-Path $testRoot 'join.txt'
    [IO.File]::WriteAllText(
        $invitePath, [string]$invite.joinCode, [Text.UTF8Encoding]::new($false)
    )
    $joinCredential = Join-Path $testRoot 'join.json'
    & $python $entry relay-invite-accept --relay-url $relayUrl `
        --invite-file $invitePath --credentials $joinCredential `
        --allow-insecure-loopback | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Relay invite acceptance failed.' }

    [void](Start-TestProcess @(
        (Join-Path $main 'tests\relay_loopback_echo.py'),
        [string]$hostGameplay, [string]$hostSave
    ) 'echo')
    Start-Sleep -Milliseconds 300
    [void](Start-TestProcess @(
        $entry, 'relay-tunnel', '--credentials', $hostCredential,
        '--gameplay-port', [string]$hostGameplay,
        '--save-port', [string]$hostSave,
        '--status', (Join-Path $testRoot 'host-status.json')
    ) 'host-tunnel')
    [void](Start-TestProcess @(
        $entry, 'relay-tunnel', '--credentials', $joinCredential,
        '--gameplay-port', [string]$joinGameplay,
        '--save-port', [string]$joinSave,
        '--status', (Join-Path $testRoot 'join-status.json')
    ) 'join-tunnel')
    Start-Sleep -Milliseconds 700
    $probe = & $python (Join-Path $main 'tests\relay_loopback_client.py') `
        --gameplay-port $joinGameplay --save-port $joinSave
    if ($LASTEXITCODE -ne 0) { throw "Relay round trip failed: $probe" }
    $probeText = @($probe) -join "`n"

    $secret = 'secretBearerValue012345678901234567890'
    $diagnosticLog = Join-Path $testRoot 'client.log'
    $line = 'Bearer ' + $secret + ' ' + [string]$invite.joinCode `
        + ' C:\Users\PrivateName\save.sav 100.69.37.25 [fd7a:115c:a1e0::1]'
    [IO.File]::WriteAllText(
        $diagnosticLog, $line + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    [void](Start-TestProcess @(
        $entry, 'relay-diagnostics', '--credentials', $hostCredential,
        '--source', "test=$diagnosticLog",
        '--status', (Join-Path $testRoot 'diagnostics-status.json'),
        '--interval', '0.5'
    ) 'diagnostics')
    Start-Sleep -Seconds 2

    $headers = @{ Authorization = 'Bearer admin-token-with-at-least-thirty-two-characters' }
    $events = Invoke-RestMethod `
        -Uri "$relayUrl/v1/admin/sessions/$($invite.sessionId)/events?limit=1000" `
        -Headers $headers -TimeoutSec 5
    $rendered = $events | ConvertTo-Json -Depth 20 -Compress
    foreach ($forbidden in @(
        $secret, [string]$invite.joinCode, 'PrivateName', '100.69.37.25',
        'fd7a:115c:a1e0::1'
    )) {
        if ($rendered.Contains($forbidden)) {
            throw "Server received forbidden diagnostic value: $forbidden"
        }
    }
    if (@($events.events | Where-Object event_type -eq 'client.log').Count -lt 1) {
        throw 'Server did not receive the redacted client log event.'
    }
    if ($probeText -notmatch 'gameplay_echo=true' -or $probeText -notmatch 'save_echo=true') {
        throw 'Relay did not preserve both byte streams.'
    }
    Write-Host "PASS relay gameplay/save round trip and pre-transmission redaction ($($invite.sessionId))"
}
finally {
    foreach ($process in @($processes | Sort-Object Id -Descending)) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        }
        catch { }
    }
    if ($testRoot.StartsWith(
            (Resolve-Tpf2mpFullPath ([IO.Path]::GetTempPath())).TrimEnd('\') + '\tpf2mp-relay-e2e-',
            [StringComparison]::OrdinalIgnoreCase) `
            -and (Test-Path -LiteralPath $testRoot -PathType Container)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
