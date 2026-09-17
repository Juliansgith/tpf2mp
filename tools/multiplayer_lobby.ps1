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
$credentials = $null
$companion = Get-Tpf2mpCompanionCommand $bundle
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'launcher_theme.ps1')
[Windows.Forms.Application]::EnableVisualStyles()

$theme = Get-Tpf2mpTheme
$fonts = Get-Tpf2mpFonts

# List scrollbars and check glyphs come from the window theme, which stays light
# even on a dark control. Opting the list into the dark explorer theme keeps the
# Mods tab consistent. Guarded because the smoke test runs this script twice in
# one session, and optional because it is decoration only.
try {
    if (-not ('Tpf2mpWindowTheme' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Tpf2mpWindowTheme {
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    private static extern int SetWindowTheme(IntPtr window, string application, string id);
    public static void Apply(IntPtr window, string application) { SetWindowTheme(window, application, null); }
}
'@
    }
} catch { }

# Dark owner-drawn painters for the two system controls the theme module does
# not cover: combo boxes and up/down spinners.
$script:comboPainter = {
    param($sender, $eventArgs)
    $colors = Get-Tpf2mpTheme
    $isEdit = ($eventArgs.State -band [Windows.Forms.DrawItemState]::ComboBoxEdit) -ne 0
    $isHot = (-not $isEdit) -and (($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0)
    $fill = New-Object Drawing.SolidBrush($(if ($isHot) { $colors.SurfaceAlt } else { $colors.Field }))
    if ($isEdit) { $eventArgs.Graphics.FillRectangle($fill, 0, 0, $sender.Width, $sender.Height) }
    else { $eventArgs.Graphics.FillRectangle($fill, $eventArgs.Bounds) }
    $fill.Dispose()
    $color = if ($sender.Enabled) { $colors.Text } else { $colors.Disabled }
    if ($eventArgs.Index -ge 0) {
        $bounds = [Drawing.Rectangle]::new(($eventArgs.Bounds.X + 8), $eventArgs.Bounds.Y,
            ($eventArgs.Bounds.Width - 10), $eventArgs.Bounds.Height)
        [Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics, [string]$sender.Items[$eventArgs.Index],
            $sender.Font, $bounds, $color,
            ([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis))
    }
    if ($isEdit -and $sender.Parent) {
        # The system's light drop-down button hangs outside the field frame and
        # is clipped away, so the closed box draws its own chevron instead.
        $arrow = New-Object Drawing.SolidBrush($(if ($sender.Enabled) { $colors.Muted } else { $colors.Disabled }))
        $eventArgs.Graphics.SmoothingMode = 'AntiAlias'
        $x = $sender.Parent.ClientSize.Width - $sender.Left - 14
        $y = [int]($sender.Height / 2)
        $eventArgs.Graphics.FillPolygon($arrow, @([Drawing.Point]::new(($x - 4), ($y - 2)),
            [Drawing.Point]::new(($x + 4), ($y - 2)), [Drawing.Point]::new($x, ($y + 3))))
        $arrow.Dispose()
    }
}
$script:spinnerPainter = {
    param($sender, $eventArgs)
    $colors = Get-Tpf2mpTheme
    $fill = New-Object Drawing.SolidBrush($colors.Field)
    $eventArgs.Graphics.FillRectangle($fill, 0, 0, $sender.Width, $sender.Height)
    $arrow = New-Object Drawing.SolidBrush($(if ($sender.Parent.Enabled) { $colors.Muted } else { $colors.Disabled }))
    $eventArgs.Graphics.SmoothingMode = 'AntiAlias'
    $middle = [int]($sender.Width / 2)
    $top = [int]($sender.Height / 4)
    $bottom = [int]($sender.Height * 3 / 4)
    $eventArgs.Graphics.FillPolygon($arrow, @([Drawing.Point]::new(($middle - 4), ($top + 2)),
        [Drawing.Point]::new(($middle + 4), ($top + 2)), [Drawing.Point]::new($middle, ($top - 3))))
    $eventArgs.Graphics.FillPolygon($arrow, @([Drawing.Point]::new(($middle - 4), ($bottom - 2)),
        [Drawing.Point]::new(($middle + 4), ($bottom - 2)), [Drawing.Point]::new($middle, ($bottom + 3))))
    $fill.Dispose(); $arrow.Dispose()
}

# A hairline field frame, matching New-Tpf2mpTextBox, for the controls that
# cannot draw their own dark border.
function New-FieldFrame($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height = 32) {
    $frame = New-Object Windows.Forms.Panel
    $frame.SetBounds($X, $Y, $Width, $Height)
    $frame.BackColor = $theme.Field
    $border = $theme.FieldBorder
    $frame.Add_Paint({
        param($sender, $eventArgs)
        $pen = New-Object Drawing.Pen($border)
        $eventArgs.Graphics.DrawRectangle($pen, 0, 0, ($sender.Width - 1), ($sender.Height - 1))
        $pen.Dispose()
    }.GetNewClosure())
    $Parent.Controls.Add($frame)
    return $frame
}
function Get-FriendlyChoice([string]$Value) {
    switch ($Value) {
        'very hard' { 'Very hard' }
        'skeleton' { 'Reduced crowds' }
        'vanilla' { 'Full native crowds' }
        'empty' { 'No native crowds' }
        'disabled' { 'Off' }
        'england' { 'English' }
        'usa' { 'North American' }
        'asia' { 'Asian' }
        'europe' { 'European' }
        default { if ($Value.Length) { $Value.Substring(0,1).ToUpperInvariant()+$Value.Substring(1) } else { $Value } }
    }
}
function Add-Choice($Parent, [string]$Label, [int]$X, [int]$Y, [int]$Width, [string[]]$Values, [string]$Default) {
    [void](New-Tpf2mpLabel $Parent $Label $X $Y $Width 18 'Muted')
    $frame = New-FieldFrame $Parent $X ($Y + 20) $Width 32
    $control = New-Object Windows.Forms.ComboBox
    $control.DropDownStyle = 'DropDownList'
    $control.FlatStyle = 'Flat'
    $control.DrawMode = 'OwnerDrawFixed'
    $control.ItemHeight = 32
    $control.Font = $fonts.Base
    $control.BackColor = $theme.Field
    $control.ForeColor = $theme.Text
    # Three pixels of overhang on every edge, plus the drop-down button's width
    # on the right, push the system's light flat chrome outside the frame's
    # client area, where it is clipped. Clicks still land on the combo box.
    $control.SetBounds(-3, -3, ($Width + 28), 38)
    $control.add_DrawItem($script:comboPainter)
    $control.Tag = [string[]]$Values
    [void]$control.Items.AddRange([string[]]@($Values | ForEach-Object { Get-FriendlyChoice $_ }))
    $control.SelectedIndex = [Array]::IndexOf($Values, $Default)
    $frame.Controls.Add($control)
    return $control
}
function Get-ChoiceValue($Control) {
    if ($Control.SelectedIndex -lt 0) { return '' }
    return [string]$Control.Tag[$Control.SelectedIndex]
}
function Set-ChoiceValue($Control, [string]$Value) {
    $index = [Array]::IndexOf([string[]]$Control.Tag, $Value)
    if ($index -ge 0 -and $Control.SelectedIndex -ne $index) { $Control.SelectedIndex = $index }
}
function Add-Number($Parent, [string]$Label, [int]$X, [int]$Y, [int]$Width, [int]$Minimum, [int]$Maximum, [int]$Value) {
    [void](New-Tpf2mpLabel $Parent $Label $X $Y $Width 18 'Muted')
    $frame = New-FieldFrame $Parent $X ($Y + 20) $Width 32
    $control = New-Object Windows.Forms.NumericUpDown
    $control.BorderStyle = 'None'
    $control.Font = $fonts.Base
    $control.BackColor = $theme.Field
    $control.ForeColor = $theme.Text
    $control.Minimum = $Minimum; $control.Maximum = $Maximum; $control.Value = $Value
    $control.SetBounds(9, 6, ($Width - 18), 20)
    $frame.Controls.Add($control)
    $control.Controls[0].BackColor = $theme.Field
    $control.Controls[0].add_Paint($script:spinnerPainter)
    return $control
}
function Add-Slider($Parent, [string]$Name, [int]$Maximum, [int]$Default) {
    $caption = New-Tpf2mpLabel $Parent $Name 0 0 105 18 'Muted'
    $value = New-Tpf2mpLabel $Parent "$Default / $Maximum" 105 0 58 18 'Faint'
    $value.TextAlign = 'TopRight'
    $control = New-Object Windows.Forms.TrackBar
    $control.SetBounds(0, 20, 158, 30); $control.Minimum = 0; $control.Maximum = $Maximum
    $control.TickStyle = 'None'; $control.AutoSize = $false; $control.Value = $Default
    $control.BackColor = $theme.SurfaceAlt
    $Parent.Controls.Add($control)
    $handler = { $value.Text = "$($control.Value) / $($control.Maximum)" }.GetNewClosure()
    $control.add_ValueChanged($handler)
    return [pscustomobject]@{ Label=$caption; ValueLabel=$value; Control=$control; Name=$Name }
}
function Set-ControlText($Control, [string]$Value) { if ($Control.Text -cne $Value) { $Control.Text = $Value } }
function Set-ControlEnabled($Control, [bool]$Value) { if ($Control.Enabled -ne $Value) { $Control.Enabled = $Value } }
function Set-PeerState($Pill, [string]$Value) {
    $state = if ($Value -eq 'Ready') { 'Success' } elseif ($Value -eq 'Offline') { 'Muted' } else { 'Info' }
    Set-Tpf2mpPill $Pill $Value $state
}

$form = New-Object Windows.Forms.Form
Set-Tpf2mpFormStyle $form "TPF2MP - $supportId"
$form.ClientSize = [Drawing.Size]::new(1400, 890)
$form.MinimumSize = $form.Size
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

# Header: title, role pill and support id, then the connection notice.
$title = New-Tpf2mpLabel $form 'Create multiplayer world' 28 22 620 34 'Title'
$title.TextAlign = 'MiddleLeft'
$sessionLabel = New-Tpf2mpLabel $form "Support ID  $supportId" 860 30 400 18 'Faint'
$sessionLabel.TextAlign = 'MiddleRight'
$roleBadge = New-Tpf2mpPill $form 'Host' 1280 26 92 26
Set-Tpf2mpPill $roleBadge $(if ($isHost) { 'Host' } else { 'Join' }) $(if ($isHost) { 'Accent' } else { 'Info' })
$noticeBar = New-Tpf2mpCard $form 28 72 1344 34 '' $theme.SurfaceAlt
$noticeAccent = New-Object Windows.Forms.Panel
$noticeAccent.SetBounds(1, 1, 3, 32); $noticeAccent.BackColor = $theme.Warning
$noticeBar.Controls.Add($noticeAccent)
$notice = New-Tpf2mpLabel $noticeBar 'Connecting...' 18 7 1200 20
$notice.ForeColor = $theme.Warning

$settingsPanel = New-Tpf2mpCard $form 28 116 620 682 'World settings'
$tabs = New-Object Windows.Forms.TabControl
$tabs.SetBounds(18, 44, 584, 568); $settingsPanel.Controls.Add($tabs)
$mapTab = New-Object Windows.Forms.TabPage; $mapTab.Text = 'Map'; $tabs.TabPages.Add($mapTab)
$gameplayTab = New-Object Windows.Forms.TabPage; $gameplayTab.Text = 'Gameplay'; $tabs.TabPages.Add($gameplayTab)
$modsTab = New-Object Windows.Forms.TabPage; $modsTab.Text = 'Mods'; $tabs.TabPages.Add($modsTab)
Set-Tpf2mpTabStyle $tabs

$worldControls = @{}
$worldControls.climate = Add-Choice $mapTab 'Climate' 16 18 170 @('temperate','dry','tropical') 'temperate'
$worldControls.size = Add-Choice $mapTab 'Map size' 203 18 170 @('small','medium','large') 'medium'
$worldControls.format = Add-Choice $mapTab 'Map format' 390 18 170 @('1:1','1:2','1:3','1:4','1:5') '1:1'
$year = Add-Number $mapTab 'Starting year' 16 84 170 1850 2050 1950
$worldControls.environment = Add-Choice $mapTab 'Environment' 203 84 170 @('temperate','dry','tropical') 'temperate'
$worldControls.vehicles = Add-Choice $mapTab 'Vehicles' 390 84 170 @('europe','usa','asia','all') 'all'
$worldControls.nameList = Add-Choice $mapTab 'Town names' 16 150 170 @('europe','england','france','germany','italy','korea','netherlands','norway','russia','spain','sweden','usa','asia') 'england'
$worldControls.towns = Add-Choice $mapTab 'Towns' 203 150 170 @('low','medium','high') 'medium'
$worldControls.industries = Add-Choice $mapTab 'Initial industries' 390 150 170 @('low','medium','high') 'medium'
$worldControls.industryTarget = Add-Choice $mapTab 'Industry growth target' 16 216 170 @('disabled','low','medium','high') 'medium'
$seed = Add-Number $mapTab 'Map seed' 203 216 170 0 2147483647 (Get-Random -Minimum 1 -Maximum 2147483647)
$randomSeed = New-Tpf2mpButton $mapTab 'Randomize' 390 236 170 32 'Ghost'

$terrainBox = New-Tpf2mpCard $mapTab 16 288 544 176 'Terrain' $theme.SurfaceAlt
$terrain = @{}
foreach ($definition in @(
    @('hilliness','Hilliness',4,2), @('water','Water',4,2), @('forest','Forest',6,3),
    @('canyon','Canyons',4,2), @('mesa','Mesas',4,2), @('ridge','Ridges',4,2),
    @('land','Mainland',4,2), @('islands','Islands',6,3))) {
    $terrain[$definition[0]] = Add-Slider $terrainBox $definition[1] $definition[2] $definition[3]
}
function Update-TerrainLayout {
    $active = switch (Get-ChoiceValue $worldControls.climate) {
        'dry' { @('canyon','mesa','ridge','water','forest') }
        'tropical' { @('hilliness','land','forest','islands') }
        default { @('hilliness','water','forest') }
    }
    foreach ($item in $terrain.Values) { $item.Label.Visible=$false; $item.ValueLabel.Visible=$false; $item.Control.Visible=$false }
    for ($index=0; $index -lt $active.Count; $index++) {
        $item = $terrain[$active[$index]]; $column=$index%3; $row=[Math]::Floor($index/3)
        $x=18+$column*176; $y=48+$row*62
        $item.Label.SetBounds($x,$y,105,18); $item.ValueLabel.SetBounds(($x+100),$y,58,18)
        $item.Control.SetBounds($x,($y+20),158,30)
        $item.Label.Visible=$true; $item.ValueLabel.Visible=$true; $item.Control.Visible=$true
    }
}
Update-TerrainLayout

$worldControls.difficulty = Add-Choice $gameplayTab 'TPF2MP economy' 16 18 262 @('relaxed','easy','normal','hard') 'normal'
$worldControls.nativeDifficulty = Add-Choice $gameplayTab 'Native rules' 298 18 262 @('easy','medium','hard','very hard') 'easy'
$worldControls.agentMode = Add-Choice $gameplayTab 'Native crowd simulation' 16 84 262 @('skeleton','vanilla','empty') 'skeleton'
[void](New-Tpf2mpRule $gameplayTab 16 160 544)
$growth = New-Tpf2mpCheckBox $gameplayTab 'Physical town growth (experimental)' 16 182 420 24

$modsHeader = New-Tpf2mpLabel $modsTab 'Enabled content - order is load order' 16 18 544 18 'Muted'
$modsFrame = New-FieldFrame $modsTab 16 44 544 464
$mods = New-Object Windows.Forms.CheckedListBox
$mods.SetBounds(1, 1, 542, 462); $mods.CheckOnClick = $true
$mods.BorderStyle = 'None'; $mods.IntegralHeight = $false
$mods.Font = $fonts.Base
$mods.BackColor = $theme.Field; $mods.ForeColor = $theme.Text
$modsFrame.Controls.Add($mods)
if ('Tpf2mpWindowTheme' -as [type]) {
    $mods.Add_HandleCreated({ param($sender, $eventArgs) [Tpf2mpWindowTheme]::Apply($sender.Handle, 'DarkMode_Explorer') })
}

$existing = New-Tpf2mpButton $settingsPanel 'Use existing save' 18 628 170 36 'Ghost'
$newSeed = New-Tpf2mpButton $settingsPanel 'New seed' 200 628 120 36 'Ghost'
$generate = New-Tpf2mpButton $settingsPanel 'Generate preview' 412 628 190 36 'Secondary'

$previewPanel = New-Tpf2mpCard $form 668 116 704 682 'Map preview'
$previewState = New-Tpf2mpLabel $previewPanel 'Choose settings and generate a preview.' 18 40 540 20 'Muted'
[void](New-FieldFrame $previewPanel 17 69 670 422)
$mapImage = New-Object Windows.Forms.PictureBox
$mapImage.SetBounds(18, 70, 668, 420); $mapImage.SizeMode = 'Zoom'; $mapImage.BackColor = $theme.Field
$previewPanel.Controls.Add($mapImage)
$previewMeta = New-Tpf2mpLabel $previewPanel '' 18 502 668 18 'Faint'
$peerOne = New-Tpf2mpCard $previewPanel 18 536 326 68 '' $theme.SurfaceAlt
$peerTwo = New-Tpf2mpCard $previewPanel 360 536 326 68 '' $theme.SurfaceAlt
[void](New-Tpf2mpLabel $peerOne 'Player 1' 16 25 160 18 'Section')
[void](New-Tpf2mpLabel $peerTwo 'Player 2' 16 25 160 18 'Section')
$peerOneState = New-Tpf2mpPill $peerOne 'Connecting' 194 22 116 24
$peerTwoState = New-Tpf2mpPill $peerTwo 'Connecting' 194 22 116 24
$ready = New-Tpf2mpButton $previewPanel 'Ready' 142 624 150 36 'Secondary'
$unready = New-Tpf2mpButton $previewPanel 'Not ready' 304 624 150 36 'Ghost'
$start = New-Tpf2mpButton $previewPanel 'Start match' 466 620 220 44 'Primary'
$ready.Enabled=$false; $unready.Enabled=$false; $start.Enabled=$false

$errorLabel = New-Tpf2mpLabel $form '' 28 814 1344 34
$errorLabel.ForeColor = $theme.Danger
$footer = New-Tpf2mpLabel $form 'Settings stay local until you generate a preview. Both players must review the same preview.' 28 852 1344 20 'Faint'

$script:lobbyState = $null
$script:lobbyWorker = $null
$script:lobbyPendingRequest = $null
$script:lobbyMods = @()
$script:lobbyDirty = $false
$script:lobbySuppressEvents = $false
$script:lobbyLastPoll = [DateTime]::MinValue
$script:lobbyLastStateKey = $null
$script:lobbyDraftDirectory = $null
$script:lobbyFailures = 0
$script:lobbyStartingSave = $null
$script:lobbyLaunchStarted = $false
$script:lobbyPreviewDigest = $null
$script:lobbyPreviewFiles = @()
$script:lobbyGenerateAfterApply = $false

function Test-InteractiveBusy {
    return $script:lobbyWorker -and $script:lobbyWorker.Operation -notin @('presence','preview-download','catalogue')
}
function Update-Buttons {
    $busy = Test-InteractiveBusy
    $configured = $script:lobbyState -and $script:lobbyState.config -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $editable = $isHost -and -not $busy -and $script:lobbyState -and $script:lobbyState.phase -in @('configuring','preview-ready')
    $reviewed = $configured -and ($script:lobbyState.config.mode -eq 'existing' -or
        ($script:lobbyState.phase -eq 'preview-ready' -and $script:lobbyPreviewDigest -ceq $script:lobbyState.previewDigest))
    foreach ($control in $worldControls.Values) { Set-ControlEnabled $control $editable }
    foreach ($item in $terrain.Values) { Set-ControlEnabled $item.Control $editable }
    foreach ($control in @($seed,$year,$growth,$mods,$randomSeed,$newSeed)) { Set-ControlEnabled $control $editable }
    Set-ControlEnabled $existing ($editable)
    Set-ControlEnabled $generate ($editable -and $script:lobbyMods.Count -gt 0)
    Set-ControlEnabled $ready ($reviewed -and -not $busy -and -not $script:lobbyDirty)
    Set-ControlEnabled $unready ($configured -and -not $busy)
    Set-ControlEnabled $start ($isHost -and $reviewed -and $script:lobbyState.canStart -and -not $busy -and -not $script:lobbyDirty)
    Set-ControlText $generate $(if ($script:lobbyState -and $script:lobbyState.phase -eq 'preview-ready') { 'Regenerate preview' } else { 'Generate preview' })
}
function Mark-Dirty {
    if ($isHost -and -not $script:lobbySuppressEvents) {
        $script:lobbyDirty = $true
        Set-ControlText $previewState 'Settings changed - generate a new preview.'
        Update-Buttons
    }
}
foreach ($control in $worldControls.Values) { $control.add_SelectedIndexChanged({ Mark-Dirty }) }
$worldControls.climate.add_SelectedIndexChanged({ Update-TerrainLayout })
foreach ($item in $terrain.Values) { $item.Control.add_ValueChanged({ Mark-Dirty }) }
$seed.add_ValueChanged({ Mark-Dirty }); $year.add_ValueChanged({ Mark-Dirty })
$growth.add_CheckedChanged({ Mark-Dirty }); $mods.add_ItemCheck({ Mark-Dirty })

function Start-LobbyMatchWorker {
    if ($script:lobbyLaunchStarted -or $script:lobbyWorker -or $SmokeTest) { return }
    $arguments = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $PSScriptRoot 'start_lobby_match.ps1'),
        '-CredentialsPath',$CredentialsPath,'-GameExecutable',$GameExecutable,'-ModDirectory',$ModDirectory,
        '-BundleRoot',$bundle,'-ConfigDigest',[string]$script:lobbyState.configDigest)
    if ($script:lobbyStartingSave) { $arguments += @('-StartingSave',$script:lobbyStartingSave) }
    if ($NativeBuildDirectory) { $arguments += @('-NativeBuildDirectory',$NativeBuildDirectory) }
    if ($AllowInsecureLoopback) { $arguments += '-AllowInsecureLoopback' }
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = ConvertTo-Tpf2mpCommandLine $arguments; $info.WorkingDirectory=$bundle
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        if (-not $process.Start()) { throw 'Match worker did not start.' }
        $script:lobbyWorker=[pscustomobject]@{Process=$process;Operation='match-launch';Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
        $script:lobbyLaunchStarted=$true
        Set-ControlText $notice $(if ($script:lobbyState.phase -eq 'preview-generating') {'Generating preview...'} else {'Preparing the multiplayer world...'})
    } catch { $process.Dispose(); throw }
    Update-Buttons
}
function Start-LobbyRequest([string]$Operation,[string[]]$Extra=@()) {
    if ($script:lobbyWorker) {
        if ($script:lobbyWorker.Operation -in @('presence','catalogue','preview-download') -and $Operation -notin @('presence','catalogue','preview-download')) {
            $script:lobbyPendingRequest=[pscustomobject]@{Operation=$Operation;Extra=@($Extra)}
        }
        return $false
    }
    $arguments=@($companion.Prefix)+@('relay-lobby',$Operation,'--credentials',$CredentialsPath,
        '--game-executable',$GameExecutable,'--mod-directory',$ModDirectory)+$Extra
    $info=[Diagnostics.ProcessStartInfo]::new(); $info.FileName=$companion.FilePath
    $info.Arguments=ConvertTo-Tpf2mpCommandLine $arguments; $info.WorkingDirectory=$bundle
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    try {
        if (-not $process.Start()) { throw 'Lobby worker did not start.' }
        $script:lobbyWorker=[pscustomobject]@{Process=$process;Operation=$Operation;Output=$process.StandardOutput.ReadToEndAsync();Error=$process.StandardError.ReadToEndAsync()}
    } catch { $process.Dispose(); throw }
    Update-Buttons; return $true
}
function Reviewed-Arguments {
    if (-not $script:lobbyState) { throw 'Wait for lobby status.' }
    $result=@('--revision',[string]$script:lobbyState.revision)
    if ($script:lobbyState.configDigest) { $result+=@('--config-digest',[string]$script:lobbyState.configDigest) }
    if ($script:lobbyState.phase -eq 'preview-ready') { $result+=@('--preview-digest',[string]$script:lobbyState.previewDigest) }
    return $result
}
function Set-WorldControls($World) {
    if ($isHost -or -not $World) { return }
    $script:lobbySuppressEvents=$true
    try {
        foreach ($key in $worldControls.Keys) { if ($World.PSObject.Properties[$key]) { Set-ChoiceValue $worldControls[$key] ([string]$World.$key) } }
        $seed.Value=[int]$World.seed; $year.Value=[int]$World.year; $growth.Checked=[bool]$World.townDevelopment
        if ($World.terrain) { foreach ($key in $terrain.Keys) { $terrain[$key].Control.Value=[int]$World.terrain.$key } }
        Update-TerrainLayout
    } finally { $script:lobbySuppressEvents=$false }
}
function Show-LobbyState($State) {
    $script:lobbyState=$State
    $states=@{}
    foreach ($role in @('host','join')) {
        $entry=$State.peers.PSObject.Properties[$role]; $peer=if($entry){$entry.Value}else{$null}
        $states[$role]=if(-not $peer -or -not $peer.online){'Offline'}elseif($peer.ready){'Ready'}else{'Connected'}
    }
    Set-PeerState $peerOneState $states.host; Set-PeerState $peerTwoState $states.join
    if ($State.config -and $State.config.world) { Set-WorldControls $State.config.world }
    if (-not $State.PSObject.Properties['previewDigest'] -or -not $State.previewDigest) {
        if ($script:lobbyPreviewDigest) {
            $script:lobbyPreviewDigest=$null
            if($mapImage.Image){$mapImage.Image.Dispose();$mapImage.Image=$null}
        }
        if ($State.phase -eq 'preview-generating') { Set-ControlText $previewState 'Generating preview...' }
        elseif (-not $script:lobbyDirty) { Set-ControlText $previewState $(if($isHost){'Choose settings and generate a preview.'}else{'Waiting for Player 1 to generate a preview.'}) }
    }
    if ($State.phase -eq 'preview-ready' -and $script:lobbyPreviewDigest -cne $State.previewDigest -and -not $SmokeTest) {
        if (-not $script:lobbyDraftDirectory) { $script:lobbyDraftDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-lobby-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $script:lobbyDraftDirectory) }
        $script:lobbyNextPreview=Join-Path $script:lobbyDraftDirectory ([guid]::NewGuid().ToString('N')+'.bmp')
        $script:lobbyPreviewFiles+=$script:lobbyNextPreview
        [void](Start-LobbyRequest 'preview-download' ((Reviewed-Arguments)+@('--preview-file',$script:lobbyNextPreview)))
    }
    if ($State.phase -in @('generating','preparing-save','save-ready') -or ($isHost -and $State.phase -eq 'preview-generating')) { Start-LobbyMatchWorker }
    Update-Buttons
}
function Publish-LobbyWorld {
    try {
        $selected=@(foreach($index in $mods.CheckedIndices){$item=$script:lobbyMods[$index];if(-not $item.selectable){throw 'This Workshop mod needs an existing save because its native version is unknown.'};@{id=[string]$item.id;version=[int]$item.version}})
        $terrainValues=@{}; foreach($key in $terrain.Keys){$terrainValues[$key]=[int]$terrain[$key].Control.Value}
        $world=@{seed=[int]$seed.Value;year=[int]$year.Value;townDevelopment=[bool]$growth.Checked;terrain=$terrainValues}
        foreach($key in $worldControls.Keys){$world[$key]=Get-ChoiceValue $worldControls[$key]}
        if(-not $script:lobbyDraftDirectory){$script:lobbyDraftDirectory=Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-lobby-'+[guid]::NewGuid().ToString('N'));[void](New-Item -ItemType Directory -Path $script:lobbyDraftDirectory)}
        $path=Join-Path $script:lobbyDraftDirectory 'world.json'
        [IO.File]::WriteAllText($path,(@{world=$world;mods=$selected}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        [void](Start-LobbyRequest 'configure-new' ((Reviewed-Arguments)+@('--configuration',$path)))
    } catch { $script:lobbyGenerateAfterApply=$false; Set-ControlText $errorLabel $_.Exception.Message }
}
$generate.add_Click({$script:lobbyGenerateAfterApply=$true;Publish-LobbyWorld})
$newSeed.add_Click({$seed.Value=Get-Random -Minimum 1 -Maximum 2147483647;$script:lobbyGenerateAfterApply=$true;Publish-LobbyWorld})
$randomSeed.add_Click({$seed.Value=Get-Random -Minimum 1 -Maximum 2147483647})
$existing.add_Click({
    $picker=[Windows.Forms.OpenFileDialog]::new()
    try{$picker.Filter='Transport Fever 2 save (*.sav)|*.sav';if($picker.ShowDialog($form)-eq 'OK'){$script:lobbyStartingSave=$picker.FileName;[void](Start-LobbyRequest 'configure-save' ((Reviewed-Arguments)+@('--save',$picker.FileName)))}}
    catch{Set-ControlText $errorLabel $_.Exception.Message}finally{$picker.Dispose()}
})
$ready.add_Click({try{[void](Start-LobbyRequest 'ready' (Reviewed-Arguments))}catch{Set-ControlText $errorLabel $_.Exception.Message}})
$unready.add_Click({try{[void](Start-LobbyRequest 'unready' (Reviewed-Arguments))}catch{Set-ControlText $errorLabel $_.Exception.Message}})
$start.add_Click({try{[void](Start-LobbyRequest 'start' (Reviewed-Arguments))}catch{Set-ControlText $errorLabel $_.Exception.Message}})
$form.add_FormClosing({param($sender,$eventArgs);if($script:lobbyWorker -and $script:lobbyWorker.Operation -eq 'match-launch'){$eventArgs.Cancel=$true;Set-ControlText $errorLabel 'World generation is still running.'}})

$timer=[Windows.Forms.Timer]::new();$timer.Interval=200
$timer.add_Tick({
    try {
        if($script:lobbyWorker){
            $worker=$script:lobbyWorker
            if(-not $worker.Process.HasExited -or -not $worker.Output.IsCompleted -or -not $worker.Error.IsCompleted){return}
            $exitCode=$worker.Process.ExitCode;$stdout=$worker.Output.Result;$stderr=$worker.Error.Result
            $worker.Process.Dispose();$script:lobbyWorker=$null
            if($exitCode -ne 0){throw "Lobby request failed: $stderr"}
            if($worker.Operation -eq 'match-launch'){
                if($stdout -match '(?m)^lobby_preview_prepared='){$script:lobbyLaunchStarted=$false;Set-ControlText $notice 'Preview ready';[void](Start-LobbyRequest 'presence');return}
                Set-ControlText $notice $(if($stdout -match '(?m)^lobby_match_existing='){'This player is already in the match.'}else{'Multiplayer world loaded.'})
                $timer.Stop();Update-Buttons;return
            }
            $value=$stdout|ConvertFrom-Json;$script:lobbyFailures=0;Set-ControlText $errorLabel ''
            if($worker.Operation -eq 'preview-download'){
                $bitmap=[Drawing.Image]::FromFile($script:lobbyNextPreview)
                try{if($mapImage.Image){$mapImage.Image.Dispose()};$mapImage.Image=[Drawing.Bitmap]::new($bitmap)}finally{$bitmap.Dispose()}
                $script:lobbyPreviewDigest=[string]$value.previewDigest
                Set-ControlText $previewState 'Preview ready'
                Set-ControlText $previewMeta "$($value.config.world.climate) - $($value.config.world.size) $($value.config.world.format) - seed $($value.config.world.seed)"
                Show-LobbyState $value
            } elseif($worker.Operation -eq 'catalogue'){
                $script:lobbyMods=@($value.mods)
                foreach($item in $script:lobbyMods){$text="$($item.id)  v$($item.version)";if(-not $item.selectable){$text+='  - existing save only'};[void]$mods.Items.Add($text,($item.id -in @('!tpf2_mp','tpf2_mp')))}
            } else {
                if($worker.Operation -in @('configure-new','configure-save')){$script:lobbyDirty=$false}
                Show-LobbyState $value
                if($worker.Operation -eq 'configure-new' -and $script:lobbyGenerateAfterApply){$script:lobbyGenerateAfterApply=$false;[void](Start-LobbyRequest 'generate' (Reviewed-Arguments))}
            }
            if($script:lobbyPendingRequest -and -not $script:lobbyWorker){$pending=$script:lobbyPendingRequest;$script:lobbyPendingRequest=$null;[void](Start-LobbyRequest $pending.Operation $pending.Extra)}
            Update-Buttons
        }
        $delay=if($script:lobbyFailures -gt 0){10}else{5}
        if(-not $script:lobbyWorker -and ([DateTime]::UtcNow-$script:lobbyLastPoll).TotalSeconds -ge $delay){$script:lobbyLastPoll=[DateTime]::UtcNow;[void](Start-LobbyRequest 'presence')}
    } catch {
        $script:lobbyFailures++;$script:lobbyGenerateAfterApply=$false;$script:lobbyLastPoll=[DateTime]::UtcNow
        $message=$_.Exception.Message;Set-ControlText $errorLabel $message.Substring(0,[Math]::Min(900,$message.Length))
        Set-ControlText $notice 'Connection interrupted - retrying'
        Update-Buttons
    }
})
try {
    if($SmokeTest){
        if(-not $form.Controls.Contains($settingsPanel) -or -not $form.Controls.Contains($previewPanel) `
                -or $tabs.TabPages.Count -ne 3 -or -not $settingsPanel.Controls.Contains($generate) `
                -or -not $previewPanel.Controls.Contains($mapImage) -or -not $previewPanel.Controls.Contains($ready) `
                -or $ready.Enabled){throw 'Lobby control construction failed.'}
        Show-LobbyState ('{"schemaVersion":1,"revision":0,"config":null,"configDigest":null,"phase":"configuring","peers":{},"canStart":false}'|ConvertFrom-Json)
        if($ready.Enabled -or $peerOneState.Text -ne 'Offline'){throw 'Empty lobby must not allow Ready.'}
        $review='{"schemaVersion":1,"revision":2,"config":{"mode":"new","release":"test","world":{"seed":7,"year":1950,"size":"small","format":"1:1","climate":"temperate","terrain":{"hilliness":2,"water":2,"forest":3,"canyon":2,"mesa":2,"ridge":2,"land":2,"islands":3},"towns":"low","industries":"low","industryTarget":"medium","vehicles":"all","nameList":"england","environment":"temperate","nativeDifficulty":"easy","difficulty":"normal","agentMode":"skeleton","townDevelopment":false},"mods":[]},"configDigest":"config","previewDigest":"map","phase":"preview-ready","peers":{},"canStart":true}'|ConvertFrom-Json
        Show-LobbyState $review
        if($ready.Enabled -or $start.Enabled){throw 'An undownloaded preview cannot be accepted.'}
        $script:lobbyPreviewDigest='map';$script:lobbyDirty=$false;Show-LobbyState $review
        if(-not $ready.Enabled -or ($isHost -and -not $start.Enabled)){throw 'Reviewed map readiness failed.'}
        $script:lobbyWorker=[pscustomobject]@{Operation='presence'};Update-Buttons
        if(-not $ready.Enabled){throw 'Passive presence polling must not disable or flash reviewed controls.'}
        $script:lobbyWorker=$null
        Set-ChoiceValue $worldControls.climate 'dry';Update-TerrainLayout
        $visibleTerrain=@('canyon','mesa','ridge','water','forest' | ForEach-Object {$terrain[$_]})
        if($visibleTerrain.Count -ne 5 -or @($visibleTerrain | Where-Object {
                $_.Control.Right -gt $terrainBox.ClientSize.Width -or $_.Control.Bottom -gt $terrainBox.ClientSize.Height}).Count){
            $bounds=@($visibleTerrain | ForEach-Object { "$($_.Name):$($_.Control.Left),$($_.Control.Top),$($_.Control.Right),$($_.Control.Bottom)" }) -join ';'
            throw "Climate-specific terrain controls are clipped or incomplete (count=$($visibleTerrain.Count), panel=$($terrainBox.ClientSize.Width)x$($terrainBox.ClientSize.Height), controls=$bounds)."
        }
        Write-Output 'Lobby dialog smoke passed (stable controls, no window/network/game started).'
    } else {
        [void](Start-LobbyRequest 'catalogue');$timer.Start();[void]$form.ShowDialog()
    }
} finally {
    $timer.Stop();$timer.Dispose()
    if($script:lobbyWorker){if(-not $script:lobbyWorker.Process.HasExited){$script:lobbyWorker.Process.Kill();$script:lobbyWorker.Process.WaitForExit()};$script:lobbyWorker.Process.Dispose()}
    if($script:lobbyDraftDirectory){foreach($file in $script:lobbyPreviewFiles){if(Test-Path -LiteralPath $file){Remove-Item -LiteralPath $file}};$draftPath=Join-Path $script:lobbyDraftDirectory 'world.json';if(Test-Path -LiteralPath $draftPath){Remove-Item -LiteralPath $draftPath};Remove-Item -LiteralPath $script:lobbyDraftDirectory}
    if($mapImage.Image){$mapImage.Image.Dispose()};$form.Dispose()
}
