[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
    [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$BoundarySeq,
    [Parameter(Mandatory = $true)][string]$BridgePath,
    [Parameter(Mandatory = $true)][string]$SaveDirectory,
    [Parameter(Mandatory = $true)][string]$SaveBaseName,
    [Parameter(Mandatory = $true)][int]$GameProcessId,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$GameStartedAtUtc,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [string]$InputHelperPath,
    [ValidateRange(0, 10)][int]$PublishedUiWaitSeconds = 4,
    [ValidateRange(10, 300)][int]$TimeoutSeconds = 60,
    [ValidateRange(10, 3600)][int]$SaveCompletionTimeoutSeconds = 1200
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'native_load_common.ps1')
. (Join-Path $PSScriptRoot 'recovery_save_common.ps1')

$safeSession = Assert-Tpf2mpSessionId $Session
$expectedName = Get-Tpf2mpRecoverySaveBaseName `
    -Session $safeSession -Peer $Peer -BoundarySeq $BoundarySeq
if ($SaveBaseName -ne $expectedName -or $SaveBaseName.Length -gt 50 `
    -or $SaveBaseName -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'Stock-UI recovery save name is not the exact bounded automatic name.'
}
$bridge = Resolve-Tpf2mpFullPath $BridgePath
$saveRoot = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory
$expectedGame = Resolve-Tpf2mpFullPath $GameExecutable
$expectedStart = [DateTime]::Parse($GameStartedAtUtc).ToUniversalTime()
$savePath = Join-Path $saveRoot ($SaveBaseName + '.sav')
$metadataPath = $savePath + '.lua'
$metadataTemporaryPath = $metadataPath + '.tmp'
$evidence = Resolve-Tpf2mpFullPath $EvidenceDirectory
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$resultPath = Join-Path $evidence 'stock-ui-save.json'
$inputHelper = Resolve-Tpf2mpFullPath $(if ($InputHelperPath) {
    $InputHelperPath
} else { Join-Path $PSScriptRoot 'send_game_console.ps1' })
if (-not (Test-Path -LiteralPath $inputHelper -PathType Leaf)) {
    throw "Stock-UI input helper is missing: $inputHelper"
}
$startedAt = [DateTime]::UtcNow
$existingSave = Test-Path -LiteralPath $savePath -PathType Leaf

function Get-ExactGameProcess {
    $game = Get-Process -Id $GameProcessId -ErrorAction Stop
    if ($game.HasExited -or -not $game.Path `
        -or -not [string]::Equals((Resolve-Tpf2mpFullPath $game.Path), $expectedGame,
            [StringComparison]::OrdinalIgnoreCase) `
        -or [Math]::Abs(($game.StartTime.ToUniversalTime() - $expectedStart).TotalSeconds) -ge 2) {
        throw 'Recorded game process identity changed before stock-UI recovery save.'
    }
    return $game
}

function Invoke-GameInput {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Command,
        [int]$X = -1,
        [int]$Y = -1,
        [string]$ReceiptName = $Action
    )
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        $inputHelper,
        '-GameProcessId', [string]$GameProcessId, '-Action', $Action,
        '-DelayMilliseconds', '0', '-ResultPath', (Join-Path $evidence ($ReceiptName + '.json'))
    )
    if ($Command) { $arguments += @('-Command', $Command) }
    if ($X -ge 0 -and $Y -ge 0) {
        $arguments += @(
            '-ClientX', [string]$X, '-ClientY', [string]$Y,
            '-UiWidth', '1920', '-UiHeight', '1080', '-PhysicalPixels'
        )
    }
    & (Join-Path $PSHOME 'powershell.exe') @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Game input '$Action' exited $LASTEXITCODE." }
}

function Wait-ForPublishedSaveButton([int]$Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $status = Read-Tpf2mpMenuStatus `
            -BridgePath $bridge -Session $safeSession -Peer $Peer
        $components = if ($status) { $status.components } else { $null }
        if ($components -and $components.PSObject.Properties['inGameSaveVisible'] `
            -and $components.inGameSaveVisible -eq $true `
            -and (Test-PositiveRectangle $components.inGameSaveRect) `
            -and (Test-PositiveRectangle $components.inGameUiRect)) {
            return $status
        }
        Start-Sleep -Milliseconds 100
    }
    return $null
}

function Test-PositiveRectangle([object]$Rectangle) {
    if (-not $Rectangle) { return $false }
    foreach ($field in @('x', 'y', 'w', 'h')) {
        if ($null -eq $Rectangle.PSObject.Properties[$field] `
            -or $null -eq $Rectangle.$field) { return $false }
    }
    return [double]$Rectangle.w -gt 0 -and [double]$Rectangle.h -gt 0
}

$sessionLockRoot = Join-Path (Get-Tpf2mpSupportRoot) "sessions\$safeSession"
New-Item -ItemType Directory -Force -Path $sessionLockRoot | Out-Null
$lockPath = Join-Path $sessionLockRoot 'stock-ui-save.lock'
$lock = $null
$lockDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
while (-not $lock -and [DateTime]::UtcNow -lt $lockDeadline) {
    try {
        $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch [IO.IOException] { Start-Sleep -Milliseconds 200 }
}
if (-not $lock) { throw 'Timed out waiting for the same-machine stock-save UI lock.' }

try {
    [void](Get-ExactGameProcess)
    Invoke-GameInput -Action maximize -ReceiptName '01-maximize'

    # A previous attempt or the player's explicit pause can already have the
    # pause menu open. Pressing Escape blindly would close it and made the
    # watcher chase stale zero-sized rectangles on alternate attempts.
    $published = Wait-ForPublishedSaveButton 1
    $supportsReadback = $false
    for ($attempt = 1; $attempt -le 2 -and -not $published; $attempt++) {
        Invoke-GameInput -Action escape -ReceiptName ("02-open-pause-$attempt")
        $published = Wait-ForPublishedSaveButton $PublishedUiWaitSeconds
        $status = Read-Tpf2mpMenuStatus `
            -BridgePath $bridge -Session $safeSession -Peer $Peer
        $supportsReadback = $status -and $status.components `
            -and $status.components.PSObject.Properties['inGameSaveVisible']
        if (-not $supportsReadback) { break }
        if (-not $published -and $status.components.inGameSaveVisible -eq $true) {
            throw 'Published stock Save control has an invalid or stale UI rectangle.'
        }
    }

    $game = Get-ExactGameProcess
    if ($published -and $published.components.inGameUiRect) {
        Invoke-Tpf2mpUiRectangleClick -GameProcess $game `
            -Rectangle $published.components.inGameSaveRect `
            -MenuRectangle $published.components.inGameUiRect `
            -ReceiptPath (Join-Path $evidence '03-click-save.json')
    }
    elseif (-not $supportsReadback) {
        # Compatibility fallback for an older already-loaded bootstrap. These
        # normalized coordinates are the stock 16:9 pause menu's Save control;
        # the next watcher poll still requires a stable exact-name file before
        # it can attest anything.
        Invoke-GameInput -Action click-ui -X 960 -Y 472 -ReceiptName '03-click-save'
    }
    else {
        throw 'Stock Save control did not become visible after two bounded pause-menu attempts.'
    }
    Start-Sleep -Milliseconds 700
    Invoke-GameInput -Action click-ui -X 950 -Y 813 -ReceiptName '04-focus-name'
    Invoke-GameInput -Action replace-ui-text -Command $SaveBaseName -ReceiptName '05-type-name'
    Invoke-GameInput -Action click-ui -X 1443 -Y 858 -ReceiptName '06-confirm-save'
    if ($existingSave) {
        Start-Sleep -Milliseconds 700
        Invoke-GameInput -Action click-ui -X 998 -Y 574 -ReceiptName '07-confirm-overwrite'
    }

    # Large populated worlds can write the native .sav immediately and then
    # spend many minutes producing metadata. Keep the same-machine lock for
    # that entire bounded operation so the watcher cannot open a second Save
    # dialog while the first native save is still active.
    $fileDeadline = [DateTime]::UtcNow.AddSeconds($SaveCompletionTimeoutSeconds)
    $nativeActivityObserved = $false
    do {
        [void](Get-ExactGameProcess)
        foreach ($activityPath in @($savePath, $metadataPath, $metadataTemporaryPath)) {
            if (Test-Path -LiteralPath $activityPath -PathType Leaf) {
                $activity = Get-Item -LiteralPath $activityPath
                if ($activity.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2)) {
                    $nativeActivityObserved = $true
                }
            }
        }
        if ((Test-Path -LiteralPath $savePath -PathType Leaf) `
            -and (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            $save = Get-Item -LiteralPath $savePath
            $metadata = Get-Item -LiteralPath $metadataPath
            if ($save.Length -gt 0 -and $metadata.Length -gt 0 `
                -and $save.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2) `
                -and $metadata.LastWriteTimeUtc -ge $startedAt.AddSeconds(-2)) {
                [ordered]@{
                    schemaVersion = 1
                    status = 'completed'
                    session = $safeSession
                    peer = $Peer
                    boundarySeq = $BoundarySeq
                    saveName = $SaveBaseName
                    savePath = $savePath
                    usedPublishedRectangle = $null -ne $published
                    overwritten = $existingSave
                    nativeActivityObserved = $nativeActivityObserved
                    durationSeconds = [Math]::Round(
                        ([DateTime]::UtcNow - $startedAt).TotalSeconds, 3)
                    completedAtUtc = [DateTime]::UtcNow.ToString('o')
                } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
                Write-Host "Stock-UI recovery save completed: $savePath"
                exit 0
            }
        }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $fileDeadline)
    $activityDescription = if ($nativeActivityObserved) {
        'Native output appeared but did not finalize'
    } else { 'No fresh native output appeared' }
    throw "$activityDescription for '$SaveBaseName' within $SaveCompletionTimeoutSeconds seconds."
}
catch {
    [ordered]@{
        schemaVersion = 1
        status = 'failed'
        session = $safeSession
        peer = $Peer
        boundarySeq = $BoundarySeq
        saveName = $SaveBaseName
        error = $_.Exception.Message
        failedAtUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    throw
}
finally {
    if ($lock) { $lock.Dispose() }
}
