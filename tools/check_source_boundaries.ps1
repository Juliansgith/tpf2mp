[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'
if (-not $ProjectRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
$root = [IO.Path]::GetFullPath($ProjectRoot)

$budgets = [ordered]@{
    'tools\recovery_plan_common.ps1' = 120
    'tools\recovery_save_common.ps1' = 120
    'tools\save_recovery_via_ui.ps1' = 240
    'tpf2_mp_1\res\config\game_script\tpf2_mp.lua' = 3400
    'tpf2_mp_1\res\scripts\tpf2_mp\economy.lua' = 880
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_costs.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_flow.lua' = 260
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_allocation.lua' = 110
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_feeder_access.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_revenue.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_difficulty.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_town_demand.lua' = 210
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_action_runtime.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\state_retention.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_line_registration.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_settlement_transaction.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_service_quarantine.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_public_view.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_pending_delivery.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_clock_runtime.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_asset_cost_runtime.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_cost_runtime.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\native_command_authority.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\native_hook.lua' = 290
    'tpf2_mp_1\res\scripts\tpf2_mp\operation_vehicle_postcondition.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\operation_rejection_proof.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\network_operation_outcome.lua' = 170
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_demo.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_runtime.lua' = 1451
    'tpf2_mp_1\res\scripts\tpf2_mp\active_record_index.lua' = 45
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_collateral_runtime.lua' = 40
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_derived_station_runtime.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\network_finance_housekeeping.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\network_intent_runtime.lua' = 480
    'tpf2_mp_1\res\scripts\tpf2_mp\network_origin_capture_runtime.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\network_busy_rejection.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\service_registration_runtime.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\network_followup_queue.lua' = 170
    'tpf2_mp_1\res\scripts\tpf2_mp\network_bridge_consumer.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_runtime.lua' = 360
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_health.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\network_speed_indicator.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_runtime.lua' = 420
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_release_runtime.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_sync_state.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\native_ownership_projection.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\match_runtime.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\authored_followup_runtime.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\recovery_prepare_runtime.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\fault_recovery_runtime.lua' = 220
    'tpf2_mp_1\res\scripts\tpf2_mp\recovery_native_save_runtime.lua' = 170
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_runtime.lua' = 900
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_station_proposal.lua' = 160
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_clock.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_content_gate.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\validation_town_development.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\operational_capture_runtime.lua' = 220
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_event_runtime.lua' = 1450
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_build_capture_runtime.lua' = 340
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_build_correlation.lua' = 340
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_build_gate_sampler.lua' = 110
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_load_runtime.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_line_command_codec.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_entry_points.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_quarantine.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_construction_submission.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_network_bootstrap.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_runtime.lua' = 652
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_replay_work_index.lua' = 40
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_view.lua' = 600
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_fault_recovery.lua' = 40
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_authoritative_text.lua' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_station_access_text.lua' = 50
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_authoritative_lists.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_stock_presentation.lua' = 350
    'companion\tpf2mp\network.py' = 1460
    'companion\tpf2mp\fault_recovery.py' = 270
    'companion\tpf2mp\fault_recovery_evidence.py' = 130
    'companion\tpf2mp\fault_recovery_protocol.py' = 60
    'companion\tpf2mp\fault_recovery_operation_protocol.py' = 50
    'companion\tpf2mp\fault_recovery_audit.py' = 80
    'companion\tpf2mp\cli.py' = 430
    'companion\tpf2mp\relay_cli.py' = 180
    'companion\tpf2mp\relay_api.py' = 280
    'companion\tpf2mp\relay_tunnel.py' = 420
    'companion\tpf2mp\relay_diagnostics.py' = 230
    'companion\tpf2mp\diagnostic_redaction.py' = 100
    'companion\tpf2mp\save_sync.py' = 600
    'companion\tpf2mp\audit_consensus.py' = 180
    'companion\tpf2mp\audit_operation_consensus.py' = 130
    'companion\tpf2mp\operation_rejection.py' = 80
    'companion\tpf2mp\operation_consensus.py' = 120
    'companion\tpf2mp\completion_validation.py' = 150
    'companion\tpf2mp\client.py' = 200
    'companion\tpf2mp\bridge.py' = 200
    'companion\tpf2mp\commit_index.py' = 70
    'companion\tpf2mp\anchor.py' = 300
    'companion\tpf2mp\anchor_history.py' = 100
    'companion\tpf2mp\anchor_prepare.py' = 260
    'companion\tpf2mp\anchor_prepare_checkpoint.py' = 80
    'companion\tpf2mp\anchor_prepare_phase.py' = 180
    'companion\tpf2mp\anchor_prepare_phase_recovery.py' = 140
    'companion\tpf2mp\anchor_io.py' = 320
    'companion\tpf2mp\json_file_index.py' = 70
    'companion\tpf2mp\restore.py' = 400
    'companion\tpf2mp\restore_plan.py' = 180
    'companion\tpf2mp\native_save.py' = 70
    'companion\tpf2mp\session_identity.py' = 80
    'companion\tpf2mp\restore_plan_exchange.py' = 120
    'companion\tpf2mp\local_restore.py' = 150
    'tools\run_latest_local_restore_acceptance.ps1' = 120
    'tools\start_relay_network_session.ps1' = 300
    'tools\relay_diagnostic_process.ps1' = 180
    'tools\relay_port_common.ps1' = 60
    'tools\new_relay_session.ps1' = 70
    'tools\accept_relay_invite.ps1' = 60
    'tools\sync_starting_save.ps1' = 120
    'tools\launcher_worker_result.ps1' = 300
    'tools\launcher_update_controller.ps1' = 300
    'tools\network_common.ps1' = 600
    'tools\multiplayer_launcher.ps1' = 1150
    'tools\start_network_session.ps1' = 620
    'tools\network_session_retry_cleanup.ps1' = 120
    'tools\stop_network_session.ps1' = 340
    'tools\session_lifecycle.ps1' = 180
    'tools\watch_network_session_lifecycle.ps1' = 120
    'tools\ensure_paused_network_wake.ps1' = 120
    'tools\automatic_restore_capture.ps1' = 150
    'tools\run_fresh_local_restore_cycle.ps1' = 150
    'tools\analyze_alpha_live_evidence.ps1' = 100
    'tools\run_alpha_live_acceptance.ps1' = 70
    'tools\update_common.ps1' = 220
    'tools\update_release.ps1' = 260
    'tools\github_release_common.ps1' = 80
    'tools\publish_github_release.ps1' = 180
    'tools\installed_entrypoint.ps1' = 70
    'companion\tpf2mp\recovery_receipt_protocol.py' = 70
    'companion\tpf2mp\consensus.py' = 300
    'companion\tpf2mp\consensus_registry_index.py' = 80
    'companion\tpf2mp\synchronization.py' = 700
    'companion\tpf2mp\vehicle_barrier.py' = 390
    'companion\tpf2mp\paused_deadline.py' = 210
    'native\src\hook_dll.cpp' = 1320
    'native\src\native_build_correlation.cpp' = 100
    'tools\verify_build_transition_gate.ps1' = 180
    'native\src\native_async_bridge.cpp' = 450
    'native\src\native_command_codec.cpp' = 350
    'native\src\native_vehicle_command_codec.cpp' = 180
    'native\src\native_hook_status.cpp' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_codec.lua' = 2400
    'tpf2_mp_1\res\scripts\tpf2_mp\world.lua' = 2080
    'tpf2_mp_1\res\scripts\tpf2_mp\world_vehicle_restore_phase.lua' = 110
    'tpf2_mp_1\res\scripts\tpf2_mp\public_snapshot.lua' = 280
    'tpf2_mp_1\res\scripts\tpf2_mp\capture_public_view.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\performance_runtime.lua' = 130
    'tpf2_mp_1\res\scripts\tpf2_mp\network_pump_runtime.lua' = 130
    'tpf2_mp_1\res\scripts\tpf2_mp\network_clock_heartbeat.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\native_observation_telemetry.lua' = 70
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
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_industry_model.lua' = 570
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
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_transport_retirement.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_transport_validation.lua' = 165
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_transport_history.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_path_pin.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\restore_session_identity.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\freight_service_binding.lua' = 300
    'tpf2_mp_1\res\scripts\tpf2_mp\cargo_presentation.lua' = 520
    'tpf2_mp_1\res\scripts\tpf2_mp\cargo_presentation_projection.lua' = 230
    'tpf2_mp_1\res\scripts\tpf2_mp\multihop_network.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\multihop_passenger.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\multihop_cargo.lua' = 230
    'tpf2_mp_1\res\scripts\tpf2_mp\transport_network_graph.lua' = 160
    'tpf2_mp_1\res\scripts\tpf2_mp\resource_compatibility.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_transport_manager.lua' = 190
    'tpf2_mp_1\res\scripts\tpf2_mp\alpha_readiness.lua' = 180
    'tpf2_mp_1\res\scripts\tpf2_mp\delivery_snapshot.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\diagnostic_log.lua' = 30
    'tpf2_mp_1\res\scripts\tpf2_mp\service_registration_integration.lua' = 60
    'companion\tpf2mp\host_intents.py' = 60
    'companion\tpf2mp\anchor_state.py' = 120
    'companion\tpf2mp\industry_content.py' = 500
    'companion\tpf2mp\freight.py' = 260
    'companion\tpf2mp\freight_protocol.py' = 180
    'companion\tpf2mp\freight_transport.py' = 180
    'companion\tpf2mp\cargo_checkpoint.py' = 235
    'companion\tpf2mp\cargo_transfer_checkpoint.py' = 80
    'companion\tpf2mp\freight_checkpoint.py' = 220
    'companion\tpf2mp\live_evidence.py' = 300
    'companion\tpf2mp\aboard_witness.py' = 80
    'companion\tpf2mp\aboard_milestone_protocol.py' = 60
    'companion\tpf2mp\freight_live_report.py' = 260
    'companion\tpf2mp\passenger_feeder_live_report.py' = 500
    'companion\tpf2mp\protocol.py' = 1650
    'companion\tpf2mp\freight_action_protocol.py' = 130
    'companion\tpf2mp\transport_network.py' = 430
    'companion\tpf2mp\reconnect.py' = 210
    'companion\tpf2mp\peer_session.py' = 190
    'companion\tpf2mp\client_session.py' = 180
    'companion\tpf2mp\alpha_acceptance.py' = 300
    'companion\tpf2mp\vehicle_phase_proof.py' = 60
    'companion\tpf2mp\mobility_telemetry.py' = 110
    'companion\tpf2mp\line_registration_protocol.py' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\operation_codec.lua' = 680
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_facts.lua' = 480
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_view_reader.lua' = 260
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_merge.lua' = 120
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_artifact.lua' = 100
    'tpf2_mp_1\res\scripts\tpf2_mp\industry_resource_loader.lua' = 130
    'tpf2_mp_1\res\scripts\tpf2_mp\vehicle_resource_facts.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\engine_background_runtime.lua' = 70
    'tpf2_mp_1\res\scripts\tpf2_mp\economy_clock_policy.lua' = 30
    'tpf2_mp_1\res\scripts\tpf2_mp\proposal_work_scheduler.lua' = 30
    'tpf2_mp_1\res\scripts\tpf2_mp\construction_verification_runtime.lua' = 210
    'tpf2_mp_1\res\scripts\tpf2_mp\construction_delta_attestation.lua' = 170
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_proposal_result_capture.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\construction_output_order.lua' = 60
    'tpf2_mp_1\res\scripts\tpf2_mp\construction_proposal_materializer.lua' = 150
    'tpf2_mp_1\res\scripts\tpf2_mp\construction_replay_state.lua' = 80
    'tpf2_mp_1\res\scripts\tpf2_mp\gui_native_capture_scheduler.lua' = 90
    'tpf2_mp_1\res\scripts\tpf2_mp\checkpoint_retention.lua' = 50
    'tpf2_mp_1\res\scripts\tpf2_mp\network_bootstrap_policy.lua' = 30
    'tpf2_mp_1\res\scripts\tpf2_mp\network_pump_errors.lua' = 30
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
$guiEventRuntime = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\gui_event_runtime.lua') -Raw
$guiCapture = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\gui_capture.lua') -Raw
$guiBuildRuntime = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\gui_build_capture_runtime.lua') -Raw
$nativeHookSource = Get-Content -LiteralPath `
    (Join-Path $root 'native\src\hook_dll.cpp') -Raw
foreach ($correlationBoundary in @(
    'guiBuildCaptureRuntimeModule.new',
    'buildCorrelation.validateApply',
    'gui.invalidateBuildCorrelation',
    'context.constructionPlacement'
)) {
    if (-not $guiEventRuntime.Contains($correlationBoundary)) {
        throw "Generation-bound GUI build boundary is missing: $correlationBoundary"
    }
}
foreach ($captureBoundary in @(
    'local result = util.deepCopy(snapshot)',
    'walk(result, 0)',
    'return result'
)) {
    if (-not $guiCapture.Contains($captureBoundary)) {
        throw "Immutable construction-cache boundary is missing: $captureBoundary"
    }
}
if ($guiEventRuntime.Contains('gui.lastConstructionPreviewSnapshot = rebased')) {
    throw 'Click-time construction rebase regressed to mutating/replacing the cached template.'
}
foreach ($nativeCorrelationBoundary in @(
    'tpf2mp_native_arm_build_correlation',
    'tpf2mp_native_take_suppressed_build',
    'g_suppressed_builds.Capture',
    'tpf2mp native hook 0.19.0'
)) {
    if (-not $nativeHookSource.Contains($nativeCorrelationBoundary)) {
        throw "Native BuildProposal correlation boundary is missing: $nativeCorrelationBoundary"
    }
}
foreach ($failClosedBoundary in @(
    'generation was replayed or reordered',
    'crossed correlation boundaries',
    'correlation.validatePending',
    'eventError ~= "unavailable"'
)) {
    if (-not $guiBuildRuntime.Contains($failClosedBoundary)) {
        throw "Fail-closed build-correlation boundary is missing: $failClosedBoundary"
    }
}
$menuBootstrap = Get-Content -LiteralPath `
    (Join-Path $root 'tools\multiplayer_menu_bootstrap.lua') -Raw
if ($menuBootstrap.Contains('networkPumpCount >= 30')) {
    throw 'Paused launcher heartbeat regressed to a finite startup burst.'
}
foreach ($pausedHeartbeatBoundary in @(
    'launcherHeartbeat = true',
    'if startClicked then pumpPausedNetwork() end',
    'local ready = nativeIsReady or markerReady',
    'exists(root .. "/launcher/start-clicked")',
    'network-pump-generation'
)) {
    if (-not $menuBootstrap.Contains($pausedHeartbeatBoundary)) {
        throw "Persistent paused launcher heartbeat boundary is missing: $pausedHeartbeatBoundary"
    }
}
$pausedWakeScript = Get-Content -LiteralPath `
    (Join-Path $root 'tools\ensure_paused_network_wake.ps1') -Raw
if (-not $pausedWakeScript.Contains('Request-Tpf2mpPersistentPausedPump')) {
    throw 'Paused-network startup no longer rearms and verifies its persistent menu pump.'
}
foreach ($launcherPath in @('tools\run_localhost_live_validation.ps1', 'tools\start_network_session.ps1')) {
    $launcherSource = Get-Content -LiteralPath (Join-Path $root $launcherPath) -Raw
    if (-not $launcherSource.Contains('-RequirePersistentMenuPump')) {
        throw "$launcherPath no longer fails closed when its persistent paused-world pump is unavailable."
    }
}
$liveLauncher = Get-Content -LiteralPath `
    (Join-Path $root 'tools\run_localhost_live_validation.ps1') -Raw
foreach ($loadedSaveHandoffBoundary in @(
    'function Suspend-LoadedWorldForPeerHandoff',
    'Suspend-LoadedWorldForPeerHandoff $GameProcess $Peer',
    'function Release-LoadedWorldHandoffPauses',
    'after both persistent pumps were armed'
)) {
    if (-not $liveLauncher.Contains($loadedSaveHandoffBoundary)) {
        throw "Loaded-save sequential handoff boundary is missing: $loadedSaveHandoffBoundary"
    }
}
if (-not $entryPoint.Contains('if not launcherHeartbeat then publishSnapshot() end')) {
    throw 'Launcher heartbeat no longer bypasses expensive GUI snapshot publication.'
}
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
    'tpf2_mp/network_pump_runtime',
    'tpf2_mp/performance_runtime',
    'tpf2_mp/network_clock_runtime',
    'tpf2_mp/authored_followup_runtime',
    'tpf2_mp/recovery_prepare_runtime',
    'tpf2_mp/fault_recovery_runtime',
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
    'tpf2_mp/native_hook',
    'tpf2_mp/native_observation_telemetry'
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
if (-not $hostSource.Contains('FaultRecoveryCoordinator')) {
    throw 'Commit host no longer composes fail-closed in-place fault recovery.'
}
$guiViewSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\gui_view.lua') -Raw
if (-not $guiViewSource.Contains('tpf2_mp/gui_fault_recovery')) {
    throw 'Multiplayer panel no longer exposes fault-recovery readiness.'
}
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
if (-not $hostSource.Contains('from .restore_plan_exchange import RestorePlanExchange')) {
    throw 'Companion host no longer composes verified restore-plan exchange.'
}
$clientSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\client.py') -Raw
if (-not $clientSource.Contains('from .anchor_io import AnchorRequestStore')) {
    throw 'Companion client no longer composes the native-save request boundary.'
}
if (-not $clientSource.Contains('from .restore_plan_exchange import RestorePlanExchange')) {
    throw 'Companion client no longer composes verified restore-plan exchange.'
}
$cliSource = Get-Content -LiteralPath (Join-Path $root 'companion\tpf2mp\cli.py') -Raw
if (-not $cliSource.Contains('from .local_restore import latest_local_restore')) {
    throw 'Companion CLI no longer composes verified local restore discovery.'
}
$launcherSource = Get-Content -LiteralPath (Join-Path $root 'tools\multiplayer_launcher.ps1') -Raw
if (-not $launcherSource.Contains(
        'Get-Tpf2mpLatestLocalRestore -BundleRoot $bundle -Peer $peer')) {
    throw 'Two-computer launcher no longer discovers its role-specific restore archive.'
}
$watcherSource = Get-Content -LiteralPath (Join-Path $root 'tools\watch_recovery_saves.ps1') -Raw
if (-not $watcherSource.Contains(". (Join-Path `$PSScriptRoot 'recovery_plan_common.ps1')")) {
    throw 'Recovery watcher no longer composes its verified plan handoff boundary.'
}
$intentSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\network_intent_runtime.lua') -Raw
foreach ($requiredModule in @(
    'network_followup_queue', 'network_bridge_consumer', 'network_origin_capture_runtime'
)) {
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
foreach ($requiredHeader in @('native_command_codec.hpp', 'native_hook_status.hpp',
    'native_async_bridge.hpp')) {
    if (-not $nativeHookSource.Contains($requiredHeader)) {
        throw "Native hook no longer composes required support header $requiredHeader"
    }
}
$nativeCmakeSource = Get-Content -LiteralPath (Join-Path $root 'native\CMakeLists.txt') -Raw
foreach ($requiredSource in @('src/native_command_codec.cpp', 'src/native_vehicle_command_codec.cpp',
    'src/native_async_bridge.cpp')) {
    if (-not $nativeCmakeSource.Contains($requiredSource)) {
        throw "Native hook support library no longer composes required source $requiredSource"
    }
}
$publicSnapshotSource = Get-Content -LiteralPath `
    (Join-Path $root 'tpf2_mp_1\res\scripts\tpf2_mp\public_snapshot.lua') -Raw
if (-not $publicSnapshotSource.Contains('require "tpf2_mp/capture_public_view"')) {
    throw 'Public snapshot no longer composes its bounded capture projection.'
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
