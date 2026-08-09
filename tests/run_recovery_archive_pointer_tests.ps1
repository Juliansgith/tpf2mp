[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $ProjectRoot 'tools\network_common.ps1')

$session = 'pointer-' + [guid]::NewGuid().ToString('N').Substring(0, 16)
$sessionRoot = Get-Tpf2mpSessionRoot $session player2
$supportRoot = Get-Tpf2mpSupportRoot
$supportPrefix = $supportRoot.TrimEnd('\') + '\'
$saveRoot = Join-Path $TemporaryRoot 'recovery-pointer-saves'
New-Item -ItemType Directory -Force -Path $saveRoot | Out-Null

function New-PointerFixtureSave([string]$Name, [byte]$Value) {
    $save = Join-Path $saveRoot ($Name + '.sav')
    [IO.File]::WriteAllBytes($save, [byte[]]($Value, $Value, $Value))
    [IO.File]::WriteAllText($save + '.lua', 'return { pointerFixture = true }',
        [Text.UTF8Encoding]::new($false))
    return $save
}

try {
    $latestPointer = Join-Path $sessionRoot 'latest-recovery-archive.json'
    New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
    $lastKnownGood = '{"sentinel":"last-known-good-receipt-bound-pointer"}'
    [IO.File]::WriteAllText($latestPointer, $lastKnownGood, [Text.UTF8Encoding]::new($false))
    $pendingSave = New-PointerFixtureSave 'pending' 3
    & (Join-Path $ProjectRoot 'tools\archive_recovery_save.ps1') `
        -Session $session -Peer player2 -SavePath $pendingSave -BoundarySeq 9 `
        -PendingReceipt -BundleRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Pending recovery archive fixture failed.' }
    $pendingPointer = Join-Path $sessionRoot 'pending-recovery-archive-b9.json'
    if (-not (Test-Path -LiteralPath $pendingPointer -PathType Leaf) `
        -or (Get-Content -LiteralPath $latestPointer -Raw) -ne $lastKnownGood) {
        throw 'Pending receipt archive displaced or impersonated the latest valid pointer.'
    }
    $pending = Get-Content -LiteralPath $pendingPointer -Raw | ConvertFrom-Json
    if ($pending.schemaVersion -ne 2 -or $pending.boundarySeq -ne 9 `
        -or $pending.recoveryPlanPath) {
        throw 'Pending recovery pointer omitted its explicit unbound boundary state.'
    }

    $candidateSave = New-PointerFixtureSave 'candidate' 7
    & (Join-Path $ProjectRoot 'tools\archive_recovery_save.ps1') `
        -Session $session -Peer player2 -SavePath $candidateSave -BoundarySeq 10 `
        -BundleRoot $ProjectRoot | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Unanchored recovery candidate fixture failed.' }
    $candidatePointer = Join-Path $sessionRoot 'latest-recovery-candidate.json'
    if (-not (Test-Path -LiteralPath $candidatePointer -PathType Leaf) `
        -or (Get-Content -LiteralPath $latestPointer -Raw) -ne $lastKnownGood) {
        throw 'An unanchored candidate displaced the last receipt-bound restore pointer.'
    }
    $candidate = Get-Content -LiteralPath $candidatePointer -Raw | ConvertFrom-Json
    if ($candidate.schemaVersion -ne 2 -or $candidate.boundarySeq -ne 10 `
        -or $candidate.promotedRestorePoint) {
        throw 'Unanchored recovery candidate was incorrectly marked restorable.'
    }
    Write-Host 'PASS pending/unanchored archives preserve the last promoted restore pointer'
}
finally {
    if (Test-Path -LiteralPath $sessionRoot -PathType Container) {
        $resolved = [IO.Path]::GetFullPath($sessionRoot)
        if (-not $resolved.StartsWith($supportPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to clean a pointer fixture outside the TPF2MP support root.'
        }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
