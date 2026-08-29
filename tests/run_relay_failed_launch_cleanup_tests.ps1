[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\relay_failed_launch_cleanup.ps1')
$caseRoot = Join-Path $TemporaryRoot 'failed-relay-room-cleanup'
New-Item -ItemType Directory -Force -Path $caseRoot | Out-Null
$receipt = Join-Path $caseRoot 'close-arguments.json'
$credentials = Join-Path $caseRoot 'host-credentials.json'
[IO.File]::WriteAllText($credentials, '{}', [Text.UTF8Encoding]::new($false))
$fake = Join-Path $caseRoot 'fake-companion.ps1'
[IO.File]::WriteAllText($fake, @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Remaining)
[IO.File]::WriteAllText($env:TPF2MP_RELAY_CLOSE_TEST_RECEIPT,
    ($Remaining | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
$companion = [pscustomobject]@{
    FilePath = (Join-Path $PSHOME 'powershell.exe')
    Prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fake)
}
$previousReceipt = $env:TPF2MP_RELAY_CLOSE_TEST_RECEIPT
try {
    $env:TPF2MP_RELAY_CLOSE_TEST_RECEIPT = $receipt
    if (Close-Tpf2mpFailedHostRelayRoom -Role Join -Companion $companion `
            -CredentialsPath $credentials) {
        throw 'Join launch incorrectly attempted to close the host relay room.'
    }
    if (Test-Path -LiteralPath $receipt) {
        throw 'Join launch invoked the relay close command.'
    }
    if (-not (Close-Tpf2mpFailedHostRelayRoom -Role Host -Companion $companion `
            -CredentialsPath $credentials)) {
        throw 'Failed host launch did not close its relay room.'
    }
    $arguments = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if ($arguments.Count -ne 3 -or $arguments[0] -cne 'relay-session-close' `
            -or $arguments[1] -cne '--credentials' `
            -or $arguments[2] -cne $credentials) {
        throw "Relay close command was not exact: $($arguments -join ' | ')"
    }
}
finally { $env:TPF2MP_RELAY_CLOSE_TEST_RECEIPT = $previousReceipt }

Write-Host 'PASS failed host launch closes its exact relay room; Join never does'
