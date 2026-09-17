[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
$fixture = Join-Path $TemporaryRoot 'cmd wrapper fixture'
$tools = Join-Path $fixture 'tools'
New-Item -ItemType Directory -Force -Path $tools | Out-Null
$probePath = Join-Path $fixture 'probe.json'
$previousNoPause = $env:TPF2MP_NO_PAUSE
$previousProbe = $env:TPF2MP_CMD_PROBE
$env:TPF2MP_NO_PAUSE = '1'
$env:TPF2MP_CMD_PROBE = $probePath
try {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tools\release_install.cmd') `
        -Destination (Join-Path $fixture 'INSTALL_TPF2MP.cmd')
    [IO.File]::WriteAllText((Join-Path $tools 'install_release.ps1'), @'
param([string]$BundleRoot)
[IO.File]::WriteAllText($env:TPF2MP_CMD_PROBE,
    ([pscustomobject]@{ action = 'Install'; root = $BundleRoot } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    & (Join-Path $fixture 'INSTALL_TPF2MP.cmd')
    if ($LASTEXITCODE -ne 0) { throw "Packaged install CMD probe failed with exit code $LASTEXITCODE." }
    $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
    if ($probe.action -ne 'Install' `
            -or [IO.Path]::GetFullPath([string]$probe.root) -ne [IO.Path]::GetFullPath($fixture)) {
        throw "Packaged install CMD corrupted its trailing-backslash bundle root: $($probe.root)"
    }

    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tools\installed_command.cmd') `
        -Destination (Join-Path $fixture 'VERIFY_TPF2MP.cmd') -Force
    [IO.File]::WriteAllText((Join-Path $fixture 'installed_entrypoint.ps1'), @'
param([string]$Action, [string]$InstallRoot)
[IO.File]::WriteAllText($env:TPF2MP_CMD_PROBE,
    ([pscustomobject]@{ action = $Action; root = $InstallRoot } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    & (Join-Path $fixture 'VERIFY_TPF2MP.cmd')
    if ($LASTEXITCODE -ne 0) { throw "Installed Verify CMD probe failed with exit code $LASTEXITCODE." }
    $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
    if ($probe.action -ne 'Verify' `
            -or [IO.Path]::GetFullPath([string]$probe.root) -ne [IO.Path]::GetFullPath($fixture)) {
        throw "Installed command corrupted its trailing-backslash install root: $($probe.root)"
    }

    # The same stable command also opens a tpf2mp:// invite link: the shell
    # hands the link over as the first argument.
    [IO.File]::WriteAllText((Join-Path $fixture 'installed_entrypoint.ps1'), @'
param([string]$Action, [string]$InstallRoot, [string]$Url)
[IO.File]::WriteAllText($env:TPF2MP_CMD_PROBE,
    ([pscustomobject]@{ action = $Action; root = $InstallRoot; url = $Url } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    Copy-Item -LiteralPath (Join-Path $ProjectRoot 'tools\installed_command.cmd') `
        -Destination (Join-Path $fixture 'LAUNCH_TPF2MP.cmd') -Force
    $inviteUrl = 'tpf2mp://join?code=TPF2MP1.' + ('d' * 44) + '&content=0123456789abcdef'
    # A protocol handler hands the link over already quoted, so drive the
    # stable command the same way instead of through PowerShell's own quoting.
    $inviteDriver = Join-Path $fixture 'drive-invite.cmd'
    [IO.File]::WriteAllText($inviteDriver,
        "@echo off`r`ncall `"%~dp0LAUNCH_TPF2MP.cmd`" `"$inviteUrl`"`r`nexit /b %ERRORLEVEL%`r`n",
        [Text.UTF8Encoding]::new($false))
    & $inviteDriver
    if ($LASTEXITCODE -ne 0) { throw "Installed Join CMD probe failed with exit code $LASTEXITCODE." }
    $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
    if ($probe.action -ne 'Join' -or [string]$probe.url -cne $inviteUrl `
            -or [IO.Path]::GetFullPath([string]$probe.root) -ne [IO.Path]::GetFullPath($fixture)) {
        throw "Installed command did not pass the invite link through intact: $($probe.url)"
    }
    & (Join-Path $fixture 'LAUNCH_TPF2MP.cmd')
    if ($LASTEXITCODE -ne 0) { throw "Installed Launch CMD probe failed with exit code $LASTEXITCODE." }
    $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
    if ($probe.action -ne 'Launch' -or [string]$probe.url) {
        throw 'Installed Launch command no longer starts the launcher without an invite.'
    }

    # The real entrypoint must decode the link itself and hand the launcher a
    # current-user-only file instead of the bearer join code.
    $joinRoot = Join-Path $TemporaryRoot 'invite entrypoint'
    $joinInstall = Join-Path $joinRoot 'support'
    $joinBundle = Join-Path $joinInstall 'versions\9.9.9-alpha'
    $joinLocalAppData = Join-Path $joinRoot 'local-app-data'
    New-Item -ItemType Directory -Force -Path (Join-Path $joinBundle 'tools'), $joinLocalAppData | Out-Null
    [IO.File]::WriteAllText((Join-Path $joinBundle 'release-manifest.json'),
        '{"version":"9.9.9-alpha"}', [Text.UTF8Encoding]::new($false))
    foreach ($name in @('installed_entrypoint.ps1', 'launcher_invite_link.ps1',
            'network_common.ps1', 'release_common.ps1')) {
        Copy-Item -LiteralPath (Join-Path $ProjectRoot "tools\$name") `
            -Destination (Join-Path $joinBundle "tools\$name") -Force
    }
    Copy-Item -LiteralPath (Join-Path $joinBundle 'tools\installed_entrypoint.ps1') `
        -Destination (Join-Path $joinInstall 'installed_entrypoint.ps1') -Force
    [IO.File]::WriteAllText((Join-Path $joinBundle 'tools\multiplayer_launcher.ps1'), @'
param([string]$BundleRoot, [string]$JoinInputFile, [string]$JoinContentDigest)
[IO.File]::WriteAllText($env:TPF2MP_CMD_PROBE,
    ([pscustomobject]@{
        bundleRoot = $BundleRoot
        joinInputFile = $JoinInputFile
        joinContentDigest = $JoinContentDigest
        joinInput = $(if ($JoinInputFile) { [IO.File]::ReadAllText($JoinInputFile) } else { '' })
    } | ConvertTo-Json),
    [Text.UTF8Encoding]::new($false))
'@, [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{
        schemaVersion = 2; version = '9.9.9-alpha'; bundleRoot = $joinBundle
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $joinInstall 'current.json') -Encoding UTF8
    $joinCode = 'TPF2MP1.' + ('e' * 44)
    $previousLocalAppData = $env:LOCALAPPDATA
    $env:LOCALAPPDATA = $joinLocalAppData
    try {
        & (Join-Path $joinInstall 'installed_entrypoint.ps1') -Action Join -InstallRoot $joinInstall `
            -Url "tpf2mp://join?code=$joinCode&content=0123456789abcdef"
        $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json
        if ([string]$probe.joinContentDigest -cne '0123456789abcdef' `
                -or [string]$probe.joinInput -cne $joinCode) {
            throw 'The Join action did not hand the launcher the decoded invite.'
        }
        if ([string]$probe.joinInputFile -notmatch 'relay-drafts\\join-input-[0-9a-f]{32}\.txt$' `
                -or -not ([string]$probe.joinInputFile).StartsWith(
                    $joinLocalAppData, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The Join action wrote its join input outside the private draft root: $($probe.joinInputFile)"
        }
        $access = @((Get-Acl -LiteralPath ([string]$probe.joinInputFile)).Access)
        if ($access.Count -ne 1) {
            throw "The join input file is not restricted to the current user: $($access.Count) rules."
        }
        $invalidRejected = $false
        try {
            & (Join-Path $joinInstall 'installed_entrypoint.ps1') -Action Join `
                -InstallRoot $joinInstall -Url 'tpf2mp://join?code=nope'
        }
        catch {
            $invalidRejected = $true
            if ($_.Exception.Message.Contains('nope')) {
                throw 'The Join action echoed an invalid invite URL into its error.'
            }
        }
        if (-not $invalidRejected) { throw 'The Join action accepted an invalid invite URL.' }
    }
    finally { $env:LOCALAPPDATA = $previousLocalAppData }
}
finally {
    $env:TPF2MP_NO_PAUSE = $previousNoPause
    $env:TPF2MP_CMD_PROBE = $previousProbe
}

Write-Host 'PASS packaged and stable CMD entrypoints preserve quoted roots with spaces and trailing separators, and route invite links to the Join action'
