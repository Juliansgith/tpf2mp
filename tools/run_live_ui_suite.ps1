[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StartingSave,
    [string]$Suite = '',
    [string]$GameExecutable,
    [string]$LocalModsPath,
    [string[]]$ExtraActiveMod = @(),
    [string]$ResultPath,
    [switch]$SkipStaticGate
)
$ErrorActionPreference = 'Stop'
if (-not $Suite) { $Suite = Join-Path $PSScriptRoot '..\content\live-ui\ui-smoke.json' }
$Suite = (Resolve-Path -LiteralPath $Suite).Path
$StartingSave = (Resolve-Path -LiteralPath $StartingSave).Path
if ($ResultPath) {
    $ResultPath = [IO.Path]::GetFullPath($ResultPath)
    if (Test-Path -LiteralPath $ResultPath) { throw 'Refusing to overwrite a prior UI run receipt.' }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $ResultPath) -PathType Container)) { throw 'UI receipt parent must already exist.' }
}
$python = if ($env:TPF2MP_PYTHON) { $env:TPF2MP_PYTHON } else { (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
& $python (Join-Path $PSScriptRoot 'run_live_ui.py') --suite $Suite --save $StartingSave --validate
if ($LASTEXITCODE -ne 0) { throw 'UI fixture validation failed before any games were launched.' }
& $python -c "from PIL import ImageGrab; import ctypes; assert hasattr(ctypes, 'WinDLL'), 'Windows required'"
if ($LASTEXITCODE -ne 0) { throw 'Windows Python with Pillow is required for UI input/screenshots.' }
$lua = if ($env:TPF2MP_LUA) { $env:TPF2MP_LUA } else { (Get-Command lua -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source }
& $lua (Join-Path $PSScriptRoot '..\tests\run_live_ui_observer_tests.lua') (Split-Path -Parent $PSScriptRoot)
if ($LASTEXITCODE -ne 0) { throw 'Mandatory UI observer/entry-script preflight failed; no game launched.' }
$session = 'localhost-ui-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$arguments = @{
    Session = $session; StartingSave = $StartingSave; LiveUiSuite = $Suite
    ManualOnly = $true; InteractiveAfterValidation = $true; InteractiveMinutes = 60
    SkipTests = $SkipStaticGate; ExtraActiveMod = $ExtraActiveMod
}
if ($GameExecutable) { $arguments.GameExecutable = $GameExecutable }
if ($LocalModsPath) { $arguments.LocalModsPath = $LocalModsPath }
try {
    & (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @arguments
    if (-not $?) { throw 'Live UI suite or disposable-world cleanup failed.' }
} finally {
        $runRoot = Join-Path (Split-Path -Parent $PSScriptRoot) ('runtime\localhost-live\' + $session)
        $statusPath = Join-Path $runRoot 'run-status.json'
        $clean = $false
        if (Test-Path -LiteralPath $statusPath) {
            $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
            $clean = $true
            foreach ($flag in @('settingsRestored','steamMarkerRestored','temporaryBootstrapRemoved','temporaryGameScriptRemoved','temporaryLibraryRemoved','temporaryStartingSaveRemoved')) {
                if ($status.$flag -ne $true) { $clean = $false }
            }
            foreach ($testPid in @($status.peer1GamePid, $status.peer2GamePid, $status.finalHostStatus.pid, $status.finalClientStatus.pid)) {
                if ($testPid -and (Get-Process -Id $testPid -ErrorAction SilentlyContinue)) { $clean = $false }
            }
        }
        $reportPath = Join-Path $runRoot 'ui-suite\report.json'
        $finalizeArgs = @('--report', $reportPath, '--status', $statusPath)
        if ($clean) { $finalizeArgs += '--processes-closed' }
        & $python (Join-Path $PSScriptRoot 'finalize_live_ui.py') @finalizeArgs
        $proofFinalized = $LASTEXITCODE -eq 0
    if ($ResultPath) {
        @{ schemaVersion = 1; session = $session; suite = $Suite; cleanupComplete = $clean
            runStatus = $statusPath; report = (Join-Path $runRoot 'ui-suite\report.json')
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
    }
    if ((Test-Path -LiteralPath $reportPath) -and -not $proofFinalized) {
        throw "UI proof failed its final audit/cleanup gate; inspect $reportPath"
    }
}
