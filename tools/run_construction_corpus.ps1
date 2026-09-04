[CmdletBinding()]
param(
    [ValidateSet('Static', 'Core', 'All')][string]$Tier = 'Static',
    [string[]]$Case = @(),
    [string]$StartingSave,
    [string]$IndustryArtifactSourceRoot,
    [ValidateRange(120, 3600)][int]$TimeoutSeconds = 1200,
    [switch]$IncludeOptional,
    [switch]$SkipStaticGate,
    [switch]$KeepGoing,
    [string]$GameExecutable,
    [string]$LocalModsPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $projectRoot 'content\construction-corpus-v1.json'
$pythonCommand = Get-Command python -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $pythonCommand) { throw 'Python is required to validate the construction corpus.' }
& $pythonCommand.Source (Join-Path $PSScriptRoot 'validate_construction_corpus.py') `
    --project-root $projectRoot --manifest $manifestPath --check
if ($LASTEXITCODE -ne 0) { throw 'Construction corpus manifest validation failed.' }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

if ($Tier -eq 'Static') {
    if (-not $SkipStaticGate) {
        & (Join-Path $PSScriptRoot 'run_tests.ps1')
        if (-not $?) { throw 'Static construction corpus gate failed.' }
    }
    Write-Host ('PASS construction corpus static validators: {0} declared matrix cases; no live physical proof was run.' -f `
        (@($manifest.matrices | Measure-Object -Property expectedCases -Sum).Sum))
    return
}

if (-not $StartingSave) {
    throw 'Core/All corpus tiers require -StartingSave with the populated qualification world.'
}
$startingSavePath = [IO.Path]::GetFullPath($StartingSave)
if (-not (Test-Path -LiteralPath $startingSavePath -PathType Leaf)) {
    throw "Construction corpus starting save is missing: $startingSavePath"
}
if (-not $SkipStaticGate) {
    & (Join-Path $PSScriptRoot 'run_tests.ps1')
    if (-not $?) { throw 'Static construction corpus gate failed.' }
}

$requested = @($Case | ForEach-Object { [string]$_ } | Where-Object { $_ })
$liveCases = @($manifest.cases | Where-Object {
    $_.executor.kind -eq 'localhost-slice' `
        -and ($_.tier -eq 'localhost' -or ($IncludeOptional -and $_.tier -eq 'localhost-optional')) `
        -and ($requested.Count -eq 0 -or $requested -contains [string]$_.id)
})
if ($requested.Count -gt 0) {
    $missing = @($requested | Where-Object {
        $wanted = $_
        -not ($liveCases | Where-Object { $_.id -eq $wanted })
    })
    if ($missing.Count -gt 0) {
        throw 'Unknown, non-live, or optional-without-IncludeOptional corpus case(s): ' + `
            ($missing -join ', ')
    }
}
if ($liveCases.Count -eq 0) { throw 'No live construction corpus cases were selected.' }

$runId = 'construction-corpus-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$reportRoot = Join-Path $projectRoot "runtime\construction-corpus\$runId"
New-Item -ItemType Directory -Force -Path $reportRoot | Out-Null
$results = @()
$failed = $false
foreach ($entry in $liveCases) {
    $caseId = [string]$entry.id
    $slice = [string]$entry.executor.slice
    $session = ('corpus-' + $caseId + '-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    $arguments = @{
        Session = $session
        ValidationSlice = $slice
        StartingSave = $startingSavePath
        TimeoutSeconds = $TimeoutSeconds
        SkipTests = $true
        EvidenceTag = $caseId
    }
    if ($GameExecutable) { $arguments.GameExecutable = $GameExecutable }
    if ($LocalModsPath) { $arguments.LocalModsPath = $LocalModsPath }
    if ($IndustryArtifactSourceRoot) {
        $arguments.IndustryArtifactSourceRoot = $IndustryArtifactSourceRoot
        $arguments.RequireIndustryContentConsensus = $true
    }
    $activeMods = @($entry.executor.activeMods | ForEach-Object { [string]$_ } |
        Where-Object { $_ })
    if ($activeMods.Count -gt 0) { $arguments.ExtraActiveMod = $activeMods }
    Write-Host "RUN construction corpus $caseId ($slice), session $session"
    $started = Get-Date
    $caseError = $null
    try {
        & (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') @arguments
    }
    catch {
        $caseError = $_.Exception.Message
        $failed = $true
    }
    $results += [ordered]@{
        id = $caseId
        slice = $slice
        session = $session
        activeMods = $activeMods
        success = $null -eq $caseError
        error = $caseError
        elapsedSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 3)
        proofScope = [string]$entry.proofScope
        requiredPostconditions = @($entry.postconditions)
    }
    $results | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath (Join-Path $reportRoot 'results.json') -Encoding UTF8
    if ($caseError -and -not $KeepGoing) {
        throw "Construction corpus case $caseId failed: $caseError"
    }
}

[ordered]@{
    schemaVersion = 1
    runId = $runId
    manifest = $manifestPath
    startedCases = $liveCases.Count
    passedCases = @($results | Where-Object { $_.success }).Count
    failedCases = @($results | Where-Object { -not $_.success }).Count
    results = $results
} | ConvertTo-Json -Depth 10 | Set-Content `
    -LiteralPath (Join-Path $reportRoot 'summary.json') -Encoding UTF8

if ($failed) { throw "Construction corpus completed with failures; see $reportRoot" }
Write-Host "PASS construction corpus live tier: $($liveCases.Count) cases; report $reportRoot"
