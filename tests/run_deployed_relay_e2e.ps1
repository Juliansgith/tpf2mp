[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://')]
    [string]$RelayUrl,
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
. (Join-Path $ProjectRoot 'tools\network_common.ps1')
$main = Resolve-Tpf2mpFullPath $ProjectRoot
$python = (Get-Command python.exe -ErrorAction Stop).Source
$entry = Join-Path $main 'companion\entrypoint.py'
$testRoot = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) (
    'tpf2mp-deployed-relay-e2e-' + [guid]::NewGuid().ToString('N')
))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$processes = @()
$hostCredential = Join-Path $testRoot 'host.json'
$sessionClosed = $false

function Get-FreeLoopbackPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    try { return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

function Start-TestProcess {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $process = Start-Process -FilePath $python `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $Arguments) `
        -WorkingDirectory $main -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path $testRoot "$Name.stdout.log") `
        -RedirectStandardError (Join-Path $testRoot "$Name.stderr.log")
    $script:processes += $process
    return $process
}

try {
    $hostGameplay = Get-FreeLoopbackPort
    $hostSave = Get-FreeLoopbackPort
    $joinGameplay = Get-FreeLoopbackPort
    $joinSave = Get-FreeLoopbackPort
    $inviteReceipt = Join-Path $testRoot 'invite.json'
    & $python $entry relay-session-create --relay-url $RelayUrl `
        --display-name 'deployed-e2e' --credentials $hostCredential `
        --invite-receipt $inviteReceipt | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Deployed relay session creation failed.' }
    $invite = Get-Content -LiteralPath $inviteReceipt -Raw | ConvertFrom-Json
    $invitePath = Join-Path $testRoot 'join.txt'
    [IO.File]::WriteAllText(
        $invitePath, [string]$invite.joinCode, [Text.UTF8Encoding]::new($false)
    )
    $joinCredential = Join-Path $testRoot 'join.json'
    & $python $entry relay-invite-accept --relay-url $RelayUrl `
        --invite-file $invitePath --credentials $joinCredential | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Deployed relay invite acceptance failed.' }

    [void](Start-TestProcess @(
        (Join-Path $main 'tests\relay_loopback_echo.py'),
        [string]$hostGameplay, [string]$hostSave
    ) 'echo')
    Start-Sleep -Milliseconds 300
    $hostStatus = Join-Path $testRoot 'host-status.json'
    [void](Start-TestProcess @(
        $entry, 'relay-tunnel', '--credentials', $hostCredential,
        '--gameplay-port', [string]$hostGameplay,
        '--save-port', [string]$hostSave, '--status', $hostStatus
    ) 'host-tunnel')
    [void](Start-TestProcess @(
        $entry, 'relay-tunnel', '--credentials', $joinCredential,
        '--gameplay-port', [string]$joinGameplay,
        '--save-port', [string]$joinSave,
        '--status', (Join-Path $testRoot 'join-status.json')
    ) 'join-tunnel')
    Start-Sleep -Seconds 2

    $probe = & $python (Join-Path $main 'tests\relay_loopback_client.py') `
        --gameplay-port $joinGameplay --save-port $joinSave
    if ($LASTEXITCODE -ne 0) { throw "Deployed relay round trip failed: $probe" }
    $probeText = @($probe) -join "`n"
    if ($probeText -notmatch 'gameplay_echo=true' `
            -or $probeText -notmatch 'save_echo=true') {
        throw 'Deployed relay did not preserve both byte streams.'
    }

    $diagnosticsStatus = Join-Path $testRoot 'diagnostics-status.json'
    [void](Start-TestProcess @(
        $entry, 'relay-diagnostics', '--credentials', $hostCredential,
        '--source', "tunnel=$hostStatus", '--status', $diagnosticsStatus,
        '--interval', '0.5'
    ) 'diagnostics')
    Start-Sleep -Seconds 2
    $diagnostics = Get-Content -LiteralPath $diagnosticsStatus -Raw | ConvertFrom-Json
    if ([int]$diagnostics.uploadedEvents -lt 1 `
            -or [int]$diagnostics.uploadFailures -ne 0) {
        throw 'Deployed relay did not accept the diagnostic status event.'
    }

    & $python $entry relay-session-close --credentials $hostCredential | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Deployed relay session closure failed.' }
    $sessionClosed = $true
    Write-Host (
        "PASS deployed relay gameplay/save/diagnostics sessionId={0}" -f `
            [string]$invite.sessionId
    )
}
finally {
    if (-not $sessionClosed -and (Test-Path -LiteralPath $hostCredential)) {
        try { & $python $entry relay-session-close --credentials $hostCredential | Out-Null }
        catch { }
    }
    foreach ($process in @($processes | Sort-Object Id -Descending)) {
        try {
            $process.Refresh()
            if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
        }
        catch { }
    }
    if ($testRoot.StartsWith(
            (Resolve-Tpf2mpFullPath ([IO.Path]::GetTempPath())).TrimEnd('\') `
                + '\tpf2mp-deployed-relay-e2e-',
            [StringComparison]::OrdinalIgnoreCase) `
            -and (Test-Path -LiteralPath $testRoot -PathType Container)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
