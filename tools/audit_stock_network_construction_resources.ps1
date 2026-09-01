[CmdletBinding()]
param(
    [string]$GameDirectory = 'F:\SteamLibrary\steamapps\common\Transport Fever 2',
    [string]$MatrixPath,
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $MatrixPath) {
    $MatrixPath = Join-Path $projectRoot 'tests\fixtures\stock_network_construction_resources.lua'
}
$matrix = [IO.Path]::GetFullPath($MatrixPath)
$game = [IO.Path]::GetFullPath($GameDirectory)
if (-not (Test-Path -LiteralPath $matrix -PathType Leaf)) { throw "Resource matrix is missing: $matrix" }
$source = [IO.File]::ReadAllText($matrix)
$rows = [ordered]@{}
$actual = [ordered]@{}
$missing = [ordered]@{}
$unexpected = [ordered]@{}
foreach ($kind in @('street', 'track', 'bridge', 'tunnel')) {
    $section = [regex]::Match($source,
        '(?s)\b' + [regex]::Escape($kind) + '\s*=\s*\{(?<body>.*?)\n\s*\},')
    if (-not $section.Success) { throw "Could not parse $kind resource section from $matrix" }
    $expected = @([regex]::Matches($section.Groups['body'].Value, '"(?<name>[a-z0-9_/-]+\.lua)"') |
        ForEach-Object { $_.Groups['name'].Value } | Sort-Object -Unique)
    $directory = Join-Path $game ('res\config\' + $kind)
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        throw "Game resource directory is missing: $directory"
    }
    $prefix = [IO.Path]::GetFullPath($directory).TrimEnd('\') + '\'
    $observed = @(Get-ChildItem -LiteralPath $directory -Recurse -File -Filter '*.lua' |
        ForEach-Object { $_.FullName.Substring($prefix.Length).Replace('\', '/') } |
        Sort-Object -Unique)
    $expectedSet, $observedSet = @{}, @{}
    foreach ($name in $expected) { $expectedSet[$name] = $true }
    foreach ($name in $observed) { $observedSet[$name] = $true }
    $rows[$kind] = $expected
    $actual[$kind] = $observed
    $missing[$kind] = @($expected | Where-Object { -not $observedSet.ContainsKey($_) })
    $unexpected[$kind] = @($observed | Where-Object { -not $expectedSet.ContainsKey($_) })
}
$passed = $true
foreach ($kind in $rows.Keys) {
    if ($missing[$kind].Count -gt 0 -or $unexpected[$kind].Count -gt 0) { $passed = $false }
}
$report = [ordered]@{
    schemaVersion = 1
    gameBuild = 35924
    matrix = $matrix
    counts = [ordered]@{
        street = $actual.street.Count
        track = $actual.track.Count
        bridge = $actual.bridge.Count
        tunnel = $actual.tunnel.Count
    }
    missing = $missing
    unexpected = $unexpected
    passed = $passed
}
if ($OutputPath) {
    $output = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $output
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $output -Encoding UTF8
    Write-Host "networkConstructionCoverage=$output"
}
Write-Host "stock network resources: street=$($report.counts.street), track=$($report.counts.track), bridge=$($report.counts.bridge), tunnel=$($report.counts.tunnel), passed=$passed"
if (-not $passed) { throw 'Stock network-construction resource inventory changed.' }
