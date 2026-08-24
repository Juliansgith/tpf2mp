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
}
finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:TPF2MP_RESTART_PROBE = $previousProbe
}

Write-Host 'PASS launcher auto-update parsing, durable relay completion, and post-update restart QoL'
