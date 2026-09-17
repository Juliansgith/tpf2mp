# The launcher's onboarding checklist: four ordered steps, live.
#
# A first-time player cannot tell from the control panel alone how far a match
# has actually got. Every signal already exists - prepared relay credentials, a
# selected save or a lobby-generated world, and the session-state status the
# timer polls - so this module turns those signals into the four steps the
# window paints. It is deliberately pure: no WinForms, no file system, no
# global launcher state, so the rule that decides "done" is unit-testable and
# the window keeps only the painting.

Set-StrictMode -Version Latest

$script:Tpf2mpChecklistLabels = @(
    '1 Create or paste a code',
    '2 Open the world lobby (or choose a save)',
    '3 Both players ready',
    '4 Host starts the match'
)

# Statuses a session writes once its companion and game are starting. Reaching
# any of them proves the code and the world choice already happened, even when
# the launcher was restarted and no longer holds those signals in memory.
$script:Tpf2mpChecklistLaunchedStatuses = @(
    'starting-companion', 'hosting', 'joining', 'injecting-native-hook',
    'waiting-for-network-world', 'awaiting-world-selection'
)
$script:Tpf2mpChecklistWorldReadyStatuses = @('hosting-world-ready', 'joined-world-ready')

function Get-Tpf2mpChecklistSignal {
    [CmdletBinding()]
    param($Signals, [Parameter(Mandatory = $true)][string]$Name)
    if ($Signals -is [hashtable] -and $Signals.ContainsKey($Name)) { return $Signals[$Name] }
    return $null
}

function Get-Tpf2mpChecklistState {
    [CmdletBinding()]
    param([hashtable]$Signals = @{})
    $role = [string](Get-Tpf2mpChecklistSignal $Signals 'CredentialRole')
    $status = [string](Get-Tpf2mpChecklistSignal $Signals 'SessionStatus')
    $link = [string](Get-Tpf2mpChecklistSignal $Signals 'NetworkLink')
    $hasSave = [bool](Get-Tpf2mpChecklistSignal $Signals 'HasSave')
    $lobbyWorldReady = [bool](Get-Tpf2mpChecklistSignal $Signals 'LobbyWorldReady')

    $done = @($false, $false, $false, $false)
    $done[0] = $role -in @('host', 'join')
    $done[1] = $hasSave -or $lobbyWorldReady -or ($status -in $script:Tpf2mpChecklistLaunchedStatuses)
    $done[2] = $status -in $script:Tpf2mpChecklistWorldReadyStatuses
    $done[3] = $link -ceq 'CONNECTED'
    # A later proof implies every earlier step: a connected match cannot exist
    # without a code, a world and both peers ready, whatever this process saw.
    for ($index = 2; $index -ge 0; $index--) {
        if ($done[$index + 1]) { $done[$index] = $true }
    }

    $steps = @()
    $currentTaken = $false
    for ($index = 0; $index -lt $script:Tpf2mpChecklistLabels.Count; $index++) {
        $state = 'pending'
        if ($done[$index]) { $state = 'done' }
        elseif (-not $currentTaken) { $state = 'current'; $currentTaken = $true }
        $steps += [pscustomobject][ordered]@{
            Label = $script:Tpf2mpChecklistLabels[$index]
            State = $state
        }
    }
    return @($steps)
}

# The strip the launcher window paints: one small pill per step, carrying the
# step number until that step is proven and a tick afterwards, with the step
# text beside it. Kept next to the derivation so the two stay in step; the
# derivation above remains free of any WinForms dependency.
$script:Tpf2mpChecklistBounds = @(
    @(28, 64, 164), @(236, 272, 264), @(548, 584, 124), @(716, 752, 160)
)
$script:Tpf2mpChecklistTick = [string][char]0x2713

function New-Tpf2mpChecklistStrip($Parent, [int]$Y) {
    $pills = @()
    $labels = @()
    for ($index = 0; $index -lt $script:Tpf2mpChecklistBounds.Count; $index++) {
        $slot = $script:Tpf2mpChecklistBounds[$index]
        $pills += New-Tpf2mpPill $Parent ([string]($index + 1)) $slot[0] $Y 30 24
        $labels += New-Tpf2mpLabel $Parent ($script:Tpf2mpChecklistLabels[$index].Substring(2)) `
            $slot[1] ($Y + 2) $slot[2] 18 'Muted'
    }
    return [pscustomobject]@{ Pills = $pills; Labels = $labels; Signature = $null }
}

function Update-Tpf2mpChecklistStrip($Strip, [hashtable]$Signals) {
    if (-not $Strip) { return }
    $steps = @(Get-Tpf2mpChecklistState -Signals $Signals)
    $signature = ($steps | ForEach-Object { $_.State }) -join ','
    if ($signature -ceq [string]$Strip.Signature) { return }
    $Strip.Signature = $signature
    $colors = Get-Tpf2mpTheme
    for ($index = 0; $index -lt $steps.Count; $index++) {
        switch ($steps[$index].State) {
            'done' {
                Set-Tpf2mpPill $Strip.Pills[$index] $script:Tpf2mpChecklistTick 'Success'
                $Strip.Labels[$index].ForeColor = $colors.Text
            }
            'current' {
                Set-Tpf2mpPill $Strip.Pills[$index] ([string]($index + 1)) 'Accent'
                $Strip.Labels[$index].ForeColor = $colors.Accent
            }
            default {
                Set-Tpf2mpPill $Strip.Pills[$index] ([string]($index + 1)) 'Muted'
                $Strip.Labels[$index].ForeColor = $colors.Faint
            }
        }
    }
}
