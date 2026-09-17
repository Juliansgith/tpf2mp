[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Launch', 'Update', 'Verify', 'Uninstall', 'Join')]
    [string]$Action,
    [string]$InstallRoot,
    [string]$Url
)

$ErrorActionPreference = 'Stop'
if (-not $InstallRoot) { $InstallRoot = $PSScriptRoot }
$install = [IO.Path]::GetFullPath($InstallRoot)
$currentPath = Join-Path $install 'current.json'
if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) {
    throw "TPF2MP has no current installation pointer: $currentPath"
}
$current = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
if ([int]$current.schemaVersion -lt 2 -or -not [string]$current.version) {
    throw 'TPF2MP current installation pointer is invalid.'
}
$bundle = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$current.bundleRoot))
$versionsRoot = [IO.Path]::GetFullPath((Join-Path $install 'versions')).TrimEnd('\') + '\'
if (-not $bundle.StartsWith($versionsRoot, [StringComparison]::OrdinalIgnoreCase) `
        -or -not (Test-Path -LiteralPath (Join-Path $bundle 'release-manifest.json') -PathType Leaf)) {
    throw "TPF2MP current bundle is missing or outside the versions root: $bundle"
}

# An invite link carries the bearer join code. Decode it in a child scope, put
# the code straight into a current-user-only file, and hand the launcher that
# path: the URL never reaches a command line, a window title, or a log.
function Resolve-Tpf2mpInviteLaunchArguments {
    param(
        [Parameter(Mandatory = $true)][string]$BundleRoot,
        [AllowEmptyString()][AllowNull()][string]$InviteUrl
    )
    . (Join-Path $BundleRoot 'tools\launcher_invite_link.ps1')
    . (Join-Path $BundleRoot 'tools\network_common.ps1')
    $invite = ConvertFrom-Tpf2mpInviteInput -Text $InviteUrl
    if (-not $invite) { throw 'That is not a valid TPF2MP invite link or join code.' }
    $draft = Join-Path (Get-Tpf2mpSupportRoot) (
        'relay-drafts\join-input-' + [guid]::NewGuid().ToString('N') + '.txt')
    $file = Write-Tpf2mpPrivateTextFile $draft $invite.JoinCode
    # A hashtable splat: Windows PowerShell 5.1 binds an array splat by
    # position, which would silently misroute these paths.
    $arguments = @{ BundleRoot = $BundleRoot; JoinInputFile = $file }
    if ($invite.ContentDigest) { $arguments['JoinContentDigest'] = $invite.ContentDigest }
    return $arguments
}

$scriptPath = switch ($Action) {
    'Launch' { Join-Path $bundle 'tools\multiplayer_launcher.ps1' }
    'Join' { Join-Path $bundle 'tools\multiplayer_launcher.ps1' }
    'Update' { Join-Path $bundle 'tools\update_release.ps1' }
    'Verify' { Join-Path $bundle 'tools\verify_install.ps1' }
    'Uninstall' { Join-Path $bundle 'tools\uninstall.ps1' }
}
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Installed $Action tool is missing: $scriptPath"
}
switch ($Action) {
    'Launch' { & $scriptPath -BundleRoot $bundle }
    'Join' {
        $joinArguments = Resolve-Tpf2mpInviteLaunchArguments -BundleRoot $bundle -InviteUrl $Url
        & $scriptPath @joinArguments
    }
    'Update' { & $scriptPath -BundleRoot $bundle -InstallRoot $install }
    'Verify' { & $scriptPath -BundleRoot $bundle }
    'Uninstall' { & $scriptPath -InstallRoot $install }
}
if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
