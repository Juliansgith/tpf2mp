[CmdletBinding()]
param(
    [string]$BundleRoot,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$background = [Drawing.Color]::FromArgb(20, 30, 36)
$panelColor = [Drawing.Color]::FromArgb(31, 45, 52)
$fieldColor = [Drawing.Color]::FromArgb(42, 58, 66)
$accent = [Drawing.Color]::FromArgb(70, 190, 157)
$muted = [Drawing.Color]::FromArgb(164, 181, 187)
$textColor = [Drawing.Color]::FromArgb(239, 245, 246)
$danger = [Drawing.Color]::FromArgb(229, 115, 115)

$form = New-Object Windows.Forms.Form
$form.Text = 'TPF2MP Multiplayer'
$form.ClientSize = New-Object Drawing.Size(850, 770)
$form.BackColor = $background
$form.ForeColor = $textColor
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$title = New-Object Windows.Forms.Label
$title.Text = 'TPF2MP  /  MULTIPLAYER'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 18)
$title.ForeColor = $textColor
$title.Location = New-Object Drawing.Point(24, 18)
$title.AutoSize = $true
$form.Controls.Add($title)

$subtitle = New-Object Windows.Forms.Label
$subtitle.Text = 'Host or join a trusted two-company world. Diagnostics remain available below for local verification.'
$subtitle.ForeColor = $muted
$subtitle.Location = New-Object Drawing.Point(27, 56)
$subtitle.Size = New-Object Drawing.Size(790, 30)
$form.Controls.Add($subtitle)

$settingsPanel = New-Object Windows.Forms.Panel
$settingsPanel.Location = New-Object Drawing.Point(24, 92)
$settingsPanel.Size = New-Object Drawing.Size(802, 250)
$settingsPanel.BackColor = $panelColor
$form.Controls.Add($settingsPanel)

function Add-LauncherLabel([string]$Text, [int]$X, [int]$Y, [int]$Width = 150) {
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text
    $label.ForeColor = $muted
    $label.Location = New-Object Drawing.Point($X, $Y)
    $label.Size = New-Object Drawing.Size($Width, 22)
    $settingsPanel.Controls.Add($label)
    return $label
}

function Add-LauncherTextBox([int]$X, [int]$Y, [int]$Width, [string]$Value) {
    $box = New-Object Windows.Forms.TextBox
    $box.Text = $Value
    $box.Location = New-Object Drawing.Point($X, $Y)
    $box.Size = New-Object Drawing.Size($Width, 27)
    $box.BackColor = $fieldColor
    $box.ForeColor = $textColor
    $box.BorderStyle = 'FixedSingle'
    $settingsPanel.Controls.Add($box)
    return $box
}

function Style-LauncherButton($Button, [bool]$Primary = $false) {
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = if ($Primary) { $accent } else { [Drawing.Color]::FromArgb(78, 99, 108) }
    $Button.BackColor = if ($Primary) { [Drawing.Color]::FromArgb(38, 104, 89) } else { $fieldColor }
    $Button.ForeColor = $textColor
    $Button.Cursor = [Windows.Forms.Cursors]::Hand
}

$defaultSession = 'match-' + (Get-Date -Format 'yyyyMMdd-HHmm')
Add-LauncherLabel 'Session name' 18 16 | Out-Null
$sessionBox = Add-LauncherTextBox 18 39 350 $defaultSession
$newSessionButton = New-Object Windows.Forms.Button
$newSessionButton.Text = 'New name'
$newSessionButton.Location = New-Object Drawing.Point(378, 38)
$newSessionButton.Size = New-Object Drawing.Size(92, 29)
Style-LauncherButton $newSessionButton
$settingsPanel.Controls.Add($newSessionButton)

Add-LauncherLabel 'Host address (Join)' 490 16 180 | Out-Null
$hostBox = Add-LauncherTextBox 490 39 190 '127.0.0.1'
Add-LauncherLabel 'TCP port' 690 16 80 | Out-Null
$portBox = Add-LauncherTextBox 690 39 92 '29742'

$saveLabel = Add-LauncherLabel 'Identical starting save (required for Host / Join)' 18 84 500
$saveBox = Add-LauncherTextBox 18 107 660 ''
$browseButton = New-Object Windows.Forms.Button
$browseButton.Text = 'Browse...'
$browseButton.Location = New-Object Drawing.Point(688, 106)
$browseButton.Size = New-Object Drawing.Size(94, 29)
Style-LauncherButton $browseButton
$settingsPanel.Controls.Add($browseButton)

$addressText = 'LAN addresses: '
try {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.AddressState -eq 'Preferred' } |
        Select-Object -ExpandProperty IPAddress -Unique)
    $addressText += if ($addresses.Count) { $addresses -join ', ' } else { 'none detected' }
}
catch { $addressText += 'unavailable' }
$lanLabel = New-Object Windows.Forms.Label
$lanLabel.Text = $addressText
$lanLabel.ForeColor = $muted
$lanLabel.Location = New-Object Drawing.Point(18, 145)
$lanLabel.Size = New-Object Drawing.Size(764, 22)
$settingsPanel.Controls.Add($lanLabel)

$hint = New-Object Windows.Forms.Label
$hint.Text = 'Host shares the session name, LAN/VPN address, port, and exact save with player 2. Launch, then click MULTIPLAYER in the game menu; mismatches are rejected.'
$hint.ForeColor = $muted
$hint.Location = New-Object Drawing.Point(18, 178)
$hint.Size = New-Object Drawing.Size(764, 40)
$settingsPanel.Controls.Add($hint)

$manualLabCheck = New-Object Windows.Forms.CheckBox
$manualLabCheck.Text = 'After the automated proof, leave both connected game windows open for manual testing (up to 2 hours)'
$manualLabCheck.ForeColor = $textColor
$manualLabCheck.Location = New-Object Drawing.Point(18, 220)
$manualLabCheck.Size = New-Object Drawing.Size(764, 24)
$manualLabCheck.Checked = $false
$settingsPanel.Controls.Add($manualLabCheck)

$hostButton = New-Object Windows.Forms.Button
$hostButton.Text = 'HOST + LAUNCH GAME'
$hostButton.Location = New-Object Drawing.Point(24, 360)
$hostButton.Size = New-Object Drawing.Size(245, 48)
Style-LauncherButton $hostButton $true
$form.Controls.Add($hostButton)

$joinButton = New-Object Windows.Forms.Button
$joinButton.Text = 'JOIN + LAUNCH GAME'
$joinButton.Location = New-Object Drawing.Point(280, 360)
$joinButton.Size = New-Object Drawing.Size(245, 48)
Style-LauncherButton $joinButton $true
$form.Controls.Add($joinButton)

$localhostButton = New-Object Windows.Forms.Button
$localhostButton.Text = 'RUN 2-INSTANCE LOCALHOST TEST'
$localhostButton.Location = New-Object Drawing.Point(536, 360)
$localhostButton.Size = New-Object Drawing.Size(290, 48)
Style-LauncherButton $localhostButton
$form.Controls.Add($localhostButton)

$stopButton = New-Object Windows.Forms.Button
$stopButton.Text = 'Stop session / lab'
$stopButton.Location = New-Object Drawing.Point(24, 420)
$stopButton.Size = New-Object Drawing.Size(150, 34)
Style-LauncherButton $stopButton
$form.Controls.Add($stopButton)

$openButton = New-Object Windows.Forms.Button
$openButton.Text = 'Open session files'
$openButton.Location = New-Object Drawing.Point(184, 420)
$openButton.Size = New-Object Drawing.Size(165, 34)
Style-LauncherButton $openButton
$form.Controls.Add($openButton)

$evidenceButton = New-Object Windows.Forms.Button
$evidenceButton.Text = 'Collect evidence'
$evidenceButton.Location = New-Object Drawing.Point(359, 420)
$evidenceButton.Size = New-Object Drawing.Size(165, 34)
Style-LauncherButton $evidenceButton
$form.Controls.Add($evidenceButton)

$operationalButton = New-Object Windows.Forms.Button
$operationalButton.Text = 'RUN POPULATED CAPTURE LAB (LOCAL ONLY)'
$operationalButton.Location = New-Object Drawing.Point(535, 420)
$operationalButton.Size = New-Object Drawing.Size(291, 34)
Style-LauncherButton $operationalButton
$form.Controls.Add($operationalButton)

$archiveButton = New-Object Windows.Forms.Button
$archiveButton.Text = 'ARCHIVE RECOVERY SAVE'
$archiveButton.Location = New-Object Drawing.Point(24, 464)
$archiveButton.Size = New-Object Drawing.Size(210, 34)
Style-LauncherButton $archiveButton
$form.Controls.Add($archiveButton)

$restoreButton = New-Object Windows.Forms.Button
$restoreButton.Text = 'SELECT RESTORE PLAN...'
$restoreButton.Location = New-Object Drawing.Point(244, 464)
$restoreButton.Size = New-Object Drawing.Size(210, 34)
Style-LauncherButton $restoreButton
$form.Controls.Add($restoreButton)

$recoveryHint = New-Object Windows.Forms.Label
$recoveryHint.Text = 'Archive a current save, or select a verified restore plan and then this peer''s attested save.'
$recoveryHint.ForeColor = $muted
$recoveryHint.Location = New-Object Drawing.Point(468, 466)
$recoveryHint.Size = New-Object Drawing.Size(358, 34)
$form.Controls.Add($recoveryHint)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text = 'Ready. Build 35924 is required for network mode.'
$statusLabel.ForeColor = $accent
$statusLabel.Location = New-Object Drawing.Point(24, 507)
$statusLabel.Size = New-Object Drawing.Size(802, 24)
$statusLabel.TextAlign = 'MiddleLeft'
$form.Controls.Add($statusLabel)

$logBox = New-Object Windows.Forms.TextBox
$logBox.Location = New-Object Drawing.Point(24, 539)
$logBox.Size = New-Object Drawing.Size(802, 195)
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [Drawing.Color]::FromArgb(12, 20, 24)
$logBox.ForeColor = [Drawing.Color]::FromArgb(190, 218, 211)
$logBox.BorderStyle = 'FixedSingle'
$logBox.Font = New-Object Drawing.Font('Cascadia Mono', 9)
$logBox.Text = "This control panel pins the role/session/save, starts the companion, launches the exact game process, drives the native Load Game page, and verifies authority gates before reporting world-ready.`r`n"
$form.Controls.Add($logBox)

$script:worker = $null
$script:workerStdout = $null
$script:workerStderr = $null
$script:workerStdoutLength = 0
$script:workerStderrLength = 0
$script:lastPeer = 'player1'
$script:restorePlanPath = $null
$script:restorePlanData = $null

function Append-LauncherLog([string]$Text) {
    if (-not $Text) { return }
    $logBox.AppendText(($Text.TrimEnd() + "`r`n"))
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

function Clear-RestorePlanSelection([bool]$ClearSave = $true) {
    $script:restorePlanPath = $null
    $script:restorePlanData = $null
    $sessionBox.ReadOnly = $false
    $saveLabel.Text = 'Identical starting save (required for Host / Join)'
    if ($ClearSave) { $saveBox.Text = '' }
    $recoveryHint.Text = 'Archive a current save, or select a verified restore plan and then this peer''s attested save.'
}

function Set-VerifiedRestorePlan([string]$Path) {
    $resolved = Resolve-Tpf2mpFullPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Restore plan does not exist: $resolved"
    }
    $companion = Get-Tpf2mpCompanionCommand $bundle
    $output = @(& $companion.FilePath @($companion.Prefix + @(
        'verify-restore-plan', $resolved, '--metadata-only'
    )) 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Restore plan signature/structure verification failed: $($output -join ' ')"
    }
    $plan = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    $resumeSession = Assert-Tpf2mpSessionId ([string]$plan.resumeSession)
    $script:restorePlanPath = $resolved
    $script:restorePlanData = $plan
    $sessionBox.Text = $resumeSession
    $sessionBox.ReadOnly = $true
    $saveBox.Text = ''
    $saveLabel.Text = 'This peer''s attested restore save (Host=player1 / Join=player2)'
    $policy = if ([int]$plan.version -ge 3) {
        "$($plan.matchContentProfile.agentMode), town growth $($plan.matchContentProfile.townDevelopment)"
    } else { 'legacy v2: policy is not plan-bound' }
    $recoveryHint.Text = "Restore boundary $($plan.boundarySeq); $policy. Select this peer's .sav."
    Append-LauncherLog "Verified restore plan $resolved -> $resumeSession (boundary $($plan.boundarySeq), $policy)."
}

function Flush-LauncherWorkerLogs {
    try {
        if ($script:workerStdout -and (Test-Path -LiteralPath $script:workerStdout -PathType Leaf)) {
            $content = [IO.File]::ReadAllText($script:workerStdout)
            if ($content.Length -gt $script:workerStdoutLength) {
                Append-LauncherLog $content.Substring($script:workerStdoutLength)
                $script:workerStdoutLength = $content.Length
            }
        }
    }
    catch { }
    try {
        if ($script:workerStderr -and (Test-Path -LiteralPath $script:workerStderr -PathType Leaf)) {
            $content = [IO.File]::ReadAllText($script:workerStderr)
            if ($content.Length -gt $script:workerStderrLength) {
                Append-LauncherLog $content.Substring($script:workerStderrLength)
                $script:workerStderrLength = $content.Length
            }
        }
    }
    catch { }
}

function Start-LauncherWorker([string]$ScriptPath, [object[]]$Arguments, [string]$Name) {
    if ($script:worker) {
        $script:worker.Refresh()
        if (-not $script:worker.HasExited) {
            [Windows.Forms.MessageBox]::Show('A launcher task is already running.', 'TPF2MP') | Out-Null
            return
        }
    }
    $logRoot = Join-Path (Get-Tpf2mpSupportRoot) 'launcher-logs'
    New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:workerStdout = Join-Path $logRoot "$stamp-$Name.stdout.log"
    $script:workerStderr = Join-Path $logRoot "$stamp-$Name.stderr.log"
    $script:workerStdoutLength = 0
    $script:workerStderrLength = 0
    $powershell = Join-Path $PSHOME 'powershell.exe'
    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $commandLine = ConvertTo-Tpf2mpCommandLine $allArguments
    $script:worker = Start-Process -FilePath $powershell -ArgumentList $commandLine -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $script:workerStdout -RedirectStandardError $script:workerStderr
    $hostButton.Enabled = $false
    $joinButton.Enabled = $false
    $localhostButton.Enabled = $false
    $operationalButton.Enabled = $false
    $manualLabCheck.Enabled = $false
    $evidenceButton.Enabled = $false
    $archiveButton.Enabled = $false
    $restoreButton.Enabled = $false
    $statusLabel.Text = "$Name running..."
    Append-LauncherLog "Started $Name (PID $($script:worker.Id))."
}

function Get-ValidatedInputs([bool]$RequireSave = $false) {
    $session = Assert-Tpf2mpSessionId $sessionBox.Text.Trim()
    $port = 0
    if (-not [int]::TryParse($portBox.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'Port must be between 1 and 65535.'
    }
    $save = $saveBox.Text.Trim()
    if ($save -and -not (Test-Path -LiteralPath $save -PathType Leaf)) { throw "Starting save does not exist: $save" }
    if ($RequireSave -and -not $save) {
        if ($script:restorePlanPath) {
            throw 'Select this peer''s attested restore .sav first (Host=player1, Join=player2).'
        }
        throw 'Select the identical starting .sav first. Both players must use byte-identical save triplets.'
    }
    return [pscustomobject]@{ Session = $session; Port = $port; Save = $save }
}

$newSessionButton.Add_Click({
    Clear-RestorePlanSelection
    $sessionBox.Text = 'match-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
})
$browseButton.Add_Click({
    $dialog = New-Object Windows.Forms.OpenFileDialog
    $dialog.Title = if ($script:restorePlanPath) {
        'Select this peer''s attested TPF2 restore save'
    } else { 'Select the identical TPF2 starting save' }
    $dialog.Filter = 'Transport Fever 2 saves (*.sav)|*.sav|All files (*.*)|*.*'
    if ($dialog.ShowDialog() -eq 'OK') { $saveBox.Text = $dialog.FileName }
})

$restoreButton.Add_Click({
    try {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select a signed TPF2MP restore plan'
        $dialog.Filter = 'TPF2MP restore plans (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq 'OK') { Set-VerifiedRestorePlan $dialog.FileName }
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot select restore plan') | Out-Null }
})

$hostButton.Add_Click({
    try {
        $input = Get-ValidatedInputs $true
        $script:lastPeer = 'player1'
        $args = @('-Role', 'Host', '-Session', $input.Session, '-Port', $input.Port,
            '-BindAddress', '0.0.0.0', '-BundleRoot', $bundle)
        if ($input.Save) { $args += @('-StartingSave', $input.Save) }
        if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'start_network_session.ps1') $args 'host-launch'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot host') | Out-Null }
})

$joinButton.Add_Click({
    try {
        $input = Get-ValidatedInputs $true
        $hostAddress = $hostBox.Text.Trim()
        if ($hostAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$') { throw 'Enter a valid LAN/VPN host address.' }
        $script:lastPeer = 'player2'
        $args = @('-Role', 'Join', '-Session', $input.Session, '-HostAddress', $hostAddress,
            '-Port', $input.Port, '-BundleRoot', $bundle)
        if ($input.Save) { $args += @('-StartingSave', $input.Save) }
        if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'start_network_session.ps1') $args 'join-launch'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot join') | Out-Null }
})

$localhostButton.Add_Click({
    try {
        if ($script:restorePlanPath) { throw 'Restore mode supports Host / Join only. Click New name to leave restore mode.' }
        $input = Get-ValidatedInputs
        if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1'))) {
            throw 'The automated two-instance harness is included only in the development laboratory build.'
        }
        if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
            throw 'Close Transport Fever 2 before starting the disposable two-instance test.'
        }
        $session = 'localhost-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        $sessionBox.Text = $session
        $arguments = @('-Session', $session, '-SkipNativeBuild', '-SoakTicks', 600, '-TimeoutSeconds', 900)
        if ($input.Save) { $arguments += @('-StartingSave', $input.Save) }
        if ($manualLabCheck.Checked) {
            $arguments += @('-InteractiveAfterValidation', '-InteractiveMinutes', 120)
        }
        if (Test-Path -LiteralPath (Join-Path $bundle 'bin\tpf2mp.exe') -PathType Leaf) {
            $arguments += @('-SkipTests', '-SkipInstall')
        }
        $taskName = if ($manualLabCheck.Checked) { 'localhost-manual-lab' } else { 'localhost-test' }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'run_localhost_live_validation.ps1') $arguments $taskName
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot run localhost test') | Out-Null }
})

$operationalButton.Add_Click({
    try {
        if ($script:restorePlanPath) { throw 'Restore mode supports Host / Join only. Click New name to leave restore mode.' }
        $input = Get-ValidatedInputs
        $scriptPath = Join-Path $PSScriptRoot 'start_operational_capture_lab.ps1'
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw 'The populated capture lab is missing from this bundle.'
        }
        if (Get-Process -Name TransportFever2 -ErrorAction SilentlyContinue) {
            throw 'Close Transport Fever 2 before starting the disposable populated capture lab.'
        }
        $session = 'operations-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        $sessionBox.Text = $session
        $arguments = @('-Session', $session, '-Minutes', 120, '-SampleTicks', 120,
            '-StartingCash', 50000000, '-SkipNativeBuild')
        if ($input.Save) { $arguments += @('-StartingSave', $input.Save) }
        if (Test-Path -LiteralPath (Join-Path $bundle 'bin\tpf2mp.exe') -PathType Leaf) {
            $arguments += @('-SkipTests', '-SkipInstall')
        }
        Start-LauncherWorker $scriptPath $arguments 'populated-capture-lab'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot start capture lab') | Out-Null }
})

$stopButton.Add_Click({
    try {
        $session = Assert-Tpf2mpSessionId $sessionBox.Text.Trim()
        $bridgeBase = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$session"
        $localPeers = @('player1', 'player2') | Where-Object {
            Test-Path -LiteralPath (Join-Path $bridgeBase $_) -PathType Container
        }
        if ($localPeers.Count -eq 2) {
            foreach ($peer in $localPeers) {
                $launcherPath = Join-Path (Join-Path $bridgeBase $peer) 'launcher'
                New-Item -ItemType Directory -Force -Path $launcherPath | Out-Null
                [IO.File]::WriteAllText((Join-Path $launcherPath 'stop'), 'stop', [Text.UTF8Encoding]::new($false))
            }
            $statusLabel.Text = 'Stopping both localhost game instances...'
            Append-LauncherLog "Requested clean stop for $session/player1 and player2."
        }
        else {
            & (Join-Path $PSScriptRoot 'stop_network_session.ps1') -Session $session -Peer $script:lastPeer
            $statusLabel.Text = 'Companion stopped; game left open.'
            Append-LauncherLog "Stopped $session/$script:lastPeer."
        }
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot stop') | Out-Null }
})

$openButton.Add_Click({
    try {
        $session = Assert-Tpf2mpSessionId $sessionBox.Text.Trim()
        $path = Get-Tpf2mpSessionRoot $session $script:lastPeer
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $path + '"') | Out-Null
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot open files') | Out-Null }
})

$evidenceButton.Add_Click({
    try {
        $session = Assert-Tpf2mpSessionId $sessionBox.Text.Trim()
        $bridgeBase = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$session"
        $collectPeer = if ((Test-Path -LiteralPath (Join-Path $bridgeBase 'player1') -PathType Container) `
            -and (Test-Path -LiteralPath (Join-Path $bridgeBase 'player2') -PathType Container)) { 'both' } else { $script:lastPeer }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'collect_live_evidence.ps1') `
            @('-Session', $session, '-Peer', $collectPeer, '-BundleRoot', $bundle) 'collect-evidence'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot collect evidence') | Out-Null }
})

$archiveButton.Add_Click({
    try {
        $input = Get-ValidatedInputs
        if (-not $input.Save) {
            $dialog = New-Object Windows.Forms.OpenFileDialog
            $dialog.Title = 'Select the native save/autosave to archive'
            $dialog.Filter = 'Transport Fever 2 saves (*.sav)|*.sav|All files (*.*)|*.*'
            if ($dialog.ShowDialog() -ne 'OK') { return }
            $saveBox.Text = $dialog.FileName
            $input = Get-ValidatedInputs
        }
        $state = Read-Tpf2mpSessionState $input.Session $script:lastPeer
        if (-not $state) { throw "No session state exists for $($input.Session)/$script:lastPeer." }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'archive_recovery_save.ps1') `
            @('-Session', $input.Session, '-Peer', $script:lastPeer, '-SavePath', $input.Save,
              '-BundleRoot', $bundle) 'archive-recovery-save'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot archive recovery save') | Out-Null }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:worker) {
        Flush-LauncherWorkerLogs
        $script:worker.Refresh()
        if ($script:worker.HasExited) {
            Flush-LauncherWorkerLogs
            if ($script:worker.ExitCode -eq 0) {
                $statusLabel.ForeColor = $accent
                $statusLabel.Text = 'Task completed successfully.'
            }
            else {
                $statusLabel.ForeColor = $danger
                $statusLabel.Text = "Task failed (exit $($script:worker.ExitCode)); see log."
            }
            $script:worker = $null
            $hostButton.Enabled = $true
            $joinButton.Enabled = $true
            $localhostButton.Enabled = $true
            $operationalButton.Enabled = $true
            $manualLabCheck.Enabled = $true
            $evidenceButton.Enabled = $true
            $archiveButton.Enabled = $true
            $restoreButton.Enabled = $true
        }
    }
    try {
        $session = $sessionBox.Text.Trim()
        if ($session -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
            $state = Read-Tpf2mpSessionState $session $script:lastPeer
            if ($state -and $state.bridgePath) {
                $statusPath = Join-Path ([string]$state.bridgePath) 'companion_state\companion_status.json'
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    $network = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
                    $link = if ($network.PSObject.Properties['connected'] -and $network.connected) { 'CONNECTED' }
                        elseif ($network.PSObject.Properties['listening'] -and $network.listening) { 'HOST LISTENING' }
                        else { [string]$network.status }
                    $sequence = if ($network.PSObject.Properties['nextCommitSeq']) { " next commit $($network.nextCommitSeq)" }
                        elseif ($network.PSObject.Properties['lastCommitSeq']) { " commit $($network.lastCommitSeq)" } else { '' }
                    $clock = if ($network.PSObject.Properties['clock'] -and $network.clock) {
                        "  /  speed $($network.clock.effectiveSpeed)/$($network.clock.requestedSpeed)"
                    } else { '' }
                    $preparing = if ($network.PSObject.Properties['pendingProposalPrepareSeq'] `
                        -and $null -ne $network.pendingProposalPrepareSeq) {
                        "  /  preparing build $($network.pendingProposalPrepareSeq)"
                    } else { '' }
                    $statusLabel.ForeColor = if ($link -eq 'CONNECTED') { $accent } else { $muted }
                    $launcherStage = if ($state.status) { "  /  $($state.status)" } else { '' }
                    $statusLabel.Text = "$link  /  $session  /  $script:lastPeer$sequence$clock$preparing$launcherStage"
                }
                if ($state.PSObject.Properties['recoveryWatcherStatusPath'] `
                    -and $state.recoveryWatcherStatusPath `
                    -and (Test-Path -LiteralPath ([string]$state.recoveryWatcherStatusPath) -PathType Leaf)) {
                    try {
                        $recovery = Get-Content -LiteralPath ([string]$state.recoveryWatcherStatusPath) -Raw | ConvertFrom-Json
                        $boundary = if ($recovery.PSObject.Properties['lastArchivedBoundary'] `
                            -and $recovery.lastArchivedBoundary) {
                            " checkpoint $($recovery.lastArchivedBoundary)"
                        } else { '' }
                        $faultEvidence = if ($recovery.PSObject.Properties['firstFaultEvidenceSummary'] `
                            -and $recovery.firstFaultEvidenceSummary) {
                            " First-fault evidence: $($recovery.firstFaultEvidenceSummary)"
                        } elseif ($recovery.PSObject.Properties['firstFaultEvidenceError'] `
                            -and $recovery.firstFaultEvidenceError) {
                            $attempts = if ($recovery.PSObject.Properties['firstFaultEvidenceAttempts']) {
                                [int]$recovery.firstFaultEvidenceAttempts
                            } else { 1 }
                            " First-fault capture failed after $attempts attempt(s): $($recovery.firstFaultEvidenceError)"
                        } else { '' }
                        $expiry = if ($recovery.PSObject.Properties['expiresAtUtc'] -and $recovery.expiresAtUtc) {
                            " Guard expires $($recovery.expiresAtUtc)."
                        } else { '' }
                        $recoveryHint.Text = "Automatic recovery: $($recovery.status)$boundary. A stable save after consensus is archived and verified.$expiry$faultEvidence"
                        $recoveryHint.ForeColor = if ($recovery.status -eq 'failed' -or $faultEvidence) { $danger } else { $muted }
                    }
                    catch { }
                }
            }
        }
    }
    catch { }
})
$timer.Start()

$form.Add_FormClosed({ $timer.Stop() })
if ($SmokeTest) {
    $timer.Stop()
    $form.Dispose()
    Write-Host 'PASS multiplayer launcher UI constructed successfully'
    return
}
[void]$form.ShowDialog()
