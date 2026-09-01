[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
$fixturePath = Join-Path $ProjectRoot 'tests\fixtures\live\second_station_transactions.json.gz.b64'
if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
    throw "Second-station live fixture is missing: $fixturePath"
}

$encoded = Get-Content -LiteralPath $fixturePath -Raw
$compressed = [Convert]::FromBase64String(($encoded -replace '\s', ''))
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $compressedSha = [BitConverter]::ToString($sha.ComputeHash($compressed)).Replace('-', '').ToLowerInvariant()
}
finally { $sha.Dispose() }
if ($compressedSha -ne '506daf240f9cecf8903eb058e13c8012952da375c54d007145f776f5af7c868c') {
    throw "Second-station fixture identity changed unexpectedly: $compressedSha"
}

$memory = [IO.MemoryStream]::new($compressed)
$gzip = [IO.Compression.GzipStream]::new($memory, [IO.Compression.CompressionMode]::Decompress)
$reader = [IO.StreamReader]::new($gzip, [Text.Encoding]::UTF8)
try { $document = $reader.ReadToEnd() | ConvertFrom-Json }
finally {
    $reader.Dispose()
    $gzip.Dispose()
    $memory.Dispose()
}

if ([int]$document.schemaVersion -ne 1 -or $document.sourceSession -ne 'mp-2b831d5eac67c488') {
    throw 'Second-station fixture provenance is not the pinned live failure.'
}
$transactions = @($document.transactions)
if ($transactions.Count -ne 2) { throw 'Second-station fixture must contain exactly two ordered transactions.' }
$expected = @(
    @{ Digest = '7fbee410'; Cost = 509204; Collateral = 0 },
    @{ Digest = 'bcc7bc62'; Cost = 902396; Collateral = 2 }
)
for ($index = 0; $index -lt 2; $index++) {
    $transaction = $transactions[$index]
    $construction = @($transaction.constructions)[0]
    $collateral = @($construction.collateral | Where-Object {
        $null -ne $_.PSObject.Properties['cid']
    })
    if ($transaction.digest -ne $expected[$index].Digest `
        -or $transaction.transactionId -ne "proposal:$($expected[$index].Digest)" `
        -or [int64]$transaction.cost -ne $expected[$index].Cost `
        -or @($transaction.nodes).Count -ne 74 `
        -or @($transaction.edges).Count -ne 72 `
        -or @($transaction.constructions).Count -ne 1 `
        -or @($construction.modules).Count -ne 41 `
        -or $collateral.Count -ne $expected[$index].Collateral) {
        throw "Second-station fixture transaction $($index + 1) no longer matches its live capture contract."
    }
}
$secondCollateral = @($transactions[1].constructions[0].collateral | ForEach-Object { $_.cid })
if (($secondCollateral -join ',') -ne 'construction:pre:8d3528af,construction:pre:8d4028a5') {
    throw 'Second-station fixture lost its two exact collateral construction identities.'
}

Write-Host 'PASS pinned live fixtures: exact sequential second-station capture'
