Set-StrictMode -Version Latest

function ConvertTo-Tpf2mpSemanticVersion {
    param([Parameter(Mandatory = $true)][string]$Version)

    $normalized = $Version.Trim()
    if ($normalized.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    $pattern = '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)' +
        '(?:-(?<pre>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?' +
        '(?:\+(?<build>[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$'
    $match = [regex]::Match($normalized, $pattern)
    if (-not $match.Success) { throw "Invalid TPF2MP semantic version: $Version" }
    return [pscustomobject][ordered]@{
        text = $normalized
        major = [uint64]::Parse($match.Groups['major'].Value)
        minor = [uint64]::Parse($match.Groups['minor'].Value)
        patch = [uint64]::Parse($match.Groups['patch'].Value)
        prerelease = $(if ($match.Groups['pre'].Success) {
                @($match.Groups['pre'].Value -split '\.')
            } else { @() })
        build = $(if ($match.Groups['build'].Success) { $match.Groups['build'].Value } else { $null })
    }
}

function Compare-Tpf2mpSemanticVersion {
    param(
        [Parameter(Mandatory = $true)]$Left,
        [Parameter(Mandatory = $true)]$Right
    )
    if ($Left -is [string]) { $Left = ConvertTo-Tpf2mpSemanticVersion $Left }
    if ($Right -is [string]) { $Right = ConvertTo-Tpf2mpSemanticVersion $Right }
    foreach ($field in @('major', 'minor', 'patch')) {
        if ([uint64]$Left.$field -lt [uint64]$Right.$field) { return -1 }
        if ([uint64]$Left.$field -gt [uint64]$Right.$field) { return 1 }
    }
    $leftPre = @($Left.prerelease)
    $rightPre = @($Right.prerelease)
    if ($leftPre.Count -eq 0 -and $rightPre.Count -eq 0) { return 0 }
    if ($leftPre.Count -eq 0) { return 1 }
    if ($rightPre.Count -eq 0) { return -1 }
    $length = [Math]::Max($leftPre.Count, $rightPre.Count)
    for ($index = 0; $index -lt $length; $index++) {
        if ($index -ge $leftPre.Count) { return -1 }
        if ($index -ge $rightPre.Count) { return 1 }
        $leftPart = [string]$leftPre[$index]
        $rightPart = [string]$rightPre[$index]
        $leftNumber = 0L
        $rightNumber = 0L
        $leftNumeric = [long]::TryParse($leftPart, [ref]$leftNumber)
        $rightNumeric = [long]::TryParse($rightPart, [ref]$rightNumber)
        if ($leftNumeric -and $rightNumeric) {
            if ($leftNumber -lt $rightNumber) { return -1 }
            if ($leftNumber -gt $rightNumber) { return 1 }
        }
        elseif ($leftNumeric -ne $rightNumeric) {
            if ($leftNumeric) { return -1 }
            return 1
        }
        else {
            $comparison = [StringComparer]::Ordinal.Compare($leftPart, $rightPart)
            if ($comparison -lt 0) { return -1 }
            if ($comparison -gt 0) { return 1 }
        }
    }
    return 0
}

function Select-Tpf2mpGitHubRelease {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Releases,
        [Parameter(Mandatory = $true)][string]$CurrentVersion,
        [ValidateSet('alpha', 'stable')][string]$Channel = 'alpha'
    )
    $current = ConvertTo-Tpf2mpSemanticVersion $CurrentVersion
    $best = $null
    $bestVersion = $null
    foreach ($release in @($Releases)) {
        if ($null -eq $release -or [bool]$release.draft) { continue }
        if ($Channel -eq 'stable' -and [bool]$release.prerelease) { continue }
        $candidate = $null
        try { $candidate = ConvertTo-Tpf2mpSemanticVersion ([string]$release.tag_name) }
        catch { continue }
        if ((Compare-Tpf2mpSemanticVersion $candidate $current) -le 0) { continue }
        if ($null -eq $bestVersion -or (Compare-Tpf2mpSemanticVersion $candidate $bestVersion) -gt 0) {
            $best = $release
            $bestVersion = $candidate
        }
    }
    if ($null -eq $best) { return $null }
    $archiveName = "TPF2MP-$($bestVersion.text).zip"
    $archive = @($best.assets | Where-Object { [string]$_.name -ceq $archiveName })
    if ($archive.Count -ne 1) {
        throw "GitHub release $($best.tag_name) must contain exactly one $archiveName asset."
    }
    $checksumName = $archiveName + '.sha256'
    $checksum = @($best.assets | Where-Object { [string]$_.name -ceq $checksumName })
    $digestProperty = $archive[0].PSObject.Properties['digest']
    $digest = if ($null -ne $digestProperty) { [string]$digestProperty.Value } else { $null }
    if ($checksum.Count -ne 1 -and $digest -notmatch '^sha256:[0-9a-fA-F]{64}$') {
        throw "GitHub release $($best.tag_name) has neither $checksumName nor a SHA-256 asset digest."
    }
    return [pscustomobject][ordered]@{
        release = $best
        version = $bestVersion.text
        archiveName = $archiveName
        archiveAsset = $archive[0]
        checksumAsset = $(if ($checksum.Count -eq 1) { $checksum[0] } else { $null })
        assetDigest = $(if ($digest -match '^sha256:([0-9a-fA-F]{64})$') {
                $matches[1].ToLowerInvariant()
            } else { $null })
    }
}

function Read-Tpf2mpSha256File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedFileName
    )
    $line = (Get-Content -LiteralPath $Path -Raw).Trim()
    $match = [regex]::Match($line, '^([0-9a-fA-F]{64})\s+\*?(.+)$')
    if (-not $match.Success -or $match.Groups[2].Value.Trim() -cne $ExpectedFileName) {
        throw "Invalid SHA-256 sidecar for $ExpectedFileName."
    }
    return $match.Groups[1].Value.ToLowerInvariant()
}

function Expand-Tpf2mpReleaseArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $manifestEntry = $null
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $totalSize = 0L
    try {
        if ($archive.Entries.Count -gt 5000) { throw 'Release archive contains too many entries.' }
        foreach ($entry in $archive.Entries) {
            $relative = ([string]$entry.FullName).Replace('\', '/')
            $segments = @($relative -split '/')
            if (-not $relative -or $relative.StartsWith('/') -or $relative.Contains(':') `
                    -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
                throw "Unsafe release archive path: $relative"
            }
            if (-not $seen.Add($relative)) { throw "Duplicate release archive path: $relative" }
            $unixMode = ([int64]$entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixMode -eq 0xA000) { throw "Release archive contains a symbolic link: $relative" }
            $totalSize += [long]$entry.Length
            if ($totalSize -gt 536870912) { throw 'Release archive expands beyond the 512 MiB safety limit.' }
            if ($relative -eq 'release-manifest.json' -or $relative.EndsWith('/release-manifest.json')) {
                if ($null -ne $manifestEntry) { throw 'Release archive contains multiple manifests.' }
                $manifestEntry = $entry
            }
        }
        if ($null -eq $manifestEntry) { throw 'Release archive contains no release manifest.' }
    }
    finally { $archive.Dispose() }

    if (Test-Path -LiteralPath $Destination) { throw "Archive destination already exists: $Destination" }
    New-Item -ItemType Directory -Path $Destination | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
    $manifestPath = Join-Path $Destination (([string]$manifestEntry.FullName).Replace('/', '\'))
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'Extracted release manifest is missing.'
    }
    return (Split-Path -Parent $manifestPath)
}
