Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release_common.ps1')

function Assert-Tpf2mpSessionId {
    param([Parameter(Mandatory = $true)][string]$Session)
    if ($Session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Session must be 1-64 characters and contain only letters, digits, dot, underscore, or hyphen.'
    }
    return $Session
}

function Get-Tpf2mpSupportRoot {
    if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable.' }
    return (Resolve-Tpf2mpFullPath (Join-Path $env:LOCALAPPDATA 'TPF2MP'))
}

function Get-Tpf2mpSessionRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    return (Resolve-Tpf2mpFullPath (Join-Path (Get-Tpf2mpSupportRoot) "sessions\$safeSession\$Peer"))
}

function Get-Tpf2mpCompanionCommand {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $packaged = Join-Path $bundle 'bin\tpf2mp.exe'
    if (Test-Path -LiteralPath $packaged -PathType Leaf) {
        return [pscustomobject]@{ FilePath = $packaged; Prefix = @(); Mode = 'packaged' }
    }
    $entrypoint = Join-Path $bundle 'companion\entrypoint.py'
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "Neither packaged nor source companion was found under $bundle"
    }
    $python = $null
    foreach ($candidate in @('python.exe', 'py.exe', 'C:\Users\Sepgi\AppData\Local\Programs\Python\Python310\python.exe')) {
        try {
            $resolved = Get-Command $candidate -ErrorAction Stop
            & $resolved.Source --version *> $null
            if ($LASTEXITCODE -eq 0) { $python = $resolved.Source; break }
        }
        catch { }
    }
    if (-not $python) { throw 'Python 3 was not found for the development companion.' }
    return [pscustomobject]@{ FilePath = $python; Prefix = @($entrypoint); Mode = 'source' }
}

function Get-Tpf2mpNativePaths {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $roots = @(
        (Join-Path $bundle 'bin\native'),
        (Join-Path $bundle 'runtime\native-build\Release')
    )
    foreach ($root in $roots) {
        $injector = Join-Path $root 'tpf2mp_injector.exe'
        $hook = Join-Path $root 'tpf2mp_hook_build35924.dll'
        if ((Test-Path -LiteralPath $injector -PathType Leaf) -and (Test-Path -LiteralPath $hook -PathType Leaf)) {
            return [pscustomobject]@{ Root = $root; Injector = $injector; Hook = $hook }
        }
    }
    throw 'Built native injector/hook was not found in the bundle or development runtime.'
}

function ConvertTo-Tpf2mpCommandLine {
    param([Parameter(Mandatory = $true)][object[]]$Arguments)
    $quoted = foreach ($argument in $Arguments) {
        $value = [string]$argument
        if ($value -notmatch '[\s"]') { $value; continue }
        '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }
    return ($quoted -join ' ')
}

function Write-Tpf2mpLauncherConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
        [bool]$TownDevelopment = $false,
        [ValidateRange(5, 1440)][int]$LifetimeMinutes = 360
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    if ($BridgePath -match '[\r\n]') { throw 'Bridge path contains a newline.' }
    $directory = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_launcher')
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    $path = Join-Path $directory 'active.ini'
    $expires = [DateTimeOffset]::UtcNow.AddMinutes($LifetimeMinutes).ToUnixTimeSeconds()
    $lines = @(
        'schemaVersion=1',
        "expiresAtUnix=$expires",
        "sessionId=$safeSession",
        "peerId=$Peer",
        "bridgeDir=$BridgePath",
        'startNetwork=true',
        "agentMode=$AgentMode",
        ('townDevelopment=' + $TownDevelopment.ToString().ToLowerInvariant())
    )
    [IO.File]::WriteAllLines($path, $lines, [Text.UTF8Encoding]::new($false))
    return $path
}

function Write-Tpf2mpMatchContentProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
        [bool]$TownDevelopment = $false
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $resolved
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    # Explicit byte spelling keeps the manifest component identical across
    # PowerShell editions, machines, roles, and peer-local directory names.
    $payload = '{"schemaVersion":1,"agentMode":"' + $AgentMode `
        + '","townDevelopment":' + $TownDevelopment.ToString().ToLowerInvariant() + "}`n"
    [IO.File]::WriteAllText($resolved, $payload, [Text.UTF8Encoding]::new($false))
    return $resolved
}

function Read-Tpf2mpSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $path = Join-Path (Get-Tpf2mpSessionRoot $Session $Peer) 'session-state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) }
    catch { return $null }
}

function Test-Tpf2mpCompanionCommandLine {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $sessionPattern = '(?:^|\s)--session(?:\s+|=)' + [Regex]::Escape($safeSession) + '(?=\s|$)'
    $peerPattern = '(?:^|\s)--peer(?:\s+|=)' + [Regex]::Escape($Peer) + '(?=\s|$)'
    return $CommandLine -match $sessionPattern -and $CommandLine -match $peerPattern
}

function Get-Tpf2mpVerifiedCompanionProcess {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [string]$ExecutablePath
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $process -or $process.HasExited) { return $null }
    $native = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if (-not $native -or -not $native.CommandLine) { return $null }
    if (-not (Test-Tpf2mpCompanionCommandLine -CommandLine ([string]$native.CommandLine) `
            -Session $safeSession -Peer $Peer)) {
        return $null
    }
    if ($ExecutablePath) {
        $expected = Resolve-Tpf2mpFullPath $ExecutablePath
        if (-not $native.ExecutablePath `
            -or -not [string]::Equals(
                (Resolve-Tpf2mpFullPath ([string]$native.ExecutablePath)),
                $expected,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return $null
        }
    }
    return $process
}
