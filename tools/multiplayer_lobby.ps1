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
$form.ClientSize = New-Object Drawing.Size(900, 740)
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
$notice = Add-Label 'Review the settings, verify mods and Ready on both PCs. The host starts once; generation, save transfer and loading are automatic.' 20 46 855 48
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
[void](Add-Label 'Installed mods (checked order is load order)' 450 102 430)
$mods = New-Object Windows.Forms.CheckedListBox
$mods.SetBounds(450, 132, 425, 261)
$mods.CheckOnClick = $true; $mods.Enabled = $isHost
$form.Controls.Add($mods)
$publish = Add-Button 'APPLY NEW WORLD SETTINGS' 20 408 270
$existing = Add-Button 'USE EXISTING SAVE...' 310 408 220
$publish.Enabled = $isHost; $existing.Enabled = $isHost
$ready = Add-Button 'VERIFY MODS / READY' 550 408 220
$unready = Add-Button 'NOT READY' 775 408 100
$ready.Enabled = $false; $unready.Enabled = $false
$peerStatus = Add-Label 'Connecting to lobby...' 20 460 605 55
$start = Add-Button 'START MATCH' 650 460 225
$start.Enabled = $false
$summary = New-Object Windows.Forms.TextBox
$summary.Multiline = $true; $summary.ReadOnly = $true; $summary.ScrollBars = 'Vertical'
$summary.SetBounds(20, 520, 855, 128)
$form.Controls.Add($summary)
$errorLabel = Add-Label '' 20 660 855 65
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

function Update-Buttons {
    $busy = $null -ne $script:lobbyWorker
    $configured = $script:lobbyState -and $script:lobbyState.config -and $script:lobbyState.phase -eq 'configuring'
    $publish.Enabled = $isHost -and -not $busy -and $script:lobbyMods.Count -gt 0 `
        -and $script:lobbyState -and $script:lobbyState.phase -eq 'configuring'
    $existing.Enabled = $isHost -and -not $busy -and $script:lobbyState `
        -and $script:lobbyState.phase -eq 'configuring'
    $ready.Enabled = $configured -and -not $busy -and -not $script:lobbyDirty
    $unready.Enabled = $configured -and -not $busy
    $start.Enabled = $isHost -and $configured -and $script:lobbyState.canStart -and -not $busy -and -not $script:lobbyDirty
    $editable = $isHost -and -not $busy -and $script:lobbyState -and $script:lobbyState.phase -eq 'configuring'
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
        $notice.Text = 'Preparing the world / transferring save / loading multiplayer. This can take a few minutes.'
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
    if ($State.phase -in @('generating','preparing-save','save-ready')) { Start-LobbyMatchWorker }
}
foreach ($control in $worldControls.Values) { $control.add_SelectedIndexChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons }) }
$seed.add_ValueChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$year.add_ValueChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$growth.add_CheckedChanged({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$mods.add_ItemCheck({ if ($isHost) { $script:lobbyDirty = $true }; Update-Buttons })
$publish.add_Click({
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
    } catch { $errorLabel.Text = $_.Exception.Message }
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
                $notice.Text = if ($stdout -match '(?m)^lobby_match_existing=') {
                    'This role was already launched. Return to its game, or stop it and create a new room.'
                } else { 'The local multiplayer world is loaded. Check in-game readiness while the other player finishes loading.' }
                $timer.Stop(); Update-Buttons; return
            }
            $value = $stdout | ConvertFrom-Json
            $script:lobbyFailures = 0; $errorLabel.Text = ''
            if ($worker.Operation -eq 'catalogue') {
                $script:lobbyMods = @($value.mods)
                foreach ($item in $script:lobbyMods) {
                    $text = "$($item.id) v$($item.version) [$($item.source)]"
                    if (-not $item.selectable) { $text += ' - existing save only for now' }
                    [void]$mods.Items.Add($text, ($item.id -in @('!tpf2_mp', 'tpf2_mp')))
                }
            } else {
                if ($worker.Operation -in @('configure-new', 'configure-save')) { $script:lobbyDirty = $false }
                Show-LobbyState $value
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
        $draftPath = Join-Path $script:lobbyDraftDirectory 'world.json'
        if (Test-Path -LiteralPath $draftPath) { Remove-Item -LiteralPath $draftPath }
        Remove-Item -LiteralPath $script:lobbyDraftDirectory # own empty unique directory only
    }
    $form.Dispose()
}
