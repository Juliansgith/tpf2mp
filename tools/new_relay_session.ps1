[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RelayUrl,
    [string]$DisplayName = 'TPF2MP match',
    [string]$BundleRoot,
    [switch]$AllowInsecureLoopback
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Get-Tpf2mpCompanionCommand $bundle
$draftRoot = Resolve-Tpf2mpFullPath (Join-Path (Get-Tpf2mpSupportRoot) (
    'relay-drafts\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
))
New-Item -ItemType Directory -Force -Path $draftRoot | Out-Null
$credentials = Join-Path $draftRoot 'host-credentials.json'
$inviteReceipt = Join-Path $draftRoot 'invite-receipt.json'
$arguments = @($companion.Prefix) + @(
    'relay-session-create', '--relay-url', $RelayUrl,
    '--display-name', $DisplayName,
    '--credentials', $credentials,
    '--invite-receipt', $inviteReceipt
)
if ($AllowInsecureLoopback) { $arguments += '--allow-insecure-loopback' }
$previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
try {
    if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
    # The companion prints the same machine-readable receipt fields that this
    # wrapper emits after independently validating and protecting the files.
    # Suppress the unvalidated copy so launcher logs contain one receipt only.
    & $companion.FilePath @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Relay session creation failed with exit code $LASTEXITCODE" }
}
finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
[void](Protect-Tpf2mpPrivateFile $credentials)
[void](Protect-Tpf2mpPrivateFile $inviteReceipt)
$receipt = Get-Content -LiteralPath $inviteReceipt -Raw | ConvertFrom-Json
if ([int]$receipt.schemaVersion -ne 1 `
        -or [string]$receipt.sessionId -notmatch '^mp-[0-9a-f]{16}$' `
        -or [string]$receipt.supportId -cne [string]$receipt.sessionId `
        -or [string]$receipt.joinCode -notmatch '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$' `
        -or -not [string]::Equals(
            (Resolve-Tpf2mpFullPath ([string]$receipt.credentialsPath)),
            (Resolve-Tpf2mpFullPath $credentials),
            [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Relay creation returned an invalid protected receipt.'
}
Write-Host "relay_session_created=$($receipt.sessionId)"
Write-Host "relay_credentials=$credentials"
Write-Host "relay_invite_receipt=$inviteReceipt"
