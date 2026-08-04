Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')

$script:Tpf2mpMenuBootstrapRelative = 'res/scripts/tpf2mp_multiplayer_menu_bootstrap.lua'

function Find-Tpf2mpSaveDirectory {
    param([string]$SaveDirectory, [string]$LocalModsPath)
    if ($SaveDirectory) {
        $resolved = Resolve-Tpf2mpFullPath $SaveDirectory
    }
    else {
        $mods = Find-Tpf2mpLocalModsPath $LocalModsPath
        $resolved = Resolve-Tpf2mpFullPath (Join-Path (Split-Path -Parent $mods) 'save')
    }
    if ($resolved.TrimEnd('\') -notmatch '(?i)\\1066780\\local\\save$') {
        throw "Refusing unexpected save root (must end in \\1066780\\local\\save): $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "Transport Fever 2 save directory is missing: $resolved"
    }
    return $resolved.TrimEnd('\')
}

function Get-Tpf2mpSaveTriplet {
    param([Parameter(Mandatory = $true)][string]$SavePath)
    $save = Resolve-Tpf2mpFullPath $SavePath
    if ([IO.Path]::GetExtension($save) -ine '.sav') {
        throw 'A Transport Fever 2 starting save must name a .sav file.'
    }
    $metadata = $save + '.lua'
    if (-not (Test-Path -LiteralPath $save -PathType Leaf)) {
        throw "Starting save is missing: $save"
    }
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) {
        throw "Starting save metadata is missing: $metadata"
    }
    $paths = @($save, $metadata)
    $image = [IO.Path]::ChangeExtension($save, '.jpg')
    if (Test-Path -LiteralPath $image -PathType Leaf) { $paths += $image }
    $files = @($paths | ForEach-Object {
        $item = Get-Item -LiteralPath $_
        [pscustomobject][ordered]@{
            path = $item.FullName
            name = $item.Name
            bytes = [int64]$item.Length
            sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    return [pscustomobject][ordered]@{
        save = $save
        metadata = $metadata
        image = if (Test-Path -LiteralPath $image -PathType Leaf) { $image } else { $null }
        files = $files
    }
}

function Copy-Tpf2mpPinnedStartingSave {
    param(
        [Parameter(Mandatory = $true)][string]$SourceSave,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory
    )
    $source = Get-Tpf2mpSaveTriplet $SourceSave
    $destinationRoot = Resolve-Tpf2mpFullPath $DestinationDirectory
    New-Item -ItemType Directory -Force -Path $destinationRoot | Out-Null
    $destinationSave = Join-Path $destinationRoot 'starting-world.sav'
    $copies = @(
        [pscustomobject]@{ Source = $source.save; Destination = $destinationSave },
        [pscustomobject]@{ Source = $source.metadata; Destination = $destinationSave + '.lua' }
    )
    if ($source.image) {
        $copies += [pscustomobject]@{
            Source = $source.image
            Destination = [IO.Path]::ChangeExtension($destinationSave, '.jpg')
        }
    }
    foreach ($copy in $copies) {
        if (Test-Path -LiteralPath $copy.Destination) {
            throw "Refusing to overwrite pinned starting-save file: $($copy.Destination)"
        }
    }
    $created = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($copy in $copies) {
            Copy-Item -LiteralPath $copy.Source -Destination $copy.Destination
            $created.Add([string]$copy.Destination)
        }
        $files = @($created | ForEach-Object {
            $item = Get-Item -LiteralPath $_
            [pscustomobject][ordered]@{
                path = $item.FullName
                name = $item.Name
                bytes = [int64]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        for ($index = 0; $index -lt $copies.Count; $index++) {
            if ((Get-FileHash -LiteralPath $copies[$index].Source -Algorithm SHA256).Hash -ne `
                (Get-FileHash -LiteralPath $copies[$index].Destination -Algorithm SHA256).Hash) {
                throw "Pinned starting-save verification failed: $($copies[$index].Destination)"
            }
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            sourceSave = $source.save
            savePath = $destinationSave
            copiedAtUtc = [DateTime]::UtcNow.ToString('o')
            files = $files
        }
    }
    catch {
        foreach ($path in $created) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
}

function New-Tpf2mpStagedStartingSave {
    param(
        [Parameter(Mandatory = $true)][string]$SourceSave,
        [Parameter(Mandatory = $true)][string]$SaveDirectory,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer
    )
    $safeSession = Assert-Tpf2mpSessionId $Session
    $saveRoot = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory
    $source = Get-Tpf2mpSaveTriplet $SourceSave
    $nonce = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $baseName = "tpf2mp_${safeSession}_${Peer}_$nonce"
    $destinationSave = Resolve-Tpf2mpFullPath (Join-Path $saveRoot ($baseName + '.sav'))
    $savePrefix = $saveRoot.TrimEnd('\') + '\'
    if (-not $destinationSave.StartsWith($savePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to stage a save outside $saveRoot"
    }
    $copies = @(
        [pscustomobject]@{ Source = $source.save; Destination = $destinationSave },
        [pscustomobject]@{ Source = $source.metadata; Destination = $destinationSave + '.lua' }
    )
    if ($source.image) {
        $copies += [pscustomobject]@{
            Source = $source.image
            Destination = [IO.Path]::ChangeExtension($destinationSave, '.jpg')
        }
    }
    foreach ($copy in $copies) {
        if (Test-Path -LiteralPath $copy.Destination) {
            throw "Refusing to overwrite staged save file: $($copy.Destination)"
        }
    }
    $created = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($copy in $copies) {
            Copy-Item -LiteralPath $copy.Source -Destination $copy.Destination
            $created.Add([string]$copy.Destination)
        }
        $newest = [DateTime]::UtcNow.AddSeconds(1)
        foreach ($path in $created) { (Get-Item -LiteralPath $path).LastWriteTimeUtc = $newest }
        $files = @($created | ForEach-Object {
            $item = Get-Item -LiteralPath $_
            [pscustomobject][ordered]@{
                path = $item.FullName
                name = $item.Name
                bytes = [int64]$item.Length
                sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
        for ($index = 0; $index -lt $copies.Count; $index++) {
            $sourceHash = (Get-FileHash -LiteralPath $copies[$index].Source -Algorithm SHA256).Hash
            $destinationHash = (Get-FileHash -LiteralPath $copies[$index].Destination -Algorithm SHA256).Hash
            if ($sourceHash -ne $destinationHash) {
                throw "Staged save verification failed: $($copies[$index].Destination)"
            }
        }
        return [pscustomobject][ordered]@{
            schemaVersion = 1
            session = $safeSession
            peer = $Peer
            sourceSave = $source.save
            saveDirectory = $saveRoot
            baseName = $baseName
            savePath = $destinationSave
            createdAtUtc = [DateTime]::UtcNow.ToString('o')
            files = $files
        }
    }
    catch {
        foreach ($path in $created) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
}

function Remove-Tpf2mpStagedStartingSave {
    param([Parameter(Mandatory = $true)]$Manifest)
    $saveRoot = Resolve-Tpf2mpFullPath ([string]$Manifest.saveDirectory)
    $prefix = $saveRoot.TrimEnd('\') + '\'
    foreach ($file in @($Manifest.files)) {
        $path = Resolve-Tpf2mpFullPath ([string]$file.path)
        if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) `
            -or -not [IO.Path]::GetFileName($path).StartsWith('tpf2mp_', [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing unsafe staged-save cleanup target: $path"
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $observed = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($observed -ne [string]$file.sha256) {
            throw "Refusing to remove changed staged-save file: $path"
        }
        Remove-Item -LiteralPath $path -Force
    }
}

function Install-Tpf2mpMenuBootstrap {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$GameExecutable
    )
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    $gameRoot = Split-Path -Parent $game
    $source = Join-Path $bundle 'tools\multiplayer_menu_bootstrap.lua'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Menu bootstrap source is missing: $source"
    }
    $target = Resolve-Tpf2mpFullPath (Join-Path $gameRoot ($script:Tpf2mpMenuBootstrapRelative -replace '/', '\'))
    $resourceRoot = Resolve-Tpf2mpFullPath (Join-Path $gameRoot 'res')
    if (-not $target.StartsWith($resourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing menu bootstrap target outside the game resources: $target"
    }
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $created = $false
    $updated = $false
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($targetHash -ne $sourceHash) {
            $firstLine = [string](Get-Content -LiteralPath $target -TotalCount 1)
            if ($firstLine -ne '-- Console-state main-menu bootstrap for launcher-managed TPF2MP sessions.') {
                throw "Existing menu bootstrap is not a managed TPF2MP file: $target"
            }
            Copy-Item -LiteralPath $source -Destination $target -Force
            $updated = $true
        }
    }
    else {
        Copy-Item -LiteralPath $source -Destination $target
        $created = $true
    }
    if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sourceHash) {
        throw "Menu bootstrap verification failed: $target"
    }
    return [pscustomobject][ordered]@{
        source = $source
        target = $target
        sha256 = $sourceHash
        created = $created
        updated = $updated
    }
}

function Enable-Tpf2mpDirectLaunch {
    param([Parameter(Mandatory = $true)][string]$GameExecutable)
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    $marker = Join-Path (Split-Path -Parent $game) 'steam_appid.txt'
    $created = $false
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
        if ((Get-Content -LiteralPath $marker -Raw).Trim() -ne [string]$script:Tpf2AppId) {
            throw "Existing steam_appid.txt belongs to another application: $marker"
        }
    }
    else {
        [IO.File]::WriteAllText($marker, [string]$script:Tpf2AppId, [Text.UTF8Encoding]::new($false))
        $created = $true
    }
    return [pscustomobject][ordered]@{ path = $marker; created = $created; appId = $script:Tpf2AppId }
}

function Install-Tpf2mpRuntimeOverlay {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$GameExecutable
    )
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $gameRoot = Split-Path -Parent (Resolve-Tpf2mpFullPath $GameExecutable)
    $gameResourceRoot = Resolve-Tpf2mpFullPath (Join-Path $gameRoot 'res')
    $sourceResourceRoot = Resolve-Tpf2mpFullPath (Join-Path $bundle 'tpf2_mp_1\res')
    $specifications = @(
        [pscustomobject]@{
            source = Join-Path $sourceResourceRoot 'config\game_script\tpf2_mp.lua'
            target = Join-Path $gameResourceRoot 'config\game_script\tpf2_mp.lua'
            directory = $false
        },
        [pscustomobject]@{
            source = Join-Path $sourceResourceRoot 'scripts\tpf2_mp'
            target = Join-Path $gameResourceRoot 'scripts\tpf2_mp'
            directory = $true
        }
    )
    $result = New-Object System.Collections.Generic.List[object]
    $created = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($specification in $specifications) {
            $source = Resolve-Tpf2mpFullPath ([string]$specification.source)
            $target = Resolve-Tpf2mpFullPath ([string]$specification.target)
            if (-not $target.StartsWith($gameResourceRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing runtime overlay target outside game resources: $target"
            }
            if (-not (Test-Path -LiteralPath $source)) { throw "Runtime overlay source is missing: $source" }
            $wasCreated = $false
            $wasUpdated = $false
            if ($specification.directory) {
                if (Test-Path -LiteralPath $target) {
                    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
                        throw "Runtime overlay target is not a directory: $target"
                    }
                    $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
                        $_.FullName.Substring($source.TrimEnd('\').Length + 1)
                    } | Sort-Object)
                    $targetFiles = @(Get-ChildItem -LiteralPath $target -Recurse -File | ForEach-Object {
                        $_.FullName.Substring($target.TrimEnd('\').Length + 1)
                    } | Sort-Object)
                    if (($sourceFiles -join "`n") -ne ($targetFiles -join "`n")) {
                        throw "Existing runtime overlay has a different file set: $target"
                    }
                    $managedMarker = Join-Path $target 'world.lua'
                    if (-not (Test-Path -LiteralPath $managedMarker -PathType Leaf) `
                        -or -not (Select-String -LiteralPath $managedMarker -SimpleMatch `
                            'local canonical = require "tpf2_mp/canonical"' -Quiet)) {
                        throw "Existing runtime library is not a managed TPF2MP overlay: $target"
                    }
                    foreach ($relative in $sourceFiles) {
                        if ((Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256).Hash -ne `
                            (Get-FileHash -LiteralPath (Join-Path $target $relative) -Algorithm SHA256).Hash) {
                            Copy-Item -LiteralPath (Join-Path $source $relative) `
                                -Destination (Join-Path $target $relative) -Force
                            $wasUpdated = $true
                        }
                    }
                }
                else {
                    Copy-Item -LiteralPath $source -Destination $target -Recurse
                    $created.Add($target)
                    $wasCreated = $true
                }
            }
            else {
                if (Test-Path -LiteralPath $target -PathType Leaf) {
                    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne `
                        (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash) {
                        if (-not (Select-String -LiteralPath $target -SimpleMatch `
                            'local util = require "tpf2_mp/util"' -Quiet)) {
                            throw "Existing runtime game script is not a managed TPF2MP overlay: $target"
                        }
                        Copy-Item -LiteralPath $source -Destination $target -Force
                        $wasUpdated = $true
                    }
                }
                else {
                    Copy-Item -LiteralPath $source -Destination $target
                    $created.Add($target)
                    $wasCreated = $true
                }
            }
            $hashes = if ($specification.directory) {
                @(Get-ChildItem -LiteralPath $target -Recurse -File | Sort-Object FullName | ForEach-Object {
                    [pscustomobject][ordered]@{
                        relativePath = $_.FullName.Substring($target.TrimEnd('\').Length + 1)
                        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
                    }
                })
            }
            else {
                @([pscustomobject][ordered]@{
                    relativePath = [IO.Path]::GetFileName($target)
                    sha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
                })
            }
            $result.Add([pscustomobject][ordered]@{
                source = $source
                target = $target
                directory = [bool]$specification.directory
                created = $wasCreated
                updated = $wasUpdated
                files = $hashes
            })
        }
        return $result.ToArray()
    }
    catch {
        foreach ($path in @($created | Sort-Object Length -Descending)) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            }
            elseif (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
        throw
    }
}

function Initialize-Tpf2mpMenuBridge {
    param([Parameter(Mandatory = $true)][string]$BridgePath)
    $launcher = Resolve-Tpf2mpFullPath (Join-Path $BridgePath 'launcher')
    New-Item -ItemType Directory -Force -Path $launcher | Out-Null
    foreach ($name in @('menu_status.json', 'menu_tree.txt', 'load_menu_tree.txt', 'load-request',
        'menu-entry-selected', 'save-selected', 'start-clicked')) {
        $path = Join-Path $launcher $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
    }
    return $launcher
}

function Start-Tpf2mpDirectGame {
    param(
        [Parameter(Mandatory = $true)][string]$GameExecutable,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$SessionRoot,
        [string]$StagedSaveBaseName,
        [switch]$RequireMenuEntry,
        [switch]$StartNetwork
    )
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    $gameRoot = Split-Path -Parent $game
    $safeSession = Assert-Tpf2mpSessionId $Session
    $launcher = Initialize-Tpf2mpMenuBridge $BridgePath
    if ($StagedSaveBaseName -and -not $RequireMenuEntry) {
        [IO.File]::WriteAllText((Join-Path $launcher 'load-request'), 'load', [Text.UTF8Encoding]::new($false))
    }
    $stdout = Join-Path $SessionRoot 'game.stdout.log'
    $stderr = Join-Path $SessionRoot 'game.stderr.log'
    $environment = [ordered]@{
        SteamAppId = [string]$script:Tpf2AppId
        SteamGameId = [string]$script:Tpf2AppId
        TPF2MP_PEER_ID = $Peer
        TPF2MP_SESSION_ID = $safeSession
        TPF2MP_BRIDGE_DIR = (Resolve-Tpf2mpFullPath $BridgePath)
        TPF2MP_START_NETWORK = if ($StartNetwork) { '1' } else { '0' }
        TPF2MP_STAGED_SAVE_NAME = [string]$StagedSaveBaseName
        TPF2MP_REQUIRE_MENU_ENTRY = if ($RequireMenuEntry) { '1' } else { '0' }
    }
    $previous = @{}
    try {
        foreach ($entry in $environment.GetEnumerator()) {
            $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $process = Start-Process -FilePath $game -WorkingDirectory $gameRoot -WindowStyle Normal -PassThru `
            -ArgumentList @('--script', $script:Tpf2mpMenuBootstrapRelative) `
            -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    }
    finally {
        foreach ($entry in $environment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $previous[$entry.Key], 'Process')
        }
    }
    return [pscustomobject][ordered]@{ process = $process; stdout = $stdout; stderr = $stderr; launcher = $launcher }
}

function Add-Tpf2mpNativeHook {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)]$NativePaths,
        [ValidateRange(1000, 120000)][int]$WaitMilliseconds = 60000
    )
    # Keep the injector's useful profile/signature diagnostics visible without
    # allowing them onto this function's success pipeline.  Callers assign the
    # return value and require exactly one status-file string.
    & $NativePaths.Injector --pid $GameProcess.Id --dll $NativePaths.Hook --wait-ms $WaitMilliseconds |
        ForEach-Object { Write-Host $_ }
    $injectorExitCode = $LASTEXITCODE
    if ($injectorExitCode -ne 0) {
        throw "Native hook injection failed for game PID $($GameProcess.Id) with exit code $injectorExitCode"
    }
    $statusPath = Join-Path (Join-Path ([IO.Path]::GetTempPath()) 'tpf2mp_native') "status-$($GameProcess.Id).json"
    return [string]$statusPath
}

function Read-Tpf2mpMenuStatus {
    param(
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Peer
    )
    $path = Join-Path $BridgePath 'launcher\menu_status.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try {
        # The title-screen Lua sandbox cannot rename files, so it replaces this
        # short document in place.  An overlapping read can therefore observe
        # an empty file or a valid JSON scalar (for example the prefix "null")
        # before the complete object lands.  Treat every incomplete snapshot as
        # transient; callers poll at 100 ms and never need to fail the session.
        $raw = [IO.File]::ReadAllText($path)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $status = $raw | ConvertFrom-Json
    }
    catch { return $null }
    if ($null -eq $status) { return $null }
    $properties = @($status.PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($required in @('schemaVersion', 'session', 'peer', 'stage', 'components', 'error')) {
        if ($properties -notcontains $required) { return $null }
    }
    if ($status.session -ne $Session -or $status.peer -ne $Peer) { return $null }
    return $status
}

function Wait-Tpf2mpMenuStage {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Peer,
        [Parameter(Mandatory = $true)][string[]]$Stage,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $GameProcess.Refresh()
        if ($GameProcess.HasExited) {
            throw "Game PID $($GameProcess.Id) exited before menu stage '$($Stage -join ',')'."
        }
        $status = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $Session -Peer $Peer
        if ($status -and $status.error) { throw "Menu bootstrap failed: $($status.error)" }
        if ($status -and $Stage -contains [string]$status.stage) { return $status }
        Start-Sleep -Milliseconds 100
    }
    throw "Game PID $($GameProcess.Id) did not reach menu stage '$($Stage -join ',')' within $TimeoutSeconds seconds."
}

function Wait-Tpf2mpMainMenuEntry {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][string]$Peer,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $GameProcess.Refresh()
        if ($GameProcess.HasExited) {
            throw "Game PID $($GameProcess.Id) exited before the TPF2MP main-menu entry was ready."
        }
        $status = Read-Tpf2mpMenuStatus -BridgePath $BridgePath -Session $Session -Peer $Peer
        if ($status -and $status.error) { throw "Menu bootstrap failed: $($status.error)" }
        if ($status -and $status.stage -eq 'main-menu' -and $status.entryInstalled -eq $true `
            -and $status.components -and $status.components.multiplayerRect) {
            return $status
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Game PID $($GameProcess.Id) did not expose the TPF2MP MULTIPLAYER entry within $TimeoutSeconds seconds."
}

function Invoke-Tpf2mpUiRectangleClick {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)]$Rectangle,
        [Parameter(Mandatory = $true)]$MenuRectangle,
        [Parameter(Mandatory = $true)][string]$ReceiptPath
    )
    foreach ($field in @('x', 'y', 'w', 'h')) {
        if ($null -eq $Rectangle.PSObject.Properties[$field] -or $null -eq $Rectangle.$field) {
            throw "Native UI rectangle is missing '$field'."
        }
    }
    if ($Rectangle.w -le 0 -or $Rectangle.h -le 0 -or $MenuRectangle.w -le 0 -or $MenuRectangle.h -le 0) {
        throw 'Native UI rectangle is empty.'
    }
    $helper = Join-Path $PSScriptRoot 'send_game_console.ps1'
    $x = [int][Math]::Floor([double]$Rectangle.x + [double]$Rectangle.w / 2)
    $y = [int][Math]::Floor([double]$Rectangle.y + [double]$Rectangle.h / 2)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper `
        -GameProcessId $GameProcess.Id -Action click-ui -ClientX $x -ClientY $y `
        -UiWidth ([int]$MenuRectangle.w) -UiHeight ([int]$MenuRectangle.h) `
        -DelayMilliseconds 0 -ResultPath $ReceiptPath
    if ($LASTEXITCODE -ne 0) { throw "Native UI click helper exited $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) {
        throw "Native UI click receipt is missing: $ReceiptPath"
    }
}

function Invoke-Tpf2mpPinnedSaveLoad {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][string]$ExpectedSaveBaseName,
        [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 180
    )
    New-Item -ItemType Directory -Force -Path $EvidenceDirectory | Out-Null
    $load = Wait-Tpf2mpMenuStage $GameProcess $BridgePath $Session $Peer `
        -Stage @('ready-to-click-load-game') -TimeoutSeconds $TimeoutSeconds
    Invoke-Tpf2mpUiRectangleClick $GameProcess $load.components.loadGameRect $load.components.menuRect `
        (Join-Path $EvidenceDirectory 'click-load-game.json')

    $save = Wait-Tpf2mpMenuStage $GameProcess $BridgePath $Session $Peer `
        -Stage @('ready-to-click-pinned-save') -TimeoutSeconds $TimeoutSeconds
    if ([string]$save.components.expectedSave -ne $ExpectedSaveBaseName `
        -or $save.components.expectedSaveVisible -ne $true) {
        throw "Pinned save '$ExpectedSaveBaseName' is not visible in the native Load Game page."
    }
    Invoke-Tpf2mpUiRectangleClick $GameProcess $save.components.expectedSaveRect $save.components.menuRect `
        (Join-Path $EvidenceDirectory 'click-pinned-save.json')
    [IO.File]::WriteAllText((Join-Path $BridgePath 'launcher\save-selected'), $ExpectedSaveBaseName, [Text.UTF8Encoding]::new($false))

    $start = Wait-Tpf2mpMenuStage $GameProcess $BridgePath $Session $Peer `
        -Stage @('ready-to-click-start-selected-save') -TimeoutSeconds $TimeoutSeconds
    Invoke-Tpf2mpUiRectangleClick $GameProcess $start.components.startGameRect $start.components.menuRect `
        (Join-Path $EvidenceDirectory 'click-start-game.json')
    [IO.File]::WriteAllText((Join-Path $BridgePath 'launcher\start-clicked'), 'start', [Text.UTF8Encoding]::new($false))

    $transition = Wait-Tpf2mpMenuStage $GameProcess $BridgePath $Session $Peer `
        -Stage @('starting-selected-save', 'world-transition') -TimeoutSeconds $TimeoutSeconds
    $receipt = [ordered]@{
        schemaVersion = 1
        processId = $GameProcess.Id
        session = $Session
        peer = $Peer
        expectedSave = $ExpectedSaveBaseName
        stage = [string]$transition.stage
        completedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $receiptPath = Join-Path $EvidenceDirectory 'native-save-load.json'
    $receipt | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    return [pscustomobject]$receipt
}

function Wait-Tpf2mpNativeWorld {
    param(
        [Parameter(Mandatory = $true)]$GameProcess,
        [Parameter(Mandatory = $true)][string]$NativeStatusPath,
        [ValidateRange(30, 600)][int]$TimeoutSeconds = 240,
        [switch]$RequireGameScriptObserver,
        [switch]$RequireAuthorityGates
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $GameProcess.Refresh()
        if ($GameProcess.HasExited) { throw "Game PID $($GameProcess.Id) exited while loading its world." }
        $status = $null
        if (Test-Path -LiteralPath $NativeStatusPath -PathType Leaf) {
            try { $status = Get-Content -LiteralPath $NativeStatusPath -Raw | ConvertFrom-Json } catch { }
        }
        if ($status -and $status.active -eq $true -and $status.hooks.enabled -eq $true `
            -and [int64]$status.setupCommandInterface.calls -gt 0) {
            $observerReady = -not $RequireGameScriptObserver `
                -or @($status.luaStates | Where-Object { $_.commandObserverRegistered -eq $true }).Count -gt 0
            $gatesReady = -not $RequireAuthorityGates `
                -or ($status.gates.buildProposal.enabled -eq $true -and $status.gates.commandVisitors.enabled -eq $true)
            if ($observerReady -and $gatesReady) { return $status }
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Game PID $($GameProcess.Id) did not reach the required native world boundary within $TimeoutSeconds seconds."
}
