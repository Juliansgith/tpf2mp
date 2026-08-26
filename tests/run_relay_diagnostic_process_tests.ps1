[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot)

$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($ProjectRoot)
. (Join-Path $root 'tools\network_common.ps1')
. (Join-Path $root 'tools\relay_diagnostic_process.ps1')

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-relay-diagnostic-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temporary | Out-Null
$handle = $null
$duplicateHandle = $null
$unrelatedHandle = $null
try {
    $sessionRoot = Join-Path $temporary 'session'
    $bridge = Join-Path $temporary 'bridge'
    New-Item -ItemType Directory -Force -Path $sessionRoot, $bridge | Out-Null
    $relayStatus = Join-Path $sessionRoot 'relay-tunnel-status.json'
    $startup = New-Tpf2mpRelayDiagnosticSources -SessionRoot $sessionRoot `
        -BridgePath $bridge -RelayStatusPath $relayStatus -Startup
    if (-not $startup.Contains('launcher.session') -or -not $startup.Contains('launcher.menu') `
            -or $startup.Contains('native.status') -or $startup.Contains('game.stdout')) {
        throw 'Startup relay diagnostics did not retain the intended bounded source set.'
    }

    $credentials = Join-Path $temporary 'credentials.json'
    [IO.File]::WriteAllText($credentials, '{}', [Text.UTF8Encoding]::new($false))
    $fakeReporter = Join-Path $temporary 'fake-relay-diagnostics.ps1'
    [IO.File]::WriteAllText($fakeReporter, @'
$statusIndex = [Array]::IndexOf($args, '--status')
if ($args.Count -lt 1 -or $args[0] -ne 'relay-diagnostics' -or $statusIndex -lt 0) { exit 3 }
$statusPath = $args[$statusIndex + 1]
$value = [ordered]@{
    schemaVersion = 1
    pid = $PID
    sessionId = 'mp-0123456789abcdef'
    role = 'join'
    state = 'running'
}
[IO.File]::WriteAllText($statusPath, ($value | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
while ($true) { Start-Sleep -Seconds 1 }
'@, [Text.UTF8Encoding]::new($false))
    $companion = [pscustomobject]@{
        FilePath = Join-Path $PSHOME 'powershell.exe'
        Prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeReporter)
    }
    $source = Join-Path $temporary 'source.json'
    [IO.File]::WriteAllText($source, '{}', [Text.UTF8Encoding]::new($false))
    $status = Join-Path $temporary 'reporter-status.json'
    $handle = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $credentials -Sources ([ordered]@{ test = $source }) `
        -StatusPath $status -StdoutPath (Join-Path $temporary 'reporter.stdout.log') `
        -StderrPath (Join-Path $temporary 'reporter.stderr.log') `
        -ExpectedSessionId 'mp-0123456789abcdef' -ExpectedRole join
    if (-not $handle.ServicePid -or -not (Get-Process -Id $handle.ServicePid -ErrorAction SilentlyContinue)) {
        throw 'Relay diagnostic helper did not return its verified service process.'
    }
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $handle -Companion $companion `
        -CredentialsPath $credentials
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $handle.ServicePid -ErrorAction SilentlyContinue) {
        throw 'Relay diagnostic helper did not stop its verified service process.'
    }
    $handle = $null

    $firstStatus = Join-Path $temporary 'duplicate-first-status.json'
    $secondStatus = Join-Path $temporary 'duplicate-second-status.json'
    $otherCredentials = Join-Path $temporary 'other-credentials.json'
    [IO.File]::WriteAllText($otherCredentials, '{}', [Text.UTF8Encoding]::new($false))
    $handle = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $credentials -Sources ([ordered]@{ test = $source }) `
        -StatusPath $firstStatus -StdoutPath (Join-Path $temporary 'duplicate-first.stdout.log') `
        -StderrPath (Join-Path $temporary 'duplicate-first.stderr.log') `
        -ExpectedSessionId 'mp-0123456789abcdef' -ExpectedRole join
    $duplicateHandle = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $credentials -Sources ([ordered]@{ test = $source }) `
        -StatusPath $secondStatus -StdoutPath (Join-Path $temporary 'duplicate-second.stdout.log') `
        -StderrPath (Join-Path $temporary 'duplicate-second.stderr.log') `
        -ExpectedSessionId 'mp-0123456789abcdef' -ExpectedRole join
    $unrelatedHandle = Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
        -CredentialsPath $otherCredentials -Sources ([ordered]@{ test = $source }) `
        -StatusPath (Join-Path $temporary 'unrelated-status.json') `
        -StdoutPath (Join-Path $temporary 'unrelated.stdout.log') `
        -StderrPath (Join-Path $temporary 'unrelated.stderr.log') `
        -ExpectedSessionId 'mp-0123456789abcdef' -ExpectedRole join
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $handle -Companion $companion `
        -CredentialsPath $credentials
    Start-Sleep -Milliseconds 300
    foreach ($servicePid in @($handle.ServicePid, $duplicateHandle.ServicePid)) {
        if (Get-Process -Id $servicePid -ErrorAction SilentlyContinue) {
            throw 'Credential-scoped shutdown left a duplicate relay diagnostic process running.'
        }
    }
    if (-not (Get-Process -Id $unrelatedHandle.ServicePid -ErrorAction SilentlyContinue)) {
        throw 'Credential-scoped shutdown touched a different relay credential.'
    }
    Stop-Tpf2mpRelayDiagnosticProcess -Handle $unrelatedHandle -Companion $companion `
        -CredentialsPath $otherCredentials
    $handle = $null
    $duplicateHandle = $null
    $unrelatedHandle = $null

    $invalidStatus = Join-Path $temporary 'invalid-reporter-status.json'
    $rejected = $false
    try {
        [void](Start-Tpf2mpRelayDiagnosticProcess -Companion $companion `
            -CredentialsPath $credentials -Sources ([ordered]@{ test = $source }) `
            -StatusPath $invalidStatus -StdoutPath (Join-Path $temporary 'invalid.stdout.log') `
            -StderrPath (Join-Path $temporary 'invalid.stderr.log') `
            -ExpectedSessionId 'mp-fedcba9876543210' -ExpectedRole join `
            -StartupTimeoutSeconds 1)
    }
    catch { $rejected = $true }
    if (-not $rejected -or -not (Test-Path -LiteralPath $invalidStatus -PathType Leaf)) {
        throw 'Invalid relay diagnostic status was not rejected after publication.'
    }
    $invalidPid = [int](Get-Content -LiteralPath $invalidStatus -Raw | ConvertFrom-Json).pid
    Start-Sleep -Milliseconds 300
    if (Get-Process -Id $invalidPid -ErrorAction SilentlyContinue) {
        throw 'Rejected relay diagnostic startup left its service process running.'
    }
    Write-Host 'PASS relay diagnostics start before launch and hand off without an orphan process'
}
finally {
    if ($handle) {
        Stop-Tpf2mpRelayDiagnosticProcess -Handle $handle -Companion $companion `
            -CredentialsPath $credentials
    }
    if ($duplicateHandle) {
        Stop-Tpf2mpRelayDiagnosticProcess -Handle $duplicateHandle -Companion $companion `
            -CredentialsPath $credentials
    }
    if ($unrelatedHandle) {
        Stop-Tpf2mpRelayDiagnosticProcess -Handle $unrelatedHandle -Companion $companion `
            -CredentialsPath $otherCredentials
    }
    if (Test-Path -LiteralPath $temporary) {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}
