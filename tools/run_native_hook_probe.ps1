[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [int]$StartupDelaySeconds = 10,
    [int]$WorldReadyTimeoutSeconds = 180,
    [int]$ProbeTimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'build_native_hook.ps1')
    if ($LASTEXITCODE -ne 0) { throw "Native hook build failed with exit code $LASTEXITCODE" }
}

& (Join-Path $PSScriptRoot 'run_supported_api_build_probe.ps1') `
    -CapabilityOnly `
    -NativeHook `
    -SkipNativeBuild `
    -StartupDelaySeconds $StartupDelaySeconds `
    -WorldReadyTimeoutSeconds $WorldReadyTimeoutSeconds `
    -ProbeTimeoutSeconds $ProbeTimeoutSeconds

if ($LASTEXITCODE -ne 0) { throw "Native hook live probe failed with exit code $LASTEXITCODE" }

Write-Host 'Native Build 35924 hook probe passed. Use tools\start_native_hook_test.ps1 for manual testing.'
