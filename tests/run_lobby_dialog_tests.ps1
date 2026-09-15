[CmdletBinding()]
param([string]$BundleRoot)
$ErrorActionPreference = 'Stop'
if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ('tpf2mp-lobby-dialog-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $testDirectory)
$credentialPath = Join-Path $testDirectory 'fake-credentials.json'
try {
    foreach ($role in @('host', 'join')) {
        [IO.File]::WriteAllText($credentialPath, (@{ schemaVersion = 1; role = $role; sessionId = 'mp-0123456789abcdef' } | ConvertTo-Json))
        & (Join-Path $BundleRoot 'tools/multiplayer_lobby.ps1') -BundleRoot $BundleRoot `
            -CredentialsPath $credentialPath -GameExecutable (Join-Path $testDirectory 'not-launched.exe') `
            -ModDirectory (Join-Path $testDirectory 'not-installed') -SmokeTest
    }
} finally {
    if (Test-Path -LiteralPath $credentialPath) { Remove-Item -LiteralPath $credentialPath }
    Remove-Item -LiteralPath $testDirectory
}
