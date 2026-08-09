[CmdletBinding()]
param(
    [string]$Session = 'local-dev',
    [string]$Peer = 'player1',
    [string]$BindAddress = '127.0.0.1',
    [int]$Port = 29742,
    [ValidateRange(5, 600)][int]$CompletionTimeoutSeconds = 45,
    [string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$ManifestPath,
    [string]$BundleRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$companion = Join-Path $bundle 'bin\tpf2mp.exe'
if (-not (Test-Path -LiteralPath $companion -PathType Leaf)) { throw "Companion executable is missing: $companion" }
if (-not $BridgePath) { $BridgePath = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$Peer" }
$bridge = Resolve-Tpf2mpFullPath $BridgePath
foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit',
        'content\industry')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bridge $folder) | Out-Null
}
$arguments = @(
    'host', '--session', $Session, '--peer', $Peer, '--bind', $BindAddress,
    '--port', $Port, '--bridge', $bridge,
    '--required-peer', 'player1', '--required-peer', 'player2',
    '--completion-timeout', $CompletionTimeoutSeconds
)
$arguments += @('--manifest', (Resolve-Tpf2mpFullPath $ManifestPath))
Write-Host "Starting authoritative TPF2MP host for session '$Session' on ${BindAddress}:$Port"
if ($BindAddress -ne '127.0.0.1' -and $BindAddress -ne '::1' -and $BindAddress -ne 'localhost') {
    Write-Warning 'The prototype protocol is intended for trusted LAN/VPN peers; do not expose this port directly to the Internet.'
}
& $companion @arguments
exit $LASTEXITCODE
