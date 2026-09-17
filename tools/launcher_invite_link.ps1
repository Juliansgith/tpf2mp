# TPF2MP invite links.
#
# A join code is the bearer secret for a relay room. It therefore travels in
# the link itself but never on a command line and never into a log: callers
# hand the decoded code to Write-Tpf2mpPrivateTextFile and pass that path on.
# The optional content fragment is only the first 16 hex characters of the
# host's active-content digest, which is a compatibility hint, not a secret.
#
# Functions are dot-source safe: strict mode is scoped to each function so the
# installer, the stable entrypoint, and the launcher keep their own settings.

function New-Tpf2mpInviteLink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$JoinCode,
        [string]$ContentDigest
    )
    Set-StrictMode -Version Latest
    $code = ([string]$JoinCode).Trim()
    if ($code -notmatch '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$') {
        throw 'The join code is not a complete TPF2MP1 code.'
    }
    $link = 'tpf2mp://join?code=' + $code
    if ($ContentDigest) {
        $digest = ([string]$ContentDigest).Trim().ToLowerInvariant()
        if ($digest -notmatch '^[0-9a-f]{8,64}$') {
            throw 'The active-content digest must be 8-64 hexadecimal characters.'
        }
        $link += '&content=' + $digest.Substring(0, [Math]::Min(16, $digest.Length))
    }
    return $link
}

function ConvertFrom-Tpf2mpInviteInput {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string]$Text)
    Set-StrictMode -Version Latest
    if ($null -eq $Text) { return $null }
    $value = ([string]$Text).Trim()
    if (-not $value -or $value.Length -gt 2048) { return $null }
    if ($value -match '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$') {
        return [pscustomobject]@{ JoinCode = $value; ContentDigest = $null; Kind = 'code' }
    }
    # Accept only tpf2mp://join and tpf2mp://join/ with a query. A fragment,
    # any other host, and any deeper path are rejected by this one pattern.
    $match = [regex]::Match(
        $value, '^(?i:tpf2mp)://(?<host>[^/?#]+)/?(?:\?(?<query>[^#]*))?$')
    if (-not $match.Success) { return $null }
    if ($match.Groups['host'].Value -notmatch '^(?i:join)$') { return $null }
    $query = $match.Groups['query'].Value
    if (-not $query) { return $null }
    $code = $null
    $digest = $null
    foreach ($pair in ($query -split '&')) {
        if (-not $pair) { continue }
        $separator = $pair.IndexOf('=')
        if ($separator -lt 1) { return $null }
        $name = $pair.Substring(0, $separator)
        if ($name -notmatch '^[A-Za-z0-9_.-]{1,32}$') { return $null }
        try { $raw = [Uri]::UnescapeDataString($pair.Substring($separator + 1)) }
        catch { return $null }
        $name = $name.ToLowerInvariant()
        if ($name -eq 'code') {
            if ($null -ne $code) { return $null }
            $code = $raw
        }
        elseif ($name -eq 'content') {
            if ($null -ne $digest) { return $null }
            $digest = $raw
        }
    }
    if ($null -eq $code -or $code -notmatch '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$') { return $null }
    if ($null -ne $digest) {
        if ($digest -notmatch '^[0-9a-fA-F]{8,64}$') { return $null }
        $digest = $digest.ToLowerInvariant()
    }
    return [pscustomobject]@{ JoinCode = $code; ContentDigest = $digest; Kind = 'link' }
}

function Assert-Tpf2mpInviteRegistryRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RegistryRoot)
    Set-StrictMode -Version Latest
    $value = ([string]$RegistryRoot).Trim().TrimEnd('\')
    if ($value -notmatch '^(?i:HKCU):\\[A-Za-z0-9 _.\-]+(\\[A-Za-z0-9 _.\-]+)*$' `
            -or $value.Contains('..')) {
        throw "TPF2MP registers invite links only under a per-user HKCU: path: $RegistryRoot"
    }
    return $value
}

function Register-Tpf2mpInviteProtocol {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [string]$RegistryRoot = 'HKCU:\Software\Classes',
        [string]$IconPath
    )
    Set-StrictMode -Version Latest
    $root = Assert-Tpf2mpInviteRegistryRoot $RegistryRoot
    $install = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($InstallRoot))
    if ($install -match '["\r\n]') { throw "The install root cannot be quoted safely: $install" }
    $entrypoint = Join-Path $install 'installed_entrypoint.ps1'
    if (-not (Test-Path -LiteralPath $entrypoint -PathType Leaf)) {
        throw "Invite links need the stable entrypoint: $entrypoint"
    }
    $powershell = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell -PathType Leaf)) {
        throw "Windows PowerShell was not found at: $powershell"
    }
    $command = '"' + $powershell + '" -NoProfile -ExecutionPolicy Bypass -File "' `
        + $entrypoint + '" -Action Join -Url "%1"'
    $key = Join-Path $root 'tpf2mp'
    $commandKey = Join-Path $key 'shell\open\command'
    foreach ($path in @($key, (Join-Path $key 'shell'), (Join-Path $key 'shell\open'), $commandKey)) {
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    }
    Set-ItemProperty -LiteralPath $key -Name '(Default)' -Value 'URL:TPF2MP invite' -Type String
    Set-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value '' -Type String
    Set-ItemProperty -LiteralPath $commandKey -Name '(Default)' -Value $command -Type String
    if ($IconPath) {
        $icon = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($IconPath))
        $iconKey = Join-Path $key 'DefaultIcon'
        if (-not (Test-Path -LiteralPath $iconKey)) { New-Item -Path $iconKey -Force | Out-Null }
        Set-ItemProperty -LiteralPath $iconKey -Name '(Default)' -Value $icon -Type String
    }
    return [pscustomobject]@{ KeyPath = $key; Command = $command }
}

function Unregister-Tpf2mpInviteProtocol {
    [CmdletBinding()]
    param([string]$RegistryRoot = 'HKCU:\Software\Classes')
    Set-StrictMode -Version Latest
    $root = Assert-Tpf2mpInviteRegistryRoot $RegistryRoot
    $key = Join-Path $root 'tpf2mp'
    if (-not (Test-Path -LiteralPath $key)) { return 'absent' }
    $default = ''
    $properties = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($properties -and $properties.PSObject.Properties['(default)']) {
        $default = [string]$properties.'(default)'
    }
    if ($default -and $default -cne 'URL:TPF2MP invite') {
        Write-Warning "Leaving an unrelated tpf2mp:// handler registered at: $key"
        return 'foreign'
    }
    Remove-Item -LiteralPath $key -Recurse -Force
    return 'removed'
}
