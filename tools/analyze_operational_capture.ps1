[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Session,
    [string]$BridgeRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ($Session -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { throw "Unsafe session: $Session" }
if (-not $BridgeRoot) {
    $BridgeRoot = Join-Path ([IO.Path]::GetTempPath()) "tpf2mp_bridge\$Session"
}
$BridgeRoot = [IO.Path]::GetFullPath($BridgeRoot)
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $projectRoot "runtime\operational-analysis\$Session"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Read-Messages([string]$Peer) {
    $outbox = Join-Path $BridgeRoot "$Peer\game_outbox"
    $messages = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $outbox -File -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            $message = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            if ($message.session -eq $Session -and $message.peer -eq $Peer) { $messages += $message }
        }
        catch { }
    }
    return $messages
}

function Get-Nested($Object, [string[]]$Path) {
    $value = $Object
    foreach ($name in $Path) {
        if ($null -eq $value) { return $null }
        if ($value -is [Collections.IDictionary]) {
            if (-not $value.Contains($name)) { return $null }
            $value = $value[$name]
        }
        else {
            if ($null -eq $value.PSObject.Properties[$name]) { return $null }
            $value = $value.$name
        }
    }
    return $value
}

function Max-Number($Values) {
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($numbers.Count -eq 0) { return $null }
    return ($numbers | Measure-Object -Maximum).Maximum
}

function Town-Capacity($Sample) {
    $towns = Get-Nested $Sample @('structural', 'towns')
    if ($null -eq $towns) { return $null }
    $capacities = @($towns | ForEach-Object { $_.totalCapacity } | Where-Object { $null -ne $_ })
    if ($capacities.Count -eq 0) { return 0 }
    return [double](($capacities | Measure-Object -Sum).Sum)
}

function Digest-Changes($Samples, [string]$Domain) {
    $changes = 0
    for ($index = 1; $index -lt $Samples.Count; $index++) {
        $previous = Get-Nested $Samples[$index - 1] @('digests', $Domain)
        $current = Get-Nested $Samples[$index] @('digests', $Domain)
        if ($null -ne $previous -and $null -ne $current -and $previous -ne $current) { $changes++ }
    }
    return $changes
}

function Account-Deltas($First, $Last) {
    $result = [ordered]@{}
    $firstCompanies = Get-Nested $First @('accounts', 'companies')
    $lastCompanies = Get-Nested $Last @('accounts', 'companies')
    if (-not $firstCompanies -or -not $lastCompanies) { return $result }
    foreach ($property in @($lastCompanies.PSObject.Properties | Sort-Object Name)) {
        $company = $property.Name
        $lastAccount = $property.Value
        $firstAccount = if ($firstCompanies.PSObject.Properties[$company]) { $firstCompanies.$company } else { $null }
        $result[$company] = [ordered]@{
            firstBalance = if ($firstAccount) { $firstAccount.balance } else { $null }
            lastBalance = $lastAccount.balance
            balanceDelta = if ($firstAccount -and $null -ne $firstAccount.balance -and $null -ne $lastAccount.balance) {
                [double]$lastAccount.balance - [double]$firstAccount.balance
            } else { $null }
            firstLoan = if ($firstAccount) { $firstAccount.loan } else { $null }
            lastLoan = $lastAccount.loan
        }
    }
    return $result
}

function Summarize-Peer([string]$Peer) {
    $messages = @(Read-Messages $Peer)
    $samples = @($messages | Where-Object { $_.kind -eq 'operational' } | ForEach-Object { $_.payload })
    $commands = @($messages | Where-Object { $_.kind -eq 'operational-command' } | ForEach-Object { $_.payload })
    $guiEvents = @($messages | Where-Object { $_.kind -eq 'operational-gui' } | ForEach-Object { $_.payload })
    if ($samples.Count -eq 0) {
        return [ordered]@{
            peer = $Peer
            sampleCount = 0
            commandCount = $commands.Count
            guiActionCount = $guiEvents.Count
            error = 'no operational samples'
        }
    }
    $initializedSamples = @($samples | Where-Object { $_.initialized -eq $true })
    $first = if ($initializedSamples.Count) { $initializedSamples[0] } else { $samples[0] }
    $last = $samples[-1]
    $originCounts = [ordered]@{}
    foreach ($command in $commands) {
        $origin = [string]$command.origin
        if (-not $originCounts.Contains($origin)) { $originCounts[$origin] = 0 }
        $originCounts[$origin]++
    }
    $guiActionCounts = [ordered]@{}
    foreach ($guiEvent in $guiEvents) {
        $action = "$([string]$guiEvent.sourceId).$([string]$guiEvent.eventName)"
        if (-not $guiActionCounts.Contains($action)) { $guiActionCounts[$action] = 0 }
        $guiActionCounts[$action]++
    }
    $speedCounts = [ordered]@{}
    foreach ($sample in $samples) {
        $key = [string](Get-Nested $sample @('clock', 'gameSpeed'))
        if (-not $key) { $key = 'unavailable' }
        if (-not $speedCounts.Contains($key)) { $speedCounts[$key] = 0 }
        $speedCounts[$key]++
    }
    $availability = [ordered]@{}
    foreach ($field in @(
        'totalPersons', 'linePassengers', 'lineCargo', 'terminalInfo', 'terminalFreePlaces',
        'directPersonEntities', 'directCargoEntities', 'directEntitiesAtVehicle', 'directEntitiesAtTerminal'
    )) {
        $availability[$field] = @($samples | Where-Object {
            (Get-Nested $_ @('mobility', 'availability', $field)) -eq $true
        }).Count -gt 0
    }
    $digestChanges = [ordered]@{}
    foreach ($domain in @('model', 'core', 'structural', 'mobility', 'autonomy', 'journal', 'accounts')) {
        $digestChanges[$domain] = Digest-Changes $samples $domain
    }
    $firstHook = Get-Nested $first @('nativePipeline', 'hook')
    $finalHook = Get-Nested $last @('nativePipeline', 'hook')
    $firstApplyCalls = Get-Nested $firstHook @('applyCommand', 'calls')
    $finalApplyCalls = Get-Nested $finalHook @('applyCommand', 'calls')
    $firstDirect = Get-Nested $firstHook @('applyCommand', 'direct')
    $finalDirect = Get-Nested $finalHook @('applyCommand', 'direct')
    $firstFiltered = Get-Nested $firstHook @('applyCommand', 'filteredScriptEvents')
    $finalFiltered = Get-Nested $finalHook @('applyCommand', 'filteredScriptEvents')
    return [ordered]@{
        peer = $Peer
        sampleCount = $samples.Count
        commandCount = $commands.Count
        guiActionCount = $guiEvents.Count
        preInitializationSamples = $samples.Count - $initializedSamples.Count
        firstTick = $first.tick
        lastTick = $last.tick
        initialized = $last.initialized
        speedSamples = $speedCounts
        mobilityAvailabilityEver = $availability
        maxima = [ordered]@{
            lines = Max-Number ($samples | ForEach-Object { @($_.structural.lines).Count })
            vehicles = Max-Number ($samples | ForEach-Object { Get-Nested $_ @('structural', 'vehicleCount') })
            constructions = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('structural', 'constructionCount')
            })
            townCapacity = Max-Number ($samples | ForEach-Object { Town-Capacity $_ })
            totalPersons = Max-Number ($samples | ForEach-Object { Get-Nested $_ @('mobility', 'totalPersons') })
            passengerLineUses = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'passengerLineUses')
            })
            cargoLineUses = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'cargoLineUses')
            })
            directPersons = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'directPersons')
            })
            directCargoEntities = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'directCargoEntities')
            })
            passengersOnVehicle = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'passengersOnVehicle')
            })
            passengersWaiting = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'passengersWaiting')
            })
            cargoOnVehicle = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'cargoOnVehicle')
            })
            cargoWaiting = Max-Number ($samples | ForEach-Object {
                Get-Nested $_ @('mobility', 'totals', 'cargoWaiting')
            })
        }
        accountDeltas = Account-Deltas $first $last
        digestChanges = $digestChanges
        commandOrigins = $originCounts
        guiActions = $guiActionCounts
        nativePipeline = [ordered]@{
            applyCallsStart = $firstApplyCalls
            applyCallsEnd = $finalApplyCalls
            applyCallsDelta = if ($null -ne $firstApplyCalls -and $null -ne $finalApplyCalls) {
                [double]$finalApplyCalls - [double]$firstApplyCalls
            } else { $null }
            filteredScriptEventsDelta = if ($null -ne $firstFiltered -and $null -ne $finalFiltered) {
                [double]$finalFiltered - [double]$firstFiltered
            } else { $null }
            nonScriptApplyDelta = if ($null -ne $firstApplyCalls -and $null -ne $finalApplyCalls `
                -and $null -ne $firstFiltered -and $null -ne $finalFiltered) {
                ([double]$finalApplyCalls - [double]$firstApplyCalls) `
                    - ([double]$finalFiltered - [double]$firstFiltered)
            } else { $null }
            directAppliesStart = $firstDirect
            directAppliesEnd = $finalDirect
            directAppliesDelta = if ($null -ne $firstDirect -and $null -ne $finalDirect) {
                [double]$finalDirect - [double]$firstDirect
            } else { $null }
            unknownTags = Get-Nested $finalHook @('applyCommand', 'unknownTags')
            tagMismatches = Get-Nested $finalHook @('applyCommand', 'tagMismatches')
            tagCounts = Get-Nested $finalHook @('applyCommand', 'tagCounts')
            commandEvents = Get-Nested $finalHook @('commandEvents')
        }
        autonomyFirst = $first.autonomy
        autonomyLast = $last.autonomy
        agentPolicyFirst = $first.agentPolicy
        agentPolicyLast = $last.agentPolicy
        firstDigests = $first.digests
        lastDigests = $last.digests
    }
}

$peer1 = Summarize-Peer 'player1'
$peer2 = Summarize-Peer 'player2'
$cross = [ordered]@{ comparableSamples = [Math]::Min([int]$peer1.sampleCount, [int]$peer2.sampleCount); domains = [ordered]@{} }
foreach ($domain in @('model', 'core', 'structural', 'mobility', 'autonomy', 'accounts')) {
    $cross.domains[$domain] = [ordered]@{
        firstEqual = (Get-Nested $peer1 @('firstDigests', $domain)) -eq (Get-Nested $peer2 @('firstDigests', $domain))
        lastEqual = (Get-Nested $peer1 @('lastDigests', $domain)) -eq (Get-Nested $peer2 @('lastDigests', $domain))
    }
}
$report = [ordered]@{
    schemaVersion = 2
    generatedAt = (Get-Date).ToString('o')
    session = $Session
    scope = 'two-independent-local-worlds; comparison is diagnostic, not multiplayer consensus'
    bridgeRoot = $BridgeRoot
    peers = [ordered]@{ player1 = $peer1; player2 = $peer2 }
    crossInstance = $cross
}
$jsonPath = Join-Path $OutputDirectory 'operational-analysis.json'
$report | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# TPF2MP operational capture analysis')
$lines.Add('')
$lines.Add("Session: ``$Session``")
$lines.Add('')
$lines.Add('Scope: two independent, unrestricted local hot-seat worlds. Equality below is diagnostic only; it is not network consensus.')
foreach ($peer in @($peer1, $peer2)) {
    $lines.Add('')
    $lines.Add("## $($peer.peer)")
    $lines.Add('')
    if ([int]$peer.sampleCount -eq 0) {
        $lines.Add("- No operational samples: $($peer.error).")
        continue
    }
    $lines.Add("- Samples: $($peer.sampleCount) ($($peer.preInitializationSamples) before initialization), initialized ticks $($peer.firstTick) to $($peer.lastTick); captured commands: $($peer.commandCount); GUI mutation envelopes: $($peer.guiActionCount).")
    $lines.Add("- Operational maxima: constructions $($peer.maxima.constructions), town capacity $($peer.maxima.townCapacity), lines $($peer.maxima.lines), vehicles $($peer.maxima.vehicles), people $($peer.maxima.totalPersons), passenger line uses $($peer.maxima.passengerLineUses), cargo line uses $($peer.maxima.cargoLineUses).")
    if ($peer.agentPolicyLast) {
        $lines.Add("- Agent policy: mode=$($peer.agentPolicyLast.mode), construction scaling=$($peer.agentPolicyLast.constructionScalingActive), runtime scaling=$($peer.agentPolicyLast.runtimeScalingWorks), fingerprint=$($peer.agentPolicyLast.configuredFingerprint).")
    }
    $lines.Add("- Documented mobility helpers ever available: persons=$($peer.mobilityAvailabilityEver.totalPersons), line passengers=$($peer.mobilityAvailabilityEver.linePassengers), line cargo=$($peer.mobilityAvailabilityEver.lineCargo), terminal info/free places=$($peer.mobilityAvailabilityEver.terminalInfo)/$($peer.mobilityAvailabilityEver.terminalFreePlaces).")
    $lines.Add("- Direct ECS readers ever available: persons=$($peer.mobilityAvailabilityEver.directPersonEntities), cargo=$($peer.mobilityAvailabilityEver.directCargoEntities), at vehicle=$($peer.mobilityAvailabilityEver.directEntitiesAtVehicle), at terminal=$($peer.mobilityAvailabilityEver.directEntitiesAtTerminal).")
    $lines.Add("- Direct maxima: people $($peer.maxima.directPersons), cargo entities $($peer.maxima.directCargoEntities), aboard pax/cargo $($peer.maxima.passengersOnVehicle)/$($peer.maxima.cargoOnVehicle), waiting pax/cargo $($peer.maxima.passengersWaiting)/$($peer.maxima.cargoWaiting).")
    $lines.Add("- Native non-script apply/direct deltas after initialized baseline: $($peer.nativePipeline.nonScriptApplyDelta)/$($peer.nativePipeline.directAppliesDelta) (filtered script events $($peer.nativePipeline.filteredScriptEventsDelta)); final unknown/mismatch: $($peer.nativePipeline.unknownTags)/$($peer.nativePipeline.tagMismatches).")
    $lines.Add("- Digest changes (model/core/structure/mobility/autonomy/accounts): $($peer.digestChanges.model)/$($peer.digestChanges.core)/$($peer.digestChanges.structural)/$($peer.digestChanges.mobility)/$($peer.digestChanges.autonomy)/$($peer.digestChanges.accounts).")
    foreach ($property in @($peer.accountDeltas.GetEnumerator())) {
        $value = $property.Value
        $lines.Add("- $($property.Key) balance: $($value.firstBalance) -> $($value.lastBalance) (delta $($value.balanceDelta)); loan $($value.firstLoan) -> $($value.lastLoan).")
    }
}
$lines.Add('')
$lines.Add('## Cross-instance diagnostic')
$lines.Add('')
foreach ($property in @($cross.domains.GetEnumerator())) {
    $lines.Add("- $($property.Key): first equal=$($property.Value.firstEqual), last equal=$($property.Value.lastEqual).")
}
$markdownPath = Join-Path $OutputDirectory 'operational-analysis.md'
$lines | Set-Content -LiteralPath $markdownPath -Encoding UTF8
Write-Host "analysisJson=$jsonPath"
Write-Host "analysisMarkdown=$markdownPath"
