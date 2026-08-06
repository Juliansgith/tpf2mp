[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($ProjectRoot)

$budgets = [ordered]@{
    'tpf2_mp_1\res\config\game_script\tpf2_mp.lua' = 3400
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_runtime.lua' = 1450
    'tpf2_mp_1\res\scripts\tpf2_mp\network_intent_runtime.lua' = 480
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_runtime.lua' = 360
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_runtime.lua' = 420
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_runtime.lua' = 900
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_clock.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_event_runtime.lua' = 1450
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_network_bootstrap.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_runtime.lua' = 650
    'companion\tpf2mp\network.py' = 1450
    'companion\tpf2mp\consensus.py' = 400
    'companion\tpf2mp\synchronization.py' = 700
    'native\src\hook_dll.cpp' = 1250
    'native\src\native_command_codec.cpp' = 350
    'native\src\native_hook_status.cpp' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_codec.lua' = 2400
    'tpf2_mp_1\res\scripts\tpf2_mp\world.lua' = 2100
}

foreach ($relative in $budgets.Keys) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Architecture source is missing: $relative"
    }
    $lines = (Get-Content -LiteralPath $path | Measure-Object -Line).Lines
    $limit = $budgets[$relative]
    if ($lines -gt $limit) {
        throw "Architecture budget exceeded: $relative has $lines lines (limit $limit). Extract a cohesive module or deliberately revise the documented boundary."
    }
}

$entryPoint = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\config\game_script\tpf2_mp.lua') -Raw
$requiredModules = @(
    'tpf2_mp/runtime_config',
    'tpf2_mp/state_schema',
    'tpf2_mp/checkpoint_runtime',
    'tpf2_mp/public_snapshot',
    'tpf2_mp/proposal_runtime',
    'tpf2_mp/operation_runtime',
    'tpf2_mp/network_intent_runtime',
    'tpf2_mp/network_clock_runtime',
    'tpf2_mp/vehicle_sync_runtime',
    'tpf2_mp/validation_runtime',
    'tpf2_mp/gui_state',
    'tpf2_mp/gui_capture',
    'tpf2_mp/gui_view',
    'tpf2_mp/gui_event_runtime',
    'tpf2_mp/native_hook'
)
foreach ($module in $requiredModules) {
    if (-not $entryPoint.Contains($module)) {
        throw "Game-script entry point no longer composes required module $module"
    }
}
foreach ($movedDefinition in @(
    'local function compactNativeHookStatus',
    'local function economyDigestView',
    'local function pruneOperationRecords',
    'local function collectNumeric',
    'local function routeProposalFinance',
    'local function networkPendingBarrierReason',
    'function networkClock.apply',
    'local function validationTransition',
    'local function processSuppressedNativeBuildCapture',
    'local function processGuiOperationQueue',
    'local gui = {'
)) {
    if ($entryPoint.Contains($movedDefinition)) {
        throw "Extracted responsibility was copied back into the game-script entry point: $movedDefinition"
    }
}

$hostSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\network.py') -Raw
if ($hostSource -match '(?m)^class CommitClient:') {
    throw 'CommitClient was copied back into the host authority module.'
}
if (-not $hostSource.Contains('from .client import CommitClient') `
    -or -not $hostSource.Contains('from .transport import ConnectedPeer') `
    -or -not $hostSource.Contains('ConsensusTrackers')) {
    throw 'Companion host no longer composes the client/transport/consensus boundaries.'
}
if (-not $hostSource.Contains('from .synchronization import SynchronizationCoordinator')) {
    throw 'Companion host no longer composes the clock/vehicle synchronization boundary.'
}
foreach ($movedDefinition in @(
    'class ConsensusTrackers:',
    'def proposal_completion_payload(',
    'def operation_completion_payload(',
    'def clock_health_payload('
)) {
    if ($hostSource.Contains($movedDefinition)) {
        throw "Extracted consensus responsibility was copied back into network.py: $movedDefinition"
    }
}

$nativeHookSource = Get-Content -LiteralPath (Join-Path $root 'native\src\hook_dll.cpp') -Raw
foreach ($requiredHeader in @('native_command_codec.hpp', 'native_hook_status.hpp')) {
    if (-not $nativeHookSource.Contains($requiredHeader)) {
        throw "Native hook no longer composes required support header $requiredHeader"
    }
}
foreach ($movedDefinition in @(
    'struct SuppressedLineCommand {',
    'bool DecodeSuppressedLineCommand(',
    'struct HookStatusView {'
)) {
    if ($nativeHookSource.Contains($movedDefinition)) {
        throw "Extracted native responsibility was copied back into hook_dll.cpp: $movedDefinition"
    }
}

Write-Host 'PASS source-size budgets and extracted architecture boundaries'
