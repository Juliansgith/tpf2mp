[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$ArchivePath,
    [string]$Repository = 'Juliansgith/tpf2mp',
    [string]$ReleaseNotesPath,
    [switch]$ConfirmPublish,
    [switch]$NoCredentialPrompt
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_common.ps1')
. (Join-Path $PSScriptRoot 'update_common.ps1')
. (Join-Path $PSScriptRoot 'github_release_common.ps1')

if (-not $ConfirmPublish) {
    throw 'Publishing changes GitHub. Re-run with -ConfirmPublish after reviewing the archive and release notes.'
}
$projectRoot = Resolve-Tpf2mpFullPath (Join-Path $PSScriptRoot '..')
$semanticVersion = ConvertTo-Tpf2mpSemanticVersion $Version
[void](Assert-Tpf2mpGitHubRepository $Repository)
if (-not $ArchivePath) { $ArchivePath = Join-Path $projectRoot "dist\TPF2MP-$($semanticVersion.text).zip" }
$archive = Resolve-Tpf2mpFullPath $ArchivePath
$sidecar = $archive + '.sha256'
if (-not (Test-Path -LiteralPath $archive -PathType Leaf) `
        -or -not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
    throw "Release archive or SHA-256 sidecar is missing: $archive"
}
$expectedHash = Read-Tpf2mpSha256File $sidecar ([IO.Path]::GetFileName($archive))
$actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualHash -ne $expectedHash) { throw 'Release archive does not match its SHA-256 sidecar.' }

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if (-not $git) { $git = Get-Command git -ErrorAction Stop }
$status = @(& $git.Source -C $projectRoot status --porcelain --untracked-files=normal)
if ($LASTEXITCODE -ne 0 -or $status.Count -gt 0) { throw 'Publish requires a clean Git worktree.' }
$head = ([string](@(& $git.Source -C $projectRoot rev-parse HEAD) -join '')).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $head -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve Git HEAD.' }

$tempBase = Resolve-Tpf2mpFullPath ([IO.Path]::GetTempPath())
$temporaryRoot = Resolve-Tpf2mpFullPath (Join-Path $tempBase ('tpf2mp-publish-' + [guid]::NewGuid().ToString('N')))
$tempPrefix = $tempBase.TrimEnd('\') + '\'
if (-not $temporaryRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Refusing publication temporary path outside the system temporary directory.'
}
$publishedRelease = $null
try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $bundle = Expand-Tpf2mpReleaseArchive $archive (Join-Path $temporaryRoot 'extracted')
    $manifest = Test-Tpf2mpReleaseManifest $bundle
    if ([string]$manifest.version -cne $semanticVersion.text) {
        throw "Archive version $($manifest.version) does not match requested version $($semanticVersion.text)."
    }
    if ([int]$manifest.format -lt 2 -or [bool]$manifest.source.dirty) {
        throw 'Only a clean format-2 release may be published.'
    }
    if ([string]$manifest.source.commit -ne $head) {
        throw "Archive source commit $($manifest.source.commit) does not match Git HEAD $head."
    }
    if ([string]$manifest.update.repository -ne $Repository) {
        throw "Archive update repository $($manifest.update.repository) does not match $Repository."
    }

    $notes = "TPF2MP $($semanticVersion.text)"
    if ($ReleaseNotesPath) {
        $resolvedNotes = Resolve-Tpf2mpFullPath $ReleaseNotesPath
        if (-not (Test-Path -LiteralPath $resolvedNotes -PathType Leaf)) { throw "Release notes are missing: $resolvedNotes" }
        $notes = Get-Content -LiteralPath $resolvedNotes -Raw
    }
    $token = Get-Tpf2mpGitHubToken -NoCredentialPrompt:$NoCredentialPrompt
    if (-not $token) {
        throw 'Publishing requires the user to sign in with GitHub CLI/Git Credential Manager or set TPF2MP_GITHUB_TOKEN.'
    }
    $headers = New-Tpf2mpGitHubHeaders $token
    $tag = 'v' + $semanticVersion.text
    $createBody = [ordered]@{
        tag_name = $tag
        target_commitish = $head
        name = "TPF2MP $($semanticVersion.text)"
        body = $notes
        draft = $true
        prerelease = @($semanticVersion.prerelease).Count -gt 0
        generate_release_notes = $false
    } | ConvertTo-Json -Depth 4
    $publishedRelease = Invoke-RestMethod -Method Post `
        -Uri "https://api.github.com/repos/$Repository/releases" -Headers $headers `
        -ContentType 'application/json' -Body $createBody
    $uploadBase = ([string]$publishedRelease.upload_url) -replace '\{.*$', ''
    if ($uploadBase -notmatch '^https://uploads\.github\.com/') { throw 'GitHub returned an unsafe release upload URL.' }
    foreach ($asset in @(
            [pscustomobject]@{ path = $archive; contentType = 'application/zip' },
            [pscustomobject]@{ path = $sidecar; contentType = 'text/plain' })) {
        $assetName = [IO.Path]::GetFileName([string]$asset.path)
        $uploadUri = $uploadBase + '?name=' + [Uri]::EscapeDataString($assetName)
        [void](Invoke-RestMethod -Method Post -Uri $uploadUri `
            -Headers (New-Tpf2mpGitHubHeaders $token 'application/vnd.github+json') `
            -ContentType ([string]$asset.contentType) -InFile ([string]$asset.path))
    }
    $publishedRelease = Invoke-RestMethod -Method Patch `
        -Uri "https://api.github.com/repos/$Repository/releases/$($publishedRelease.id)" `
        -Headers $headers -ContentType 'application/json' -Body '{"draft":false}'
    Write-Host "Published $tag from $head"
    Write-Host "Release: $($publishedRelease.html_url)"
}
catch {
    if ($publishedRelease -and $publishedRelease.html_url) {
        Write-Warning "A draft release may remain for repair or deletion: $($publishedRelease.html_url)"
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
