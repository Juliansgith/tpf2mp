from __future__ import annotations

from typing import Any

from .anchor_state import anchor_state_message


def write_host_status(host: Any, status: str | None = None) -> None:
    if status is not None:
        host.status = status
    with host.peers_lock:
        connected = sorted(host.peers)
    pending_proposal = host._pending_proposal()
    pending_prepare = host._pending_prepare()
    pending_operation = host._pending_operation()
    pending_checkpoint = host._pending_checkpoint()
    checkpoint_counts = {"pending": 0, "complete": 0, "faulted": 0}
    for tracker in host.checkpoint_consensus.values():
        tracker_status = str(tracker.get("status", "pending"))
        if tracker_status in checkpoint_counts:
            checkpoint_counts[tracker_status] += 1
    restore_plan_message = host.restore_plan_exchange.published_message()
    receipt_readiness = host.anchor.readiness(receipt=True)
    host.bridge.write_status({
        "role": "host",
        "status": host.status,
        "listening": host.status == "running",
        "connected": all(
            peer == host.bridge.peer or peer in connected for peer in host.required_peers
        ),
        "bind": host.bind,
        "port": host.port,
        "connectedPeers": connected,
        "requiredPeers": list(host.required_peers),
        "nextCommitSeq": host.next_seq,
        "outboxCursor": host.bridge.outbox_cursor,
        "outboxPrunedThrough": host.bridge.outbox_pruned_through,
        "outboxEphemeralRetention": host.bridge.outbox_ephemeral_retention,
        "pendingProposalPrepareSeq": pending_prepare and pending_prepare.get("prepareSeq"),
        "pendingProposalSeq": pending_proposal and pending_proposal.get("commitSeq"),
        "pendingOperationSeq": pending_operation and pending_operation.get("commitSeq"),
        "pendingCheckpointSeq": pending_checkpoint and pending_checkpoint.get("boundarySeq"),
        "pendingCheckpointReason": pending_checkpoint and pending_checkpoint.get("reason"),
        "lastAgreedCheckpointSeq": host.last_agreed_checkpoint
        and host.last_agreed_checkpoint.get("boundarySeq"),
        "lastAgreedCheckpointReason": host.last_agreed_checkpoint
        and host.last_agreed_checkpoint.get("reason"),
        "checkpointCounts": checkpoint_counts,
        "sessionFault": host.session_fault,
        "lastError": host.last_error,
        "auditAppendRetries": host.audit.append_retries,
        "auditReadRetries": host.audit.read_retries,
        "auditFaulted": host.audit_failure.is_set(),
        "clockHealthAuditIntervalSeconds": 10,
        "clockHealthSamplesAudited": host.clock_health_audited,
        "clockHealthSamplesNotAudited": host.clock_health_not_audited,
        "pausedHeartbeatRequired": host.clock_effective_speed == 0,
        "matchFingerprint": host.match_fingerprint,
        "anchorReceiptReady": receipt_readiness["ready"],
        "anchorReceiptReasons": receipt_readiness["reasons"],
        "mobilityOutcomes": dict(host.mobility_outcomes),
        "vehicleLifecycleOutcomes": dict(host.vehicle_lifecycle_outcomes),
        "vehiclePhaseOutcomes": dict(host.vehicle_phase_outcomes),
        "vehicleRestoreSafety": dict(host.vehicle_restore_safety),
        "vehiclePhaseDivergenceStreak": host.vehicle_phase_divergence_streak,
        "vehiclePhaseState": host.vehicle_phase_state,
        **host.synchronization.status(),
        **host.restore_session.status(),
        **host.anchor.status(),
        **host.anchor_preparation.status(),
        **host.anchor_requests.status(),
        **host.restore_plan_exchange.status(),
        **host.industry_content.status(),
        **host.industry_content_consensus.status(),
    })
    host._broadcast(anchor_state_message(
        host.bridge.session, host.bridge.peer, host.anchor.readiness(),
        host.anchor_preparation.status(), receipt_readiness,
        paused_heartbeat_required=host.clock_effective_speed == 0,
    ))
    if restore_plan_message:
        host._broadcast(restore_plan_message)
