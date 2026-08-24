[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LeasePath,
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [Parameter(Mandatory = $true)][string]$StatusPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_autosave_guard.ps1')

function Write-GuardStatus([string]$Status, [string]$ErrorText) {
    $value = [pscustomobject][ordered]@{
        schemaVersion = 1
        status = $Status
        gameProcessId = $GameProcessId
        leasePath = [IO.Path]::GetFullPath($LeasePath)
        error = $ErrorText
        updatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($StatusPath))
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $value | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StatusPath -Encoding UTF8
}

try {
    $expectedExecutable = [IO.Path]::GetFullPath($GameExecutable)
    $expectedStart = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
    $game = Get-Process -Id $GameProcessId -ErrorAction SilentlyContinue
    if ($game) {
        $observedExecutable = [IO.Path]::GetFullPath([string]$game.Path)
        $observedStart = $game.StartTime.ToUniversalTime()
        if (-not [string]::Equals($expectedExecutable, $observedExecutable,
                [StringComparison]::OrdinalIgnoreCase) `
                -or [math]::Abs(($observedStart - $expectedStart).TotalSeconds) -gt 2) {
            throw 'Autosave guard watcher refused a reused or mismatched game process.'
        }
        Write-GuardStatus 'active' ''
        $game.WaitForExit()
        Start-Sleep -Milliseconds 500
    }
    $restored = Restore-Tpf2mpNetworkAutosaveGuard -LeasePath $LeasePath `
        -Reason 'game-process-ended'
    Write-GuardStatus ([string]$restored.status) ''
}
catch {
    $message = $_.Exception.Message
    try {
        [void](Restore-Tpf2mpNetworkAutosaveGuard -LeasePath $LeasePath `
            -Reason 'watcher-error-fallback')
    }
    catch { $message += "; restore also failed: $($_.Exception.Message)" }
    Write-GuardStatus 'error' $message
    throw
}

