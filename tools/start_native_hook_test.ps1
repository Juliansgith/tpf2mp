[CmdletBinding()]
param(
    [string]$GameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2',
    [string]$SteamExecutable = 'C:\Program Files (x86)\Steam\steam.exe',
    [int]$SteamAppId = 1066780,
    [int]$ExistingPid = 0,
    [switch]$DirectExecutableLaunch,
    [switch]$NoBuild,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [int]$WaitMilliseconds = 45000,
    [int]$LaunchTimeoutSeconds = 120,
    [string[]]$GameArguments = @()
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$gameDirectoryPath = [IO.Path]::GetFullPath($GameDirectory)
$game = Join-Path $gameDirectoryPath 'TransportFever2.exe'
$bin = Join-Path $projectRoot "runtime\native-build\$Configuration"
$injector = Join-Path $bin 'tpf2mp_injector.exe'
$dll = Join-Path $bin 'tpf2mp_hook_build35924.dll'

if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot 'build_native_hook.ps1') -Configuration $Configuration -GameExecutable $game
}
foreach ($path in @($game, $injector, $dll)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required file is missing: $path" }
}

if ($ExistingPid -gt 0) {
    & $injector --pid $ExistingPid --dll $dll --wait-ms $WaitMilliseconds
} elseif ($DirectExecutableLaunch) {
    $arguments = @('--launch', $game, '--dll', $dll, '--workdir', $gameDirectoryPath, '--wait-ms', $WaitMilliseconds)
    if ($GameArguments.Count -gt 0) { $arguments += '--'; $arguments += $GameArguments }
    & $injector @arguments
} else {
    if (-not (Test-Path -LiteralPath $SteamExecutable -PathType Leaf)) {
        throw "Steam executable is missing: $SteamExecutable"
    }
    if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
        throw 'Transport Fever 2 is already running. Pass -ExistingPid explicitly to attach to it.'
    }
    & $injector --verify $game
    if ($LASTEXITCODE -ne 0) { throw "Pinned executable verification failed with exit code $LASTEXITCODE" }
    $steamArguments = @('-applaunch', [string]$SteamAppId) + $GameArguments
    Start-Process -FilePath $SteamExecutable -ArgumentList $steamArguments -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $gameProcess = $null
    while ((Get-Date) -lt $deadline) {
        $gameProcess = Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue |
            Sort-Object StartTime -Descending | Select-Object -First 1
        if ($gameProcess) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $gameProcess) { throw "Steam did not launch Transport Fever 2 within $LaunchTimeoutSeconds seconds" }
    Write-Host "Steam launched pinned game process $($gameProcess.Id); attaching native hook."
    & $injector --pid $gameProcess.Id --dll $dll --wait-ms $WaitMilliseconds
    if ($LASTEXITCODE -ne 0) {
        Stop-Process -Id $gameProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
if ($LASTEXITCODE -ne 0) { throw "Native hook launch/injection failed with exit code $LASTEXITCODE" }

Write-Host 'The hook is active. Start only a fresh disposable world; leave Toggle Build Gate (Test) OFF.'
Write-Host 'Next sample: initialise, make one short road player-owned, reconcile once, then Export Research before another build.'
Write-Host 'Inspect the current-process evidence with tools\get_native_hook_status.ps1.'
