from __future__ import annotations

import time
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
    checkpoint_counts = host.consensus.status_counts(
        host.checkpoint_consensus, ("pending", "complete", "faulted")
    )
    restore_plan_message = host.restore_plan_exchange.published_message()
    anchor_readiness = host.anchor.readiness()
    receipt_readiness = host.anchor.readiness(receipt=True)
    fault_recovery = host.fault_recovery.assessment()
    automatic_recovery = host.automatic_recovery.status()
    now = time.monotonic()
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
        "pendingProposalProgressEvents": pending_proposal and pending_proposal.get("progressEvents", 0),
        "pendingProposalDeadlineSeconds": pending_proposal and max(
            0.0, float(pending_proposal.get("deadline", now)) - now
        ),
        "pendingOperationSeq": pending_operation and pending_operation.get("commitSeq"),
        "pendingCheckpointSeq": pending_checkpoint and pending_checkpoint.get("boundarySeq"),
        "pendingCheckpointReason": pending_checkpoint and pending_checkpoint.get("reason"),
        "lastAgreedCheckpointSeq": host.last_agreed_checkpoint
        and host.last_agreed_checkpoint.get("boundarySeq"),
        "lastAgreedCheckpointReason": host.last_agreed_checkpoint
        and host.last_agreed_checkpoint.get("reason"),
        "checkpointCounts": checkpoint_counts,
        "sessionFault": host.session_fault,
        "faultRecovery": fault_recovery,
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
        **host.reconnect.status(),
        **host.restore_session.status(),
        **host.anchor.status(anchor_readiness),
        **host.anchor_preparation.status(),
        **automatic_recovery,
        **host.anchor_requests.status(),
        **host.restore_plan_exchange.status(),
        **host.industry_content.status(),
        **host.industry_content_consensus.status(),
    })
    host._broadcast(anchor_state_message(
        host.bridge.session, host.bridge.peer, anchor_readiness,
        host.anchor_preparation.status(), receipt_readiness,
        paused_heartbeat_required=host.clock_effective_speed == 0,
        fault_recovery=fault_recovery,
        automatic_recovery=automatic_recovery["automaticRecovery"],
    ))
    if restore_plan_message:
        host._broadcast(restore_plan_message)
