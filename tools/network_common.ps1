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

function Get-Tpf2mpLatestLocalRestore {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $sessionsRoot = Join-Path (Get-Tpf2mpSupportRoot) 'sessions'
    $companion = Get-Tpf2mpCompanionCommand $BundleRoot
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') {
        $env:PYTHONPATH = Join-Path (Resolve-Tpf2mpFullPath $BundleRoot) 'companion'
    }
    try {
        $output = @(& $companion.FilePath @($companion.Prefix + @(
            'latest-local-restore', '--sessions-root', $sessionsRoot, '--peer', $Peer
        )) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "No verified local restore is ready for ${Peer}: $($output -join ' ')"
        }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
    $candidate = ($output -join "`n") | ConvertFrom-Json
    if ($candidate.peer -ne $Peer -or -not $candidate.planPath -or -not $candidate.savePath) {
        throw 'Local restore discovery returned an incomplete or wrong-peer candidate.'
    }
    return $candidate
}

function Get-Tpf2mpLatestLocalRestorePair {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $sessionsRoot = Join-Path (Get-Tpf2mpSupportRoot) 'sessions'
    $companion = Get-Tpf2mpCompanionCommand $BundleRoot
    $previousPythonPath = $env:PYTHONPATH
    if ($companion.Mode -eq 'source') {
        $env:PYTHONPATH = Join-Path (Resolve-Tpf2mpFullPath $BundleRoot) 'companion'
    }
    try {
        $output = @(& $companion.FilePath @($companion.Prefix + @(
            'latest-local-restore-pair', '--sessions-root', $sessionsRoot
        )) 2>&1)
        if ($LASTEXITCODE -ne 0) {
            throw "No verified two-peer local restore is ready: $($output -join ' ')"
        }
    }
    finally { $env:PYTHONPATH = $previousPythonPath }
    $pair = ($output -join "`n") | ConvertFrom-Json
    if (-not $pair.planPath -or -not $pair.peers.player1.savePath `
            -or -not $pair.peers.player2.savePath) {
        throw 'Local restore-pair discovery returned incomplete metadata.'
    }
    return $pair
}

function Get-Tpf2mpExpectedNativeHookVersion {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $manifestPath = Join-Path $bundle 'release-manifest.json'
    if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $nativeProperty = $manifest.PSObject.Properties['supportedNativeBuild']
            $versionProperty = if ($nativeProperty -and $nativeProperty.Value) {
                $nativeProperty.Value.PSObject.Properties['hookVersion']
            } else { $null }
            if ($versionProperty) {
                $version = [string]$versionProperty.Value
                if ($version -notmatch '^\d+\.\d+\.\d+$') {
                    throw 'Release manifest contains an invalid native hook version.'
                }
                return $version
            }
        }
        catch {
            throw "Could not read the release native-hook version: $($_.Exception.Message)"
        }
        # Bundles published before the hook-version binding remain readable by
        # their own launcher.  A current package always writes the field below.
        return $null
    }

    $sourcePath = Join-Path $bundle 'native\src\hook_dll.cpp'
    if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
        $source = Get-Content -LiteralPath $sourcePath -Raw
        if ($source -match 'native hook (?<version>\d+\.\d+\.\d+)') {
            return [string]$Matches.version
        }
        throw 'Could not derive the required native hook version from source.'
    }
    return $null
}

function Get-Tpf2mpNativePaths {
    param([Parameter(Mandatory = $true)][string]$BundleRoot)
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $expectedHookVersion = Get-Tpf2mpExpectedNativeHookVersion $bundle
    $roots = @(
        (Join-Path $bundle 'bin\native'),
        (Join-Path $bundle 'runtime\native-build\Release')
    )
    foreach ($root in $roots) {
        $injector = Join-Path $root 'tpf2mp_injector.exe'
        $hook = Join-Path $root 'tpf2mp_hook_build35924.dll'
        if ((Test-Path -LiteralPath $injector -PathType Leaf) -and (Test-Path -LiteralPath $hook -PathType Leaf)) {
            return [pscustomobject]@{
                Root = $root
                Injector = $injector
                Hook = $hook
                ExpectedHookVersion = $expectedHookVersion
            }
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

function Assert-Tpf2mpCurrentRestorePlan {
    param([Parameter(Mandatory = $true)][object]$RestorePlan)

    if ([int]$RestorePlan.version -ne 6) {
        throw 'Network resume requires current restore plan v6; older plans do not bind native vehicle route phase and station-round cursors.'
    }
    $proofProperty = $RestorePlan.PSObject.Properties['vehiclePhaseProof']
    $proof = if ($proofProperty) { $proofProperty.Value } else { $null }
    $digestProperty = if ($proof) {
        $proof.PSObject.Properties['vehiclePhaseDigest']
    } else { $null }
    $digest = if ($digestProperty) { [string]$digestProperty.Value } else { '' }
    $roundsProperty = if ($proof) { $proof.PSObject.Properties['vehicleRounds'] } else { $null }
    if (-not $proof -or -not $roundsProperty -or [int]$proof.schemaVersion -ne 1 `
        -or $digest -notmatch '^[0-9a-f]{8}$') {
        throw 'Current restore plan is missing a valid native vehicle phase/cursor proof.'
    }
    return $RestorePlan
}

function Resolve-Tpf2mpRestoreMatchProfile {
    param(
        [Parameter(Mandatory = $true)][object]$RestorePlan,
        [ValidateSet('skeleton', 'vanilla', 'empty')][string]$AgentMode = 'skeleton',
        [bool]$TownDevelopment = $false,
        [bool]$AgentModeExplicit = $false,
        [bool]$TownDevelopmentExplicit = $false
    )
    $version = [int]$RestorePlan.version
    if ($version -lt 3) {
        return [pscustomobject]@{
            agentMode = $AgentMode
            townDevelopment = $TownDevelopment
            legacyUnbound = $true
        }
    }
    if (-not $RestorePlan.PSObject.Properties['matchContentProfile']) {
        throw 'Verified current restore plan omitted its match-content profile.'
    }
    $profile = $RestorePlan.matchContentProfile
    if ([int]$profile.schemaVersion -ne 1 -or $profile.agentMode -notin @('skeleton', 'vanilla', 'empty') `
        -or $profile.townDevelopment -isnot [bool]) {
        throw 'Verified restore plan carries an invalid match-content profile.'
    }
    if ($AgentModeExplicit -and $AgentMode -ne [string]$profile.agentMode) {
        throw "AgentMode conflicts with bound restore plan policy '$($profile.agentMode)'."
    }
    if ($TownDevelopmentExplicit -and $TownDevelopment -ne [bool]$profile.townDevelopment) {
        throw "TownDevelopment conflicts with bound restore plan policy '$($profile.townDevelopment)'."
    }
    return [pscustomobject]@{
        agentMode = [string]$profile.agentMode
        townDevelopment = [bool]$profile.townDevelopment
        legacyUnbound = $false
    }
}

function Read-Tpf2mpSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $path = Join-Path (Get-Tpf2mpSessionRoot $Session $Peer) 'session-state.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $stream = [IO.FileStream]::new(
                $path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            )
            try {
                $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
                try { $raw = $reader.ReadToEnd() }
                finally { $reader.Dispose() }
            }
            finally {
                if ($stream) { $stream.Dispose() }
            }
            if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Session state is empty.' }
            return ($raw | ConvertFrom-Json)
        }
        catch {
            if ($attempt -ge 4) { return $null }
            Start-Sleep -Milliseconds 20
        }
    }
    return $null
}

function Write-Tpf2mpSessionState {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)]$State,
        [ValidateRange(2, 50)][int]$Attempts = 20
    )
    $root = Get-Tpf2mpSessionRoot $Session $Peer
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $path = Join-Path $root 'session-state.json'
    $temporary = Join-Path $root ('.session-state.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temporary + '.previous'
    $json = $State | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    try {
        for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
            try {
                if ([IO.File]::Exists($path)) {
                    [IO.File]::Replace($temporary, $path, $backup, $true)
                }
                else {
                    [IO.File]::Move($temporary, $path)
                }
                return $path
            }
            catch {
                if ($attempt -ge ($Attempts - 1)) { throw }
                Start-Sleep -Milliseconds ([Math]::Min(250, 20 * ($attempt + 1)))
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
        }
    }
}

function Find-Tpf2mpPausedWakeEvidence {
    param(
        [Parameter(Mandatory = $true)][string]$OutboxPath,
        [string]$Session,
        [ValidateSet('', 'player1', 'player2')][string]$Peer = '',
        [string[]]$ExcludeNames = @()
    )
    if (-not (Test-Path -LiteralPath $OutboxPath -PathType Container)) { return $null }
    foreach ($file in Get-ChildItem -LiteralPath $OutboxPath -File -Filter '*.json' `
            -ErrorAction SilentlyContinue | Sort-Object Name -Descending) {
        if ($ExcludeNames -contains $file.Name) { continue }
        try {
            $message = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if (($Session -and [string]$message.session -ne $Session) `
                    -or ($Peer -and [string]$message.peer -ne $Peer)) { continue }
            $eventProperty = $message.payload.PSObject.Properties['event']
            $eventName = if ($eventProperty) { [string]$eventProperty.Value } else { '' }
            if ($message.kind -eq 'clock_health' -or $eventName -eq 'launcher-bootstrap-state') {
                return $file.FullName
            }
            $actionProperty = $message.payload.PSObject.Properties['action']
            $actionType = if ($actionProperty) { [string]$actionProperty.Value.type } else { '' }
            if ($actionType -in @('recovery.resume', 'match.initialise')) { return $file.FullName }
        }
        catch { }
    }
    return $null
}

function Request-Tpf2mpPersistentPausedPump {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [ValidateRange(1, 30)][int]$WaitSeconds = 8
    )
    $receiptPath = Join-Path $BridgePath 'launcher\paused-network-pump'
    $generationPath = Join-Path $BridgePath 'launcher\network-pump-generation'
    $generation = 'wake-' + [DateTime]::UtcNow.Ticks.ToString('x')
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { [IO.File]::Delete($receiptPath) }
    [IO.File]::WriteAllText($generationPath, $generation, [Text.UTF8Encoding]::new($false))
    $receipt = $null
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline -and -not $receipt) {
        $GameProcess.Refresh()
        if ($GameProcess.HasExited) { throw 'Game exited while waiting for its persistent paused-world pump.' }
        if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
            try {
                $candidate = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
                if ([string]$candidate.generation -eq $generation) { $receipt = $candidate }
            }
            catch { }
        }
        if (-not $receipt) { Start-Sleep -Milliseconds 100 }
    }
    return [pscustomobject]@{ generation = $generation; receipt = $receipt; path = $receiptPath }
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

function Get-Tpf2mpTcpListenerOwners {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port)

    $connections = @()
    try {
        $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    }
    catch {
        # No matching listener is reported as an error on some Windows builds.
        return @()
    }
    $owners = New-Object System.Collections.Generic.List[object]
    foreach ($ownerPid in @($connections | Select-Object -ExpandProperty OwningProcess -Unique)) {
        $native = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
        $commandLine = if ($native -and $native.CommandLine) { [string]$native.CommandLine } else { '' }
        $sessionMatch = [Regex]::Match($commandLine,
            '(?:^|\s)--session(?:\s+|=)"?([A-Za-z0-9][A-Za-z0-9._-]{0,63})"?(?=\s|$)')
        $peerMatch = [Regex]::Match($commandLine,
            '(?:^|\s)--peer(?:\s+|=)"?(player1|player2)"?(?=\s|$)')
        $owners.Add([pscustomobject][ordered]@{
            processId = [int]$ownerPid
            processName = if ($native) { [string]$native.Name } else { 'unknown' }
            executablePath = if ($native) { [string]$native.ExecutablePath } else { $null }
            commandLine = $commandLine
            session = if ($sessionMatch.Success) { $sessionMatch.Groups[1].Value } else { $null }
            peer = if ($peerMatch.Success) { $peerMatch.Groups[1].Value } else { $null }
            tpf2mpCompanion = $commandLine -match '(?i)(?:tpf2mp(?:\.exe)?|entrypoint\.py).*(?:host|client)'
        })
    }
    return @($owners | ForEach-Object { $_ })
}

function Assert-Tpf2mpHostPortAvailable {
    param(
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Session
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $owners = @(Get-Tpf2mpTcpListenerOwners -Port $Port)
    if ($owners.Count -eq 0) { return }
    $owner = $owners[0]
    $identity = if ($owner.tpf2mpCompanion -and $owner.session) {
        "TPF2MP session '$($owner.session)'"
    }
    else { "process '$($owner.processName)'" }
    throw "TCP port $Port is already occupied by $identity (PID $($owner.processId)). Stop the old session or choose another port before hosting '$safeSession'."
}

function Assert-Tpf2mpLoopbackJoinTarget {
    param(
        [Parameter(Mandatory = $true)][string]$HostAddress,
        [Parameter(Mandatory = $true)][ValidateRange(1, 65535)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Session
    )
    if ($HostAddress -notin @('127.0.0.1', 'localhost', '::1')) { return }
    $safeSession = Assert-Tpf2mpSessionId $Session
    foreach ($owner in @(Get-Tpf2mpTcpListenerOwners -Port $Port)) {
        if ($owner.tpf2mpCompanion -and $owner.session -and $owner.session -ne $safeSession) {
            throw "Local port $Port belongs to TPF2MP session '$($owner.session)', not '$safeSession'. Stop the old host or copy its exact session name before joining."
        }
    }
}
