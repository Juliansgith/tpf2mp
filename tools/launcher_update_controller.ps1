Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')
. (Join-Path $PSScriptRoot 'update_common.ps1')
. (Join-Path $PSScriptRoot 'launcher_worker_result.ps1')

function Read-Tpf2mpLauncherLogText {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $stream = $null
    $reader = $null
    try {
        $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $stream = [IO.FileStream]::new(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        $reader = [IO.StreamReader]::new(
            $stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        return $reader.ReadToEnd()
    }
    catch [IO.IOException] { return $null }
    catch [UnauthorizedAccessException] { return $null }
    finally {
        if ($reader) { $reader.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
}

function Get-Tpf2mpReleaseUpdateCheckResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [string]$ExpectedCurrentVersion
    )
    try {
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf) `
                -or -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }
        $stdout = [IO.File]::ReadAllText($StdoutPath)
        $available = [regex]::Match(
            $stdout,
            '(?m)^TPF2MP\s+(\S+)\s+is available \(installed:\s+(\S+)\)\.\s*$')
        if ($available.Success) {
            $next = $available.Groups[1].Value
            $current = $available.Groups[2].Value
            if ($ExpectedCurrentVersion -and $current -cne $ExpectedCurrentVersion) { return $null }
            if ((Compare-Tpf2mpSemanticVersion $next $current) -le 0) { return $null }
            return [pscustomobject]@{
                state = 'available'; currentVersion = $current; availableVersion = $next
            }
        }
        $currentMatch = [regex]::Match(
            $stdout,
            '(?m)^TPF2MP\s+(\S+)\s+(?:is current on the \S+ channel|is already installed)\.\s*$')
        if (-not $currentMatch.Success) { return $null }
        $current = $currentMatch.Groups[1].Value
        if ($ExpectedCurrentVersion -and $current -cne $ExpectedCurrentVersion) { return $null }
        [void](ConvertTo-Tpf2mpSemanticVersion $current)
        return [pscustomobject]@{
            state = 'current'; currentVersion = $current; availableVersion = $null
        }
    }
    catch { return $null }
}

function Get-Tpf2mpCompletedProcessExitCode {
    param([Parameter(Mandatory = $true)]$Process)
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) { return $null }
        $Process.WaitForExit()
        $Process.Refresh()
        return [int]$Process.ExitCode
    }
    catch {
        # Receipt verification remains authoritative for operations that have
        # a durable result. A missing Process.ExitCode must not discard one.
        return $null
    }
}

function Test-Tpf2mpWorkerCompletionSucceeded {
    param(
        [AllowNull()][object]$ExitCode,
        [object[]]$VerifiedReceipts = @()
    )
    if ($null -ne $ExitCode -and [int]$ExitCode -eq 0) { return $true }
    foreach ($receipt in $VerifiedReceipts) {
        if ($null -ne $receipt) { return $true }
    }
    return $false
}

function Start-Tpf2mpLauncherUpdateProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$UpdateScript,
        [switch]$CheckOnly
    )
    $logRoot = Join-Path (Get-Tpf2mpSupportRoot) 'launcher-logs'
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $kind = if ($CheckOnly) { 'release-update-check' } else { 'release-update' }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $stdout = Join-Path $logRoot "$stamp-$kind.stdout.log"
    $stderr = Join-Path $logRoot "$stamp-$kind.stderr.log"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $UpdateScript,
        '-BundleRoot', $BundleRoot)
    if ($CheckOnly) { $arguments += @('-CheckOnly', '-NoCredentialPrompt') }
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return [pscustomobject]@{
        Process = $process; StdoutPath = $stdout; StderrPath = $stderr; Kind = $kind
    }
}

function Start-Tpf2mpInstalledLauncherAfterUpdate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$VerifiedUpdate)
    $bundle = Resolve-Tpf2mpFullPath ([string]$VerifiedUpdate.bundleRoot)
    $versions = Resolve-Tpf2mpFullPath (Split-Path -Parent $bundle)
    $install = Resolve-Tpf2mpFullPath (Split-Path -Parent $versions)
    if ((Split-Path -Leaf $versions) -cne 'versions') {
        throw "Updated bundle is not in an installed versions directory: $bundle"
    }
    $entrypoint = Join-Path $install 'installed_entrypoint.ps1'
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "Stable installed launcher is missing: $entrypoint"
    }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $entrypoint,
        '-Action', 'Launch', '-InstallRoot', $install)
    return Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine $arguments) -PassThru -WindowStyle Hidden
}

function Initialize-Tpf2mpLauncherUpdateController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Form,
        [Parameter(Mandatory = $true)]$Button,
        [Parameter(Mandatory = $true)]$StatusLabel,
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CurrentVersion,
        [Parameter(Mandatory = $true)][scriptblock]$LogAction,
        [Parameter(Mandatory = $true)][scriptblock]$CanEnableAction,
        [string]$UpdateScript,
        [switch]$SmokeTest
    )
    if (-not $UpdateScript) { $UpdateScript = Join-Path $PSScriptRoot 'update_release.ps1' }
    $updateScriptPath = Resolve-Tpf2mpFullPath $UpdateScript
    # WinForms callbacks execute outside a caller script's dynamic child
    # scope. Capture the helper bodies while that scope is alive so an
    # installed_entrypoint.ps1 -> multiplayer_launcher.ps1 invocation behaves
    # exactly like launching multiplayer_launcher.ps1 directly.
    $startUpdateProcess = ${function:Start-Tpf2mpLauncherUpdateProcess}
    $readExitCode = ${function:Get-Tpf2mpCompletedProcessExitCode}
    $readCheckResult = ${function:Get-Tpf2mpReleaseUpdateCheckResult}
    $readInstalledResult = ${function:Get-Tpf2mpVerifiedReleaseUpdateResult}
    $readLogText = ${function:Read-Tpf2mpLauncherLogText}
    $restartInstalledLauncher = ${function:Start-Tpf2mpInstalledLauncherAfterUpdate}
    $state = [pscustomobject]@{
        Work = $null; Mode = $null; StdoutLength = 0; StderrLength = 0; Started = $false
    }
    $writeLog = { param([string]$Text) if ($Text) { & $LogAction $Text } }.GetNewClosure()
    $setReadyButton = {
        param([string]$Text)
        $Button.Text = $Text
        $Button.Enabled = [bool](& $CanEnableAction)
    }.GetNewClosure()
    $start = {
        param([ValidateSet('check', 'install')][string]$Mode)
        if ($state.Work) { return }
        if (-not (Test-Path -LiteralPath $updateScriptPath -PathType Leaf)) {
            throw "Release updater is missing: $updateScriptPath"
        }
        $state.Mode = $Mode
        $state.StdoutLength = 0
        $state.StderrLength = 0
        $state.Work = & $startUpdateProcess -BundleRoot $BundleRoot `
            -UpdateScript $updateScriptPath -CheckOnly:($Mode -eq 'check')
        $Button.Enabled = $false
        $Button.Text = if ($Mode -eq 'check') { 'CHECKING FOR UPDATE...' } else { 'INSTALLING UPDATE...' }
        if ($Mode -eq 'install') {
            $Form.Enabled = $false
            & $writeLog "Started release-update (PID $($state.Work.Process.Id))."
        }
    }.GetNewClosure()
    $flushInstallLog = {
        if ($state.Mode -ne 'install' -or -not $state.Work) { return }
        foreach ($field in @(
                @{ Path = 'StdoutPath'; Length = 'StdoutLength' },
                @{ Path = 'StderrPath'; Length = 'StderrLength' })) {
            $path = [string]$state.Work.($field.Path)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            $content = & $readLogText -Path $path
            if ($null -eq $content) { continue }
            $offset = [int]$state.($field.Length)
            if ($content.Length -gt $offset) {
                & $writeLog $content.Substring($offset)
                $state.($field.Length) = $content.Length
            }
        }
    }.GetNewClosure()
    $Button.Add_Click({
        try {
            if ($state.Work) { return }
            if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
                throw 'Close Transport Fever 2 before installing an update.'
            }
            if (Get-Process -Name tpf2mp -ErrorAction SilentlyContinue) {
                throw 'Stop the active multiplayer session before installing an update.'
            }
            & $start 'install'
            & $writeLog 'The updater uses your own GitHub authentication when the repository is private.'
        }
        catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot update') | Out-Null }
    }.GetNewClosure())
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 500
    $timer.Add_Tick({
        if (-not $state.Work) { return }
        & $flushInstallLog
        $state.Work.Process.Refresh()
        if (-not $state.Work.Process.HasExited) { return }
        $exitCode = & $readExitCode $state.Work.Process
        & $flushInstallLog
        $work = $state.Work
        $mode = $state.Mode
        $state.Work = $null
        $state.Mode = $null
        if ($mode -eq 'check') {
            $result = & $readCheckResult -StdoutPath $work.StdoutPath `
                -StderrPath $work.StderrPath -ExpectedCurrentVersion $CurrentVersion
            if ($result -and $result.state -eq 'available') {
                & $setReadyButton "UPDATE $($result.availableVersion.ToUpperInvariant())"
                & $writeLog "Update $($result.availableVersion) is available."
            }
            elseif ($result) {
                & $setReadyButton 'UP TO DATE'
            }
            else {
                & $setReadyButton 'CHECK / INSTALL UPDATE'
                & $writeLog 'Automatic update check was unavailable; the update button can retry interactively.'
            }
            return
        }
        $verified = & $readInstalledResult -StdoutPath $work.StdoutPath `
            -StderrPath $work.StderrPath
        if ($verified -and [bool]$verified.changed) {
            try {
                $StatusLabel.Text = "Updated to $($verified.version); restarting launcher..."
                & $writeLog "Update $($verified.version) installed and verified; restarting into the new launcher."
                [void](& $restartInstalledLauncher $verified)
                $timer.Stop()
                $Form.Close()
                return
            }
            catch {
                $Form.Enabled = $true
                & $setReadyButton 'RESTART LAUNCHER'
                [Windows.Forms.MessageBox]::Show(
                    "The update installed, but automatic restart failed: $($_.Exception.Message)",
                    'TPF2MP updated') | Out-Null
                return
            }
        }
        $Form.Enabled = $true
        if ($verified) {
            & $setReadyButton 'UP TO DATE'
            $StatusLabel.Text = "TPF2MP $($verified.version) is already current."
            return
        }
        & $setReadyButton 'CHECK / INSTALL UPDATE'
        $exitText = if ($null -eq $exitCode) { 'unknown' } else { [string]$exitCode }
        $StatusLabel.Text = "Update failed (exit $exitText); see log."
        [Windows.Forms.MessageBox]::Show('The update did not complete. See the launcher log.', 'Update failed') | Out-Null
    }.GetNewClosure())
    $Form.Add_Shown({
        if ($state.Started -or $SmokeTest) { return }
        $state.Started = $true
        try { & $start 'check' }
        catch {
            & $setReadyButton 'CHECK / INSTALL UPDATE'
            & $writeLog "Automatic update check could not start: $($_.Exception.Message)"
        }
    }.GetNewClosure())
    $Form.Add_FormClosed({ $timer.Stop(); $timer.Dispose() }.GetNewClosure())
    if (-not $SmokeTest) { $timer.Start() }
    return $state
}
