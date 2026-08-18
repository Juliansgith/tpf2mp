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
}
finally {
    $env:TPF2MP_NO_PAUSE = $previousNoPause
    $env:TPF2MP_CMD_PROBE = $previousProbe
}

Write-Host 'PASS packaged and stable CMD entrypoints preserve quoted roots with spaces and trailing separators'
