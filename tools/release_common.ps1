Set-StrictMode -Version Latest

$script:Tpf2AppId = 1066780
$script:Tpf2ExeHash = '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c'

function Resolve-Tpf2mpFullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path))
}

function Get-Tpf2mpSteamRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    try {
        $steam = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction Stop
        if ($steam.SteamPath) { $candidates.Add([string]$steam.SteamPath) }
    }
    catch { }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'Steam')) }
    foreach ($candidate in $candidates) {
        $resolved = Resolve-Tpf2mpFullPath $candidate
        if (Test-Path -LiteralPath (Join-Path $resolved 'steam.exe') -PathType Leaf) { return $resolved }
    }
    return $null
}

function Get-Tpf2mpLibraryRoots {
    $result = New-Object System.Collections.Generic.List[string]
    $steamRoot = Get-Tpf2mpSteamRoot
    if ($steamRoot) { $result.Add($steamRoot) }
    if ($steamRoot) {
        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $libraryFile -PathType Leaf) {
            foreach ($line in Get-Content -LiteralPath $libraryFile -ErrorAction SilentlyContinue) {
                if ($line -match '^\s*"path"\s+"(.+)"\s*$') {
                    $candidate = $matches[1] -replace '\\\\', '\'
                    try { $candidate = Resolve-Tpf2mpFullPath $candidate } catch { continue }
                    if (-not $result.Contains($candidate)) { $result.Add($candidate) }
                }
            }
        }
    }
    return @($result)
}

function Find-Tpf2mpGameExecutable {
    param([string]$GameExecutable)
    if ($GameExecutable) {
        $resolved = Resolve-Tpf2mpFullPath $GameExecutable
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) { throw "Game executable is missing: $resolved" }
        return $resolved
    }
    foreach ($library in Get-Tpf2mpLibraryRoots) {
        $candidate = Join-Path $library 'steamapps\common\Transport Fever 2\TransportFever2.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Tpf2mpFullPath $candidate) }
    }
    return $null
}

function Find-Tpf2mpLocalModsPath {
    param([string]$LocalModsPath)
    if ($LocalModsPath) {
        $resolved = Resolve-Tpf2mpFullPath $LocalModsPath
    }
    else {
        $steamRoot = Get-Tpf2mpSteamRoot
        if (-not $steamRoot) { throw 'Steam userdata was not found; pass -LocalModsPath explicitly.' }
        $userdata = Join-Path $steamRoot 'userdata'
        $candidates = @()
        if (Test-Path -LiteralPath $userdata -PathType Container) {
            $candidates = @(Get-ChildItem -LiteralPath $userdata -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $localRoot = Join-Path $_.FullName "$script:Tpf2AppId\local"
                if (Test-Path -LiteralPath $localRoot -PathType Container) {
                    [pscustomobject]@{
                        Path = Join-Path $localRoot 'mods'
                        LastWriteTimeUtc = (Get-Item -LiteralPath $localRoot).LastWriteTimeUtc
                    }
                }
            } | Sort-Object LastWriteTimeUtc -Descending)
        }
        if ($candidates.Count -eq 0) {
            throw 'No Transport Fever 2 Steam userdata profile was found; launch the game once or pass -LocalModsPath.'
        }
        $resolved = Resolve-Tpf2mpFullPath $candidates[0].Path
        if ($candidates.Count -gt 1) {
            Write-Warning "Multiple Transport Fever 2 userdata profiles found; selected most recently used path: $resolved"
        }
    }
    $normalized = $resolved.TrimEnd('\')
    if ($normalized -notmatch '(?i)\\1066780\\local\\mods$') {
        throw "Refusing unexpected mod root (must end in \\1066780\\local\\mods): $resolved"
    }
    return $normalized
}

function Assert-Tpf2mpModTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$LocalModsPath
    )
    $resolvedTarget = Resolve-Tpf2mpFullPath $Target
    $resolvedRoot = (Resolve-Tpf2mpFullPath $LocalModsPath).TrimEnd('\')
    $expected = Resolve-Tpf2mpFullPath (Join-Path $resolvedRoot 'tpf2_mp_1')
    if (-not $resolvedTarget.Equals($expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing mod operation outside exact target $expected (received $resolvedTarget)"
    }
    return $resolvedTarget
}

function Test-Tpf2mpReleaseManifest {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $resolvedRoot = Resolve-Tpf2mpFullPath $BundleRoot
    $manifestPath = Join-Path $resolvedRoot 'release-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Release manifest is missing: $manifestPath"
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    foreach ($file in @($manifest.files)) {
        $relative = [string]$file.path
        if ([IO.Path]::IsPathRooted($relative) -or $relative.Contains('..')) {
            throw "Unsafe release manifest path: $relative"
        }
        $path = Resolve-Tpf2mpFullPath (Join-Path $resolvedRoot ($relative -replace '/', '\'))
        $prefix = $resolvedRoot.TrimEnd('\') + '\'
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Release manifest path escapes bundle: $relative"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Release file is missing: $relative" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne ([string]$file.sha256).ToLowerInvariant()) {
            throw "Release checksum mismatch: $relative"
        }
    }
    return $manifest
}

function Initialize-Tpf2mpBridge {
    param([switch]$Reset)
    $bridgeBase = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_bridge')
    foreach ($peer in @('player1', 'player2')) {
        $peerPath = Resolve-Tpf2mpFullPath (Join-Path $bridgeBase $peer)
        $prefix = $bridgeBase.TrimEnd('\') + '\'
        if (-not $peerPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing bridge operation outside $bridgeBase"
        }
        if ($Reset -and (Test-Path -LiteralPath $peerPath)) {
            Remove-Item -LiteralPath $peerPath -Recurse -Force
        }
        foreach ($folder in @('game_outbox', 'game_inbox', 'companion_state', 'audit',
                'content\industry')) {
            New-Item -ItemType Directory -Force -Path (Join-Path $peerPath $folder) | Out-Null
        }
    }
    return $bridgeBase
}
