[CmdletBinding()]
param(
    [string]$BundleRoot,
    [string]$GameExecutable,
    [string]$SteamExecutable,
    [int]$ExistingPid = 0,
    [int]$WaitMilliseconds = 45000,
    [int]$LaunchTimeoutSeconds = 120,
    [string[]]$GameArguments = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered; pass -GameExecutable.' }
$gameHash = (Get-FileHash -LiteralPath $game -Algorithm SHA256).Hash.ToLowerInvariant()
if ($gameHash -ne $script:Tpf2ExeHash) {
    throw "Native hook supports only Transport Fever 2 Build 35924; installed SHA-256 is $gameHash"
}
$native = Get-Tpf2mpNativePaths $bundle
$injector = $native.Injector
$dll = $native.Hook
& $injector --verify $game
if ($LASTEXITCODE -ne 0) { throw "Native profile verification failed with exit code $LASTEXITCODE" }

if ($ExistingPid -gt 0) {
    & $injector --pid $ExistingPid --dll $dll --wait-ms $WaitMilliseconds
}
else {
    if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
        throw 'Transport Fever 2 is already running; close it or pass its exact PID with -ExistingPid.'
    }
    if (-not $SteamExecutable) {
        $steamRoot = Get-Tpf2mpSteamRoot
        if ($steamRoot) { $SteamExecutable = Join-Path $steamRoot 'steam.exe' }
    }
    if (-not $SteamExecutable -or -not (Test-Path -LiteralPath $SteamExecutable -PathType Leaf)) {
        throw 'Steam executable was not discovered; pass -SteamExecutable.'
    }
    Start-Process -FilePath $SteamExecutable -ArgumentList (@('-applaunch', [string]$script:Tpf2AppId) + $GameArguments) -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds($LaunchTimeoutSeconds)
    $process = $null
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue |
            Sort-Object StartTime -Descending | Select-Object -First 1
        if ($process) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $process) { throw "Steam did not launch Transport Fever 2 within $LaunchTimeoutSeconds seconds" }
    Write-Host "Attaching the pinned native hook to game process $($process.Id)."
    & $injector --pid $process.Id --dll $dll --wait-ms $WaitMilliseconds
    if ($LASTEXITCODE -ne 0) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
}
if ($LASTEXITCODE -ne 0) { throw "Native injection failed with exit code $LASTEXITCODE" }
Write-Host 'Native hook active. For network play, select Network companion and the matching peer/session in the mod options.'
