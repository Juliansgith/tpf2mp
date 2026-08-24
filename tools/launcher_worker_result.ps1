Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'release_common.ps1')

function Get-Tpf2mpVerifiedReleaseUpdateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [string]$InstallRoot
    )

    try {
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
            return $null
        }
        if (-not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }

        $stdout = [IO.File]::ReadAllText($StdoutPath)
        $expectedVersion = $null
        $updated = [regex]::Match(
            $stdout,
            '(?m)^TPF2MP updated successfully:\s+\S+\s+->\s+(\S+)\s*$')
        if ($updated.Success) {
            $expectedVersion = $updated.Groups[1].Value
        }
        else {
            $current = [regex]::Match(
                $stdout,
                '(?m)^TPF2MP\s+(\S+)\s+(?:is current on the \S+ channel|is already installed)\.\s*$')
            if ($current.Success) { $expectedVersion = $current.Groups[1].Value }
        }
        if (-not $expectedVersion -or $expectedVersion -notmatch '^[0-9A-Za-z][0-9A-Za-z.+-]{0,63}$') {
            return $null
        }

        if (-not $InstallRoot) {
            if (-not $env:LOCALAPPDATA) { return $null }
            $InstallRoot = Join-Path $env:LOCALAPPDATA 'TPF2MP'
        }
        $install = Resolve-Tpf2mpFullPath $InstallRoot
        $currentPath = Join-Path $install 'current.json'
        if (-not (Test-Path -LiteralPath $currentPath -PathType Leaf)) { return $null }
        $pointer = Get-Content -LiteralPath $currentPath -Raw | ConvertFrom-Json
        if ([string]$pointer.version -cne $expectedVersion -or -not [string]$pointer.bundleRoot) {
            return $null
        }

        $installedBundle = Resolve-Tpf2mpFullPath ([string]$pointer.bundleRoot)
        $versionsRoot = Resolve-Tpf2mpFullPath (Join-Path $install 'versions')
        if (-not $installedBundle.StartsWith(
                $versionsRoot.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $manifest = Test-Tpf2mpReleaseManifest $installedBundle
        if ([string]$manifest.version -cne $expectedVersion `
                -or [int]$manifest.format -lt 2 `
                -or [bool]$manifest.source.dirty) {
            return $null
        }

        return [pscustomobject]@{
            version = $expectedVersion
            bundleRoot = $installedBundle
            sourceCommit = [string]$manifest.source.commit
        }
    }
    catch {
        # This is a secondary proof used only after a worker reports failure.
        # Any unreadable or incomplete evidence must preserve the failure.
        return $null
    }
}

function Get-Tpf2mpVerifiedSaveSyncResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath,
        [Parameter(Mandatory = $true)][string]$Session
    )

    try {
        $safeSession = $Session.Trim()
        if ($safeSession -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return $null }
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf) `
                -or -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }
        $stdout = [IO.File]::ReadAllText($StdoutPath)
        $saveMatch = [regex]::Match($stdout, '(?m)^save_sync_received=(.+\.sav)\s*$')
        $receiptMatch = [regex]::Match($stdout, '(?m)^save_sync_receipt=(.+\.json)\s*$')
        $bundleMatch = [regex]::Match($stdout, '(?m)^save_sync_bundle=([0-9a-f]{64})\s*$')
        if (-not $saveMatch.Success -or -not $receiptMatch.Success -or -not $bundleMatch.Success) {
            return $null
        }
        $save = Resolve-Tpf2mpFullPath $saveMatch.Groups[1].Value.Trim()
        $receiptPath = Resolve-Tpf2mpFullPath $receiptMatch.Groups[1].Value.Trim()
        if ($save -notmatch '(?i)\\1066780\\local\\save\\[^\\]+\.sav$' `
                -or -not (Test-Path -LiteralPath $save -PathType Leaf) `
                -or -not (Test-Path -LiteralPath ($save + '.lua') -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            return $null
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ([int]$receipt.schemaVersion -ne 1 -or [string]$receipt.session -cne $safeSession `
                -or [string]$receipt.bundleId -cne $bundleMatch.Groups[1].Value `
                -or -not [string]::Equals(
                    (Resolve-Tpf2mpFullPath ([string]$receipt.savePath)),
                    $save,
                    [StringComparison]::OrdinalIgnoreCase) `
                -or -not [string]::Equals(
                    (Resolve-Tpf2mpFullPath ([string]$receipt.metadataPath)),
                    $save + '.lua',
                    [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        $paths = @{
            save = $save
            metadata = $save + '.lua'
        }
        if ($receipt.previewPath) {
            $paths.preview = Resolve-Tpf2mpFullPath ([string]$receipt.previewPath)
        }
        $entries = @($receipt.files)
        $roles = @($entries | ForEach-Object { [string]$_.role })
        $expectedRoles = if ($receipt.previewPath) { @('save', 'metadata', 'preview') } `
            else { @('save', 'metadata') }
        if ($roles.Count -ne $expectedRoles.Count `
                -or (($roles -join ',') -cne ($expectedRoles -join ','))) {
            return $null
        }
        foreach ($entry in $entries) {
            $role = [string]$entry.role
            if (-not $paths.ContainsKey($role)) { return $null }
            $path = [string]$paths[$role]
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) `
                    -or (Get-Item -LiteralPath $path).Length -ne [int64]$entry.bytes `
                    -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() `
                        -cne [string]$entry.sha256) {
                return $null
            }
        }
        return [pscustomobject]@{
            session = $safeSession
            savePath = $save
            receiptPath = $receiptPath
            bundleId = [string]$receipt.bundleId
            totalBytes = [int64]$receipt.totalBytes
            reused = [bool]$receipt.reused
        }
    }
    catch { return $null }
}

function Get-Tpf2mpVerifiedRelayCreateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )
    try {
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf) `
                -or -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }
        $stdout = [IO.File]::ReadAllText($StdoutPath)
        if ($stdout -match 'TPF2MP1\.' -or $stdout -match '(?i)hostToken|joinToken|Bearer\s') {
            return $null
        }
        $sessionMatch = [regex]::Match($stdout, '(?m)^relay_session_created=(mp-[0-9a-f]{16})\s*$')
        $credentialMatch = [regex]::Match($stdout, '(?m)^relay_credentials=(.+\.json)\s*$')
        $receiptMatch = [regex]::Match($stdout, '(?m)^relay_invite_receipt=(.+\.json)\s*$')
        if (-not $sessionMatch.Success -or -not $credentialMatch.Success -or -not $receiptMatch.Success) {
            return $null
        }
        $credentialsPath = Resolve-Tpf2mpFullPath $credentialMatch.Groups[1].Value.Trim()
        $receiptPath = Resolve-Tpf2mpFullPath $receiptMatch.Groups[1].Value.Trim()
        $relayRoot = Resolve-Tpf2mpFullPath (Join-Path (Get-Tpf2mpSupportRoot) 'relay-drafts')
        foreach ($path in @($credentialsPath, $receiptPath)) {
            if (-not $path.StartsWith(
                    $relayRoot.TrimEnd('\') + '\',
                    [StringComparison]::OrdinalIgnoreCase) `
                    -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
                return $null
            }
        }
        $credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        $session = $sessionMatch.Groups[1].Value
        if ([int]$credentials.schemaVersion -ne 1 -or [string]$credentials.role -cne 'host' `
                -or [string]$credentials.sessionId -cne $session `
                -or [string]$credentials.token -notmatch '^[A-Za-z0-9_-]{40,96}$' `
                -or [int]$receipt.schemaVersion -ne 1 `
                -or [string]$receipt.sessionId -cne $session `
                -or [string]$receipt.supportId -cne $session `
                -or [string]$receipt.relayUrl -cne [string]$credentials.relayUrl `
                -or [string]$receipt.joinCode -notmatch '^TPF2MP1\.[A-Za-z0-9_-]{32,256}$' `
                -or -not [string]::Equals(
                    (Resolve-Tpf2mpFullPath ([string]$receipt.credentialsPath)),
                    $credentialsPath,
                    [StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        return [pscustomobject]@{
            session = $session
            supportId = $session
            relayUrl = [string]$credentials.relayUrl
            credentialsPath = $credentialsPath
            inviteReceiptPath = $receiptPath
            joinCode = [string]$receipt.joinCode
            expiresAt = [string]$receipt.expiresAt
        }
    }
    catch { return $null }
}

function Get-Tpf2mpVerifiedRelayJoinResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StdoutPath,
        [Parameter(Mandatory = $true)][string]$StderrPath
    )
    try {
        if (-not (Test-Path -LiteralPath $StdoutPath -PathType Leaf) `
                -or -not (Test-Path -LiteralPath $StderrPath -PathType Leaf) `
                -or -not [string]::IsNullOrWhiteSpace([IO.File]::ReadAllText($StderrPath))) {
            return $null
        }
        $stdout = [IO.File]::ReadAllText($StdoutPath)
        if ($stdout -match 'TPF2MP1\.' -or $stdout -match '(?i)hostToken|joinToken|Bearer\s') {
            return $null
        }
        $sessionMatch = [regex]::Match($stdout, '(?m)^relay_session_joined=(mp-[0-9a-f]{16})\s*$')
        $credentialMatch = [regex]::Match($stdout, '(?m)^relay_credentials=(.+\.json)\s*$')
        if (-not $sessionMatch.Success -or -not $credentialMatch.Success) { return $null }
        $credentialsPath = Resolve-Tpf2mpFullPath $credentialMatch.Groups[1].Value.Trim()
        $relayRoot = Resolve-Tpf2mpFullPath (Join-Path (Get-Tpf2mpSupportRoot) 'relay-drafts')
        if (-not $credentialsPath.StartsWith(
                $relayRoot.TrimEnd('\') + '\',
                [StringComparison]::OrdinalIgnoreCase) `
                -or -not (Test-Path -LiteralPath $credentialsPath -PathType Leaf)) {
            return $null
        }
        $credentials = Get-Content -LiteralPath $credentialsPath -Raw | ConvertFrom-Json
        $session = $sessionMatch.Groups[1].Value
        if ([int]$credentials.schemaVersion -ne 1 -or [string]$credentials.role -cne 'join' `
                -or [string]$credentials.sessionId -cne $session `
                -or [string]$credentials.token -notmatch '^[A-Za-z0-9_-]{40,96}$') {
            return $null
        }
        return [pscustomobject]@{
            session = $session
            supportId = $session
            relayUrl = [string]$credentials.relayUrl
            credentialsPath = $credentialsPath
        }
    }
    catch { return $null }
}
