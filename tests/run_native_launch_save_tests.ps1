$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '../tools/native_launch_save.ps1')
$script:calls=@()
function Wait-Tpf2mpMenuStage { param($GameProcess,$BridgePath,$Session,$Peer,$Stage,$TimeoutSeconds)
    if ('native-load-requested' -notin $Stage -or 'world-transition' -notin $Stage) { throw 'Unqualified automatic load stage.' }
    $script:calls+='automatic'
}
function Wait-Tpf2mpMainMenuEntry { param($GameProcess,$BridgePath,$Session,$Peer,$TimeoutSeconds) $script:calls+='manual' }
function Write-Tpf2mpSessionState { param($Session,$Peer,$State) $script:calls+='state' }
function Invoke-Tpf2mpPinnedSaveLoad { param($GameProcess,$BridgePath,$Session,$Peer,$ExpectedSaveBaseName,$EvidenceDirectory,$TimeoutSeconds)
    if ($ExpectedSaveBaseName -ne 'owned-world') { throw 'Changed save identity.' }
    $script:calls+='load'
}
$state=@{status='initial';nativeSaveLoadReceipt=$null}
$arguments=@{GameProcess=(Get-Process -Id $PID);BridgePath='unused';Session='test';Peer='player1'
    SessionRoot=$PSScriptRoot;SaveBaseName='owned-world';State=$state}
Invoke-Tpf2mpStagedWorldLoad @arguments -AutomaticWorldLoad
if (($script:calls -join ',') -ne 'automatic' -or $state.status -ne 'initial') { throw 'Automatic load invoked the menu interaction path.' }
$script:calls=@()
Invoke-Tpf2mpStagedWorldLoad @arguments
if (($script:calls -join ',') -ne 'manual,state,load' -or -not $state.nativeSaveLoadReceipt) { throw 'Legacy pinned-save loading regressed.' }
Write-Host 'PASS native staged load selection: automatic and legacy paths remain separate'
