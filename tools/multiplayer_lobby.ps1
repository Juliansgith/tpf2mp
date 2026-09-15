[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CredentialsPath,
    [Parameter(Mandatory = $true)][string]$GameExecutable,
    [Parameter(Mandatory = $true)][string]$ModDirectory,
    [string]$BundleRoot,
    [string]$NativeBuildDirectory,
    [switch]$AllowInsecureLoopback,
    [switch]$SmokeTest
)

# Lobby worker owns generation/transfer/launch; UI polling never runs game work.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
$credentials = Get-Content -LiteralPath $CredentialsPath -Raw | ConvertFrom-Json
if ($credentials.schemaVersion -ne 1 -or $credentials.role -notin @('host', 'join') `
        -or $credentials.sessionId -notmatch '^mp-[0-9a-f]{16}$') { throw 'Invalid lobby credential file.' }
$isHost = $credentials.role -eq 'host'
$supportId = [string]$credentials.sessionId
$credentials = $null # Never show the token or put it on a command line.
$companion = Get-Tpf2mpCompanionCommand $bundle
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object Windows.Forms.Form
$form.Text = "TPF2MP Lobby - $supportId"
$form.ClientSize = New-Object Drawing.Size(1180, 810)
$form.MinimumSize = $form.Size
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.BackColor = [Drawing.Color]::FromArgb(20, 30, 36)
$form.ForeColor = [Drawing.Color]::FromArgb(239, 245, 246)

function Add-Label([string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 25) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text
    $control.SetBounds($X, $Y, $Width, $Height)
    $form.Controls.Add($control)
    return $control
}
function Add-Button([string]$Text, [int]$X, [int]$Y, [int]$Width) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $Text
    $control.SetBounds($X, $Y, $Width, 34)
    $control.FlatStyle = 'Flat'
    $form.Controls.Add($control)
    return $control
}
function Add-Choice([string]$Label, [int]$X, [int]$Y, [string[]]$Values, [string]$Default) {
    [void](Add-Label $Label $X $Y 190)
    $control = New-Object Windows.Forms.ComboBox
    $control.SetBounds($X, ($Y + 25), 190, 28)
    $control.DropDownStyle = 'DropDownList'
    $control.Items.AddRange($Values)
    $control.SelectedItem = $Default
    $control.Enabled = $isHost
    $form.Controls.Add($control)
    return $control
}
[void](Add-Label $(if ($isHost) { 'HOST / WORLD SETUP' } else { 'PLAYER 2 / WORLD SETUP' }) 20 15 850)
$notice = Add-Label 'Generate a map, inspect the shared preview and regenerate if wanted. Both players accept / Ready, then the host starts.' 20 46 1135 48
$notice.ForeColor = [Drawing.Color]::FromArgb(245, 190, 92)
$worldControls = @{}
$worldControls.size = Add-Choice 'Map size' 20 102 @('small', 'medium', 'large') 'medium'
$worldControls.terrain = Add-Choice 'Terrain' 225 102 @('flat', 'hilly', 'mountainous') 'flat'
$worldControls.towns = Add-Choice 'Towns' 20 167 @('low', 'medium', 'high') 'medium'
$worldControls.industries = Add-Choice 'Industries' 225 167 @('low', 'medium', 'high') 'medium'
$worldControls.difficulty = Add-Choice 'TPF2MP economy' 20 232 @('relaxed', 'easy', 'normal', 'hard') 'normal'
$worldControls.agentMode = Add-Choice 'Native crowd simulation' 225 232 @('skeleton', 'vanilla', 'empty') 'skeleton'
[void](Add-Label 'Starting year' 20 300 190)
$year = New-Object Windows.Forms.NumericUpDown
$year.SetBounds(20, 325, 190, 28)
$year.Minimum = 1850; $year.Maximum = 2050; $year.Value = 1950; $year.Enabled = $isHost
$form.Controls.Add($year)
[void](Add-Label 'Map seed' 225 300 190)
$seed = New-Object Windows.Forms.NumericUpDown
$seed.SetBounds(225, 325, 190, 28)
$seed.Maximum = 2147483647; $seed.Value = Get-Random -Minimum 1 -Maximum 2147483647
$seed.Enabled = $isHost
$form.Controls.Add($seed)
$growth = New-Object Windows.Forms.CheckBox
$growth.Text = 'Physical town growth (experimental)'
$growth.SetBounds(20, 365, 400, 28); $growth.Enabled = $isHost
$form.Controls.Add($growth)
[void](Add-Label 'Installed mods (checked order is load order)' 20 410 425)
$mods = New-Object Windows.Forms.CheckedListBox
$mods.SetBounds(20, 435, 395, 118)
$mods.CheckOnClick = $true; $mods.Enabled = $isHost
$form.Controls.Add($mods)
$publish = Add-Button 'APPLY SETTINGS' 20 575 190
$existing = Add-Button 'USE EXISTING SAVE...' 220 575 195
$publish.Enabled = $isHost; $existing.Enabled = $isHost
$ready = Add-Button 'ACCEPT MAP / READY' 450 575 225
$unready = Add-Button 'NOT READY' 690 575 130
$ready.Enabled = $false; $unready.Enabled = $false
$peerStatus = Add-Label 'Connecting to lobby...' 20 632 410 55
$start = Add-Button 'START MATCH' 925 632 225
$generate = Add-Button 'GENERATE MAP' 925 575 225
$regenerate = Add-Button 'NEW SEED / REGENERATE' 450 632 300
$generate.Enabled = $false; $regenerate.Enabled = $false
$mapLabel = Add-Label 'Map preview - generate a world to begin' 450 102 700
$mapImage = New-Object Windows.Forms.PictureBox
$mapImage.SetBounds(450,132,700,394)
$mapImage.SizeMode = 'Zoom'; $mapImage.BackColor = [Drawing.Color]::FromArgb(12,20,25)
$form.Controls.Add($mapImage)
[void](Add-Label 'Actual generated world. Both players review the same saved map; no second generation on Start.' 450 532 700 36)
$start.Enabled = $false
$summary = New-Object Windows.Forms.TextBox
$summary.Multiline = $true; $summary.ReadOnly = $true; $summary.ScrollBars = 'Vertical'
$summary.SetBounds(20, 695, 1130, 66)
$form.Controls.Add($summary)
$errorLabel = Add-Label '' 20 766 1130 40
$errorLabel.ForeColor = [Drawing.Color]::FromArgb(245, 190, 92)

$script:lobbyState = $null
$script:lobbyWorker = $null
$script:lobbyMods = @()
$script:lobbyDirty = $false
$script:lobbyLastPoll = [DateTime]::MinValue
$script:lobbyDraftDirectory = $null
$script:lobbyFailures = 0
$script:lobbyStartingSave = $null
$script:lobbyLaunchStarted = $false
$script:lobbyPreviewDigest = $null
$script:lobbyPreviewFiles = @()
$script:lobbyGenerateAfterApply = $false

function Update-Buttons {
    $busy = $null -ne $script:lobbyWorker
    $configured = $script:lobbyState -and $script:lobbyState.config -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $publish.Enabled = $isHost -and -not $busy -and $script:lobbyMods.Count -gt 0 `
        -and $script:lobbyState -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $existing.Enabled = $isHost -and -not $busy -and $script:lobbyState `
        -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $reviewed = $configured -and ($script:lobbyState.config.mode -eq 'existing' -or
        ($script:lobbyState.phase -eq 'preview-ready' -and $script:lobbyPreviewDigest -ceq $script:lobbyState.previewDigest))
    $ready.Enabled = $reviewed -and -not $busy -and -not $script:lobbyDirty
    $unready.Enabled = $configured -and -not $busy
    $start.Enabled = $isHost -and $reviewed -and $script:lobbyState.canStart -and -not $busy -and -not $script:lobbyDirty
    $editable = $isHost -and -not $busy -and $script:lobbyState -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $generate.Enabled = $editable -and $script:lobbyMods.Count -gt 0
    $regenerate.Enabled = $generate.Enabled -and $script:lobbyState.phase -eq 'preview-ready'
    foreach ($control in $worldControls.Values) { $control.Enabled = $editable }
    foreach ($control in @($seed, $year, $growth, $mods)) { $control.Enabled = $editable }
}
function Start-LobbyMatchWorker {
    if ($script:lobbyLaunchStarted -or $script:lobbyWorker -or $SmokeTest) { return }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File', (Join-Path $PSScriptRoot 'start_lobby_match.ps1'),
        '-CredentialsPath',$CredentialsPath,'-GameExecutable',$GameExecutable,'-ModDirectory',$ModDirectory,
        '-BundleRoot',$bundle,'-ConfigDigest',[string]$script:lobbyState.configDigest)
    if ($script:lobbyStartingSave) { $arguments += @('-StartingSave',$script:lobbyStartingSave) }
    if ($NativeBuildDirectory) { $arguments += @('-NativeBuildDirectory',$NativeBuildDirectory) }
    if ($AllowInsecureLoopback) { $arguments += '-AllowInsecureLoopback' }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = ConvertTo-Tpf2mpCommandLine $arguments
    $info.WorkingDirectory = $bundle; $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Match worker did not start.' }
        $script:lobbyWorker = [pscustomobject]@{ Process=$process; Operation='match-launch'
            Output=$process.StandardOutput.ReadToEndAsync(); Error=$process.StandardError.ReadToEndAsync() }
        $script:lobbyLaunchStarted = $true
        $notice.Text = if ($script:lobbyState.phase -eq 'preview-generating') {
            'Generating a map for review. Neither multiplayer game will launch until you accept / Ready and Start.'
        } else { 'Transferring the accepted save / loading multiplayer. This can take a few minutes.' }
    } catch { $process.Dispose(); throw }
    Update-Buttons
}
function Start-LobbyRequest([string]$Operation, [string[]]$Extra = @()) {
    if ($script:lobbyWorker) { return }
    $arguments = @($companion.Prefix) + @('relay-lobby', $Operation, '--credentials', $CredentialsPath,
        '--game-executable', $GameExecutable, '--mod-directory', $ModDirectory) + $Extra
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $companion.FilePath
    $info.Arguments = ConvertTo-Tpf2mpCommandLine $arguments
    $info.WorkingDirectory = $bundle
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) { throw 'Lobby worker did not start.' }
        $script:lobbyWorker = [pscustomobject]@{ Process = $process; Operation = $Operation
            Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
    } catch { $process.Dispose(); throw }
    Update-Buttons
}
function Reviewed-Arguments {
    if (-not $script:lobbyState) { throw 'Wait for lobby status.' }
    $result = @('--revision', [string]$script:lobbyState.revision)
    if ($script:lobbyState.configDigest) { $result += @('--config-digest', [string]$script:lobbyState.configDigest) }
    if ($script:lobbyState.phase -eq 'preview-ready') { $result += @('--preview-digest',[string]$script:lobbyState.previewDigest) }
    return $result
}
function Show-LobbyState($State) {
    $script:lobbyState = $State
    $lines = foreach ($role in @('host', 'join')) {
        $entry = $State.peers.PSObject.Properties[$role]
        $peer = if ($entry) { $entry.Value } else { $null }
        $label = if ($role -eq 'host') { 'Player 1' } else { 'Player 2' }
        $value = if (-not $peer -or -not $peer.online) { 'not connected' } elseif ($peer.ready) { 'READY - content verified' } else { 'connected / not ready' }
        "$label : $value"
    }
    $peerStatus.Text = ($lines -join "`r`n")
    if ($State.config) {
        $c = $State.config
        $details = @("Agreed settings / revision $($State.revision) / $($State.phase)", "Mode: $($c.mode) | TPF2MP $($c.release)")
        if ($c.world) {
            $details += 'Temperate / square / no water / all vehicles / English names (native Easy; TPF2MP economy below)'
            $details += "Seed $($c.world.seed) | $($c.world.size), $($c.world.terrain) | Year $($c.world.year) | Economy $($c.world.difficulty)"
            $details += "Towns $($c.world.towns) | Industries $($c.world.industries) | Agents $($c.world.agentMode) | Physical growth $($c.world.townDevelopment)"
            if (-not $isHost) {
                foreach ($key in $worldControls.Keys) { $worldControls[$key].SelectedItem = [string]$c.world.$key }
                $seed.Value = $c.world.seed; $year.Value = $c.world.year; $growth.Checked = $c.world.townDevelopment
            }
        }
        $details += 'Mods: ' + (($c.mods | ForEach-Object { "$($_.id) v$($_.version)" }) -join ', ')
        $summary.Text = $details -join "`r`n"
    } else { $summary.Text = 'The host has not published world settings yet.' }
    Update-Buttons
    if (-not $State.PSObject.Properties['previewDigest'] -or -not $State.previewDigest) {
        $script:lobbyPreviewDigest = $null
        if ($mapImage.Image) { $mapImage.Image.Dispose(); $mapImage.Image = $null }
        $mapLabel.Text = if ($State.phase -eq 'preview-generating') { 'Generating native map overview...' } else { 'Map preview - generate a world to begin' }
    }
    if ($State.phase -eq 'preview-ready' -and $script:lobbyPreviewDigest -cne $State.previewDigest -and -not $SmokeTest) {
        if (-not $script:lobbyDraftDirectory) {
            $script:lobbyDraftDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-lobby-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $script:lobbyDraftDirectory)
        }
        $script:lobbyNextPreview = Join-Path $script:lobbyDraftDirectory ([guid]::NewGuid().ToString('N') + '.bmp')
        $script:lobbyPreviewFiles += $script:lobbyNextPreview
        Start-LobbyRequest 'preview-download' ((Reviewed-Arguments) + @('--preview-file',$script:lobbyNextPreview))
    }
    if ($State.phase -in @('generating','preparing-save','save-ready') -or ($isHost -and $State.phase -eq 'preview-generating')) { Start-LobbyMatchWorker }
}
foreach ($control in $worldControls.Values) { $control.add_SelectedIndexChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons }) }
$seed.add_ValueChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$year.add_ValueChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$growth.add_CheckedChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$mods.add_ItemCheck({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
function Publish-LobbyWorld {
    try {
        $selected = @(foreach ($index in $mods.CheckedIndices) {
            $item = $script:lobbyMods[$index]
            if (-not $item.selectable) { throw 'Workshop version must be read from native metadata. Use an existing save for this mod for now.' }
            @{ id = [string]$item.id; version = [int]$item.version }
        })
        $world = @{ seed = [int]$seed.Value; year = [int]$year.Value; townDevelopment = [bool]$growth.Checked }
        foreach ($key in $worldControls.Keys) { $world[$key] = [string]$worldControls[$key].SelectedItem }
        if (-not $script:lobbyDraftDirectory) {
            $script:lobbyDraftDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-lobby-' + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $script:lobbyDraftDirectory)
        }
        $path = Join-Path $script:lobbyDraftDirectory 'world.json'
        [IO.File]::WriteAllText($path, (@{ world = $world; mods = $selected } | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
        Start-LobbyRequest 'configure-new' ((Reviewed-Arguments) + @('--configuration', $path))
    } catch { $script:lobbyGenerateAfterApply = $false; $errorLabel.Text = $_.Exception.Message }
}
$publish.add_Click({ Publish-LobbyWorld })
$generate.add_Click({ $script:lobbyGenerateAfterApply = $true; Publish-LobbyWorld })
$regenerate.add_Click({
    $seed.Value = Get-Random -Minimum 1 -Maximum 2147483647
    $script:lobbyGenerateAfterApply = $true; Publish-LobbyWorld
})
$existing.add_Click({
    $picker = New-Object Windows.Forms.OpenFileDialog
    try {
        $picker.Filter = 'Transport Fever 2 save (*.sav)|*.sav'
        if ($picker.ShowDialog($form) -eq 'OK') {
            $script:lobbyStartingSave = $picker.FileName
            Start-LobbyRequest 'configure-save' ((Reviewed-Arguments) + @('--save', $picker.FileName))
        }
    } catch { $errorLabel.Text = $_.Exception.Message } finally { $picker.Dispose() }
})
$ready.add_Click({ try { Start-LobbyRequest 'ready' (Reviewed-Arguments) } catch { $errorLabel.Text = $_.Exception.Message } })
$unready.add_Click({ try { Start-LobbyRequest 'unready' (Reviewed-Arguments) } catch { $errorLabel.Text = $_.Exception.Message } })
$start.add_Click({ try { Start-LobbyRequest 'start' (Reviewed-Arguments) } catch { $errorLabel.Text = $_.Exception.Message } })
$form.add_FormClosing({
    param($sender,$eventArgs)
    if ($script:lobbyWorker -and $script:lobbyWorker.Operation -eq 'match-launch') {
        $eventArgs.Cancel = $true
        $errorLabel.Text = 'Please wait for the active generation/launch job to finish or report an error before closing this lobby.'
    }
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
    try {
        if ($script:lobbyWorker) {
            $worker = $script:lobbyWorker
            if (-not $worker.Process.HasExited -or -not $worker.Output.IsCompleted -or -not $worker.Error.IsCompleted) { return }
            $exitCode = $worker.Process.ExitCode
            $stdout = $worker.Output.Result; $stderr = $worker.Error.Result
            $worker.Process.Dispose(); $script:lobbyWorker = $null
            if ($exitCode -ne 0) { throw "Lobby request failed: $stderr" }
            if ($worker.Operation -eq 'match-launch') {
                $summary.Text = $stdout
                if ($stdout -match '(?m)^lobby_preview_prepared=') {
                    $script:lobbyLaunchStarted = $false
                    $notice.Text = 'Map generated. Review the preview, regenerate or accept / Ready on both PCs.'
                    Start-LobbyRequest 'presence'; return
                }
                $notice.Text = if ($stdout -match '(?m)^lobby_match_existing=') {
                    'This role was already launched. Return to its game, or stop it and create a new room.'
                } else { 'The local multiplayer world is loaded. Check in-game readiness while the other player finishes loading.' }
                $timer.Stop(); Update-Buttons; return
            }
            $value = $stdout | ConvertFrom-Json
            $script:lobbyFailures = 0; $errorLabel.Text = ''
            if ($worker.Operation -eq 'preview-download') {
                $bitmap = [Drawing.Image]::FromFile($script:lobbyNextPreview)
                try {
                    if ($mapImage.Image) { $mapImage.Image.Dispose() }
                    $mapImage.Image = New-Object Drawing.Bitmap($bitmap)
                } finally { $bitmap.Dispose() }
                $script:lobbyPreviewDigest = [string]$value.previewDigest
                $mapLabel.Text = "Native map - seed $($value.config.world.seed) | White: towns / orange: industries"
                Show-LobbyState $value
            } elseif ($worker.Operation -eq 'catalogue') {
                $script:lobbyMods = @($value.mods)
                foreach ($item in $script:lobbyMods) {
                    $text = "$($item.id) v$($item.version) [$($item.source)]"
                    if (-not $item.selectable) { $text += ' - existing save only for now' }
                    [void]$mods.Items.Add($text, ($item.id -in @('!tpf2_mp', 'tpf2_mp')))
                }
            } else {
                if ($worker.Operation -in @('configure-new', 'configure-save')) { $script:lobbyDirty = $false }
                Show-LobbyState $value
                if ($worker.Operation -eq 'configure-new' -and $script:lobbyGenerateAfterApply) {
                    $script:lobbyGenerateAfterApply = $false
                    Start-LobbyRequest 'generate' (Reviewed-Arguments)
                }
            }
            Update-Buttons
        }
        $delay = if ($script:lobbyFailures -gt 0) { 10 } else { 3 }
        if (-not $script:lobbyWorker -and ([DateTime]::UtcNow - $script:lobbyLastPoll).TotalSeconds -ge $delay) {
            $script:lobbyLastPoll = [DateTime]::UtcNow
            Start-LobbyRequest 'presence'
        }
    } catch {
        $script:lobbyFailures++
        $script:lobbyGenerateAfterApply = $false
        $script:lobbyLastPoll = [DateTime]::UtcNow
        $errorLabel.Text = $_.Exception.Message.Substring(0, [Math]::Min(850, $_.Exception.Message.Length))
        $script:lobbyState = $null
        $peerStatus.Text = 'Lobby unavailable. Ready is disabled until the connection recovers.'
        Update-Buttons
    }
})
try {
    if ($SmokeTest) {
        if ($form.Controls.Count -lt 25 -or $ready.Enabled) { throw 'Lobby control construction failed.' }
        Show-LobbyState ('{"schemaVersion":1,"revision":0,"config":null,"configDigest":null,"phase":"configuring","peers":{},"canStart":false}' | ConvertFrom-Json)
        if ($ready.Enabled -or $peerStatus.Text -notmatch 'not connected') { throw 'Empty lobby must not allow Ready.' }
        $review = '{"schemaVersion":1,"revision":2,"config":{"mode":"new","world":{"seed":7,"year":1950,"size":"small","terrain":"flat","difficulty":"normal","towns":"low","industries":"low","agentMode":"skeleton","townDevelopment":false},"mods":[]},"configDigest":"config","previewDigest":"map","phase":"preview-ready","peers":{},"canStart":true}' | ConvertFrom-Json
        $review.config | Add-Member -NotePropertyName release -NotePropertyValue 'test'
        Show-LobbyState $review
        if ($ready.Enabled -or $start.Enabled) { throw 'An undownloaded preview cannot be accepted.' }
        $script:lobbyPreviewDigest = 'map'; $script:lobbyDirty = $false
        Show-LobbyState $review
        if (-not $ready.Enabled -or ($isHost -and -not $start.Enabled)) { throw 'Reviewed map readiness failed.' }
        Write-Output 'Lobby dialog smoke passed (no window shown, no network/game started).'
    } else {
        Start-LobbyRequest 'catalogue'
        $timer.Start()
        [void]$form.ShowDialog()
    }
} finally {
    $timer.Stop(); $timer.Dispose()
    if ($script:lobbyWorker) {
        if (-not $script:lobbyWorker.Process.HasExited) { $script:lobbyWorker.Process.Kill(); $script:lobbyWorker.Process.WaitForExit() }
        $script:lobbyWorker.Process.Dispose()
    }
    # Deliberately do not close the room or terminate a game on closing this
    # settings dialog. Its presence expires; launcher remains session owner.
    if ($script:lobbyDraftDirectory) {
        foreach ($file in $script:lobbyPreviewFiles) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file } }
        $draftPath = Join-Path $script:lobbyDraftDirectory 'world.json'
        if (Test-Path -LiteralPath $draftPath) { Remove-Item -LiteralPath $draftPath }
        Remove-Item -LiteralPath $script:lobbyDraftDirectory # own empty unique directory only
    }
    if ($mapImage.Image) { $mapImage.Image.Dispose() }
    $form.Dispose()
}
