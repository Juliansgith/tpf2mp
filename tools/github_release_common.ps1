Set-StrictMode -Version Latest

function Assert-Tpf2mpGitHubRepository {
    param([Parameter(Mandatory = $true)][string]$Repository)
    $parts = @($Repository -split '/')
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' `
            -or $parts.Count -ne 2 -or $parts[0] -in @('.', '..') -or $parts[1] -in @('.', '..')) {
        throw "Unsafe GitHub repository name: $Repository"
    }
    return $Repository
}

function Get-Tpf2mpGitHubToken {
    param([switch]$NoCredentialPrompt)
    if ($env:TPF2MP_GITHUB_TOKEN) { return [string]$env:TPF2MP_GITHUB_TOKEN }
    if ($env:GITHUB_TOKEN) { return [string]$env:GITHUB_TOKEN }
    $gh = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($gh) {
        $value = @(& $gh.Source auth token 2>$null)
        if ($LASTEXITCODE -eq 0 -and $value.Count -gt 0 -and [string]$value[0]) {
            return ([string]$value[0]).Trim()
        }
    }
    if (-not $NoCredentialPrompt) {
        $git = Get-Command git.exe -ErrorAction SilentlyContinue
        if (-not $git) { $git = Get-Command git -ErrorAction SilentlyContinue }
        if ($git) {
            $credentialInput = "protocol=https`nhost=github.com`n`n"
            $lines = @($credentialInput | & $git.Source credential fill 2>$null)
            if ($LASTEXITCODE -eq 0) {
                foreach ($line in $lines) {
                    if ([string]$line -match '^password=(.+)$') { return [string]$matches[1] }
                }
            }
        }
    }
    return $null
}

function New-Tpf2mpGitHubHeaders {
    param(
        [string]$Token,
        [string]$Accept = 'application/vnd.github+json'
    )
    $headers = @{
        Accept = $Accept
        'User-Agent' = 'TPF2MP-Release-Client'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    if ($Token) { $headers.Authorization = "Bearer $Token" }
    return $headers
}
