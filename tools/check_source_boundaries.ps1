[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($ProjectRoot)

$budgets = [ordered]@{
    'tpf2_mp_1\res\config\game_script\tpf2_mp.lua' = 3400
    'tpf2_mp_1\res\scripts\tpf2_mp\economy.lua' = 880
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_costs.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_flow.lua' = 260
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_feeder_access.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_revenue.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_difficulty.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_town_demand.lua' = 210
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_action_runtime.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_line_registration.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_settlement_transaction.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_service_quarantine.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_public_view.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_pending_delivery.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_clock_runtime.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_asset_cost_runtime.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_cost_runtime.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\native_command_authority.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\operation_vehicle_postcondition.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_demo.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_runtime.lua' = 1450
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_collateral_runtime.lua' = 40
    'tpf2_mp_1\res\scripts\tpf2_mp\network_intent_runtime.lua' = 480
    'tpf2_mp_1\res\scripts\tpf2_mp\service_registration_runtime.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\network_followup_queue.lua' = 170
    'tpf2_mp_1\res\scripts\tpf2_mp\network_bridge_consumer.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_runtime.lua' = 360
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_health.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\network_speed_indicator.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_runtime.lua' = 420
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_state.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\native_ownership_projection.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\match_runtime.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\authored_followup_runtime.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\recovery_prepare_runtime.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\recovery_native_save_runtime.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_runtime.lua' = 900
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_clock.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_content_gate.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_town_development.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\operational_capture_runtime.lua' = 220
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_event_runtime.lua' = 1450
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_load_runtime.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_line_command_codec.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_entry_points.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_quarantine.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_network_bootstrap.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_runtime.lua' = 650
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_view.lua' = 600
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_authoritative_text.lua' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_authoritative_lists.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_stock_presentation.lua' = 350
    'companion\tpf2mp\network.py' = 1450
    'companion\tpf2mp\cli.py' = 430
    'companion\tpf2mp\audit_consensus.py' = 180
    'companion\tpf2mp\completion_validation.py' = 150
    'companion\tpf2mp\client.py' = 200
    'companion\tpf2mp\bridge.py' = 200
    'companion\tpf2mp\anchor.py' = 300
    'companion\tpf2mp\anchor_prepare.py' = 260
    'companion\tpf2mp\anchor_io.py' = 300
    'companion\tpf2mp\restore.py' = 400
    'companion\tpf2mp\restore_plan.py' = 180
    'companion\tpf2mp\native_save.py' = 70
    'companion\tpf2mp\session_identity.py' = 80
    'companion\tpf2mp\recovery_receipt_protocol.py' = 70
    'companion\tpf2mp\consensus.py' = 300
    'companion\tpf2mp\synchronization.py' = 700
    'companion\tpf2mp\vehicle_barrier.py' = 390
    'companion\tpf2mp\paused_deadline.py' = 210
    'native\src\hook_dll.cpp' = 1250
    'native\src\native_command_codec.cpp' = 350
    'native\src\native_vehicle_command_codec.cpp' = 180
    'native\src\native_hook_status.cpp' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_codec.lua' = 2400
    'tpf2_mp_1\res\scripts\tpf2_mp\world.lua' = 2080
    'tpf2_mp_1\res\scripts\tpf2_mp\public_snapshot.lua' = 280
    'tpf2_mp_1\res\scripts\tpf2_mp\research_report.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\state_success_normalization.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\world_identity.lua' = 200
    'tpf2_mp_1\res\scripts\tpf2_mp\world_operational_telemetry.lua' = 220
    'tpf2_mp_1\res\scripts\tpf2_mp\world_town_reading.lua' = 220
    'tpf2_mp_1\res\scripts\tpf2_mp\world_station_reading.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\world_line_reading.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\world_industry_reading.lua' = 160
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_registry_sidecar.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_content_runtime.lua' = 360
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_model.lua' = 560
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_runtime.lua' = 190
    'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_runtime.lua' = 140
    'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_witness.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_integration.lua' = 50
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_milestone_runtime.lua' = 20
    'tpf2_mp_1\res\scripts\tpf2_mp\passenger_milestone_runtime.lua' = 50
    'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_followup.lua' = 50
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_revalidation.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_public.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_transport_settlement.lua' = 190
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_transport_validation.lua' = 160
    'tpf2_mp_1\res\scripts\tpf2_mp\restore_session_identity.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_service_binding.lua' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\cargo_presentation.lua' = 520
    'tpf2_mp_1\res\scripts\tpf2_mp\delivery_snapshot.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\diagnostic_log.lua' = 30
    'tpf2_mp_1\res\scripts\tpf2_mp\service_registration_integration.lua' = 60
    'companion\tpf2mp\host_intents.py' = 60
    'companion\tpf2mp\industry_content.py' = 500
    'companion\tpf2mp\freight.py' = 260
    'companion\tpf2mp\freight_protocol.py' = 180
    'companion\tpf2mp\freight_transport.py' = 180
    'companion\tpf2mp\cargo_checkpoint.py' = 230
    'companion\tpf2mp\freight_checkpoint.py' = 220
    'companion\tpf2mp\live_evidence.py' = 300
    'companion\tpf2mp\aboard_witness.py' = 80
    'companion\tpf2mp\aboard_milestone_protocol.py' = 60
    'companion\tpf2mp\freight_live_report.py' = 260
    'companion\tpf2mp\passenger_feeder_live_report.py' = 500
    'companion\tpf2mp\protocol.py' = 1650
    'companion\tpf2mp\line_registration_protocol.py' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\operation_codec.lua' = 680
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_facts.lua' = 480
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_view_reader.lua' = 260
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_merge.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_artifact.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_loader.lua' = 130
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_resource_facts.lua' = 150
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

# Lua's `condition and value or fallback` shorthand cannot represent false or
# nil: the fallback always wins. These forms previously left successful
# checkpoint/recovery/UI records carrying false error text and erased explicit
# native command failures. Keep that class of bug out of shipped Lua.
$luaSources = Get-ChildItem -LiteralPath (Join-Path $root 'tpf2_mp_1') `
    -Recurse -File -Filter '*.lua'
foreach ($file in $luaSources) {
    $source = [IO.File]::ReadAllText($file.FullName)
    if ($source -match '\band\s+nil\b' -or $source -match '\band\s+false\s+or\b') {
        $relative = $file.FullName.Substring($root.Length + 1)
        throw "Unsafe Lua falsey ternary in ${relative}; use an explicit conditional or invert the condition."
    }
}

$entryPoint = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\config\game_script\tpf2_mp.lua') -Raw
$requiredModules = @(
    'tpf2_mp/runtime_config',
    'tpf2_mp/state_schema',
    'tpf2_mp/match_runtime',
    'tpf2_mp/checkpoint_runtime',
    'tpf2_mp/public_snapshot',
    'tpf2_mp/research_report',
    'tpf2_mp/proposal_runtime',
    'tpf2_mp/operation_runtime',
    'tpf2_mp/network_intent_runtime',
    'tpf2_mp/network_clock_runtime',
    'tpf2_mp/authored_followup_runtime',
    'tpf2_mp/recovery_prepare_runtime',
    'tpf2_mp/recovery_native_save_runtime',
    'tpf2_mp/economy_clock_runtime',
    'tpf2_mp/economy_action_runtime',
    'tpf2_mp/economy_settlement_transaction',
    'tpf2_mp/economy_asset_cost_runtime',
    'tpf2_mp/economy_demo',
    'tpf2_mp/network_speed_indicator',
    'tpf2_mp/vehicle_sync_runtime',
    'tpf2_mp/validation_runtime',
    'tpf2_mp/operational_capture_runtime',
    'tpf2_mp/freight_industry_model',
    'tpf2_mp/freight_industry_runtime',
    'tpf2_mp/aboard_milestone_integration',
    'tpf2_mp/cargo_presentation',
    'tpf2_mp/gui_state',
    'tpf2_mp/gui_entry_points',
    'tpf2_mp/gui_capture',
    'tpf2_mp/gui_view',
    'tpf2_mp/gui_load_runtime',
    'tpf2_mp/gui_stock_presentation',
    'tpf2_mp/gui_event_runtime',
    'tpf2_mp/native_hook'
)
foreach ($module in $requiredModules) {
    if (-not $entryPoint.Contains($module)) {
        throw "Game-script entry point no longer composes required module $module"
    }
}
if (-not (Get-Content -LiteralPath (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\state_schema.lua') -Raw).Contains('tpf2_mp/state_success_normalization')) {
    throw 'State schema no longer composes historical successful-record normalization'
}
if (-not (Get-Content -LiteralPath (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\state_schema.lua') -Raw).Contains('tpf2_mp/restore_session_identity')) {
    throw 'State schema no longer composes bounded restore-session identity'
}
if (-not (Get-Content -LiteralPath (Join-Path $projectRoot 'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_runtime.lua') -Raw).Contains('tpf2_mp/freight_industry_revalidation')) {
    throw 'Freight-industry runtime no longer composes its saved-state/content revalidation boundary'
}
$followupSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\network_followup_queue.lua') -Raw
if (-not $followupSource.Contains('tpf2_mp/aboard_milestone_followup')) {
    throw 'Network follow-up queue no longer composes aboard-milestone retry/coalescing.'
}
$milestoneSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_integration.lua') -Raw
foreach ($module in @('tpf2_mp/freight_milestone_runtime',
    'tpf2_mp/passenger_milestone_runtime')) {
    if (-not $milestoneSource.Contains($module)) {
        throw "Aboard milestone integration no longer composes $module"
    }
}
$aboardRuntimeSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\aboard_milestone_runtime.lua') -Raw
if (-not $aboardRuntimeSource.Contains('tpf2_mp/aboard_milestone_witness')) {
    throw 'Aboard milestone runtime no longer composes its strict witness boundary.'
}
$protocolSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\protocol.py') -Raw
if (-not $protocolSource.Contains('from .aboard_milestone_protocol import')) {
    throw 'Companion protocol no longer composes its aboard-milestone wire boundary.'
}
if (-not $protocolSource.Contains('from .recovery_receipt_protocol import')) {
    throw 'Companion protocol no longer composes its recovery-receipt wire boundary.'
}
$restoreSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\restore.py') -Raw
foreach ($module in @('from .native_save import', 'from .restore_plan import')) {
    if (-not $restoreSource.Contains($module)) {
        throw "Restore coordinator no longer composes $module"
    }
}
foreach ($report in @('freight_live_report.py', 'passenger_feeder_live_report.py')) {
    $reportSource = Get-Content -LiteralPath (Join-Path $root "companion\tpf2mp\$report") -Raw
    if (-not $reportSource.Contains('from .aboard_witness import')) {
        throw "$report no longer composes the shared checkpoint witness verifier."
    }
}
$freightModelSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_model.lua') -Raw
foreach ($module in @('tpf2_mp/freight_transport_settlement',
    'tpf2_mp/freight_transport_validation', 'tpf2_mp/freight_industry_public')) {
    if (-not $freightModelSource.Contains($module)) {
        throw "Freight-industry model no longer composes $module"
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
    'local function sampleOperationalCapture',
    'local function operationalAccountSnapshot',
    'local function operationModelNames',
    'local gui = {'
)) {
    if ($entryPoint.Contains($movedDefinition)) {
        throw "Extracted responsibility was copied back into the game-script entry point: $movedDefinition"
    }
}
$vehicleSyncSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_runtime.lua') -Raw
if (-not $vehicleSyncSource.Contains('require "tpf2_mp/vehicle_sync_state"')) {
    throw 'Vehicle runtime no longer composes the vehicle synchronization state boundary.'
}
if (-not $vehicleSyncSource.Contains('require "tpf2_mp/vehicle_sync_passengers"')) {
    throw 'Vehicle runtime no longer composes the atomic passenger/cargo presentation boundary.'
}
$operationRuntimeSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\operation_runtime.lua') -Raw
if (-not $operationRuntimeSource.Contains('require "tpf2_mp/operation_vehicle_postcondition"')) {
    throw 'Operation runtime no longer composes the vehicle physical-postcondition boundary.'
}
$worldSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\world.lua') -Raw
if (-not $worldSource.Contains('require "tpf2_mp/native_ownership_projection"')) {
    throw 'World runtime no longer composes the native ownership projection boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_identity"')) {
    throw 'World runtime no longer composes the collision-safe identity boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_operational_telemetry"')) {
    throw 'World runtime no longer composes the operational telemetry boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_town_reading"')) {
    throw 'World runtime no longer composes the town reading boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_station_reading"')) {
    throw 'World runtime no longer composes the station association reading boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_line_reading"')) {
    throw 'World runtime no longer composes the line transport-mode reading boundary.'
}
if (-not $worldSource.Contains('require "tpf2_mp/world_industry_reading"')) {
    throw 'World runtime no longer composes the evaluated industry-resource reading boundary.'
}
$economySource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\economy.lua') -Raw
foreach ($requiredModule in @('economy_difficulty', 'economy_town_demand')) {
    if (-not $economySource.Contains($requiredModule)) {
        throw "Economy runtime no longer composes $requiredModule."
    }
}
$economyActionSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\economy_action_runtime.lua') -Raw
if (-not $economyActionSource.Contains('require "tpf2_mp/economy_service_quarantine"')) {
    throw 'Economy action runtime no longer composes the ordered service-quarantine boundary.'
}
# Town size for the economy must stay policy-independent. Native land-use
# capacity is scaled by the crowd policy, so reading it into gravity demand
# lets a cosmetic setting rescale the match economy.
$corridorSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\corridor_binding.lua') -Raw
if (-not $corridorSource.Contains('require "tpf2_mp/vehicle_resource_facts"')) {
    throw 'Corridor binding no longer composes the portable vehicle-resource facts boundary.'
}
if (-not $corridorSource.Contains('require "tpf2_mp/freight_service_binding"')) {
    throw 'Corridor binding no longer composes the canonical freight-service boundary.'
}
if ($corridorSource -match 'local\s+capacity[AB]\s*=\s*townCapacity\(') {
    throw 'Corridor binding reads presentation-scaled town capacity into gravity demand.'
}
$validationSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\validation_runtime.lua') -Raw
if (-not $validationSource.Contains('require "tpf2_mp/validation_town_development"')) {
    throw 'Validation runtime no longer composes the town-development validation boundary.'
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
if (-not $hostSource.Contains('from .anchor_io import AnchorRequestStore')) {
    throw 'Companion host no longer composes the native-save request boundary.'
}
if (-not $hostSource.Contains('from .anchor_prepare import AnchorPreparationCoordinator')) {
    throw 'Companion host no longer composes the one-action anchor preparation boundary.'
}
$clientSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\client.py') -Raw
if (-not $clientSource.Contains('from .anchor_io import AnchorRequestStore')) {
    throw 'Companion client no longer composes the native-save request boundary.'
}
$intentSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\network_intent_runtime.lua') -Raw
foreach ($requiredModule in @('network_followup_queue', 'network_bridge_consumer')) {
    if (-not $intentSource.Contains($requiredModule)) {
        throw "Network intent runtime no longer composes $requiredModule."
    }
}
$syncSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\synchronization.py') -Raw
if (-not $syncSource.Contains('from .vehicle_barrier import VehicleStationBarrier')) {
    throw 'Clock coordinator no longer composes the vehicle-station barrier boundary.'
}
$vehicleBarrierSource = Get-Content -LiteralPath `
    (Join-Path $root 'companion\tpf2mp\vehicle_barrier.py') -Raw
if (-not $vehicleBarrierSource.Contains('from .paused_deadline import PausedDeadlineRegistry')) {
    throw 'Vehicle-station barrier no longer composes pause-aware deadline bookkeeping.'
}
if (-not $syncSource.Contains('from .paused_deadline import SharedPauseProtection')) {
    throw 'Clock coordinator no longer composes shared-pause timeout protection.'
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
$nativeCmakeSource = Get-Content -LiteralPath (Join-Path $root 'native\CMakeLists.txt') -Raw
foreach ($requiredSource in @('src/native_command_codec.cpp', 'src/native_vehicle_command_codec.cpp')) {
    if (-not $nativeCmakeSource.Contains($requiredSource)) {
        throw "Native hook support library no longer composes required source $requiredSource"
    }
}
foreach ($movedDefinition in @(
    'struct SuppressedLineCommand {',
    'bool DecodeSuppressedLineCommand(',
    'bool DecodeSuppressedVehicleCommand(',
    'struct HookStatusView {'
)) {
    if ($nativeHookSource.Contains($movedDefinition)) {
        throw "Extracted native responsibility was copied back into hook_dll.cpp: $movedDefinition"
    }
}

Write-Host 'PASS source-size budgets and extracted architecture boundaries'
