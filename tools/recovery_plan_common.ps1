Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')

function Read-Tpf2mpVerifiedRestorePlan {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$PlanPath
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $resolved = Resolve-Tpf2mpFullPath $PlanPath
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Restore plan is missing: $resolved"
    }
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $companion = Get-Tpf2mpCompanionCommand $bundle
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') { $env:PYTHONPATH = Join-Path $bundle 'companion' }
    try {
        $output = @(& $companion.FilePath @($companion.Prefix + @(
            'verify-restore-plan', $resolved, '--metadata-only'
        )) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "Restore-plan verification failed: $($output -join ' ')"
        }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
    $plan = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    [void](Assert-Tpf2mpCurrentRestorePlan $plan)
    if ([string]$plan.session -ne $safeSession) {
        throw 'Restore plan names a different source session.'
    }
    return $plan
}

function Copy-Tpf2mpAtomicRecoveryPlan {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $sourcePath = Resolve-Tpf2mpFullPath $Source
    $destinationPath = [IO.Path]::GetFullPath($Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationPath) | Out-Null
    $temporary = $destinationPath + '.tmp-' + [guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllBytes($temporary, [IO.File]::ReadAllBytes($sourcePath))
        Move-Item -LiteralPath $temporary -Destination $destinationPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $destinationPath
}

function Publish-Tpf2mpVerifiedRestorePlan {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$PlanPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $plan = Read-Tpf2mpVerifiedRestorePlan -BundleRoot $BundleRoot `
        -Session $Session -PlanPath $PlanPath
    $published = Copy-Tpf2mpAtomicRecoveryPlan -Source $PlanPath -Destination $Destination
    return [pscustomobject]@{
        path = $published
        checksum = [string]$plan.checksum
        boundarySeq = [int]$plan.boundarySeq
    }
}

function New-Tpf2mpReceiptBoundArchive {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][string]$ReceivedPlanPath,
        [Parameter(Mandatory = $true)][string]$SavePath,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$BoundarySeq
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $plan = Read-Tpf2mpVerifiedRestorePlan -BundleRoot $BundleRoot `
        -Session $safeSession -PlanPath $ReceivedPlanPath
    if ([int]$plan.boundarySeq -ne $BoundarySeq -or @($plan.requiredPeers) -notcontains $Peer) {
        throw 'Restore plan does not bind this peer and archived boundary.'
    }
    $recoveryRoot = Join-Path (Get-Tpf2mpSessionRoot $safeSession $Peer) 'recovery'
    $checksum = [string]$plan.checksum
    $safeChecksum = $checksum.Substring(0, [Math]::Min(12, $checksum.Length))
    $durablePlan = Join-Path $recoveryRoot `
        "received-restore-plan-$BoundarySeq-$safeChecksum.json"
    [void](Copy-Tpf2mpAtomicRecoveryPlan -Source $ReceivedPlanPath -Destination $durablePlan)
    & (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') `
        -Session $safeSession -Peer $Peer -SavePath $SavePath `
        -RecoveryPlanPath $durablePlan -BoundarySeq $BoundarySeq `
        -BundleRoot $BundleRoot | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Receipt-bound recovery archive exited $LASTEXITCODE" }
    return [pscustomobject]@{
        plan = $plan
        durablePlan = $durablePlan
        latestPointer = Join-Path (Get-Tpf2mpSessionRoot $safeSession $Peer) `
            'latest-recovery-archive.json'
    }
}
