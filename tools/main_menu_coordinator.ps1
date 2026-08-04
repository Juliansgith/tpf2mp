[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [ValidateRange(1, 24)][int]$LifetimeHours = 6
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$expectedGame = Resolve-Tpf2mpFullPath $GameExecutable
$expectedStart = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
$deadline = (Get-Date).AddHours($LifetimeHours)
New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null

while ((Get-Date) -lt $deadline) {
    $game = Get-Process -Id $GameProcessId -ErrorAction SilentlyContinue
    if (-not $game -or $game.HasExited) { exit 0 }
    $pathMatches = $game.Path -and [string]::Equals(
        (Resolve-Tpf2mpFullPath $game.Path), $expectedGame, [StringComparison]::OrdinalIgnoreCase
    )
    $startMatches = [Math]::Abs(($game.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds) -lt 2
    if (-not $pathMatches -or -not $startMatches) {
        throw 'Recorded game PID was reused; main-menu coordinator stopped without sending input.'
    }
    $status = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $safeSession -Peer $Peer
    if ($status -and $status.error) { throw "Menu bootstrap failed: $($status.error)" }
    if ($status -and $status.stage -eq 'ready-to-click-load-game') {
        Invoke-Tpf2mpUiRectangleClick -GameProcess $game `
            -Rectangle $status.components.loadGameRect -MenuRectangle $status.components.menuRect `
            -ReceiptPath (Join-Path $EvidenceDirectory 'click-multiplayer-load-game.json')
        [ordered]@{
            schemaVersion = 1
            session = $safeSession
            peer = $Peer
            gameProcessId = $GameProcessId
            result = 'native-load-page-opened'
            completedAtUtc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'main-menu-coordinator.json') -Encoding UTF8
        exit 0
    }
    Start-Sleep -Milliseconds 250
}
throw "Main-menu coordinator expired after $LifetimeHours hour(s) without a MULTIPLAYER selection."
