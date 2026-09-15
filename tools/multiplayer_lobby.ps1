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
[Windows.Forms.Application]::EnableVisualStyles()

$palette = @{
    Background = [Drawing.Color]::FromArgb(13, 22, 28)
    Panel = [Drawing.Color]::FromArgb(20, 34, 42)
    PanelAlt = [Drawing.Color]::FromArgb(16, 28, 34)
    Border = [Drawing.Color]::FromArgb(54, 76, 86)
    Text = [Drawing.Color]::FromArgb(235, 243, 246)
    Muted = [Drawing.Color]::FromArgb(148, 169, 177)
    Accent = [Drawing.Color]::FromArgb(62, 174, 207)
    Gold = [Drawing.Color]::FromArgb(239, 181, 71)
    Success = [Drawing.Color]::FromArgb(78, 199, 137)
    Error = [Drawing.Color]::FromArgb(238, 112, 105)
}

$form = New-Object Windows.Forms.Form
$form.Text = "TPF2MP - $supportId"
$form.ClientSize = [Drawing.Size]::new(1380, 850)
$form.MinimumSize = $form.Size
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Segoe UI', 10)
$form.BackColor = $palette.Background
$form.ForeColor = $palette.Text

function Add-Panel($Parent, [int]$X, [int]$Y, [int]$Width, [int]$Height, $Color = $palette.Panel) {
    $control = New-Object Windows.Forms.Panel
    $control.SetBounds($X, $Y, $Width, $Height); $control.BackColor = $Color
    $Parent.Controls.Add($control); return $control
}
function Add-Label($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 24) {
    $control = New-Object Windows.Forms.Label
    $control.Text = $Text; $control.SetBounds($X, $Y, $Width, $Height)
    $control.ForeColor = $palette.Text; $control.BackColor = [Drawing.Color]::Transparent
    $Parent.Controls.Add($control); return $control
}
function Add-Button($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height = 38, [switch]$Primary) {
    $control = New-Object Windows.Forms.Button
    $control.Text = $Text; $control.SetBounds($X, $Y, $Width, $Height)
    $control.FlatStyle = 'Flat'; $control.FlatAppearance.BorderSize = 1
    $control.FlatAppearance.BorderColor = $(if ($Primary) { $palette.Accent } else { $palette.Border })
    $control.BackColor = $(if ($Primary) { [Drawing.Color]::FromArgb(30, 103, 124) } else { $palette.PanelAlt })
    $control.ForeColor = $palette.Text; $control.UseVisualStyleBackColor = $false
    $Parent.Controls.Add($control); return $control
}
function Get-FriendlyChoice([string]$Value) {
    switch ($Value) {
        'very hard' { 'Very Hard' }
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
    $caption = Add-Label $Parent $Label $X $Y $Width 22; $caption.ForeColor = $palette.Muted
    $control = New-Object Windows.Forms.ComboBox
    $control.SetBounds($X, ($Y + 23), $Width, 29); $control.DropDownStyle = 'DropDownList'
    $control.Tag = [string[]]$Values
    [void]$control.Items.AddRange([string[]]@($Values | ForEach-Object { Get-FriendlyChoice $_ }))
    $control.SelectedIndex = [Array]::IndexOf($Values, $Default)
    $Parent.Controls.Add($control); return $control
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
    $caption = Add-Label $Parent $Label $X $Y $Width 22; $caption.ForeColor = $palette.Muted
    $control = New-Object Windows.Forms.NumericUpDown
    $control.SetBounds($X, ($Y + 23), $Width, 29); $control.Minimum = $Minimum
    $control.Maximum = $Maximum; $control.Value = $Value
    $Parent.Controls.Add($control); return $control
}
function Add-Slider($Parent, [string]$Name, [int]$Maximum, [int]$Default) {
    $caption = Add-Label $Parent $Name 0 0 185 20; $caption.ForeColor = $palette.Muted
    $value = Add-Label $Parent "$Default / $Maximum" 185 0 55 20; $value.TextAlign = 'TopRight'
    $control = New-Object Windows.Forms.TrackBar
    $control.SetBounds(0, 19, 240, 34); $control.Minimum = 0; $control.Maximum = $Maximum
    $control.TickStyle = 'BottomRight'; $control.AutoSize = $false; $control.Value = $Default
    $Parent.Controls.Add($control)
    $handler = { $value.Text = "$($control.Value) / $($control.Maximum)" }.GetNewClosure()
    $control.add_ValueChanged($handler)
    return [pscustomobject]@{ Label=$caption; ValueLabel=$value; Control=$control; Name=$Name }
}
function Set-ControlText($Control, [string]$Value) { if ($Control.Text -cne $Value) { $Control.Text = $Value } }
function Set-ControlEnabled($Control, [bool]$Value) { if ($Control.Enabled -ne $Value) { $Control.Enabled = $Value } }

$header = Add-Panel $form 0 0 1380 72 $palette.PanelAlt
$title = Add-Label $header 'Create Multiplayer World' 22 12 520 32
$title.Font = [Drawing.Font]::new('Segoe UI Semibold', 17)
$roleBadge = Add-Label $header $(if ($isHost) { 'PLAYER 1 · HOST' } else { 'PLAYER 2' }) 1110 13 240 26
$roleBadge.TextAlign = 'MiddleRight'; $roleBadge.ForeColor = $palette.Accent
$sessionLabel = Add-Label $header "Support ID  $supportId" 900 40 450 22
$sessionLabel.TextAlign = 'MiddleRight'; $sessionLabel.ForeColor = $palette.Muted
$notice = Add-Label $form 'Connecting…' 22 80 1335 30
$notice.ForeColor = $palette.Gold

$settingsPanel = Add-Panel $form 20 112 555 628
$tabs = New-Object Windows.Forms.TabControl
$tabs.SetBounds(12, 12, 531, 548); $settingsPanel.Controls.Add($tabs)
$mapTab = New-Object Windows.Forms.TabPage; $mapTab.Text = 'Map'; $mapTab.BackColor = $palette.Panel; $tabs.TabPages.Add($mapTab)
$gameplayTab = New-Object Windows.Forms.TabPage; $gameplayTab.Text = 'Gameplay'; $gameplayTab.BackColor = $palette.Panel; $tabs.TabPages.Add($gameplayTab)
$modsTab = New-Object Windows.Forms.TabPage; $modsTab.Text = 'Mods'; $modsTab.BackColor = $palette.Panel; $tabs.TabPages.Add($modsTab)

$worldControls = @{}
$worldControls.climate = Add-Choice $mapTab 'Climate' 16 15 235 @('temperate','dry','tropical') 'temperate'
$worldControls.size = Add-Choice $mapTab 'Map size' 270 15 235 @('small','medium','large') 'medium'
$worldControls.format = Add-Choice $mapTab 'Map format' 16 77 235 @('1:1','1:2','1:3','1:4','1:5') '1:1'
$year = Add-Number $mapTab 'Starting year' 270 77 235 1850 2050 1950
$worldControls.environment = Add-Choice $mapTab 'Environment' 16 139 235 @('temperate','dry','tropical') 'temperate'
$worldControls.vehicles = Add-Choice $mapTab 'Vehicles' 270 139 235 @('europe','usa','asia','all') 'all'
$worldControls.nameList = Add-Choice $mapTab 'Town names' 16 201 235 @('europe','england','france','germany','italy','korea','netherlands','norway','russia','spain','sweden','usa','asia') 'england'
$worldControls.towns = Add-Choice $mapTab 'Towns' 270 201 235 @('low','medium','high') 'medium'
$worldControls.industries = Add-Choice $mapTab 'Initial industries' 16 263 235 @('low','medium','high') 'medium'
$worldControls.industryTarget = Add-Choice $mapTab 'Industry growth target' 270 263 235 @('disabled','low','medium','high') 'medium'
$seed = Add-Number $mapTab 'Map seed' 16 325 190 0 2147483647 (Get-Random -Minimum 1 -Maximum 2147483647)
$randomSeed = Add-Button $mapTab 'Randomize' 214 348 94 29

$terrainBox = Add-Panel $mapTab 16 391 489 126 $palette.PanelAlt
$terrainTitle = Add-Label $terrainBox 'Terrain' 12 7 465 22
$terrainTitle.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
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
        $x=12+$column*158; $y=32+$row*47
        $item.Label.SetBounds($x,$y,105,18); $item.ValueLabel.SetBounds(($x+105),$y,40,18)
        $item.Control.SetBounds($x,($y+17),145,28)
        $item.Label.Visible=$true; $item.ValueLabel.Visible=$true; $item.Control.Visible=$true
    }
}
Update-TerrainLayout

$worldControls.difficulty = Add-Choice $gameplayTab 'TPF2MP economy' 16 20 235 @('relaxed','easy','normal','hard') 'normal'
$worldControls.nativeDifficulty = Add-Choice $gameplayTab 'Native rules' 270 20 235 @('easy','medium','hard','very hard') 'easy'
$worldControls.agentMode = Add-Choice $gameplayTab 'Native crowd simulation' 16 92 235 @('skeleton','vanilla','empty') 'skeleton'
$growth = New-Object Windows.Forms.CheckBox
$growth.Text = 'Physical town growth (experimental)'; $growth.SetBounds(270, 118, 235, 28)
$growth.ForeColor = $palette.Text; $growth.BackColor = [Drawing.Color]::Transparent
$gameplayTab.Controls.Add($growth)

$modsHeader = Add-Label $modsTab 'Enabled content · order is load order' 16 16 480 24; $modsHeader.ForeColor=$palette.Muted
$mods = New-Object Windows.Forms.CheckedListBox
$mods.SetBounds(16, 48, 489, 454); $mods.CheckOnClick = $true
$modsTab.Controls.Add($mods)

$existing = Add-Button $settingsPanel 'Use Existing Save' 14 574 190 40
$generate = Add-Button $settingsPanel 'Generate Preview' 216 574 210 40 -Primary
$newSeed = Add-Button $settingsPanel 'New Seed' 438 574 103 40

$previewPanel = Add-Panel $form 595 112 765 628
$previewTitle = Add-Label $previewPanel 'Map Preview' 20 16 500 30
$previewTitle.Font = [Drawing.Font]::new('Segoe UI Semibold', 14)
$previewState = Add-Label $previewPanel 'Choose settings and generate a preview.' 20 49 720 24
$previewState.ForeColor = $palette.Muted
$mapImage = New-Object Windows.Forms.PictureBox
$mapImage.SetBounds(20, 80, 725, 408); $mapImage.SizeMode = 'Zoom'; $mapImage.BackColor = $palette.PanelAlt
$previewPanel.Controls.Add($mapImage)
$previewMeta = Add-Label $previewPanel '' 20 497 725 24; $previewMeta.ForeColor=$palette.Muted
$peerOne = Add-Panel $previewPanel 20 535 225 70 $palette.PanelAlt
$peerTwo = Add-Panel $previewPanel 259 535 225 70 $palette.PanelAlt
$peerOneTitle = Add-Label $peerOne 'PLAYER 1' 12 8 200 20; $peerOneTitle.ForeColor=$palette.Muted
$peerTwoTitle = Add-Label $peerTwo 'PLAYER 2' 12 8 200 20; $peerTwoTitle.ForeColor=$palette.Muted
$peerOneState = Add-Label $peerOne 'Connecting…' 12 33 200 25
$peerTwoState = Add-Label $peerTwo 'Connecting…' 12 33 200 25
$ready = Add-Button $previewPanel 'Ready' 500 535 115 40 -Primary
$unready = Add-Button $previewPanel 'Not Ready' 625 535 120 40
$start = Add-Button $previewPanel 'Start Match' 500 582 245 34 -Primary
$ready.Enabled=$false; $unready.Enabled=$false; $start.Enabled=$false

$errorLabel = Add-Label $form '' 22 751 1336 42
$errorLabel.ForeColor = $palette.Error
$footer = Add-Label $form 'Settings stay local until Generate Preview. Both players must review the same preview.' 22 807 1336 22
$footer.ForeColor = $palette.Muted

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
    Set-ControlText $generate $(if ($script:lobbyState -and $script:lobbyState.phase -eq 'preview-ready') { 'Regenerate Preview' } else { 'Generate Preview' })
}
function Mark-Dirty {
    if ($isHost -and -not $script:lobbySuppressEvents) {
        $script:lobbyDirty = $true
        Set-ControlText $previewState 'Settings changed · generate a new preview.'
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
        Set-ControlText $notice $(if ($script:lobbyState.phase -eq 'preview-generating') {'Generating preview…'} else {'Preparing the multiplayer world…'})
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
    Set-ControlText $peerOneState $states.host; Set-ControlText $peerTwoState $states.join
    $peerOneState.ForeColor=$(if($states.host -eq 'Ready'){$palette.Success}elseif($states.host -eq 'Offline'){$palette.Muted}else{$palette.Text})
    $peerTwoState.ForeColor=$(if($states.join -eq 'Ready'){$palette.Success}elseif($states.join -eq 'Offline'){$palette.Muted}else{$palette.Text})
    if ($State.config -and $State.config.world) { Set-WorldControls $State.config.world }
    if (-not $State.PSObject.Properties['previewDigest'] -or -not $State.previewDigest) {
        if ($script:lobbyPreviewDigest) {
            $script:lobbyPreviewDigest=$null
            if($mapImage.Image){$mapImage.Image.Dispose();$mapImage.Image=$null}
        }
        if ($State.phase -eq 'preview-generating') { Set-ControlText $previewState 'Generating preview…' }
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
                Set-ControlText $previewMeta "$($value.config.world.climate) · $($value.config.world.size) $($value.config.world.format) · seed $($value.config.world.seed)"
                Show-LobbyState $value
            } elseif($worker.Operation -eq 'catalogue'){
                $script:lobbyMods=@($value.mods)
                foreach($item in $script:lobbyMods){$text="$($item.id)  v$($item.version)";if(-not $item.selectable){$text+='  · existing save only'};[void]$mods.Items.Add($text,($item.id -in @('!tpf2_mp','tpf2_mp')))}
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
        Set-ControlText $notice 'Connection interrupted · retrying'
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
