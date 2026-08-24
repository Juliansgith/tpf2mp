[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectRoot 'tools\launcher_worker_result.ps1')

$root = Join-Path $TemporaryRoot 'save-sync-worker\userdata\1\1066780\local\save'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$save = Join-Path $root 'tpf2mp_sync-result_0123456789.sav'
[IO.File]::WriteAllBytes($save, [byte[]](11, 22, 33, 44))
[IO.File]::WriteAllText($save + '.lua', 'return { synced = true }', [Text.UTF8Encoding]::new($false))
$bundle = 'a' * 64
$receiptPath = Join-Path $TemporaryRoot 'save-sync-worker\sync-receipt.json'
$receipt = [ordered]@{
    schemaVersion = 1
    session = 'sync-result-test'
    host = '127.0.0.1'
    port = 29743
    bundleId = $bundle
    savePath = $save
    metadataPath = $save + '.lua'
    previewPath = $null
    totalBytes = (Get-Item -LiteralPath $save).Length + (Get-Item -LiteralPath ($save + '.lua')).Length
    files = @(
        [ordered]@{
            role = 'save'; bytes = (Get-Item -LiteralPath $save).Length
            sha256 = (Get-FileHash -LiteralPath $save -Algorithm SHA256).Hash.ToLowerInvariant()
        },
        [ordered]@{
            role = 'metadata'; bytes = (Get-Item -LiteralPath ($save + '.lua')).Length
            sha256 = (Get-FileHash -LiteralPath ($save + '.lua') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    )
    reused = $false
    receivedAtUtc = [DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$stdout = Join-Path $TemporaryRoot 'save-sync-worker\sync.stdout.log'
$stderr = Join-Path $TemporaryRoot 'save-sync-worker\sync.stderr.log'
[IO.File]::WriteAllText($stdout,
    "save_sync_received=$save`nsave_sync_receipt=$receiptPath`nsave_sync_bundle=$bundle`n",
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($stderr, '', [Text.UTF8Encoding]::new($false))

$result = Get-Tpf2mpVerifiedSaveSyncResult -StdoutPath $stdout `
    -StderrPath $stderr -Session 'sync-result-test'
if (-not $result -or $result.savePath -ne $save -or $result.bundleId -ne $bundle) {
    throw 'Launcher did not accept a complete verified save-sync worker receipt.'
}
$missingRoleReceipt = [ordered]@{}
foreach ($entry in $receipt.GetEnumerator()) { $missingRoleReceipt[$entry.Key] = $entry.Value }
$missingRoleReceipt.files = @($receipt.files | Select-Object -First 1)
[IO.File]::WriteAllText($receiptPath, ($missingRoleReceipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
if (Get-Tpf2mpVerifiedSaveSyncResult -StdoutPath $stdout `
        -StderrPath $stderr -Session 'sync-result-test') {
    throw 'Launcher accepted a save-sync receipt without its metadata role.'
}
[IO.File]::WriteAllText($receiptPath, ($receipt | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
[IO.File]::AppendAllText($save + '.lua', '-- tampered')
if (Get-Tpf2mpVerifiedSaveSyncResult -StdoutPath $stdout `
        -StderrPath $stderr -Session 'sync-result-test') {
    throw 'Launcher accepted a save-sync receipt after its metadata changed.'
}

Write-Host 'PASS launcher save-sync result verification and tamper rejection'
