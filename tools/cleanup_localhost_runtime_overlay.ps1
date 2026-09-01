[CmdletBinding()]
param(
    [string]$GameExecutable,
    [switch]$AllowStaleDevelopmentOverlay
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
    throw 'Transport Fever 2 is running; refusing to remove a runtime overlay in use.'
}
$game = Find-Tpf2mpGameExecutable $GameExecutable
if (-not $game) { throw 'Transport Fever 2 executable was not discovered.' }
$game = Resolve-Tpf2mpFullPath $game
$gameRoot = Split-Path -Parent $game
$resourceRoot = [IO.Path]::GetFullPath((Join-Path $gameRoot 'res'))
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot 'tpf2_mp_1\res'))

$targets = @(
    [pscustomobject]@{
        Source = Join-Path $sourceRoot 'scripts\tpf2_mp'
        Target = Join-Path $resourceRoot 'scripts\tpf2_mp'
        Directory = $true
    },
    [pscustomobject]@{
        Source = Join-Path $sourceRoot 'config\game_script\tpf2_mp.lua'
        Target = Join-Path $resourceRoot 'config\game_script\tpf2_mp.lua'
        Directory = $false
    },
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'multiplayer_menu_bootstrap.lua'
        Target = Join-Path $resourceRoot 'scripts\tpf2mp_multiplayer_menu_bootstrap.lua'
        Directory = $false
    },
    [pscustomobject]@{
        Source = Join-Path $PSScriptRoot 'localhost_bootstrap.lua'
        Target = Join-Path $resourceRoot 'scripts\tpf2mp_localhost_bootstrap.lua'
        Directory = $false
    }
)

foreach ($entry in $targets) {
    $target = [IO.Path]::GetFullPath([string]$entry.Target)
    if (-not $target.StartsWith($resourceRoot.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing runtime-overlay cleanup outside game resources: $target"
    }
    if (-not (Test-Path -LiteralPath $target)) { continue }
    $source = [IO.Path]::GetFullPath([string]$entry.Source)
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Cannot verify runtime overlay because its source is missing: $source"
    }
    if ($entry.Directory) {
        if (-not (Test-Path -LiteralPath $target -PathType Container)) {
            throw "Runtime overlay target is not a directory: $target"
        }
        $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
            $_.FullName.Substring($source.TrimEnd('\').Length + 1)
        } | Sort-Object)
        $targetFiles = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
            $_.FullName.Substring($target.TrimEnd('\').Length + 1)
        } | Sort-Object)
        if ($AllowStaleDevelopmentOverlay -and
                $target.Equals((Join-Path $resourceRoot 'scripts\tpf2_mp'),
                    [StringComparison]::OrdinalIgnoreCase)) {
            # An interrupted unattended validator may leave the source-tree
            # copy from the start of its run plus its one probe-only module.
            # Never turn the escape hatch into a broad recursive delete: the
            # resolved target is pinned above and every relative file must be
            # one the current source knows, or the exact validator probe.
            $allowed = @{}
            foreach ($relative in $sourceFiles) { $allowed[$relative.ToLowerInvariant()] = $true }
            $allowed['live_console_probe.lua'] = $true
            $unexpected = @($targetFiles | Where-Object {
                -not $allowed.ContainsKey($_.ToLowerInvariant())
            })
            if ($unexpected.Count -gt 0) {
                throw "Stale runtime overlay contains unexpected files: $($unexpected -join ', ')"
            }
        }
        else {
            if (($sourceFiles -join "`n") -ne ($targetFiles -join "`n")) {
                throw "Runtime overlay file set differs from the current source; refusing cleanup: $target"
            }
            foreach ($relative in $sourceFiles) {
                $sourceHash = (Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256).Hash
                $targetHash = (Get-FileHash -LiteralPath (Join-Path $target $relative) -Algorithm SHA256).Hash
                if ($sourceHash -ne $targetHash) {
                    throw "Runtime overlay content differs at $relative; refusing cleanup."
                }
            }
        }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    else {
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $targetHash = if (Test-Path -LiteralPath $target -PathType Leaf) {
            (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        } else { $null }
        $staleGameScript = $AllowStaleDevelopmentOverlay -and
            $target.Equals((Join-Path $resourceRoot 'config\game_script\tpf2_mp.lua'),
                [StringComparison]::OrdinalIgnoreCase)
        if (-not $targetHash -or (-not $staleGameScript -and $sourceHash -ne $targetHash)) {
            throw "Runtime overlay file differs from the current source; refusing cleanup: $target"
        }
        Remove-Item -LiteralPath $target -Force
    }
    Write-Host "Removed verified disposable runtime overlay: $target"
}

Write-Host 'Localhost runtime-overlay cleanup complete.'
