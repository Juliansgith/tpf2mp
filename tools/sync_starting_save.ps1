[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][string]$HostAddress,
    [ValidateRange(1, 65534)][int]$Port = 29742,
    [string]$BundleRoot,
    [string]$LocalModsPath,
    [string]$SaveDirectory,
    [ValidateRange(1, 300)][int]$ConnectTimeoutSeconds = 30,
    [ValidateRange(30, 3600)][int]$TransferTimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'native_load_common.ps1')

if (-not $BundleRoot) { $BundleRoot = Split-Path -Parent $PSScriptRoot }
$bundle = Resolve-Tpf2mpFullPath $BundleRoot
$safeSession = Assert-Tpf2mpSessionId $Session
if ($HostAddress -notmatch '^[A-Za-z0-9.:-]{1,253}$') {
    throw 'Host address contains unsupported characters.'
}
$saveRoot = Find-Tpf2mpSaveDirectory -SaveDirectory $SaveDirectory -LocalModsPath $LocalModsPath
$saveRootPrefix = $saveRoot.TrimEnd('\') + '\'
$syncPort = $Port + 1
$sessionRoot = Get-Tpf2mpSessionRoot $safeSession 'player2'
New-Item -ItemType Directory -Force -Path $sessionRoot | Out-Null
$receiptPath = Join-Path $sessionRoot 'received-starting-save.json'
$companion = Get-Tpf2mpCompanionCommand $bundle
$arguments = @($companion.Prefix) + @(
    'save-sync-receive', $HostAddress,
    '--port', $syncPort,
    '--session', $safeSession,
    '--peer', 'player2',
    '--output-dir', $saveRoot,
    '--receipt', $receiptPath,
    '--connect-timeout', $ConnectTimeoutSeconds,
    '--transfer-timeout', $TransferTimeoutSeconds
)

Write-Host "Waiting for $safeSession host save at ${HostAddress}:$syncPort..."
& $companion.FilePath @arguments
if ($LASTEXITCODE -ne 0) {
    throw "Automatic starting-save sync failed with exit code $LASTEXITCODE. Confirm the host has already clicked Host + Launch and that TCP $syncPort is allowed."
}
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw 'Save-sync companion completed without a receipt.'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ([int]$receipt.schemaVersion -ne 1 -or [string]$receipt.session -ne $safeSession `
        -or [int]$receipt.port -ne $syncPort `
        -or [string]$receipt.bundleId -notmatch '^[0-9a-f]{64}$') {
    throw 'Save-sync receipt identity is invalid.'
}
$receivedSave = Resolve-Tpf2mpFullPath ([string]$receipt.savePath)
if (-not $receivedSave.StartsWith($saveRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing a synchronized save outside the Transport Fever 2 save directory: $receivedSave"
}
if (-not [string]::Equals(
        (Resolve-Tpf2mpFullPath ([string]$receipt.metadataPath)),
        $receivedSave + '.lua',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Save-sync receipt metadata path does not accompany its save.'
}
$triplet = Get-Tpf2mpSaveTriplet $receivedSave
$receiptFiles = @($receipt.files)
$receivedRoles = @($receiptFiles | ForEach-Object { [string]$_.role })
$requiredRoles = if ($receipt.previewPath) { @('save', 'metadata', 'preview') } `
    else { @('save', 'metadata') }
if ($receivedRoles.Count -ne $requiredRoles.Count `
        -or (($receivedRoles -join ',') -cne ($requiredRoles -join ','))) {
    throw 'Save-sync receipt does not contain the exact native save role set.'
}
$expected = @{}
foreach ($file in $receiptFiles) { $expected[[string]$file.role] = $file }
foreach ($pair in @(
        [pscustomobject]@{ Role = 'save'; Path = $triplet.save },
        [pscustomobject]@{ Role = 'metadata'; Path = $triplet.metadata }
    )) {
    $entry = $expected[$pair.Role]
    if (-not $entry -or [int64]$entry.bytes -ne (Get-Item -LiteralPath $pair.Path).Length `
            -or [string]$entry.sha256 -ne (Get-FileHash -LiteralPath $pair.Path -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw "Synchronized $($pair.Role) no longer matches its verified receipt."
    }
}
if ($expected.ContainsKey('preview')) {
    if (-not $triplet.image `
            -or [string]$expected['preview'].sha256 -ne (Get-FileHash -LiteralPath $triplet.image -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Synchronized preview no longer matches its verified receipt.'
    }
}

Write-Host "Automatic save sync verified $($receipt.totalBytes) bytes."
Write-Host "save_sync_received=$receivedSave"
Write-Host "save_sync_receipt=$receiptPath"
Write-Host "save_sync_bundle=$($receipt.bundleId)"
