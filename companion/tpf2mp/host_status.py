from __future__ import annotations

from typing import Any

from .anchor_io import anchor_state_message


def write_host_status(host: Any, status: str | None = None) -> None:
    if status is not None:
        host.status = status
    with host.peers_lock:
        connected = sorted(host.peers)
    pending_proposal = host._pending_proposal()
    pending_prepare = host._pending_prepare()
    pending_operation = host._pending_operation()
    pending_checkpoint = host._pending_checkpoint()
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
        "pendingProposalPrepareSeq": pending_prepare and pending_prepare.get("prepareSeq"),
        "pendingProposalSeq": pending_proposal and pending_proposal.get("commitSeq"),
        "pendingOperationSeq": pending_operation and pending_operation.get("commitSeq"),
        "pendingCheckpointSeq": pending_checkpoint and pending_checkpoint.get("boundarySeq"),
        "lastAgreedCheckpointSeq": host.last_agreed_checkpoint
        and host.last_agreed_checkpoint.get("boundarySeq"),
        "sessionFault": host.session_fault,
        "lastError": host.last_error,
        "matchFingerprint": host.match_fingerprint,
        "mobilityOutcomes": dict(host.mobility_outcomes),
        "vehicleLifecycleOutcomes": dict(host.vehicle_lifecycle_outcomes),
        "vehiclePhaseOutcomes": dict(host.vehicle_phase_outcomes),
        "vehiclePhaseDivergenceStreak": host.vehicle_phase_divergence_streak,
        "vehiclePhaseState": host.vehicle_phase_state,
        **host.synchronization.status(),
        **host.restore_session.status(),
        **host.anchor.status(),
        **host.anchor_preparation.status(),
        **host.anchor_requests.status(),
    })
    host._broadcast(anchor_state_message(
        host.bridge.session, host.bridge.peer, host.anchor.readiness(),
        host.anchor_preparation.status(),
    ))
