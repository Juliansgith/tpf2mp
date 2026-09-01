[CmdletBinding()]
param(
    [string]$GameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2',
    [string]$MatrixPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $MatrixPath) {
    $MatrixPath = Join-Path $projectRoot 'tests\fixtures\stock_nonbuilding_constructions.lua'
}
$matrix = [IO.Path]::GetFullPath($MatrixPath)
$game = [IO.Path]::GetFullPath($GameDirectory)
$zipPath = Join-Path $game 'res\construction\construction.zip'
if (-not (Test-Path -LiteralPath $matrix -PathType Leaf)) { throw "Construction matrix is missing: $matrix" }
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw "Construction archive is missing: $zipPath" }

$fixturePattern = [regex]'fileName\s*=\s*"(?<file>[^"]+)"\s*,\s*type\s*=\s*"(?<type>[^"]+)"\s*,\s*kind\s*=\s*"(?<kind>[^"]+)"\s*,\s*surface\s*=\s*"(?<surface>[^"]+)"\s*,\s*evidence\s*=\s*"(?<evidence>[^"]+)"'
$fixtureRows = @()
foreach ($match in $fixturePattern.Matches([IO.File]::ReadAllText($matrix))) {
    $fixtureRows += [pscustomobject]@{
        fileName = $match.Groups['file'].Value
        type = $match.Groups['type'].Value
        kind = $match.Groups['kind'].Value
        surface = $match.Groups['surface'].Value
        evidence = $match.Groups['evidence'].Value
    }
}
if ($fixtureRows.Count -eq 0) { throw "No construction rows were parsed from $matrix" }

function Get-ExpectedCodecKind([string]$FileName) {
    $lower = $FileName.ToLowerInvariant()
    if ($lower -in @('asset/headquarter.con', 'asset/field_decoration.con',
            'asset/ground_texture_builder.con')) { return 'construction' }
    if ($lower.StartsWith('asset/')) { return 'asset' }
    if ($lower.Contains('depot')) { return 'depot' }
    if ($lower -eq 'station/rail/modular_station/modular_station.con') { return 'rail_station' }
    if ($lower.Contains('station')) { return 'station' }
    return 'construction'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $archiveRows = @()
    foreach ($entry in $archive.Entries) {
        if (-not $entry.FullName.EndsWith('.con', [StringComparison]::OrdinalIgnoreCase) `
                -or $entry.FullName.StartsWith('building/', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $reader = [IO.StreamReader]::new($entry.Open())
        try { $source = $reader.ReadToEnd() } finally { $reader.Dispose() }
        $typeMatch = [regex]::Match($source, '(?m)^\s*type\s*=\s*"([^"]+)"')
        $type = if ($typeMatch.Success) { $typeMatch.Groups[1].Value } `
            elseif ($entry.FullName.StartsWith('industry/', [StringComparison]::OrdinalIgnoreCase)) { 'INDUSTRY' } `
            else { '' }
        $archiveRows += [pscustomobject]@{
            fileName = $entry.FullName
            type = $type
            kind = Get-ExpectedCodecKind $entry.FullName
        }
    }
}
finally { $archive.Dispose() }

$fixtureByName, $archiveByName = @{}, @{}
foreach ($row in $fixtureRows) {
    if ($fixtureByName.ContainsKey($row.fileName)) { throw "Duplicate matrix row: $($row.fileName)" }
    $fixtureByName[$row.fileName] = $row
}
foreach ($row in $archiveRows) {
    if ($archiveByName.ContainsKey($row.fileName)) { throw "Duplicate archive row: $($row.fileName)" }
    $archiveByName[$row.fileName] = $row
}

$missing = @($fixtureRows | Where-Object { -not $archiveByName.ContainsKey($_.fileName) } | ForEach-Object fileName)
$unexpected = @($archiveRows | Where-Object { -not $fixtureByName.ContainsKey($_.fileName) } | ForEach-Object fileName)
$mismatches = @()
foreach ($row in $fixtureRows) {
    $actual = $archiveByName[$row.fileName]
    if (-not $actual) { continue }
    if ($row.type -ne $actual.type -or $row.kind -ne $actual.kind) {
        $mismatches += [pscustomobject]@{
            fileName = $row.fileName
            expectedType = $row.type
            actualType = $actual.type
            expectedKind = $row.kind
            actualKind = $actual.kind
        }
    }
}

$publicRows = @($fixtureRows | Where-Object surface -eq 'public')
$report = [ordered]@{
    schemaVersion = 1
    gameBuild = 35924
    archive = $zipPath
    matrix = $matrix
    constructionCount = $archiveRows.Count
    publicCount = $publicRows.Count
    evidence = [ordered]@{}
    publicOfflineOnly = @($publicRows | Where-Object evidence -eq 'offline' | ForEach-Object fileName)
    missing = $missing
    unexpected = $unexpected
    mismatches = $mismatches
    passed = $missing.Count -eq 0 -and $unexpected.Count -eq 0 -and $mismatches.Count -eq 0
}
foreach ($group in $fixtureRows | Group-Object evidence | Sort-Object Name) {
    $report.evidence[$group.Name] = $group.Count
}

$json = $report | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $output = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $output
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [IO.File]::WriteAllText($output, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host "constructionCoverage=$output"
}
Write-Host "stock constructions=$($report.constructionCount), public=$($report.publicCount), offline-only=$($report.publicOfflineOnly.Count), passed=$($report.passed)"
if (-not $report.passed) {
    Write-Host $json
    throw 'Stock construction inventory differs from the pinned coverage matrix.'
}
