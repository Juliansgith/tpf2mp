[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RelayUrl,
    [Parameter(Mandatory = $true)][string]$InviteFile,
    [string]$BundleRoot,
    [switch]$AllowInsecureLoopback
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Get-Tpf2mpCompanionCommand $bundle
$protectedInvite = Protect-Tpf2mpPrivateFile $InviteFile
$draftRoot = Resolve-Tpf2mpFullPath (Join-Path (Get-Tpf2mpSupportRoot) (
    'relay-drafts\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N')
))
New-Item -ItemType Directory -Force -Path $draftRoot | Out-Null
$credentials = Join-Path $draftRoot 'join-credentials.json'
$arguments = @($companion.Prefix) + @(
    'relay-invite-accept', '--relay-url', $RelayUrl,
    '--invite-file', $protectedInvite, '--credentials', $credentials
)
if ($AllowInsecureLoopback) { $arguments += '--allow-insecure-loopback' }
$previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
try {
    if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
    # Publish only the wrapper's validated receipt below; otherwise the
    # companion and wrapper duplicate every field in the launcher log.
    & $companion.FilePath @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Relay invitation validation failed with exit code $LASTEXITCODE" }
}
finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }
[void](Protect-Tpf2mpPrivateFile $credentials)
$value = Get-Content -LiteralPath $credentials -Raw | ConvertFrom-Json
if ([int]$value.schemaVersion -ne 1 -or [string]$value.role -cne 'join' `
        -or [string]$value.sessionId -notmatch '^mp-[0-9a-f]{16}$') {
    throw 'Relay invitation produced invalid protected credentials.'
}
Write-Host "relay_session_joined=$($value.sessionId)"
Write-Host "relay_credentials=$credentials"
