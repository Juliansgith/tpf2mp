Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release_common.ps1')

function Get-Tpf2mpRuntimeOverlayInventory {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$GameExecutable
    )
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    $gameRoot = Split-Path -Parent $game
    $resourceRoot = Resolve-Tpf2mpFullPath (Join-Path $gameRoot 'res')
    $sourceResourceRoot = Resolve-Tpf2mpFullPath (Join-Path $bundle 'tpf2_mp_1\res')
    return @(
        [pscustomobject][ordered]@{
            kind = 'game-script'
            source = Join-Path $sourceResourceRoot 'config\game_script\tpf2_mp.lua'
            target = Join-Path $resourceRoot 'config\game_script\tpf2_mp.lua'
            directory = $false
        },
        [pscustomobject][ordered]@{
            kind = 'runtime-library'
            source = Join-Path $sourceResourceRoot 'scripts\tpf2_mp'
            target = Join-Path $resourceRoot 'scripts\tpf2_mp'
            directory = $true
        },
        [pscustomobject][ordered]@{
            kind = 'menu-bootstrap'
            source = Join-Path $bundle 'tools\multiplayer_menu_bootstrap.lua'
            target = Join-Path $resourceRoot 'scripts\tpf2mp_multiplayer_menu_bootstrap.lua'
            directory = $false
        },
        [pscustomobject][ordered]@{
            kind = 'localhost-bootstrap'
            source = Join-Path $bundle 'tools\localhost_bootstrap.lua'
            target = Join-Path $resourceRoot 'scripts\tpf2mp_localhost_bootstrap.lua'
            directory = $false
        }
    )
}

function Test-Tpf2mpManagedRuntimeOverlayEntry {
    param([Parameter(Mandatory = $true)]$Entry)
    $target = Resolve-Tpf2mpFullPath ([string]$Entry.target)
    if (-not (Test-Path -LiteralPath $target)) { return $false }
    $item = Get-Item -LiteralPath $target -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }

    if ([bool]$Entry.directory) {
        if (-not $item.PSIsContainer) { return $false }
        $files = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force)
        if ($files.Count -eq 0 -or $files.Count -gt 1000) { return $false }
        if (@($files | Where-Object {
                $_.Extension -ine '.lua' `
                    -or (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            }).Count -gt 0) { return $false }
        $world = Join-Path $target 'world.lua'
        $canonical = Join-Path $target 'canonical.lua'
        if (-not (Test-Path -LiteralPath $world -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $canonical -PathType Leaf)) { return $false }
        $worldText = Get-Content -LiteralPath $world -Raw
        return $worldText.Contains('local canonical = require "tpf2_mp/canonical"')
    }

    if ($item.PSIsContainer) { return $false }
    $firstLine = [string](Get-Content -LiteralPath $target -TotalCount 1)
    switch ([string]$Entry.kind) {
        'game-script' {
            $content = Get-Content -LiteralPath $target -Raw
            return $firstLine -eq '-- TPF2MP managed base-game runtime overlay; inert without explicit activation.' `
                -or ($content.Contains('local util = require "tpf2_mp/util"') `
                    -and $content.Contains('local canonical = require "tpf2_mp/canonical"'))
        }
        'menu-bootstrap' {
            return $firstLine -eq '-- Console-state main-menu bootstrap for launcher-managed TPF2MP sessions.'
        }
        'localhost-bootstrap' {
            return $firstLine -eq '-- Console-state bootstrap used only by the disposable two-process localhost'
        }
        default { return $false }
    }
}

function Remove-Tpf2mpManagedRuntimeOverlay {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$GameExecutable,
        [string]$ArchiveRoot,
        [switch]$SkipIfGameRunning
    )
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    $running = @(Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        if ($SkipIfGameRunning) {
            return [pscustomobject][ordered]@{
                status = 'in-use'
                removed = 0
                archive = $null
            }
        }
        throw 'Close every Transport Fever 2 instance before cleaning the TPF2MP runtime overlay.'
    }

    $gameRoot = Resolve-Tpf2mpFullPath (Split-Path -Parent $game)
    $resourceRoot = Resolve-Tpf2mpFullPath (Join-Path $gameRoot 'res')
    $resourcePrefix = $resourceRoot.TrimEnd('\') + '\'
    $existing = [Collections.Generic.List[object]]::new()
    foreach ($entry in @(Get-Tpf2mpRuntimeOverlayInventory `
            -BundleRoot $BundleRoot -GameExecutable $game)) {
        $target = Resolve-Tpf2mpFullPath ([string]$entry.target)
        if (-not $target.StartsWith($resourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing runtime-overlay cleanup outside game resources: $target"
        }
        if (-not (Test-Path -LiteralPath $target)) { continue }
        if (-not (Test-Tpf2mpManagedRuntimeOverlayEntry $entry)) {
            throw "Runtime-overlay target is not recognizably managed by TPF2MP; refusing cleanup: $target"
        }
        $existing.Add($entry)
    }
    if ($existing.Count -eq 0) {
        return [pscustomobject][ordered]@{
            status = 'absent'
            removed = 0
            archive = $null
        }
    }

    if (-not $ArchiveRoot) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -ArchiveRoot explicitly.' }
        $ArchiveRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP\backups'
    }
    $archiveBase = Resolve-Tpf2mpFullPath $ArchiveRoot
    New-Item -ItemType Directory -Force -Path $archiveBase | Out-Null
    $archive = Resolve-Tpf2mpFullPath (Join-Path $archiveBase (
        'runtime-overlay-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' `
            + [guid]::NewGuid().ToString('N').Substring(0, 8)))
    $archivePrefix = $archive.TrimEnd('\') + '\'
    New-Item -ItemType Directory -Path $archive | Out-Null
    $moved = [Collections.Generic.List[object]]::new()
    $records = [Collections.Generic.List[object]]::new()
    try {
        foreach ($entry in $existing) {
            $target = Resolve-Tpf2mpFullPath ([string]$entry.target)
            $relative = $target.Substring($gameRoot.TrimEnd('\').Length + 1)
            $destination = Resolve-Tpf2mpFullPath (Join-Path (Join-Path $archive 'game-root') $relative)
            if (-not $destination.StartsWith($archivePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing runtime-overlay archive target outside $archive"
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            $fileCount = if ([bool]$entry.directory) {
                @(Get-ChildItem -LiteralPath $target -Recurse -File -Force).Count
            } else { 1 }
            $sha256 = if (-not [bool]$entry.directory) {
                (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
            } else { $null }
            Move-Item -LiteralPath $target -Destination $destination
            $moved.Add([pscustomobject]@{ source = $target; destination = $destination })
            $records.Add([pscustomobject][ordered]@{
                kind = [string]$entry.kind
                originalPath = $target
                archivedPath = $destination
                directory = [bool]$entry.directory
                fileCount = $fileCount
                sha256 = $sha256
            })
        }
        $manifest = [pscustomobject][ordered]@{
            schemaVersion = 1
            gameExecutable = $game
            archivedAtUtc = [DateTime]::UtcNow.ToString('o')
            entries = $records.ToArray()
        }
        [IO.File]::WriteAllText((Join-Path $archive 'overlay-cleanup.json'),
            ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    }
    catch {
        $cleanupFailure = $_
        for ($index = $moved.Count - 1; $index -ge 0; $index--) {
            $move = $moved[$index]
            try {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $move.source) | Out-Null
                Move-Item -LiteralPath $move.destination -Destination $move.source
            }
            catch { }
        }
        throw $cleanupFailure
    }
    return [pscustomobject][ordered]@{
        status = 'archived'
        removed = $records.Count
        archive = $archive
    }
}
