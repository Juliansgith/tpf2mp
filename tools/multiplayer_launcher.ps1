[CmdletBinding()]
param(
    [string]$BundleRoot,
    [switch]$SmokeTest
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'network_common.ps1')
. (Join-Path $PSScriptRoot 'launcher_worker_result.ps1')
. (Join-Path $PSScriptRoot 'launcher_update_controller.ps1')
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
[void](Remove-Tpf2mpExpiredRelayDrafts)
$bundleVersion = 'development'
try {
    $bundleManifestPath = Join-Path $bundle 'release-manifest.json'
    if (Test-Path -LiteralPath $bundleManifestPath -PathType Leaf) {
        $bundleVersion = [string](Get-Content -LiteralPath $bundleManifestPath -Raw | ConvertFrom-Json).version
    }
    elseif (Test-Path -LiteralPath (Join-Path $bundle 'companion\tpf2mp\__init__.py') -PathType Leaf) {
        $versionMatch = [regex]::Match(
            (Get-Content -LiteralPath (Join-Path $bundle 'companion\tpf2mp\__init__.py') -Raw),
            '__version__\s*=\s*["'']([^"'']+)["'']')
        if ($versionMatch.Success) { $bundleVersion = $versionMatch.Groups[1].Value }
    }
}
catch { $bundleVersion = 'unknown' }
$defaultRelayUrl = [string]$env:TPF2MP_RELAY_URL
if (-not $defaultRelayUrl) {
    $relayConfigPath = Join-Path $bundle 'relay-config.json'
    if (Test-Path -LiteralPath $relayConfigPath -PathType Leaf) {
        try { $defaultRelayUrl = [string](Get-Content -LiteralPath $relayConfigPath -Raw | ConvertFrom-Json).relayUrl }
        catch { $defaultRelayUrl = '' }
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'launcher_theme.ps1')
[Windows.Forms.Application]::EnableVisualStyles()

$theme = Get-Tpf2mpTheme
$accent = $theme.Accent
$muted = $theme.Muted
$danger = $theme.Danger

$form = New-Object Windows.Forms.Form
Set-Tpf2mpFormStyle $form 'TPF2MP Multiplayer'
$form.ClientSize = New-Object Drawing.Size(940, 970)
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false

$launcherOwner = Get-Process -Id $PID -ErrorAction Stop
$script:launcherOwnerProcessId = $launcherOwner.Id
$script:launcherOwnerExecutable = [string]$launcherOwner.Path
$script:launcherOwnerStartedAtUtc = $launcherOwner.StartTime.ToUniversalTime().ToString('o')

# Header: product mark, bundle version pill, one-line promise, update action.
$title = New-Tpf2mpLabel $form 'TPF2MP' 28 18 130 34 'Title'
$versionPill = New-Tpf2mpPill $form $bundleVersion 158 23 124 24
Set-Tpf2mpPill $versionPill $bundleVersion 'Accent'
$subtitle = New-Tpf2mpLabel $form ('Host or join a trusted two-company world. Keep this launcher open; ' +
    'closing it cleanly ends its game and session.') 30 58 880 18 'Muted'
$sourceTreeLauncher = -not (Test-Path -LiteralPath (Join-Path $bundle 'release-manifest.json') -PathType Leaf)
$updateText = if ($sourceTreeLauncher) { 'Update installed release' } else { 'Check / install update' }
$updateButton = New-Tpf2mpButton $form $updateText 702 18 210 36 'Ghost'

# Connection: how the two computers reach each other.
$connectionCard = New-Tpf2mpCard $form 28 88 884 156 'Connection'
$relayCheck = New-Tpf2mpCheckBox $connectionCard `
    'Use secure relay (recommended) - no port forwarding; redacted diagnostics enabled' 18 36 820 22
$relayCheck.Checked = $true
New-Tpf2mpLabel $connectionCard 'Relay URL' 18 68 200 18 'Muted' | Out-Null
$relayUrlBox = New-Tpf2mpTextBox $connectionCard $defaultRelayUrl 18 86 260 32
$createRelayButton = New-Tpf2mpButton $connectionCard 'Create session' 286 84 144 36 'Ghost'
New-Tpf2mpLabel $connectionCard 'Join code (secret; paste on Player 2)' 458 68 300 18 'Muted' | Out-Null
$joinCodeBox = New-Tpf2mpTextBox $connectionCard '' 458 86 190 32
$joinCodeBox.UseSystemPasswordChar = $true
$prepareJoinButton = New-Tpf2mpButton $connectionCard 'Prepare join' 656 84 110 36 'Ghost'
$copyJoinButton = New-Tpf2mpButton $connectionCard 'Copy code' 774 84 92 36 'Ghost'
$relayDisclosure = New-Tpf2mpLabel $connectionCard ('Support ID and redacted structured logs are retained ' +
    'by the relay; raw crash dumps are never automatic.') 18 130 848 18 'Faint'

# Session: the match identity, its starting save, and the shared world.
$defaultSession = 'match-' + (Get-Date -Format 'yyyyMMdd-HHmm')
$addressText = 'LAN addresses: '
try {
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.AddressState -eq 'Preferred' } |
        Select-Object -ExpandProperty IPAddress -Unique)
    $addressText += if ($addresses.Count) { $addresses -join ', ' } else { 'none detected' }
}
catch { $addressText += 'unavailable' }
$sessionCard = New-Tpf2mpCard $form 28 258 884 248 'Session'
New-Tpf2mpLabel $sessionCard 'Session name' 18 36 200 18 'Muted' | Out-Null
$sessionBox = New-Tpf2mpTextBox $sessionCard $defaultSession 18 54 300 32
$newSessionButton = New-Tpf2mpButton $sessionCard 'New name' 326 52 110 36 'Ghost'
New-Tpf2mpLabel $sessionCard 'Host address (Join)' 560 36 180 18 'Muted' | Out-Null
$hostBox = New-Tpf2mpTextBox $sessionCard '127.0.0.1' 560 54 170 32
New-Tpf2mpLabel $sessionCard 'TCP port' 746 36 120 18 'Muted' | Out-Null
$portBox = New-Tpf2mpTextBox $sessionCard '29742' 746 54 120 32
$lanLabel = New-Tpf2mpLabel $sessionCard $addressText 560 98 306 18 'Faint'
$saveLabel = New-Tpf2mpLabel $sessionCard `
    'Starting save: Host selects it; Join can receive the exact set automatically' 18 98 520 18 'Muted'
$saveBox = New-Tpf2mpTextBox $sessionCard '' 18 116 420 32
$browseButton = New-Tpf2mpButton $sessionCard 'Browse...' 446 114 104 36 'Ghost'
$syncSaveButton = New-Tpf2mpButton $sessionCard 'Sync from host' 558 114 150 36 'Ghost'
$lobbyButton = New-Tpf2mpButton $sessionCard 'Open world lobby' 716 114 150 36 'Secondary'
$hostSnapshotCheck = New-Tpf2mpCheckBox $sessionCard ('Recover from HOST snapshot (both peers enable; ' +
    'discards old session faults/pending work; new session required)') 18 162 848 22
$manualLabCheck = New-Tpf2mpCheckBox $sessionCard ('After the automated proof, leave both connected game ' +
    'windows open for manual testing (up to 2 hours)') 18 188 848 22
$manualLabCheck.Checked = $false
$hint = New-Tpf2mpLabel $sessionCard `
    'Host selects a save and launches first. Join syncs the host save, then launches.' 18 220 848 18 'Muted'

# Launch: the two real entry points, then the ways out of a running match.
$launchCard = New-Tpf2mpCard $form 28 520 884 138 'Launch'
$hostButton = New-Tpf2mpButton $launchCard 'Host and launch game' 18 36 265 44 'Primary'
$joinButton = New-Tpf2mpButton $launchCard 'Join and launch game' 291 36 265 44 'Secondary'
$localhostButton = New-Tpf2mpButton $launchCard 'Run 2-instance localhost test' 564 36 302 44 'Ghost'
$stopButton = New-Tpf2mpButton $launchCard 'Stop session / lab' 18 92 170 36 'Danger'
$openButton = New-Tpf2mpButton $launchCard 'Open session files' 196 92 180 36 'Ghost'

# Recovery and tools: evidence collection and the attested restore path.
$toolsCard = New-Tpf2mpCard $form 28 672 884 130 'Recovery and tools'
$evidenceButton = New-Tpf2mpButton $toolsCard 'Check playable alpha' 18 36 200 36 'Ghost'
$operationalButton = New-Tpf2mpButton $toolsCard 'Run populated capture lab (local only)' 230 36 300 36 'Ghost'
$archiveButton = New-Tpf2mpButton $toolsCard 'Archive recovery save' 542 36 210 36 'Ghost'
$restoreButton = New-Tpf2mpButton $toolsCard 'Select restore plan...' 18 82 210 36 'Ghost'
$latestRestoreButton = New-Tpf2mpButton $toolsCard 'Load latest restore' 240 82 210 36 'Ghost'
$recoveryHint = New-Tpf2mpLabel $toolsCard ('Archive a current save, or select a verified restore plan ' +
    'and then this peer''s attested save.') 462 74 404 46 'Faint'

$statusPill = New-Tpf2mpPill $form 'Ready' 28 815 76 24
Set-Tpf2mpPill $statusPill 'Ready' 'Accent'
$statusLabel = New-Tpf2mpLabel $form 'Ready. Build 35924 is required for network mode.' 116 814 796 26
$statusLabel.ForeColor = $accent
$statusLabel.TextAlign = 'MiddleLeft'

$logBox = New-Tpf2mpLogBox $form 28 850 884 100
$logBox.Text = "This control panel pins the role/session/save, starts the companion, launches the exact game process, drives the native Load Game page, and verifies authority gates before reporting world-ready.`r`n"

$script:worker = $null
$script:workerStdout = $null
$script:workerStderr = $null
$script:workerStdoutLength = 0
$script:workerStderrLength = 0
$script:lastPeer = 'player1'
$script:restorePlanPath = $null
$script:restorePlanData = $null
$script:restorePeer = $null
$script:pendingSaveSyncSession = $null
$script:relayCredentialsPath = $null
$script:relayCredentialRole = $null
$script:relaySupportId = $null
$script:relayInviteReceiptPath = $null
$script:pendingRelayInviteFile = $null

function Append-LauncherLog([string]$Text) {
    if (-not $Text) { return }
    $logBox.AppendText(($Text.TrimEnd() + "`r`n"))
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()
}

$script:updateController = Initialize-Tpf2mpLauncherUpdateController `
    -Form $form -Button $updateButton -StatusLabel $statusLabel `
    -BundleRoot $bundle -CurrentVersion $(if ($sourceTreeLauncher) { '' } else { $bundleVersion }) `
    -LogAction { param($message) Append-LauncherLog $message } `
    -CanEnableAction { -not [bool]$script:worker } -SmokeTest:$SmokeTest

function Get-ValidatedRelayUrl {
    $value = $relayUrlBox.Text.Trim().TrimEnd('/')
    if ($value -match '^https://[A-Za-z0-9.-]+(?::\d+)?(?:/[A-Za-z0-9._~!$&''()*+,;=:@%-]+)*$') {
        return $value
    }
    if ($sourceTreeLauncher -and $value -match '^http://(?:127\.0\.0\.1|localhost|\[?::1\]?):\d+$') {
        return $value
    }
    throw 'Enter the configured HTTPS relay URL. Plain HTTP is accepted only for source-tree loopback tests.'
}

function Clear-RelayCredentials {
    $script:relayCredentialsPath = $null
    $script:relayCredentialRole = $null
    $script:relaySupportId = $null
    $script:relayInviteReceiptPath = $null
}

function Update-TransportControls {
    $relay = $relayCheck.Checked
    $lobbyButton.Enabled = $relay -and [bool]$script:relayCredentialsPath -and -not [bool]$script:worker `
        -and -not [bool]$script:restorePlanPath -and -not $hostSnapshotCheck.Checked
    $relayUrlBox.Enabled = $relay
    $createRelayButton.Enabled = $relay -and -not [bool]$script:worker
    $prepareJoinButton.Enabled = $relay -and -not [bool]$script:worker
    $copyJoinButton.Enabled = $relay -and $joinCodeBox.TextLength -gt 0 -and -not [bool]$script:worker
    $hostBox.Enabled = -not $relay
    $newSessionButton.Enabled = -not $relay -and -not [bool]$script:restorePlanPath
    $sessionBox.ReadOnly = $relay -or [bool]$script:restorePlanPath
    $syncSaveButton.Enabled = -not $relay -and -not [bool]$script:restorePlanPath `
        -and -not [bool]$script:worker
    $lanLabel.Visible = -not $relay
    if ($relay) {
        $hint.Text = if ([string]::IsNullOrWhiteSpace($relayUrlBox.Text)) {
            'Secure relay is built but this development bundle has no deployed HTTPS URL yet. Enter it after server setup.'
        } else {
            'Create / prepare code, then WORLD LOBBY: generate a new map or select a save; both Ready, host Start.'
        }
        $saveLabel.Text = if ($script:restorePlanPath) {
            'This peer''s attested restore save (relay transfers ordinary starting saves only)'
        } else { 'Optional existing save (or create a new world in WORLD LOBBY)' }
    }
    else {
        $hint.Text = 'Direct LAN: Host shares the session, address, port, and exact save; Join may use SYNC FROM HOST.'
        $saveLabel.Text = if ($script:restorePlanPath) {
            'This peer''s attested restore save (Host=player1 / Join=player2)'
        } else { 'Starting save: Host selects it; Join can receive the exact set automatically' }
    }
}

function Get-RelayCredentialSelection([ValidateSet('host', 'join')][string]$Role) {
    if (-not $script:relayCredentialsPath `
            -or -not (Test-Path -LiteralPath $script:relayCredentialsPath -PathType Leaf)) {
        $action = if ($Role -eq 'host') { 'CREATE SESSION' } else { 'PREPARE JOIN' }
        throw "Click $action first."
    }
    $value = Get-Content -LiteralPath $script:relayCredentialsPath -Raw | ConvertFrom-Json
    $relayUrl = Get-ValidatedRelayUrl
    if ([int]$value.schemaVersion -ne 1 -or [string]$value.role -cne $Role `
            -or [string]$value.sessionId -notmatch '^mp-[0-9a-f]{16}$' `
            -or [string]$value.relayUrl -cne $relayUrl) {
        throw 'Prepared relay credentials do not match this role or Relay URL. Create/prepare them again.'
    }
    return [pscustomobject]@{
        Path = Resolve-Tpf2mpFullPath $script:relayCredentialsPath
        Session = [string]$value.sessionId
        RelayUrl = [string]$value.relayUrl
    }
}

function Clear-RestorePlanSelection([bool]$ClearSave = $true) {
    $script:restorePlanPath = $null
    $script:restorePlanData = $null
    $script:restorePeer = $null
    $hostButton.Enabled = $true
    $joinButton.Enabled = $true
    $sessionBox.ReadOnly = $false
    $saveLabel.Text = 'Starting save: Host selects it; Join can receive the exact set automatically'
    $syncSaveButton.Enabled = $true
    if ($ClearSave) { $saveBox.Text = '' }
    $recoveryHint.Text = 'Archive a current save, or select a verified restore plan and then this peer''s attested save.'
    Update-TransportControls
}

function Set-VerifiedRestorePlan([string]$Path) {
    $hostSnapshotCheck.Checked = $false
    $resolved = Resolve-Tpf2mpFullPath $Path
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "Restore plan does not exist: $resolved"
    }
    $companion = Get-Tpf2mpCompanionCommand $bundle
    $output = @(& $companion.FilePath @($companion.Prefix + @(
        'verify-restore-plan', $resolved, '--metadata-only'
    )) 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Restore plan checksum/structure verification failed: $($output -join ' ')"
    }
    $plan = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json
    $resumeSession = Assert-Tpf2mpSessionId ([string]$plan.resumeSession)
    $script:restorePlanPath = $resolved
    $script:restorePlanData = $plan
    $script:restorePeer = $null
    $hostButton.Enabled = $true
    $joinButton.Enabled = $true
    $sessionBox.Text = $resumeSession
    $sessionBox.ReadOnly = $true
    $saveBox.Text = ''
    $saveLabel.Text = 'This peer''s attested restore save (Host=player1 / Join=player2)'
    $syncSaveButton.Enabled = $false
    $policy = if ([int]$plan.version -ge 3) {
        "$($plan.matchContentProfile.agentMode), town growth $($plan.matchContentProfile.townDevelopment)"
    } else { 'legacy v2: policy is not plan-bound' }
    $recoveryHint.Text = "Restore boundary $($plan.boundarySeq); $policy. Select this peer's .sav."
    Append-LauncherLog "Verified restore plan $resolved -> $resumeSession (boundary $($plan.boundarySeq), $policy)."
    Update-TransportControls
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
    # The lobby is an interactive dialog, not a background helper. SW_HIDE can
    # suppress its first native window even though ShowDialog is running.
    $workerWindowStyle = if ($Name -eq 'world-lobby') { 'Normal' } else { 'Hidden' }
    $script:worker = Start-Process -FilePath $powershell -ArgumentList $commandLine -PassThru -WindowStyle $workerWindowStyle `
        -RedirectStandardOutput $script:workerStdout -RedirectStandardError $script:workerStderr
    $script:workerName = $Name
    $hostButton.Enabled = $false
    $joinButton.Enabled = $false
    $localhostButton.Enabled = $false
    $operationalButton.Enabled = $false
    $manualLabCheck.Enabled = $false
    $evidenceButton.Enabled = $false
    $archiveButton.Enabled = $false
    $restoreButton.Enabled = $false
    $latestRestoreButton.Enabled = $false
    $updateButton.Enabled = $false
    $syncSaveButton.Enabled = $false
    $createRelayButton.Enabled = $false
    $prepareJoinButton.Enabled = $false
    $copyJoinButton.Enabled = $false
    $lobbyButton.Enabled = $false
    $statusLabel.Text = "$Name running..."
    Append-LauncherLog "Started $Name (PID $($script:worker.Id))."
}

function Open-WorldLobby {
    if (-not $relayCheck.Checked -or $script:restorePlanPath -or $hostSnapshotCheck.Checked) {
        throw 'The world lobby is for ordinary relay matches. Use the existing restore controls for recovery.'
    }
    if ($script:relayCredentialRole -notin @('host','join')) { throw 'Create a room or prepare its join code first.' }
    $selected = Get-RelayCredentialSelection $script:relayCredentialRole
    $game = Find-Tpf2mpGameExecutable
    if (-not $game) { throw 'Transport Fever 2 executable was not found.' }
    $modsRoot = Find-Tpf2mpLocalModsPath
    $arguments = @('-BundleRoot',$bundle,'-CredentialsPath',$selected.Path,
        '-GameExecutable',$game,'-ModDirectory',(Join-Path $modsRoot 'tpf2_mp_1'))
    if ($sourceTreeLauncher -and $selected.RelayUrl -match '^http://') { $arguments += '-AllowInsecureLoopback' }
    $script:lastPeer = if ($script:relayCredentialRole -eq 'host') { 'player1' } else { 'player2' }
    Start-LauncherWorker (Join-Path $PSScriptRoot 'multiplayer_lobby.ps1') $arguments 'world-lobby'
}
$lobbyButton.Add_Click({ try { Open-WorldLobby } catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message,'Cannot open world lobby') | Out-Null } })

function Get-ValidatedInputs([bool]$RequireSave = $false, [bool]$IgnoreSave = $false) {
    if ($hostSnapshotCheck.Checked -and $script:restorePlanPath) {
        throw 'Choose either host snapshot recovery or a verified paired restore plan, not both.'
    }
    $session = Assert-Tpf2mpSessionId $sessionBox.Text.Trim()
    $port = 0
    if (-not [int]::TryParse($portBox.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw 'Port must be between 1 and 65535.'
    }
    $save = if ($IgnoreSave) { '' } else { $saveBox.Text.Trim() }
    if ($save -and -not (Test-Path -LiteralPath $save -PathType Leaf)) { throw "Starting save does not exist: $save" }
    if ($RequireSave -and -not $save) {
        if ($script:restorePlanPath) {
            throw 'Select this peer''s attested restore .sav first (Host=player1, Join=player2).'
        }
        throw 'Select a starting .sav, or on Join click SYNC FROM HOST first.'
    }
    return [pscustomobject]@{ Session = $session; Port = $port; Save = $save }
}
function Add-LauncherSessionOwnership([object[]]$Arguments) {
    return @($Arguments + @(
        '-OwnerLauncherProcessId', [string]$script:launcherOwnerProcessId,
        '-OwnerLauncherExecutable', $script:launcherOwnerExecutable,
        '-OwnerLauncherStartedAtUtc', $script:launcherOwnerStartedAtUtc,
        '-ReplaceExistingSession'
    ))
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

$relayCheck.Add_CheckedChanged({
    Update-TransportControls
    if ($relayCheck.Checked) {
        Append-LauncherLog 'Secure relay selected: both PCs use outbound WSS; no inbound game/save port is exposed.'
    }
    else {
        Append-LauncherLog 'Direct LAN selected. Internet exposure of the raw TCP port is unsupported; use only a trusted LAN/VPN.'
    }
})

$joinCodeBox.Add_TextChanged({ Update-TransportControls })

$createRelayButton.Add_Click({
    try {
        if (-not $relayCheck.Checked) { throw 'Enable secure relay first.' }
        $relayUrl = Get-ValidatedRelayUrl
        Clear-RelayCredentials
        $arguments = @('-RelayUrl', $relayUrl, '-DisplayName', 'TPF2MP match', '-BundleRoot', $bundle)
        if ($sourceTreeLauncher -and $relayUrl -match '^http://') { $arguments += '-AllowInsecureLoopback' }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'new_relay_session.ps1') `
            $arguments 'relay-session-create'
        Append-LauncherLog 'Creating a short-lived two-player relay room. Credentials will stay in a current-user-only local file.'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot create relay session') | Out-Null }
})

$prepareJoinButton.Add_Click({
    try {
        if (-not $relayCheck.Checked) { throw 'Enable secure relay first.' }
        $relayUrl = Get-ValidatedRelayUrl
        $joinCode = $joinCodeBox.Text.Trim()
        if ($joinCode -notmatch '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$') {
            throw 'Paste the complete TPF2MP1 join code from the host.'
        }
        Clear-RelayCredentials
        $draft = Join-Path (Get-Tpf2mpSupportRoot) (
            'relay-drafts\join-input-' + [guid]::NewGuid().ToString('N') + '.txt'
        )
        $script:pendingRelayInviteFile = Write-Tpf2mpPrivateTextFile $draft $joinCode
        $arguments = @(
            '-RelayUrl', $relayUrl, '-InviteFile', $script:pendingRelayInviteFile,
            '-BundleRoot', $bundle
        )
        if ($sourceTreeLauncher -and $relayUrl -match '^http://') { $arguments += '-AllowInsecureLoopback' }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'accept_relay_invite.ps1') `
            $arguments 'relay-invite-accept'
        Append-LauncherLog 'Validating the join code locally; its credential is never placed on a process command line.'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot prepare relay join') | Out-Null }
})

$copyJoinButton.Add_Click({
    try {
        if (-not $joinCodeBox.Text) { throw 'Create a relay session first.' }
        [Windows.Forms.Clipboard]::SetText($joinCodeBox.Text)
        $statusLabel.Text = "Join code copied. Support ID: $script:relaySupportId"
        Append-LauncherLog 'Copied the secret join code. Share it privately with Player 2; use only the support ID in bug reports.'
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot copy join code') | Out-Null }
})

$syncSaveButton.Add_Click({
    try {
        if ($relayCheck.Checked) {
            throw 'Relay Join receives the complete save automatically during Join + Launch.'
        }
        if ($script:restorePlanPath) {
            throw 'Receipt-bound restores use a different save per peer and cannot use starting-save sync.'
        }
        $input = Get-ValidatedInputs $false $true
        if ($input.Port -ge 65535) {
            throw 'Choose a gameplay port below 65535; automatic save sync uses the next TCP port.'
        }
        $hostAddress = $hostBox.Text.Trim()
        if ($hostAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$') {
            throw 'Enter the Host PC LAN/VPN address first.'
        }
        $script:lastPeer = 'player2'
        $script:pendingSaveSyncSession = $input.Session
        Start-LauncherWorker (Join-Path $PSScriptRoot 'sync_starting_save.ps1') `
            @('-Session', $input.Session, '-HostAddress', $hostAddress,
              '-Port', $input.Port, '-BundleRoot', $bundle) 'save-sync-receive'
        Append-LauncherLog "Receiving the host's complete save set on TCP $($input.Port + 1); the .sav becomes visible only after verification."
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot sync starting save') | Out-Null }
})

$restoreButton.Add_Click({
    try {
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Select a checksummed TPF2MP restore plan'
        $dialog.Filter = 'TPF2MP restore plans (*.json)|*.json|All files (*.*)|*.*'
        if ($dialog.ShowDialog() -eq 'OK') { Set-VerifiedRestorePlan $dialog.FileName }
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot select restore plan') | Out-Null }
})

$latestRestoreButton.Add_Click({
    try {
        $choice = [Windows.Forms.MessageBox]::Show(
            'Load the Host/player1 restore? Choose No for Join/player2.',
            'Choose restore role',
            [Windows.Forms.MessageBoxButtons]::YesNoCancel,
            [Windows.Forms.MessageBoxIcon]::Question
        )
        if ($choice -eq [Windows.Forms.DialogResult]::Cancel) { return }
        $peer = if ($choice -eq [Windows.Forms.DialogResult]::Yes) { 'player1' } else { 'player2' }
        # A real two-computer match intentionally stores only this machine's
        # receipt-bound save. The signed plan binds both peer receipts; each
        # remote game independently verifies its own bytes during bootstrap.
        # Requiring both large archives locally belongs only to the localhost
        # paired-restore acceptance harness.
        $candidate = Get-Tpf2mpLatestLocalRestore -BundleRoot $bundle -Peer $peer
        Set-VerifiedRestorePlan ([string]$candidate.planPath)
        $saveBox.Text = [string]$candidate.savePath
        $script:lastPeer = $peer
        $script:restorePeer = $peer
        $hostButton.Enabled = $peer -eq 'player1'
        $joinButton.Enabled = $peer -eq 'player2'
        $role = if ($peer -eq 'player1') { 'Host' } else { 'Join' }
        $recoveryHint.Text = "$role restore ready at boundary $($candidate.boundarySeq). Click $role + Launch Game."
        Append-LauncherLog "Loaded latest verified $peer restore from $($candidate.archivedAtUtc)."
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot load latest restore') | Out-Null }
})

$hostButton.Add_Click({
    try {
        if ($script:restorePeer -and $script:restorePeer -ne 'player1') {
            throw 'The loaded automatic restore belongs to Join/player2.'
        }
        $input = Get-ValidatedInputs $true
        $script:lastPeer = 'player1'
        if ($relayCheck.Checked) {
            $relay = Get-RelayCredentialSelection 'host'
            if (-not $script:restorePlanPath -and $input.Session -cne $relay.Session) {
                throw 'Ordinary relay matches use the generated support ID as their game session. Create the room again.'
            }
            $args = @(
                '-Role', 'Host', '-Session', $input.Session,
                '-RelayCredentials', $relay.Path,
                '-Port', $input.Port, '-BundleRoot', $bundle
            )
            if ($sourceTreeLauncher -and $relay.RelayUrl -match '^http://') {
                $args += '-AllowInsecureLoopback'
            }
            if ($input.Save) { $args += @('-StartingSave', $input.Save) }
            if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
            if ($hostSnapshotCheck.Checked) { $args += '-HostSnapshotRecovery' }
            $args = Add-LauncherSessionOwnership $args
            Start-LauncherWorker (Join-Path $PSScriptRoot 'start_relay_network_session.ps1') `
                $args 'relay-host-launch'
            Append-LauncherLog "Secure host launch started. Share the copied join code; support ID $($relay.Session)."
            return
        }
        $args = @('-Role', 'Host', '-Session', $input.Session, '-Port', $input.Port,
            '-BindAddress', '0.0.0.0', '-BundleRoot', $bundle)
        if ($input.Save) { $args += @('-StartingSave', $input.Save) }
        if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
        if ($hostSnapshotCheck.Checked) { $args += '-HostSnapshotRecovery' }
        $args = Add-LauncherSessionOwnership $args
        Start-LauncherWorker (Join-Path $PSScriptRoot 'start_network_session_retry.ps1') $args 'host-launch'
        if (-not $script:restorePlanPath) {
            Append-LauncherLog "Host will share only this pinned save on TCP $($input.Port + 1) for the matching session."
        }
    }
    catch { [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Cannot host') | Out-Null }
})

$joinButton.Add_Click({
    try {
        if ($script:restorePeer -and $script:restorePeer -ne 'player2') {
            throw 'The loaded automatic restore belongs to Host/player1.'
        }
        $requireSave = -not $relayCheck.Checked -or [bool]$script:restorePlanPath
        $input = Get-ValidatedInputs $requireSave
        if ($relayCheck.Checked) {
            $relay = Get-RelayCredentialSelection 'join'
            if (-not $script:restorePlanPath -and $input.Session -cne $relay.Session) {
                throw 'This join code does not match the displayed game session. Prepare it again.'
            }
            $script:lastPeer = 'player2'
            $args = @(
                '-Role', 'Join', '-Session', $input.Session,
                '-RelayCredentials', $relay.Path,
                '-Port', $input.Port, '-BundleRoot', $bundle
            )
            if ($sourceTreeLauncher -and $relay.RelayUrl -match '^http://') {
                $args += '-AllowInsecureLoopback'
            }
            if ($input.Save) { $args += @('-StartingSave', $input.Save) }
            if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
            if ($hostSnapshotCheck.Checked) { $args += '-HostSnapshotRecovery' }
            $args = Add-LauncherSessionOwnership $args
            Start-LauncherWorker (Join-Path $PSScriptRoot 'start_relay_network_session.ps1') `
                $args 'relay-join-launch'
            Append-LauncherLog "Secure Join will receive and verify the host save automatically; support ID $($relay.Session)."
            return
        }
        $hostAddress = $hostBox.Text.Trim()
        if ($hostAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$') { throw 'Enter a valid LAN/VPN host address.' }
        $script:lastPeer = 'player2'
        $args = @('-Role', 'Join', '-Session', $input.Session, '-HostAddress', $hostAddress,
            '-Port', $input.Port, '-BundleRoot', $bundle)
        if ($input.Save) { $args += @('-StartingSave', $input.Save) }
        if ($script:restorePlanPath) { $args += @('-RestorePlan', $script:restorePlanPath) }
        if ($hostSnapshotCheck.Checked) { $args += '-HostSnapshotRecovery' }
        $args = Add-LauncherSessionOwnership $args
        Start-LauncherWorker (Join-Path $PSScriptRoot 'start_network_session_retry.ps1') $args 'join-launch'
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
            & (Join-Path $PSScriptRoot 'stop_network_session.ps1') -Session $session `
                -Peer $script:lastPeer -StopGame -StopReason 'launcher-stop-button'
            $statusLabel.Text = 'Session and game stopped cleanly.'
            Append-LauncherLog "Stopped $session/$script:lastPeer and its exact game process."
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
        if ($collectPeer -ne 'both') {
            throw 'The playable-alpha check requires both peer bridges on this computer. On two PCs, collect both bridge bundles on the host before analysis.'
        }
        Start-LauncherWorker (Join-Path $PSScriptRoot 'run_alpha_live_acceptance.ps1') `
            @('-Session', $session, '-Profile', 'playable', '-BundleRoot', $bundle) 'playable-alpha-check'
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
            $completedName = $script:workerName
            $exitCode = Get-Tpf2mpCompletedProcessExitCode $script:worker
            $verifiedSaveSync = $null
            $verifiedRelayCreate = $null
            $verifiedRelayJoin = $null
            if ($exitCode -eq 0 -and $completedName -eq 'save-sync-receive') {
                $verifiedSaveSync = Get-Tpf2mpVerifiedSaveSyncResult `
                    -StdoutPath $script:workerStdout -StderrPath $script:workerStderr `
                    -Session $script:pendingSaveSyncSession
                if (-not $verifiedSaveSync `
                        -or $sessionBox.Text.Trim() -cne [string]$verifiedSaveSync.session) {
                    $exitCode = 2
                    Append-LauncherLog 'Save-sync worker exited without a valid receipt for the currently selected session.'
                }
            }
            if ($completedName -eq 'relay-session-create') {
                $verifiedRelayCreate = Get-Tpf2mpVerifiedRelayCreateResult `
                    -StdoutPath $script:workerStdout -StderrPath $script:workerStderr
                if ($exitCode -eq 0 -and -not $verifiedRelayCreate) {
                    $exitCode = 2
                    Append-LauncherLog 'Relay creation worker exited without a valid protected credential receipt.'
                }
            }
            if ($completedName -eq 'relay-invite-accept') {
                $verifiedRelayJoin = Get-Tpf2mpVerifiedRelayJoinResult `
                    -StdoutPath $script:workerStdout -StderrPath $script:workerStderr
                if ($exitCode -eq 0 -and -not $verifiedRelayJoin) {
                    $exitCode = 2
                    Append-LauncherLog 'Relay invitation worker exited without valid protected join credentials.'
                }
            }
            if ($completedName -eq 'relay-invite-accept' `
                    -and $script:pendingRelayInviteFile) {
                try {
                    if (Test-Path -LiteralPath $script:pendingRelayInviteFile -PathType Leaf) {
                        Remove-Item -LiteralPath $script:pendingRelayInviteFile -Force
                    }
                }
                catch { Append-LauncherLog 'Warning: the protected temporary join-code input could not be removed.' }
                $script:pendingRelayInviteFile = $null
            }
            if (Test-Tpf2mpWorkerCompletionSucceeded -ExitCode $exitCode `
                    -VerifiedReceipts @($verifiedRelayCreate, $verifiedRelayJoin)) {
                $statusLabel.ForeColor = $accent
                if ($verifiedSaveSync) {
                    $saveBox.Text = [string]$verifiedSaveSync.savePath
                    $statusLabel.Text = 'Host save received and verified. Ready to Join + Launch.'
                    $reuse = if ($verifiedSaveSync.reused) { 'reused existing identical copy' } else { 'installed new copy' }
                    Append-LauncherLog "Verified save bundle $($verifiedSaveSync.bundleId.Substring(0, 12)); $reuse at $($verifiedSaveSync.savePath)."
                }
                elseif ($verifiedRelayCreate) {
                    $script:relayCredentialsPath = [string]$verifiedRelayCreate.credentialsPath
                    $script:relayCredentialRole = 'host'
                    $script:relaySupportId = [string]$verifiedRelayCreate.supportId
                    $script:relayInviteReceiptPath = [string]$verifiedRelayCreate.inviteReceiptPath
                    $joinCodeBox.Text = [string]$verifiedRelayCreate.joinCode
                    if (-not $script:restorePlanPath) {
                        $sessionBox.Text = [string]$verifiedRelayCreate.session
                    }
                    $statusLabel.Text = "Relay room ready. Support ID: $($verifiedRelayCreate.supportId)"
                    Append-LauncherLog "Secure relay room $($verifiedRelayCreate.supportId) is ready; copy the join code, then open WORLD LOBBY. No starting save is required."
                }
                elseif ($verifiedRelayJoin) {
                    $script:relayCredentialsPath = [string]$verifiedRelayJoin.credentialsPath
                    $script:relayCredentialRole = 'join'
                    $script:relaySupportId = [string]$verifiedRelayJoin.supportId
                    if (-not $script:restorePlanPath) {
                        $sessionBox.Text = [string]$verifiedRelayJoin.session
                    }
                    $joinCodeBox.Clear()
                    $statusLabel.Text = "Relay join prepared. Support ID: $($verifiedRelayJoin.supportId)"
                    Append-LauncherLog "Relay join $($verifiedRelayJoin.supportId) is prepared; open WORLD LOBBY to review the host settings and Ready."
                }
                else {
                    $statusLabel.Text = 'Task completed successfully.'
                    Append-LauncherLog "Completed $completedName with exit 0."
                }
            }
            else {
                $statusLabel.ForeColor = $danger
                $statusLabel.Text = "Task failed (exit $exitCode); see log."
                Append-LauncherLog "Failed $completedName with exit $exitCode."
            }
            $script:worker = $null
            $script:workerName = $null
            $script:pendingSaveSyncSession = $null
            if ($script:pendingRelayInviteFile `
                    -and (Test-Path -LiteralPath $script:pendingRelayInviteFile -PathType Leaf)) {
                try { [IO.File]::Delete($script:pendingRelayInviteFile) } catch { }
            }
            $script:pendingRelayInviteFile = $null
            $hostButton.Enabled = -not $script:restorePeer -or $script:restorePeer -eq 'player1'
            $joinButton.Enabled = -not $script:restorePeer -or $script:restorePeer -eq 'player2'
            $localhostButton.Enabled = $true
            $operationalButton.Enabled = $true
            $manualLabCheck.Enabled = $true
            $evidenceButton.Enabled = $true
            $archiveButton.Enabled = $true
            $restoreButton.Enabled = $true
            $latestRestoreButton.Enabled = $true
            $updateButton.Enabled = $true
            Update-TransportControls
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
                    $relayStage = if ($state.PSObject.Properties['transportMode'] `
                            -and $state.transportMode -eq 'secure-relay') {
                        "  /  RELAY $($state.supportId)"
                    } else { '' }
                    $saveShare = ''
                    if ($state.PSObject.Properties['saveSyncStatusPath'] -and $state.saveSyncStatusPath `
                            -and (Test-Path -LiteralPath ([string]$state.saveSyncStatusPath) -PathType Leaf)) {
                        try {
                            $share = Get-Content -LiteralPath ([string]$state.saveSyncStatusPath) -Raw | ConvertFrom-Json
                            if ($share.listening -eq $true) {
                                $saveShare = "  /  SAVE READY:$($share.port)"
                            }
                        }
                        catch { }
                    }
                    $statusLabel.Text = "$link  /  $session  /  $script:lastPeer$sequence$clock$preparing$saveShare$relayStage$launcherStage"
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
                        $autosaveGuardText = ''
                        if ($state.PSObject.Properties['autosaveGuardStatusPath'] `
                                -and $state.autosaveGuardStatusPath `
                                -and (Test-Path -LiteralPath ([string]$state.autosaveGuardStatusPath) -PathType Leaf)) {
                            try {
                                $autosaveGuardStatus = Get-Content `
                                    -LiteralPath ([string]$state.autosaveGuardStatusPath) -Raw | ConvertFrom-Json
                                if ($autosaveGuardStatus.status -eq 'active') {
                                    $autosaveGuardText = ' Ordinary per-client autosaves are suspended; recovery saves run only at a coordinated READY boundary.'
                                }
                            }
                            catch { }
                        }
                        $recoveryHint.Text = "Automatic recovery: $($recovery.status)$boundary. A stable save after consensus is archived and verified.$autosaveGuardText$expiry$faultEvidence"
                        $recoveryHint.ForeColor = if ($recovery.status -eq 'failed' -or $faultEvidence) { $danger } else { $muted }
                    }
                    catch { }
                }
            }
        }
    }
    catch { }
})
$relayCheck.Checked = $true
Update-TransportControls
if ([string]::IsNullOrWhiteSpace($defaultRelayUrl)) {
    Append-LauncherLog 'Secure relay is enabled, but relay-config.json has no production URL yet. Direct LAN remains available by unchecking relay.'
}
$timer.Start()

$form.Add_FormClosed({
    $timer.Stop()
    if ($script:pendingRelayInviteFile `
            -and (Test-Path -LiteralPath $script:pendingRelayInviteFile -PathType Leaf)) {
        try { Remove-Item -LiteralPath $script:pendingRelayInviteFile -Force }
        catch { }
    }
})
if ($SmokeTest) {
    $timer.Stop()
    $form.Dispose()
    Write-Host 'PASS multiplayer launcher UI constructed successfully'
    return
}
[void]$form.ShowDialog()
