# Pre-launch mod compatibility check.
#
# The lobby's verify_content walk is the slow uncached path. Before launching,
# the launcher only needs the active-content digest, which the companion
# already computes from the shared file-hash cache under
# %LOCALAPPDATA%\TPF2MP\cache\active-content-v1.json. This module runs that one
# cached command with a hard timeout and compares the truncated digest an
# invite link carries.
#
# Functions are dot-source safe: strict mode is scoped to each function.
# -CompanionCommand accepts a Get-Tpf2mpCompanionCommand-shaped object
# (FilePath/Prefix/Mode) so tests can substitute a fake companion.

function Get-Tpf2mpLocalContentDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [Parameter(Mandatory = $true)][string]$GameExecutable,
        [Parameter(Mandatory = $true)][string]$ModDirectory,
        [string]$ActiveModSave,
        [string]$ContentCache,
        [object]$CompanionCommand,
        [ValidateRange(5, 600)][int]$TimeoutSeconds = 120
    )
    Set-StrictMode -Version Latest
    if (-not (Get-Command -Name 'Resolve-Tpf2mpFullPath' -ErrorAction SilentlyContinue)) {
        . (Join-Path $PSScriptRoot 'network_common.ps1')
    }
    $bundle = Resolve-Tpf2mpFullPath $BundleRoot
    $game = Resolve-Tpf2mpFullPath $GameExecutable
    if (-not (Test-Path -LiteralPath $game -PathType Leaf)) {
        throw "Transport Fever 2 was not found at: $game"
    }
    $mod = Resolve-Tpf2mpFullPath $ModDirectory
    if (-not (Test-Path -LiteralPath $mod -PathType Container)) {
        throw "The installed TPF2MP mod directory was not found at: $mod"
    }
    $companionSource = Join-Path $bundle 'companion\tpf2mp'
    if (-not (Test-Path -LiteralPath $companionSource -PathType Container)) {
        throw "The companion content source is missing: $companionSource"
    }
    if (-not $ContentCache) {
        if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is unavailable; pass -ContentCache.' }
        $ContentCache = Join-Path $env:LOCALAPPDATA 'TPF2MP\cache\active-content-v1.json'
    }
    $cache = Resolve-Tpf2mpFullPath $ContentCache
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $cache) | Out-Null
    $companion = $CompanionCommand
    if (-not $companion) {
        try { $companion = Get-Tpf2mpCompanionCommand $bundle }
        catch { throw "TPF2MP cannot check active mods: $($_.Exception.Message)" }
    }
    $work = Resolve-Tpf2mpFullPath (Join-Path ([IO.Path]::GetTempPath()) (
        'tpf2mp-precheck-' + [guid]::NewGuid().ToString('N')))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $manifestPath = Join-Path $work 'content-manifest.json'
    $stdoutPath = Join-Path $work 'fingerprint.stdout.log'
    $stderrPath = Join-Path $work 'fingerprint.stderr.log'
    $arguments = @(
        'fingerprint', '--game-exe', $game, '--mod-dir', $mod,
        '--companion-dir', $companionSource, '--output', $manifestPath
    )
    if ($ActiveModSave) {
        $save = Resolve-Tpf2mpFullPath $ActiveModSave
        if (-not (Test-Path -LiteralPath $save -PathType Leaf)) {
            throw "The active-mod save was not found at: $save"
        }
        $arguments += @('--active-mod-save', $save, '--content-cache', $cache)
    }
    $prefix = @()
    if ($companion.PSObject.Properties['Prefix'] -and $companion.Prefix) { $prefix = @($companion.Prefix) }
    $mode = ''
    if ($companion.PSObject.Properties['Mode']) { $mode = [string]$companion.Mode }
    $previousPythonPath = $env:PYTHONPATH
    if ($mode -eq 'source') { $env:PYTHONPATH = Join-Path $bundle 'companion' }
    try {
        $process = Start-Process -FilePath ([string]$companion.FilePath) `
            -ArgumentList (ConvertTo-Tpf2mpCommandLine ($prefix + $arguments)) `
            -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        # Touching Handle keeps the process object able to report ExitCode after
        # it exits; Start-Process -PassThru otherwise loses it.
        $null = $process.Handle
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill() } catch { }
            throw "The active-mod check did not finish within $TimeoutSeconds seconds."
        }
        if ($process.ExitCode -ne 0) {
            $failure = ''
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) {
                $failure = (Get-Content -LiteralPath $stderrPath -Raw)
            }
            if (-not $failure) { $failure = "exit code $($process.ExitCode)" }
            throw "The active-mod check failed: $($failure.Trim())"
        }
        $digest = $null
        foreach ($line in @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue)) {
            $match = [regex]::Match([string]$line, '^active_content_digest=(?<digest>[0-9a-f]{64})\s*$')
            if ($match.Success) { $digest = $match.Groups['digest'].Value }
        }
        $mods = @()
        if ($digest -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            $components = $manifest.PSObject.Properties['components']
            if ($components -and $components.Value.PSObject.Properties['active_content']) {
                foreach ($record in @($components.Value.active_content.mods)) {
                    if (-not $record) { continue }
                    $mods += ('{0}@{1}.{2}' -f [string]$record.id,
                        [int]$record.majorVersion, [int]$record.minorVersion)
                }
            }
        }
        $source = 'unavailable'
        if ($digest) { $source = 'companion-fingerprint' }
        return [pscustomobject]@{ Digest = $digest; Mods = @($mods); Source = $source }
    }
    finally {
        $env:PYTHONPATH = $previousPythonPath
        if (Test-Path -LiteralPath $work) {
            Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Compare-Tpf2mpContentDigest {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][AllowNull()][string]$Local,
        [AllowEmptyString()][AllowNull()][string]$Remote
    )
    Set-StrictMode -Version Latest
    if (-not $Local -or -not $Remote) { return 'unknown' }
    $left = ([string]$Local).Trim().ToLowerInvariant()
    $right = ([string]$Remote).Trim().ToLowerInvariant()
    if ($left -notmatch '^[0-9a-f]{8,64}$' -or $right -notmatch '^[0-9a-f]{8,64}$') {
        return 'unknown'
    }
    $length = [Math]::Min(16, [Math]::Min($left.Length, $right.Length))
    if ($length -lt 8) { return 'unknown' }
    if ($left.Substring(0, $length) -ceq $right.Substring(0, $length)) { return 'match' }
    return 'mismatch'
}
