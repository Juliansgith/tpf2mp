[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$caseRoot = Join-Path $TemporaryRoot 'launcher-qol'
$localAppData = Join-Path $caseRoot 'local-app-data'
New-Item -ItemType Directory -Force -Path $localAppData | Out-Null
$previousLocalAppData = $env:LOCALAPPDATA
$previousProbe = $env:TPF2MP_RESTART_PROBE
$env:LOCALAPPDATA = $localAppData
try {
    . (Join-Path $ProjectRoot 'tools\launcher_update_controller.ps1')

    $lockedLog = Join-Path $caseRoot 'live-worker.stdout.log'
    [IO.File]::WriteAllText($lockedLog, 'worker still running', [Text.UTF8Encoding]::new($false))
    $exclusive = [IO.File]::Open(
        $lockedLog, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if ($null -ne (Read-Tpf2mpLauncherLogText -Path $lockedLog)) {
            throw 'Launcher trusted a worker log while its writer held an exclusive handle.'
        }
    }
    finally { $exclusive.Dispose() }
    if ((Read-Tpf2mpLauncherLogText -Path $lockedLog) -cne 'worker still running') {
        throw 'Launcher could not read the worker log after its writer released the handle.'
    }

    $stdout = Join-Path $caseRoot 'check.stdout.log'
    $stderr = Join-Path $caseRoot 'check.stderr.log'
    [IO.File]::WriteAllText($stderr, '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stdout,
        "TPF2MP 0.39.1-alpha is available (installed: 0.39.0-alpha).`r`n",
        [Text.UTF8Encoding]::new($false))
    $available = Get-Tpf2mpReleaseUpdateCheckResult -StdoutPath $stdout `
        -StderrPath $stderr -ExpectedCurrentVersion '0.39.0-alpha'
    if (-not $available -or $available.state -cne 'available' `
            -or $available.availableVersion -cne '0.39.1-alpha') {
        throw 'Launch-time update check did not recognize an authenticated newer release.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    $fakeUpdater = Join-Path $caseRoot 'fake-update.ps1'
    [IO.File]::WriteAllText($fakeUpdater, @'
param([string]$BundleRoot, [switch]$CheckOnly, [switch]$NoCredentialPrompt)
if (-not $CheckOnly -or -not $NoCredentialPrompt) { throw 'background flags missing' }
Write-Host 'TPF2MP 0.39.1-alpha is available (installed: 0.39.0-alpha).'
'@, [Text.UTF8Encoding]::new($false))
    $form = New-Object Windows.Forms.Form
    $form.ShowInTaskbar = $false
    $form.Opacity = 0
    $button = New-Object Windows.Forms.Button
    $label = New-Object Windows.Forms.Label
    $form.Controls.Add($button)
    $form.Controls.Add($label)
    $controllerMessages = [Collections.Generic.List[string]]::new()
    [void](Initialize-Tpf2mpLauncherUpdateController -Form $form -Button $button `
        -StatusLabel $label -BundleRoot $ProjectRoot -CurrentVersion '0.39.0-alpha' `
        -LogAction { param($message) $controllerMessages.Add([string]$message) } `
        -CanEnableAction { $true } -UpdateScript $fakeUpdater)
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    $watchdog = New-Object Windows.Forms.Timer
    $watchdog.Interval = 50
    $watchdog.Add_Tick({
        if ($button.Text -eq 'UPDATE 0.39.1-ALPHA' -or [DateTime]::UtcNow -ge $deadline) {
            $form.Close()
        }
    }.GetNewClosure())
    $watchdog.Start()
    [void]$form.ShowDialog()
    $watchdog.Stop()
    $watchdog.Dispose()
    if ($button.Text -ne 'UPDATE 0.39.1-ALPHA') {
        throw "The real launcher controller did not complete its non-blocking Shown-event update check: $($controllerMessages -join '; ')"
    }
    $form.Dispose()

    [IO.File]::WriteAllText($stdout,
        "TPF2MP 0.39.0-alpha is current on the alpha channel.`r`n",
        [Text.UTF8Encoding]::new($false))
    $current = Get-Tpf2mpReleaseUpdateCheckResult -StdoutPath $stdout `
        -StderrPath $stderr -ExpectedCurrentVersion '0.39.0-alpha'
    if (-not $current -or $current.state -cne 'current') {
        throw 'Launch-time update check did not recognize the current release.'
    }
    [IO.File]::WriteAllText($stderr, 'network failure', [Text.UTF8Encoding]::new($false))
    if (Get-Tpf2mpReleaseUpdateCheckResult -StdoutPath $stdout -StderrPath $stderr) {
        throw 'Launch-time update check trusted stdout despite stderr failure residue.'
    }

    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
        -ArgumentList (ConvertTo-Tpf2mpCommandLine @('-NoProfile', '-Command', 'exit 0')) -PassThru -WindowStyle Hidden
    $process.WaitForExit()
    if ((Get-Tpf2mpCompletedProcessExitCode $process) -ne 0) {
        throw 'Launcher process completion did not preserve a normal zero exit code.'
    }
    $receipt = [pscustomobject]@{ valid = $true }
    if (-not (Test-Tpf2mpWorkerCompletionSucceeded -ExitCode $null -VerifiedReceipts @($receipt)) `
            -or (Test-Tpf2mpWorkerCompletionSucceeded -ExitCode $null)) {
        throw 'Durable receipt evidence did not safely recover a missing worker exit code.'
    }

    $installRoot = Join-Path $caseRoot 'installed'
    $updatedBundle = Join-Path $installRoot 'versions\0.39.1-alpha'
    New-Item -ItemType Directory -Force -Path $updatedBundle | Out-Null
    $probe = Join-Path $caseRoot 'restart-probe.json'
    $env:TPF2MP_RESTART_PROBE = $probe
    [IO.File]::WriteAllText((Join-Path $installRoot 'installed_entrypoint.ps1'), @'
param([string]$Action, [string]$InstallRoot)
[IO.File]::WriteAllText($env:TPF2MP_RESTART_PROBE,
    ([pscustomobject]@{ action = $Action; installRoot = $InstallRoot } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    $restart = Start-Tpf2mpInstalledLauncherAfterUpdate ([pscustomobject]@{
        version = '0.39.1-alpha'; bundleRoot = $updatedBundle; changed = $true
    })
    $restart.WaitForExit()
    if ($restart.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $probe -PathType Leaf)) {
        throw 'Post-update launcher restart did not execute the stable installed entrypoint.'
    }
    $restartProbe = Get-Content -LiteralPath $probe -Raw | ConvertFrom-Json
    if ($restartProbe.action -cne 'Launch' `
            -or [IO.Path]::GetFullPath([string]$restartProbe.installRoot) `
                -ne [IO.Path]::GetFullPath($installRoot)) {
        throw 'Post-update restart did not bind the new launcher to the stable install root.'
    }

    $draft = Join-Path $localAppData 'TPF2MP\relay-drafts\fixture'
    New-Item -ItemType Directory -Force -Path $draft | Out-Null
    $credentialsPath = Join-Path $draft 'host-credentials.json'
    $receiptPath = Join-Path $draft 'invite-receipt.json'
    $session = 'mp-0123456789abcdef'
    [pscustomobject]@{
        schemaVersion = 1; role = 'host'; sessionId = $session
        relayUrl = 'https://relay.example.test'; token = ('a' * 48)
    } | ConvertTo-Json | Set-Content -LiteralPath $credentialsPath -Encoding UTF8
    [pscustomobject]@{
        schemaVersion = 1; sessionId = $session; supportId = $session
        relayUrl = 'https://relay.example.test'; joinCode = ('TPF2MP1.' + ('b' * 48))
        credentialsPath = $credentialsPath; expiresAt = '2026-08-24T18:00:00Z'
    } | ConvertTo-Json | Set-Content -LiteralPath $receiptPath -Encoding UTF8
    [IO.File]::WriteAllText($stderr, '', [Text.UTF8Encoding]::new($false))
    $relayLines = @(
        "relay_session_created=$session",
        "relay_credentials=$credentialsPath",
        "relay_invite_receipt=$receiptPath"
    )
    [IO.File]::WriteAllText($stdout, (($relayLines + $relayLines) -join "`r`n"),
        [Text.UTF8Encoding]::new($false))
    $relayResult = Get-Tpf2mpVerifiedRelayCreateResult -StdoutPath $stdout -StderrPath $stderr
    if (-not $relayResult -or $relayResult.session -cne $session) {
        throw 'Launcher did not recover a valid relay room receipt from the quick-worker completion case.'
    }

    # Invite links: a host shares one link instead of a bare code, and the
    # launcher must accept either without ever logging the bearer code.
    . (Join-Path $ProjectRoot 'tools\launcher_invite_link.ps1')
    . (Join-Path $ProjectRoot 'tools\launcher_mod_precheck.ps1')
    $sampleCode = 'TPF2MP1.' + ('c' * 40) + '_-9'
    $sampleDigest = '0123456789abcdef' + ('0' * 48)
    $link = New-Tpf2mpInviteLink -JoinCode $sampleCode -ContentDigest $sampleDigest
    if ($link -cne "tpf2mp://join?code=$sampleCode&content=0123456789abcdef") {
        throw "Invite link composition changed shape: $link"
    }
    if ((New-Tpf2mpInviteLink -JoinCode $sampleCode) -cne "tpf2mp://join?code=$sampleCode") {
        throw 'Invite link without a content digest gained an unexpected query.'
    }
    $parsedLink = ConvertFrom-Tpf2mpInviteInput -Text "  $link  "
    if (-not $parsedLink -or $parsedLink.Kind -cne 'link' `
            -or $parsedLink.JoinCode -cne $sampleCode `
            -or $parsedLink.ContentDigest -cne '0123456789abcdef') {
        throw 'Invite link round trip did not recover the join code and content hint.'
    }
    $parsedCode = ConvertFrom-Tpf2mpInviteInput -Text "  $sampleCode  "
    if (-not $parsedCode -or $parsedCode.Kind -cne 'code' `
            -or $parsedCode.JoinCode -cne $sampleCode -or $parsedCode.ContentDigest) {
        throw 'A pasted bare join code was not accepted as a join code.'
    }
    foreach ($accepted in @(
            "tpf2mp://join/?code=$sampleCode",
            "TPF2MP://JOIN?code=$sampleCode",
            "tpf2mp://join?source=discord&code=$sampleCode")) {
        $value = ConvertFrom-Tpf2mpInviteInput -Text $accepted
        if (-not $value -or $value.JoinCode -cne $sampleCode) {
            throw "A valid invite link shape was rejected: $accepted"
        }
    }
    foreach ($rejected in @(
            '', '   ', 'tpf2mp://join', 'tpf2mp://join?code=',
            "tpf2mp://host?code=$sampleCode",
            "tpf2mp://join/extra?code=$sampleCode",
            "https://join?code=$sampleCode",
            "tpf2mp://join?code=$sampleCode#fragment",
            "tpf2mp://join?code=$sampleCode&code=$sampleCode",
            "tpf2mp://join?code=$sampleCode&content=nothex0123456789",
            "tpf2mp://join?code=$sampleCode&content=$('a' * 65)",
            'tpf2mp://join?code=TPF2MP1.short',
            "TPF2MP1.$('!' * 40)", 'not a link at all')) {
        if ($null -ne (ConvertFrom-Tpf2mpInviteInput -Text $rejected)) {
            throw "An invalid invite input was accepted: $rejected"
        }
    }

    # The handler is per-user and needs no elevation. Tests must never touch
    # the machine's real HKCU:\Software\Classes registration.
    $registryRoot = 'HKCU:\Software\TPF2MP-test-' + [guid]::NewGuid().ToString('N')
    $inviteInstallRoot = Join-Path $caseRoot 'invite install root'
    New-Item -ItemType Directory -Force -Path $inviteInstallRoot | Out-Null
    $inviteEntrypoint = Join-Path $inviteInstallRoot 'installed_entrypoint.ps1'
    [IO.File]::WriteAllText($inviteEntrypoint, '# fixture', [Text.UTF8Encoding]::new($false))
    try {
        $registration = Register-Tpf2mpInviteProtocol -InstallRoot $inviteInstallRoot `
            -RegistryRoot $registryRoot
        [void](Register-Tpf2mpInviteProtocol -InstallRoot $inviteInstallRoot -RegistryRoot $registryRoot)
        $protocolKey = Join-Path $registryRoot 'tpf2mp'
        $values = Get-ItemProperty -LiteralPath $protocolKey
        if ([string]$values.'(default)' -cne 'URL:TPF2MP invite' `
                -or $null -eq $values.PSObject.Properties['URL Protocol'] `
                -or [string]$values.'URL Protocol' -cne '') {
            throw 'The tpf2mp registration is missing its URL protocol declaration.'
        }
        $command = [string](Get-ItemProperty -LiteralPath (Join-Path $protocolKey 'shell\open\command')).'(default)'
        if ($command -cne $registration.Command `
                -or -not $command.Contains('-Action Join -Url "%1"') `
                -or -not $command.Contains($inviteEntrypoint) `
                -or -not $command.Contains((Join-Path $PSHOME 'powershell.exe'))) {
            throw "The tpf2mp open command is not the stable entrypoint: $command"
        }
        if ((Unregister-Tpf2mpInviteProtocol -RegistryRoot $registryRoot) -cne 'removed' `
                -or (Test-Path -LiteralPath $protocolKey)) {
            throw 'Unregistering the invite protocol did not remove its key.'
        }
        if ((Unregister-Tpf2mpInviteProtocol -RegistryRoot $registryRoot) -cne 'absent') {
            throw 'Unregistering the invite protocol twice was not idempotent.'
        }
        $elevated = $false
        try { [void](Unregister-Tpf2mpInviteProtocol -RegistryRoot 'HKLM:\Software\Classes') }
        catch { $elevated = $true }
        if (-not $elevated) { throw 'The invite protocol helpers accepted a machine-wide registry root.' }
    }
    finally {
        if (Test-Path -LiteralPath $registryRoot) {
            Remove-Item -LiteralPath $registryRoot -Recurse -Force
        }
    }

    # Content pre-check: digest comparison is pure, and the companion call is
    # exercised through a fake command with the real argument contract.
    $digestCases = @(
        @{ local = $sampleDigest; remote = '0123456789abcdef'; expected = 'match' },
        @{ local = $sampleDigest; remote = '0123456789abcdee'; expected = 'mismatch' },
        @{ local = $sampleDigest; remote = ''; expected = 'unknown' },
        @{ local = $null; remote = '0123456789abcdef'; expected = 'unknown' },
        @{ local = $sampleDigest; remote = 'not-hex-value00'; expected = 'unknown' },
        @{ local = '0123456'; remote = '0123456789abcdef'; expected = 'unknown' },
        @{ local = '0123456789ABCDEF'; remote = '0123456789abcdef'; expected = 'match' }
    )
    foreach ($case in $digestCases) {
        $verdict = Compare-Tpf2mpContentDigest -Local $case.local -Remote $case.remote
        if ($verdict -cne $case.expected) {
            throw "Content digest comparison returned $verdict instead of $($case.expected)."
        }
    }

    $contentRoot = Join-Path $caseRoot 'content'
    $fakeModDirectory = Join-Path $contentRoot 'tpf2_mp_1'
    New-Item -ItemType Directory -Force -Path $fakeModDirectory | Out-Null
    $fakeGame = Join-Path $contentRoot 'TransportFever2.exe'
    $fakeSave = Join-Path $contentRoot 'start.sav'
    foreach ($fixtureFile in @($fakeGame, $fakeSave)) {
        [IO.File]::WriteAllText($fixtureFile, 'fixture', [Text.UTF8Encoding]::new($false))
    }
    $expectedDigest = ('0123456789abcdef' * 4)
    $fakeCompanion = Join-Path $caseRoot 'fake-companion.ps1'
    [IO.File]::WriteAllText($fakeCompanion, @'
param()
$arguments = @($args)
if ($arguments.Count -lt 1 -or $arguments[0] -ne 'fingerprint') { exit 3 }
$map = @{}
for ($index = 1; $index -lt $arguments.Count; $index += 2) {
    $map[[string]$arguments[$index]] = [string]$arguments[$index + 1]
}
foreach ($required in @('--game-exe', '--mod-dir', '--companion-dir', '--output',
        '--active-mod-save', '--content-cache')) {
    if (-not $map.ContainsKey($required) -or -not $map[$required]) { exit 4 }
}
$digest = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
$inventory = [pscustomobject]@{
    schemaVersion = 1
    digest = $digest
    mods = @(
        [pscustomobject]@{ id = 'tpf2_mp_1'; majorVersion = 1; minorVersion = 45 },
        [pscustomobject]@{ id = 'workshop_990'; majorVersion = 0; minorVersion = 3 }
    )
}
[pscustomobject]@{
    fingerprint = 'f' * 64
    components = [pscustomobject]@{ active_content = $inventory }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $map['--output'] -Encoding UTF8
Write-Host "manifest=$($map['--output'])"
Write-Host "active_content_digest=$digest"
Write-Host 'active_content_mods=2'
'@, [Text.UTF8Encoding]::new($false))
    $fakeCommand = [pscustomobject]@{
        FilePath = (Join-Path $PSHOME 'powershell.exe')
        Prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fakeCompanion)
        Mode = 'fake'
    }
    $content = Get-Tpf2mpLocalContentDigest -BundleRoot $ProjectRoot -GameExecutable $fakeGame `
        -ModDirectory $fakeModDirectory -ActiveModSave $fakeSave `
        -ContentCache (Join-Path $contentRoot 'cache\active-content-v1.json') `
        -CompanionCommand $fakeCommand
    if ($content.Digest -cne $expectedDigest -or $content.Source -cne 'companion-fingerprint' `
            -or $content.Mods.Count -ne 2 -or $content.Mods[0] -cne 'tpf2_mp_1@1.45' `
            -or $content.Mods[1] -cne 'workshop_990@0.3') {
        throw "The cached active-content read did not report the local mod set: $($content.Mods -join ', ')"
    }
    if ((Compare-Tpf2mpContentDigest -Local $content.Digest -Remote $parsedLink.ContentDigest) -cne 'match') {
        throw 'A matching local digest did not agree with the invite link content hint.'
    }

    $hangingCompanion = Join-Path $caseRoot 'hanging-companion.ps1'
    [IO.File]::WriteAllText($hangingCompanion,
        "param()`r`nStart-Sleep -Seconds 60`r`n", [Text.UTF8Encoding]::new($false))
    $hangingCommand = [pscustomobject]@{
        FilePath = (Join-Path $PSHOME 'powershell.exe')
        Prefix = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $hangingCompanion)
        Mode = 'fake'
    }
    $started = [DateTime]::UtcNow
    $timedOut = $false
    try {
        [void](Get-Tpf2mpLocalContentDigest -BundleRoot $ProjectRoot -GameExecutable $fakeGame `
            -ModDirectory $fakeModDirectory -ActiveModSave $fakeSave `
            -ContentCache (Join-Path $contentRoot 'cache\active-content-v1.json') `
            -CompanionCommand $hangingCommand -TimeoutSeconds 5)
    }
    catch { $timedOut = $true }
    if (-not $timedOut -or ([DateTime]::UtcNow - $started).TotalSeconds -gt 30) {
        throw 'A stuck companion content check was not bounded by its timeout.'
    }
    $missingCompanion = $false
    try {
        [void](Get-Tpf2mpLocalContentDigest -BundleRoot (Join-Path $caseRoot 'no-bundle') `
            -GameExecutable $fakeGame -ModDirectory $fakeModDirectory)
    }
    catch { $missingCompanion = $true }
    if (-not $missingCompanion) {
        throw 'A missing companion source did not fail the pre-launch content check.'
    }

    # Onboarding checklist: the launcher paints whatever this pure derivation
    # says, so the derivation is the thing worth pinning.
    . (Join-Path $ProjectRoot 'tools\launcher_checklist.ps1')
    $checklistCases = @(
        @{ case = 'a freshly opened launcher'; signals = @{}
           expected = @('current', 'pending', 'pending', 'pending') },
        @{ case = 'a created relay room'; signals = @{ CredentialRole = 'host' }
           expected = @('done', 'current', 'pending', 'pending') },
        @{ case = 'a prepared join with a chosen save'
           signals = @{ CredentialRole = 'join'; HasSave = $true }
           expected = @('done', 'done', 'current', 'pending') },
        @{ case = 'a host whose lobby generated the world'
           signals = @{ CredentialRole = 'host'; LobbyWorldReady = $true }
           expected = @('done', 'done', 'current', 'pending') },
        @{ case = 'a world-ready host'
           signals = @{ CredentialRole = 'host'; LobbyWorldReady = $true
                        SessionStatus = 'hosting-world-ready' }
           expected = @('done', 'done', 'done', 'current') },
        @{ case = 'a restarted launcher watching a live match'
           signals = @{ SessionStatus = 'joined-world-ready'; NetworkLink = 'CONNECTED' }
           expected = @('done', 'done', 'done', 'done') },
        @{ case = 'a game launched and waiting for its world'
           signals = @{ SessionStatus = 'waiting-for-network-world' }
           expected = @('done', 'done', 'current', 'pending') },
        @{ case = 'a failed session'; signals = @{ CredentialRole = 'host'; SessionStatus = 'failed' }
           expected = @('done', 'current', 'pending', 'pending') }
    )
    foreach ($checklistCase in $checklistCases) {
        $states = @(Get-Tpf2mpChecklistState -Signals $checklistCase.signals |
            ForEach-Object { $_.State })
        if (($states -join ',') -cne ($checklistCase.expected -join ',')) {
            throw ("Checklist derivation for $($checklistCase.case) produced " +
                "$($states -join ',') instead of $($checklistCase.expected -join ',').")
        }
    }
    $checklistLabels = @(Get-Tpf2mpChecklistState | ForEach-Object { $_.Label })
    if ($checklistLabels.Count -ne 4 -or $checklistLabels[0] -cne '1 Create or paste a code' `
            -or $checklistLabels[3] -cne '4 Host starts the match') {
        throw "The checklist no longer names its four ordered steps: $($checklistLabels -join ' | ')"
    }

    # Recent sessions and resume: fixtures stand in for real matches, and a
    # temporary save folder stands in for the game's save directory.
    . (Join-Path $ProjectRoot 'tools\launcher_sessions.ps1')
    $sessionsRoot = Join-Path $localAppData 'TPF2MP\sessions'
    $resumeSaves = Join-Path $caseRoot 'tpf2-saves'
    New-Item -ItemType Directory -Force -Path $resumeSaves | Out-Null
    $pinnedSave = Join-Path $resumeSaves 'pinned.sav'
    $continuedSave = Join-Path $resumeSaves 'continued.sav'
    $olderStart = [DateTime]::UtcNow.AddHours(-9)
    $newerStart = [DateTime]::UtcNow.AddHours(-2)
    foreach ($fixture in @(
            @{ session = 'match-older'; peer = 'player1'; role = 'host'; started = $olderStart },
            @{ session = 'match-newer'; peer = 'player2'; role = 'join'; started = $newerStart })) {
        $peerRoot = Join-Path $sessionsRoot "$($fixture.session)\$($fixture.peer)"
        New-Item -ItemType Directory -Force -Path $peerRoot | Out-Null
        [pscustomobject]@{
            schemaVersion = 3; session = $fixture.session; role = $fixture.role
            peer = $fixture.peer; status = 'hosting-world-ready'
            supportId = 'mp-0123456789abcdef'; transportMode = 'secure-relay'
            startedAtUtc = $fixture.started.ToString('o')
            startingSave = $pinnedSave; pinnedStartingSave = $pinnedSave
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $peerRoot 'session-state.json') `
            -Encoding UTF8
    }
    $legacyRoot = Join-Path $sessionsRoot 'match-legacy\player1'
    New-Item -ItemType Directory -Force -Path $legacyRoot | Out-Null
    [pscustomobject]@{
        schemaVersion = 2; session = 'match-legacy'; role = 'host'; peer = 'player1'
        status = 'hosting'; startedAtUtc = ([DateTime]::UtcNow.ToString('o'))
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $legacyRoot 'session-state.json') `
        -Encoding UTF8
    $recent = @(Get-Tpf2mpRecentSessions -Limit 5)
    if ($recent.Count -ne 2 -or $recent[0].Session -cne 'match-newer' `
            -or $recent[1].Session -cne 'match-older') {
        throw ('Recent session discovery did not order schemaVersion 3 matches newest first: ' +
            (($recent | ForEach-Object { $_.Session }) -join ', '))
    }
    if ($recent[0].Role -cne 'join' -or $recent[0].Peer -cne 'player2' `
            -or $recent[0].TransportMode -cne 'secure-relay' `
            -or $recent[0].SupportId -cne 'mp-0123456789abcdef' `
            -or $recent[0].StartingSave -cne $pinnedSave) {
        throw 'A recent session record lost the role, peer, transport or starting save it needs.'
    }
    if (@(Get-Tpf2mpRecentSessions -Limit 1).Count -ne 1) {
        throw 'Recent session discovery ignored its limit.'
    }
    foreach ($fixtureSave in @($pinnedSave, $continuedSave)) {
        [IO.File]::WriteAllText($fixtureSave, 'fixture save', [Text.UTF8Encoding]::new($false))
    }
    [IO.File]::SetLastWriteTimeUtc($pinnedSave, $olderStart.AddHours(-1))
    [IO.File]::SetLastWriteTimeUtc($continuedSave, [DateTime]::UtcNow.AddMinutes(-20))
    $resume = Get-Tpf2mpResumeCandidate -Session $recent[0] -SaveDirectory $resumeSaves
    if (-not $resume -or $resume.Path -cne $continuedSave -or $resume.Source -cne 'match-save') {
        throw "Resume did not choose the save made after that match began: $($resume.Path)"
    }
    # Nothing newer than the match: the pinned starting save is the answer.
    $emptySaves = Join-Path $caseRoot 'empty-saves'
    New-Item -ItemType Directory -Force -Path $emptySaves | Out-Null
    $fallback = Get-Tpf2mpResumeCandidate -Session $recent[0] -SaveDirectory $emptySaves
    if (-not $fallback -or $fallback.Path -cne $pinnedSave `
            -or $fallback.Source -cne 'starting-save') {
        throw 'Resume did not fall back to the pinned starting save of that match.'
    }
    $unknown = Get-Tpf2mpResumeCandidate -SaveDirectory $emptySaves -Session ([pscustomobject]@{
        Session = 'match-gone'; StartedAtUtc = $newerStart; StartingSave = (Join-Path $emptySaves 'x.sav')
    })
    if ($null -ne $unknown) { throw 'Resume invented a save that does not exist on this computer.' }
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:TPF2MP_RESTART_PROBE = $previousProbe
}

Write-Host ('PASS launcher auto-update parsing, durable relay completion, post-update restart QoL, ' +
    'invite links, the cached pre-launch content check, the onboarding checklist, and resume discovery')
