Set-StrictMode -Version Latest

function New-Tpf2mpRelayDiagnosticSources {
    param(
        [Parameter(Mandatory = $true)][string]$SessionRoot,
        [Parameter(Mandatory = $true)][string]$BridgePath,
        [Parameter(Mandatory = $true)][string]$RelayStatusPath,
        [string]$LocalModsPath,
        [object]$SessionState,
        [switch]$Startup
    )
    $sources = [ordered]@{
        'launcher.session' = Join-Path $SessionRoot 'session-state.json'
        'companion.stdout' = Join-Path $SessionRoot 'companion.stdout.log'
        'companion.stderr' = Join-Path $SessionRoot 'companion.stderr.log'
        'companion.status' = Join-Path $BridgePath 'companion_state\companion_status.json'
        'launcher.menu' = Join-Path $BridgePath 'launcher\menu_status.json'
        'relay.tunnel' = $RelayStatusPath
    }
    if ($Startup) { return $sources }

    $resolvedMods = Find-Tpf2mpLocalModsPath $LocalModsPath
    $localGameData = Split-Path -Parent $resolvedMods
    $sources['game.stdout'] = Join-Path $localGameData 'crash_dump\stdout.txt'
    if ($SessionState -and $SessionState.PSObject.Properties['nativeStatusPath'] `
            -and $SessionState.nativeStatusPath) {
        $sources['native.status'] = [string]$SessionState.nativeStatusPath
    }
    if ($SessionState -and $SessionState.PSObject.Properties['recoveryWatcherStatusPath'] `
            -and $SessionState.recoveryWatcherStatusPath) {
        $sources['recovery.status'] = [string]$SessionState.recoveryWatcherStatusPath
    }
    return $sources
}

function Start-Tpf2mpRelayDiagnosticProcess {
    param(
        [Parameter(Mandatory = $true)]$Companion,
        [Parameter(Mandatory = $true)][string]$CredentialsPath,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Sources,
        [Parameter(Mandatory = $true)][string]$StatusPath,
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$ExpectedSessionId,
        [Parameter(Mandatory = $true)][ValidateSet('host', 'join')][string]$ExpectedRole,
        [ValidateRange(1, 60)][int]$StartupTimeoutSeconds = 10,
        [switch]$AllowInsecureLoopback
    )
    $sourceArguments = @()
    foreach ($name in @($Sources.Keys | Sort-Object)) {
        $path = [string]$Sources[$name]
        if ($path) { $sourceArguments += @('--source', ($name + '=' + $path)) }
    }
    $arguments = @(
        'relay-diagnostics', '--credentials', $CredentialsPath,
        '--status', $StatusPath, '--interval', '2'
    ) + $sourceArguments
    $commandLine = ConvertTo-Tpf2mpCommandLine (@($Companion.Prefix) + $arguments)
    $previousLoopback = $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK
    try {
        if ($AllowInsecureLoopback) { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = '1' }
        $launcher = Start-Process -FilePath $Companion.FilePath -ArgumentList $commandLine `
            -PassThru -WindowStyle Hidden -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath
    }
    finally { $env:TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK = $previousLoopback }

    try {
        $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
        do {
            $launcher.Refresh()
            if ($launcher.HasExited) {
                $errorText = if (Test-Path -LiteralPath $StderrPath) {
                    Get-Content -LiteralPath $StderrPath -Raw
                } else { '' }
                throw "Relay diagnostics exited during startup: $errorText"
            }
            if (Test-Path -LiteralPath $StatusPath -PathType Leaf) {
                try {
                    $status = Get-Content -LiteralPath $StatusPath -Raw | ConvertFrom-Json
                    if ([string]$status.sessionId -ceq $ExpectedSessionId `
                            -and [string]$status.role -ceq $ExpectedRole `
                            -and [string]$status.state -in @('running', 'retrying')) {
                        return [pscustomobject][ordered]@{
                            LauncherPid = $launcher.Id
                            ServicePid = [int]$status.pid
                            StatusPath = $StatusPath
                            StdoutPath = $StdoutPath
                            StderrPath = $StderrPath
                        }
                    }
                }
                catch { }
            }
            Start-Sleep -Milliseconds 100
        } while ((Get-Date) -lt $deadline)
        throw "Relay diagnostics did not publish a valid status within $StartupTimeoutSeconds seconds."
    }
    catch {
        Stop-Tpf2mpVerifiedRelayProcesses -Companion $Companion `
            -CredentialsPath $CredentialsPath `
            -CommandName relay-diagnostics
        throw
    }
}

function Stop-Tpf2mpVerifiedRelayProcesses {
    param(
        [Parameter(Mandatory = $true)]$Companion,
        [Parameter(Mandatory = $true)][string]$CredentialsPath,
        [Parameter(Mandatory = $true)][ValidateSet('relay-diagnostics', 'relay-tunnel')][string]$CommandName
    )
    $expectedExecutable = Resolve-Tpf2mpFullPath ([string]$Companion.FilePath)
    $credentialPattern = [Regex]::Escape((Resolve-Tpf2mpFullPath $CredentialsPath))
    $commandPattern = [Regex]::Escape($CommandName)
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $matches = @(
            Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath -and $_.CommandLine `
                        -and [string]::Equals(
                            (Resolve-Tpf2mpFullPath ([string]$_.ExecutablePath)),
                            $expectedExecutable, [StringComparison]::OrdinalIgnoreCase) `
                        -and [string]$_.CommandLine -match $commandPattern `
                        -and [string]$_.CommandLine -match $credentialPattern
                }
        )
        if ($matches.Count -eq 0) { return }
        $matchingIds = @($matches | ForEach-Object { [int]$_.ProcessId })
        # Stop PyInstaller supervisors before their extracted children, then
        # rescan: a handoff can publish a replacement PID after the first kill.
        $ordered = @($matches | Sort-Object @{ Expression = {
            if ($matchingIds -contains [int]$_.ParentProcessId) { 1 } else { 0 }
        } })
        foreach ($native in $ordered) {
            Stop-Process -Id ([int]$native.ProcessId) -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 100
    }
    throw "Verified $CommandName shutdown left a process using the exact relay credential running."
}

function Stop-Tpf2mpRelayDiagnosticProcess {
    param(
        [object]$Handle,
        [Parameter(Mandatory = $true)]$Companion,
        [Parameter(Mandatory = $true)][string]$CredentialsPath
    )
    if (-not $Handle) { return }
    Stop-Tpf2mpVerifiedRelayProcesses -Companion $Companion `
        -CredentialsPath $CredentialsPath `
        -CommandName relay-diagnostics
}
