Set-StrictMode -Version Latest

function Invoke-Tpf2mpStagedWorldLoad {
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$GameProcess,
        [Parameter(Mandatory)][string]$BridgePath,
        [Parameter(Mandatory)][string]$Session,
        [Parameter(Mandatory)][string]$Peer,
        [Parameter(Mandatory)][string]$SessionRoot,
        [Parameter(Mandatory)][string]$SaveBaseName,
        [Parameter(Mandatory)]$State,
        [switch]$AutomaticWorldLoad
    )
    if ($AutomaticWorldLoad) {
        [void](Wait-Tpf2mpMenuStage -GameProcess $GameProcess -BridgePath $BridgePath `
            -Session $Session -Peer $Peer -Stage @('native-load-requested','world-transition') -TimeoutSeconds 120)
        return
    }
    [void](Wait-Tpf2mpMainMenuEntry -GameProcess $GameProcess -BridgePath $BridgePath `
        -Session $Session -Peer $Peer -TimeoutSeconds 120)
    $State.status='awaiting-multiplayer-selection'
    [void](Write-Tpf2mpSessionState $Session $Peer $State)
    [void](Invoke-Tpf2mpPinnedSaveLoad -GameProcess $GameProcess -BridgePath $BridgePath `
        -Session $Session -Peer $Peer -ExpectedSaveBaseName $SaveBaseName `
        -EvidenceDirectory (Join-Path $SessionRoot 'native-save-load') -TimeoutSeconds 600)
    $State.nativeSaveLoadReceipt=Join-Path $SessionRoot 'native-save-load\native-save-load.json'
}
