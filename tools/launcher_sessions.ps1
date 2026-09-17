# Recent TPF2MP matches, and the save a resumed match should start from.
#
# Every launched match leaves a schemaVersion 3 session-state.json under
# %LOCALAPPDATA%\TPF2MP\sessions\<session>\<player1|player2>\. Reading those
# records back is what lets the launcher offer "resume the last match" without
# the player hunting through the Transport Fever 2 save folder: resuming is
# simply a fresh relay session plus the newest save that match produced.
#
# Nothing here starts a session or touches the relay. It reports what already
# happened on this computer, so it stays unit-testable against fixtures.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'network_common.ps1')

function Get-Tpf2mpSessionRecordField {
    [CmdletBinding()]
    param($Record, [Parameter(Mandatory = $true)][string]$Name)
    if (-not $Record) { return $null }
    $property = $Record.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function ConvertTo-Tpf2mpSessionTimestamp {
    [CmdletBinding()]
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $parsed = [DateTime]::MinValue
    $parsedOk = [DateTime]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)
    if (-not $parsedOk) { return $null }
    return $parsed.ToUniversalTime()
}

function Get-Tpf2mpRecentSessions {
    [CmdletBinding()]
    param([ValidateRange(1, 50)][int]$Limit = 5)
    $root = Join-Path (Get-Tpf2mpSupportRoot) 'sessions'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    $records = @()
    foreach ($sessionDirectory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
        # One row per match: a localhost lab writes a state for both peers.
        $newest = $null
        foreach ($peerDirectory in @(Get-ChildItem -LiteralPath $sessionDirectory.FullName -Directory `
                    -Filter 'player*' -ErrorAction SilentlyContinue)) {
            $statePath = Join-Path $peerDirectory.FullName 'session-state.json'
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
            $state = $null
            try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json }
            catch { continue }
            if ([int](Get-Tpf2mpSessionRecordField $state 'schemaVersion') -ne 3) { continue }
            $started = ConvertTo-Tpf2mpSessionTimestamp `
                ([string](Get-Tpf2mpSessionRecordField $state 'startedAtUtc'))
            if (-not $started) { continue }
            $startingSave = [string](Get-Tpf2mpSessionRecordField $state 'pinnedStartingSave')
            if (-not $startingSave) {
                $startingSave = [string](Get-Tpf2mpSessionRecordField $state 'startingSave')
            }
            $session = [string](Get-Tpf2mpSessionRecordField $state 'session')
            if (-not $session) { $session = $sessionDirectory.Name }
            $record = [pscustomobject][ordered]@{
                Session = $session
                Peer = [string](Get-Tpf2mpSessionRecordField $state 'peer')
                Role = [string](Get-Tpf2mpSessionRecordField $state 'role')
                Status = [string](Get-Tpf2mpSessionRecordField $state 'status')
                SupportId = [string](Get-Tpf2mpSessionRecordField $state 'supportId')
                StartedAtUtc = $started
                StartingSave = $startingSave
                TransportMode = [string](Get-Tpf2mpSessionRecordField $state 'transportMode')
            }
            if (-not $newest -or $record.StartedAtUtc -gt $newest.StartedAtUtc) { $newest = $record }
        }
        if ($newest) { $records += $newest }
    }
    return @($records | Sort-Object -Property StartedAtUtc -Descending | Select-Object -First $Limit)
}

function Get-Tpf2mpResumeCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Session,
        [Parameter(Mandatory = $true)][string]$SaveDirectory
    )
    $started = Get-Tpf2mpSessionRecordField $Session 'StartedAtUtc'
    if ($started -isnot [DateTime]) { $started = ConvertTo-Tpf2mpSessionTimestamp ([string]$started) }
    if ($SaveDirectory -and (Test-Path -LiteralPath $SaveDirectory -PathType Container)) {
        # A continued match is whatever Player 1 saved after that session began.
        $candidate = @(Get-ChildItem -LiteralPath $SaveDirectory -File -Filter '*.sav' `
                -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ieq '.sav' } |
            Where-Object { -not $started -or $_.LastWriteTimeUtc -gt $started } |
            Sort-Object -Property LastWriteTimeUtc -Descending) | Select-Object -First 1
        if ($candidate) {
            return [pscustomobject][ordered]@{
                Path = $candidate.FullName
                Source = 'match-save'
                ModifiedUtc = $candidate.LastWriteTimeUtc
            }
        }
    }
    $pinned = [string](Get-Tpf2mpSessionRecordField $Session 'StartingSave')
    if ($pinned -and (Test-Path -LiteralPath $pinned -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            Path = (Resolve-Tpf2mpFullPath $pinned)
            Source = 'starting-save'
            ModifiedUtc = (Get-Item -LiteralPath $pinned).LastWriteTimeUtc
        }
    }
    return $null
}
