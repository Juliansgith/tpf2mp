Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release_common.ps1')

function Get-Tpf2mpVerifiedReleaseUpdateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [string]$InstallRoot
    )

    try {
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
            return $null
        }
        if (-not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }

        $stdout = [IO.File]::ReadAllText($StdoutPath)
        $expectedVersion = $null
        $updated = [regex]::Match(
            $stdout,
            '(?m)^TPF2MP updated successfully:\s+\S+\s+->\s+(\S+)\s*$')
        if ($updated.Success) {
            $expectedVersion = $updated.Groups[1].Value
        }
        else {
            $current = [regex]::Match(
                $stdout,
                '(?m)^TPF2MP\s+(\S+)\s+(?:is current on the \S+ channel|is already installed)\.\s*$')
            if ($current.Success) { $expectedVersion = $current.Groups[1].Value }
        }
        if (-not $expectedVersion -or $expectedVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$') {
            return $null
        }

        if (-not $InstallRoot) {
            if (-not $env:LOCALAPPDATA) { return $null }
            $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
        }
        $install = Resolve-Tpf2mpFullPath $InstallRoot
        $currentPath = Join-Path $install 'current.json'
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { return $null }
        $pointer = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
        if ([string]$pointer.version -cne $expectedVersion -or -not [string]$pointer.bundleRoot) {
            return $null
        }

        $installedBundle = Resolve-Tpf2mpFullPath ([string]$pointer.bundleRoot)
        $versionsRoot = Resolve-Tpf2mpFullPath (Join-Path $install 'versions')
        if (-not $installedBundle.StartsWith(
                $versionsRoot.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $manifest = Test-Tpf2mpReleaseManifest $installedBundle
        if ([string]$manifest.version -cne $expectedVersion `
                -or [int]$manifest.format -lt 2 `
                -or [bool]$manifest.source.dirty) {
            return $null
        }

        return [pscustomobject]@{
            version = $expectedVersion
            bundleRoot = $installedBundle
            sourceCommit = [string]$manifest.source.commit
        }
    }
    catch {
        # This is a secondary proof used only after a worker reports failure.
        # Any unreadable or incomplete evidence must preserve the failure.
        return $null
    }
}
