[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot,
    [Parameter(Mandatory = $true)][string]$Python
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $ProjectRoot 'tools\recovery_plan_common.ps1')

$session = 'handoff-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$fixtureRoot = Join-Path $TemporaryRoot 'restore-handoff-fixture'
$bridgeState = Join-Path $TemporaryRoot 'restore-handoff-bridge\companion_state'
New-Item -ItemType Directory -Force -Path $fixtureRoot, $bridgeState | Out-Null
$previousPythonPath = $env:PYTHONPATH
$previousLocalAppData = $env:LOCALAPPDATA
$env:PYTHONPATH = Join-Path $ProjectRoot 'companion'
$env:LOCALAPPDATA = Join-Path $TemporaryRoot 'restore-handoff-localappdata'

try {
    $fixtureJson = & $Python (Join-Path $ProjectRoot 'tests\write_restore_handoff_fixture.py') `
        --output $fixtureRoot --session $session
    if ($LASTEXITCODE -ne 0) { throw 'Restore handoff fixture generation failed.' }
    $fixture = ($fixtureJson -join "`n") | ConvertFrom-Json
    $published = Join-Path $bridgeState 'published_restore_plan.json'
    $publication = Publish-Tpf2mpVerifiedRestorePlan -BundleRoot $ProjectRoot `
        -Session $session -PlanPath ([string]$fixture.planPath) -Destination $published
    if ($publication.boundarySeq -ne 9 `
        -or (Get-FileHash -LiteralPath $published -Algorithm SHA256).Hash `
            -ne (Get-FileHash -LiteralPath ([string]$fixture.planPath) -Algorithm SHA256).Hash) {
        throw 'Published restore plan was not the exact verified host plan.'
    }

    $archive = New-Tpf2mpReceiptBoundArchive -BundleRoot $ProjectRoot `
        -Session $session -Peer player2 -ReceivedPlanPath $published `
        -SavePath ([string]$fixture.savePath) -BoundarySeq 9
    if (-not (Test-Path -LiteralPath $archive.latestPointer -PathType Leaf) `
        -or -not (Test-Path -LiteralPath $archive.durablePlan -PathType Leaf)) {
        throw 'Player2 did not create its durable receipt-bound plan/archive pair.'
    }
    $pointer = Get-Content -LiteralPath $archive.latestPointer -Raw | ConvertFrom-Json
    if ($pointer.promotedRestorePoint -ne $true `
        -or $pointer.association -ne 'coordinated-receipt-bound-restore-save' `
        -or $pointer.recoveryPlanChecksum -ne $publication.checksum) {
        throw 'Player2 latest pointer is not bound to the published host plan.'
    }
    $discovered = Get-Tpf2mpLatestLocalRestore -BundleRoot $ProjectRoot -Peer player2
    if ($discovered.session -ne $session -or $discovered.boundarySeq -ne 9 `
        -or $discovered.planChecksum -ne $publication.checksum `
        -or $discovered.savePath -notlike '*.sav') {
        throw 'Launcher discovery did not select the synthetic player2 restore pair.'
    }
    $wrongSessionRejected = $false
    try {
        [void](Read-Tpf2mpVerifiedRestorePlan -BundleRoot $ProjectRoot `
            -Session 'different-session' -PlanPath $published)
    }
    catch { $wrongSessionRejected = $_.Exception.Message -match 'different source session' }
    if (-not $wrongSessionRejected) { throw 'Handoff accepted a plan from a different source session.' }
    Write-Host 'PASS verified publication, player2 re-archive, and launcher discovery handoff'
}
finally {
    $env:PYTHONPATH = $previousPythonPath
    $env:LOCALAPPDATA = $previousLocalAppData
}
