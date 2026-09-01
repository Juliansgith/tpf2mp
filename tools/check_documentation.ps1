[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($ProjectRoot)
$errors = [Collections.Generic.List[string]]::new()

function Add-DocumentationError {
    param([string]$Message)
    $script:errors.Add($Message)
}

function Read-RequiredText {
    param([string]$RelativePath)
    $path = Join-Path $root $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-DocumentationError "missing required file: $RelativePath"
        return ''
    }
    return [IO.File]::ReadAllText($path)
}

# Keep the repository entry surface intentional. Agent scratchpads are local
# state, while maintained project material belongs under docs/ or investigation/.
$rootMarkdown = @(Get-ChildItem -LiteralPath $root -File -Filter '*.md' |
    Where-Object { $_.Name -ne 'README.md' })
foreach ($file in $rootMarkdown) {
    Add-DocumentationError "root Markdown must move under docs/: $($file.Name)"
}
$gitignore = Read-RequiredText '.gitignore'
foreach ($pattern in @('/.codex/', '/.claude/', '/CODEX_*.md', '/CLAUDE_*.md')) {
    if (-not $gitignore.Contains($pattern)) {
        Add-DocumentationError ".gitignore is missing local-agent pattern $pattern"
    }
}

# The release identity is declared in several languages. Derive it from the
# package command and reject drift before an updater-visible archive is built.
$packageSource = Read-RequiredText 'tools/package_release.ps1'
$packageMatch = [regex]::Match($packageSource,
    "\[string\]\`$Version\s*=\s*'(?<version>[^']+)'")
if (-not $packageMatch.Success) {
    Add-DocumentationError 'could not derive package release version'
    $version = ''
}
else { $version = $packageMatch.Groups['version'].Value }

$pyproject = Read-RequiredText 'companion/pyproject.toml'
$pythonInit = Read-RequiredText 'companion/tpf2mp/__init__.py'
$modSource = Read-RequiredText 'tpf2_mp_1/mod.lua'
if ($version) {
    $escaped = [regex]::Escape($version)
    if ($pyproject -notmatch "(?m)^version\s*=\s*`"$escaped`"\s*$") {
        Add-DocumentationError "companion pyproject version differs from $version"
    }
    if ($pythonInit -notmatch "(?m)^__version__\s*=\s*`"$escaped`"\s*$") {
        Add-DocumentationError "companion runtime version differs from $version"
    }
    $minorMatch = [regex]::Match($version, '^0\.(?<minor>\d+)\.')
    $modMatch = [regex]::Match($modSource, 'local\s+minorVersion\s*=\s*(?<minor>\d+)')
    if (-not $minorMatch.Success -or -not $modMatch.Success `
            -or $minorMatch.Groups['minor'].Value -ne $modMatch.Groups['minor'].Value) {
        Add-DocumentationError "mod minor version differs from package version $version"
    }
    $currentNote = "docs/release-notes/RELEASE_NOTES_$version.md"
    if (-not (Test-Path -LiteralPath (Join-Path $root $currentNote) -PathType Leaf)) {
        Add-DocumentationError "current release note is missing: $currentNote"
    }
    foreach ($relative in @(
            'README.md', 'docs/README.md', 'docs/ALPHA_QUICK_START.md',
            'docs/PUBLIC_ALPHA_GUIDE.md', 'docs/PROTOTYPE_STATUS.md',
            'docs/REMAINING_FROM_BRIEF.md', 'investigation/README.md')) {
        $text = Read-RequiredText $relative
        if ($text -and -not $text.Contains($version)) {
            Add-DocumentationError "$relative does not name current release $version"
        }
    }
}
if (-not $packageSource.Contains("Copy-ReleaseTree (Join-Path `$projectRoot 'docs')")) {
    Add-DocumentationError 'release packaging does not copy the canonical docs tree'
}

# Every archived release note must identify the same version as its filename.
$notesRoot = Join-Path $root 'docs/release-notes'
if (-not (Test-Path -LiteralPath $notesRoot -PathType Container)) {
    Add-DocumentationError 'release-note directory is missing'
}
else {
    foreach ($note in Get-ChildItem -LiteralPath $notesRoot -File -Filter 'RELEASE_NOTES_*.md') {
        if ($note.Name -notmatch '^RELEASE_NOTES_(?<version>.+)\.md$') {
            Add-DocumentationError "malformed release-note filename: $($note.Name)"
            continue
        }
        $firstLine = [IO.File]::ReadLines($note.FullName) | Select-Object -First 1
        if ($firstLine -cne "# TPF2MP $($Matches.version)") {
            Add-DocumentationError "$($note.Name) heading does not match its filename"
        }
    }
}

# Check relative Markdown links in maintained documents. Historical release
# notes are immutable records and may refer to the layout of their own release.
$maintained = @((Get-Item -LiteralPath (Join-Path $root 'README.md'))) +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'docs') -File -Filter '*.md' |
        Where-Object { $_.DirectoryName -ne $notesRoot }) +
    @((Get-Item -LiteralPath (Join-Path $root 'investigation/README.md')))
$linkPattern = [regex]'(?<!!)\[[^\]]*\]\((?<target>[^)\r\n]+)\)'
foreach ($document in $maintained) {
    $text = [IO.File]::ReadAllText($document.FullName)
    if ($document.DirectoryName -eq (Join-Path $root 'docs') `
            -and $text -match '(?<!\[)`investigation/') {
        Add-DocumentationError "$($document.Name) contains a stale root-relative investigation path"
    }
    foreach ($match in $linkPattern.Matches($text)) {
        $target = $match.Groups['target'].Value.Trim()
        if ($target.StartsWith('<') -and $target.Contains('>')) {
            $target = $target.Substring(1, $target.IndexOf('>') - 1)
        }
        elseif ($target -match '^(?<path>\S+)\s+["'']') {
            $target = $Matches.path
        }
        if (-not $target -or $target.StartsWith('#') `
                -or $target -match '^[A-Za-z][A-Za-z0-9+.-]*:') { continue }
        $target = ($target -split '[?#]', 2)[0]
        try { $target = [Uri]::UnescapeDataString($target) } catch { }
        if (-not $target) { continue }
        if ($target.StartsWith('/')) {
            $candidate = Join-Path $root $target.TrimStart('/')
        }
        else { $candidate = Join-Path $document.DirectoryName $target }
        $candidate = [IO.Path]::GetFullPath($candidate)
        if (-not $candidate.StartsWith($root.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase) -and $candidate -ne $root) {
            Add-DocumentationError "$($document.FullName): link escapes repository: $target"
        }
        elseif (-not (Test-Path -LiteralPath $candidate)) {
            $relativeDocument = $document.FullName.Substring($root.Length + 1)
            Add-DocumentationError "$relativeDocument has broken link: $target"
        }
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "Documentation integrity failed with $($errors.Count) error(s)."
}
Write-Host "PASS documentation layout, links, release identity, and $(@(Get-ChildItem -LiteralPath $notesRoot -File -Filter 'RELEASE_NOTES_*.md').Count) release-note headings"
