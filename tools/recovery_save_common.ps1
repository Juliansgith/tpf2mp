Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')

function Get-Tpf2mpAdler32Hex {
    param([Parameter(Mandatory = $true)][string]$Text)

    [uint64]$a = 1
    [uint64]$b = 0
    foreach ($byte in [Text.Encoding]::UTF8.GetBytes($Text)) {
        $a = ($a + $byte) % 65521
        $b = ($b + $a) % 65521
    }
    [uint64]$value = $b * 65536 + $a
    return ([uint32]$value).ToString('x8')
}

function Get-Tpf2mpRecoverySaveBaseName {
    param(
        [Parameter(Mandatory = $true)][string]$Session,
        [Parameter(Mandatory = $true)][ValidateSet('player1', 'player2')][string]$Peer,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$BoundarySeq
    )

    $safeSession = Assert-Tpf2mpSessionId $Session
    $peerToken = if ($Peer -eq 'player1') { 'p1' } else { 'p2' }
    $name = 'tpf2mp_r_{0}_{1}_b{2}' -f `
        (Get-Tpf2mpAdler32Hex $safeSession), $peerToken, $BoundarySeq
    if ($name.Length -gt 50) {
        throw 'Automatic recovery save name exceeds Build 35924''s 50-character limit.'
    }
    return $name
}

function Get-Tpf2mpReceiptBoundSave {
    param(
        [Parameter(Mandatory = $true)][string]$SaveDirectory,
        [Parameter(Mandatory = $true)][string]$ExpectedSavePrefix,
        [Parameter(Mandatory = $true)][string]$AutomaticSaveName,
        [Parameter(Mandatory = $true)]$Receipt,
        [string]$PreferredSavePath
    )

    $expectedSave = ([string]$Receipt.saveSha256).ToLowerInvariant()
    $expectedMetadata = ([string]$Receipt.metadataSha256).ToLowerInvariant()
    if ($expectedSave -notmatch '^[0-9a-f]{64}$' `
        -or $expectedMetadata -notmatch '^[0-9a-f]{64}$') {
        throw 'Accepted recovery receipt omitted its load-bearing SHA-256 hashes.'
    }

    $eligible = @(Get-ChildItem -LiteralPath $SaveDirectory -File -Filter '*.sav' `
        -ErrorAction SilentlyContinue | Where-Object {
            $_.BaseName -ieq $AutomaticSaveName -or $_.BaseName.StartsWith(
                $ExpectedSavePrefix, [StringComparison]::OrdinalIgnoreCase)
        })
    if ($PreferredSavePath) {
        $preferred = [IO.Path]::GetFullPath($PreferredSavePath)
        $eligible = @($eligible | Sort-Object @{
            Expression = { if ($_.FullName -ieq $preferred) { 0 } else { 1 } }
        }, @{ Expression = 'LastWriteTimeUtc'; Descending = $true })
    }
    else { $eligible = @($eligible | Sort-Object LastWriteTimeUtc -Descending) }

    foreach ($save in $eligible) {
        $metadataPath = $save.FullName + '.lua'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
        $saveHash = (Get-FileHash -LiteralPath $save.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($saveHash -ne $expectedSave) { continue }
        $metadataHash = (Get-FileHash -LiteralPath $metadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($metadataHash -eq $expectedMetadata) { return $save }
    }
    throw 'The receipt-bound native save bytes are no longer present; a later re-save cannot replace an attested file.'
}
