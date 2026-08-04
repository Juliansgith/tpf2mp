[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$HostAddress,
    [string]$Session = 'local-dev',
    [string]$Peer = 'player2',
    [int]$Port = 29742,
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
foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bridge $folder) | Out-Null
}
$arguments = @('client', $HostAddress, '--session', $Session, '--peer', $Peer, '--port', $Port, '--bridge', $bridge)
$arguments += @('--manifest', (Resolve-Tpf2mpFullPath $ManifestPath))
Write-Host "Connecting TPF2MP client '$Peer' to ${HostAddress}:$Port for session '$Session'"
& $companion @arguments
exit $LASTEXITCODE
