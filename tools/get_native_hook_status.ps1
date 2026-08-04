[CmdletBinding()]
param(
    [int]$ProcessId = 0,
    [switch]$Raw
)

$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native'
$effectiveProcessId = $ProcessId
if ($effectiveProcessId -le 0) {
    $game = Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue |
        Sort-Object StartTime -Descending | Select-Object -First 1
    if ($game) { $effectiveProcessId = $game.Id }
}
$path = if ($effectiveProcessId -gt 0) { Join-Path $root "status-$effectiveProcessId.json" } else { Join-Path $root 'latest.json' }
if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "No native hook status exists at $path"
}
$content = Get-Content -LiteralPath $path -Raw
if ($Raw) { $content; return }
$status = $content | ConvertFrom-Json
$commandCalls = (@($status.luaStates) | Measure-Object -Property commandCalls -Sum).Sum
$wrappedStates = @($status.luaStates | Where-Object { $_.sendCommandWrapped -eq $true }).Count
Write-Host "Active=$($status.active) stage=$($status.stage) LuaStates=$(@($status.luaStates).Count) wrappedStates=$wrappedStates commandCalls=$commandCalls"
$status
Write-Host "Status file: $path"
