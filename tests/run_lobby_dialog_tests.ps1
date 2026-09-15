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
    $rgba = New-Object byte[] (8+4*4*4)
    [BitConverter]::GetBytes([uint32]4).CopyTo($rgba,0)
    [BitConverter]::GetBytes([uint32]4).CopyTo($rgba,4)
    for ($i=8; $i -lt $rgba.Length; $i+=4) { $rgba[$i]=80; $rgba[$i+1]=120; $rgba[$i+2]=60; $rgba[$i+3]=255 }
    [IO.File]::WriteAllBytes((Join-Path $testDirectory 'preview-native.rgba'),$rgba)
    [IO.File]::WriteAllText((Join-Path $testDirectory 'preview-markers.json'),'[{"kind":"town","x":0.3,"y":0.4,"name":"Test"},{"kind":"industry","x":0.7,"y":0.8,"name":""}]')
    $bitmapPath=Join-Path $testDirectory 'map.bgr'
    & (Join-Path $BundleRoot 'tools/export_lobby_map_preview.ps1') -EvidenceDirectory $testDirectory -OutputPath $bitmapPath
    if ((Get-Item -LiteralPath $bitmapPath).Length -ne 442368) { throw 'Native map export extent mismatch.' }
    Write-Output 'Native map pixel/marker export passed.'
} finally {
    if (Test-Path -LiteralPath $credentialPath) { Remove-Item -LiteralPath $credentialPath }
    foreach ($name in @('preview-native.rgba','preview-markers.json','map.bgr')) {
        $path=Join-Path $testDirectory $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    Remove-Item -LiteralPath $testDirectory
}
