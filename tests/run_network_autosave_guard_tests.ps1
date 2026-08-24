[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\network_common.ps1')
. (Join-Path $ProjectRoot 'tools\network_autosave_guard.ps1')

$autosaveRoot = Join-Path $TemporaryRoot 'network-autosave-guard'
New-Item -ItemType Directory -Force -Path $autosaveRoot | Out-Null
$autosaveSettings = Join-Path $autosaveRoot 'settings.lua'
$autosaveLease = Join-Path $autosaveRoot 'lease.json'
$autosaveStatus = Join-Path $autosaveRoot 'status.json'
[IO.File]::WriteAllText($autosaveSettings, @'
config = {
  game = {
    autosaveIntervalMinutes = 10,
  },
}
'@, [Text.UTF8Encoding]::new($false))

[void](Enter-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease `
    -SettingsPath $autosaveSettings -Session 'autosave-test' -Peer player1)
if ((Read-Tpf2mpAutosaveInterval $autosaveSettings) -ne 10080) {
    throw 'Network launch did not suspend the ordinary native autosave cadence.'
}
$fakeNetworkGame = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList (ConvertTo-Tpf2mpCommandLine @(
        '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 900')) `
    -PassThru -WindowStyle Hidden
[void](Bind-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease `
    -GameProcess $fakeNetworkGame -GameExecutable $fakeNetworkGame.Path)
$autosaveWatcherArguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
    (Join-Path $ProjectRoot 'tools\watch_network_autosave_guard.ps1'),
    '-LeasePath', $autosaveLease,
    '-GameProcessId', $fakeNetworkGame.Id,
    '-GameExecutable', $fakeNetworkGame.Path,
    '-GameStartedAtUtc', $fakeNetworkGame.StartTime.ToUniversalTime().ToString('o'),
    '-StatusPath', $autosaveStatus
)
$autosaveWatcher = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
    -ArgumentList (ConvertTo-Tpf2mpCommandLine $autosaveWatcherArguments) `
    -PassThru -WindowStyle Hidden
$autosaveWatcher.WaitForExit()
if ($autosaveWatcher.ExitCode -ne 0 `
        -or (Read-Tpf2mpAutosaveInterval $autosaveSettings) -ne 10) {
    throw 'Network autosave guard did not restore the prior cadence after the exact game process exited.'
}
$autosaveWatcherStatus = Get-Content -LiteralPath $autosaveStatus -Raw | ConvertFrom-Json
if ($autosaveWatcherStatus.status -ne 'restored') {
    throw 'Network autosave guard watcher did not publish a restored receipt.'
}

[void](Enter-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease `
    -SettingsPath $autosaveSettings -Session 'autosave-stale-test' -Peer player2)
$staleLease = Read-Tpf2mpAutosaveGuardLease $autosaveLease
$staleLease.status = 'active'
$staleLease.gameProcessId = [int]::MaxValue
$staleLease.gameExecutable = Join-Path $autosaveRoot 'TransportFever2.exe'
$staleLease.gameStartedAtUtc = [DateTime]::UtcNow.AddHours(-1).ToString('o')
Write-Tpf2mpAutosaveGuardLease -LeasePath $autosaveLease -Lease $staleLease
[void](Repair-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease)
if ((Read-Tpf2mpAutosaveInterval $autosaveSettings) -ne 10 `
        -or (Read-Tpf2mpAutosaveGuardLease $autosaveLease).status -ne 'restored') {
    throw 'A stale/crashed network launch did not repair its autosave guard.'
}

[void](Enter-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease `
    -SettingsPath $autosaveSettings -Session 'autosave-user-change-test' -Peer player1)
Set-Tpf2mpAutosaveInterval -SettingsPath $autosaveSettings -Minutes 30
$released = Restore-Tpf2mpNetworkAutosaveGuard -LeasePath $autosaveLease `
    -Reason 'test-external-change'
if ((Read-Tpf2mpAutosaveInterval $autosaveSettings) -ne 30 `
        -or $released.status -ne 'released-with-external-change') {
    throw 'Autosave guard overwrote an explicit external settings change.'
}

Write-Host 'PASS network sessions suspend native autosaves and restore settings after exit/crash'
