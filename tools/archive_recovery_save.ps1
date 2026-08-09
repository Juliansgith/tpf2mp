[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [Parameter(Mandatory = $true)][string]$SavePath,
    [string]$RecoveryPlanPath,
    [string]$BundleRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
$source = Get-Tpf2mpSaveTriplet $SavePath
$sessionRoot = Get-Tpf2mpSessionRoot $safeSession $Peer
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
$state = Read-Tpf2mpSessionState $safeSession $Peer
$companion = Get-Tpf2mpCompanionCommand $bundle

function Invoke-RecoveryCompanion([object[]]$Arguments) {
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') { $env:PYTHONPATH = Join-Path $bundle 'companion' }
    try {
        & $companion.FilePath @($companion.Prefix + $Arguments)
        if ($LASTEXITCODE -ne 0) { throw "Recovery companion exited $LASTEXITCODE" }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$recoveryRoot = Join-Path $sessionRoot 'recovery'
New-Item -ItemType Directory -Force -Path $recoveryRoot | Out-Null
$resolvedPlan = $null
if ($RecoveryPlanPath) {
    $resolvedPlan = Resolve-Tpf2mpFullPath $RecoveryPlanPath
    if (-not (Test-Path -LiteralPath $resolvedPlan -PathType Leaf)) {
        throw "Recovery plan is missing: $resolvedPlan"
    }
}
elseif ($state -and $state.bridgePath) {
    $audit = Join-Path ([string]$state.bridgePath) "audit\$safeSession.ndjson"
    if (Test-Path -LiteralPath $audit -PathType Leaf) {
        $candidatePlan = Join-Path $recoveryRoot "restore-plan-$stamp.json"
        try {
            $planArguments = @('restore-plan', $audit, '--session', $safeSession)
            if ($state.PSObject.Properties['matchContentProfile'] -and $state.matchContentProfile `
                -and (Test-Path -LiteralPath ([string]$state.matchContentProfile) -PathType Leaf)) {
                $planArguments += @('--match-profile', [string]$state.matchContentProfile)
            }
            else {
                Write-Warning 'Session has no readable match-content profile; generated restore plan will use legacy v2 policy semantics.'
                $planArguments += '--allow-legacy-unbound'
            }
            $planArguments += @('--output', $candidatePlan)
            Invoke-RecoveryCompanion -Arguments $planArguments
            $resolvedPlan = $candidatePlan
        }
        catch {
            if (Test-Path -LiteralPath $candidatePlan -PathType Leaf) {
                Remove-Item -LiteralPath $candidatePlan -Force
            }
            $candidatePlan = Join-Path $recoveryRoot "recovery-plan-$stamp.json"
            try {
                Invoke-RecoveryCompanion -Arguments @('recovery-plan', $audit, '--session', $safeSession, '--output', $candidatePlan)
                $resolvedPlan = $candidatePlan
            }
            catch {
                Write-Warning "No agreed all-peer checkpoint could be linked; creating an explicitly unanchored archive: $($_.Exception.Message)"
                if (Test-Path -LiteralPath $candidatePlan -PathType Leaf) {
                    Remove-Item -LiteralPath $candidatePlan -Force
                }
            }
        }
    }
}

$safeSaveName = ([IO.Path]::GetFileNameWithoutExtension($source.save) -replace '[^A-Za-z0-9._-]', '_')
if (-not $safeSaveName) { $safeSaveName = 'native-save' }
$archiveDirectory = Join-Path $recoveryRoot "$stamp-$safeSaveName"
$arguments = @(
    'archive-save', $source.save,
    '--session', $safeSession,
    '--peer', $Peer,
    '--output-dir', $archiveDirectory
)
if ($resolvedPlan) { $arguments += @('--recovery-plan', $resolvedPlan) }
Invoke-RecoveryCompanion -Arguments $arguments
$manifestPath = Join-Path $archiveDirectory 'archive-manifest.json'
Invoke-RecoveryCompanion -Arguments @('verify-recovery-archive', $manifestPath, '--archive-dir', $archiveDirectory)

$pointer = [ordered]@{
    schemaVersion = 1
    session = $safeSession
    peer = $Peer
    archiveDirectory = $archiveDirectory
    manifestPath = $manifestPath
    manifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    recoveryPlanPath = $resolvedPlan
    sourceSave = $source.save
    archivedAtUtc = [DateTime]::UtcNow.ToString('o')
}
$pointerPath = Join-Path $sessionRoot 'latest-recovery-archive.json'
$pointer | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pointerPath -Encoding UTF8
Write-Host "Recovery archive ready: $archiveDirectory"
$pointer | ConvertTo-Json -Depth 6
