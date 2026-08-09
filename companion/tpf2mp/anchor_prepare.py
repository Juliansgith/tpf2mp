"""One-action preparation of a coordinated native-save restore point.

The companion makes both worlds safe to save: it fences new work, rendezvouses
both simulations at pause, orders one checkpoint request at a shared sequence,
and waits for checkpoint consensus.  Once the exact boundary is READY, each
game issues Build 35924's native ``SaveGame`` command under a peer-specific
name; the independent watcher then hashes the stable file and files its ordered
receipt.
"""

from __future__ import annotations

import time
from typing import Any, Mapping

from .protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_action


class AnchorPreparationCoordinator:
    """Host-side state machine behind ``Prepare & Save Restore Point``."""

    PENDING = {"pause-requested", "pausing", "checkpointing"}

    def __init__(self, host: Any) -> None:
        self.host = host
        self.current: dict[str, Any] | None = None
        self.last: dict[str, Any] | None = None

    def before_commit(
        self, action: Mapping[str, Any], origin: str, local_seq: int
    ) -> None:
        """Fence player work while the host is manufacturing a boundary."""

        action_type = str(action.get("type", ""))
        if action_type == "network.checkpoint_request":
            raise ProtocolError("network.checkpoint_request is host-generated")
        active = self.current
        if not active:
            return
        status = str(active.get("status", ""))
        synthetic_pause = action_type == "clock.request" \
            and int(action.get("requestedSpeed", -1)) == 0 \
            and origin == self.host.bridge.peer and local_seq < 0
        if status in self.PENDING and not synthetic_pause:
            raise ProtocolError(
                f"restore point preparation {active['preparationSeq']} is {status}"
            )
        if status not in self.PENDING and not synthetic_pause:
            active["status"] = "superseded"
            active["detail"] = "new ordered work superseded the prepared boundary"
            self.last = dict(active)
            self.current = None

    def observe_ordered(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        """Rebuild or advance the workflow from the durable ordered stream."""

        action = (message.get("payload") or {}).get("action") or {}
        action_type = action.get("type")
        sequence = int(message.get("seq", 0))
        if action_type == "recovery.prepare":
            if self.current and self.current.get("status") in self.PENDING:
                if int(self.current.get("preparationSeq", 0)) == sequence:
                    return
                self.current["status"] = "superseded"
                self.last = dict(self.current)
            self.current = {
                "preparationSeq": sequence,
                "originPeer": str(message.get("origin_peer") or self.host.bridge.peer),
                "status": "pause-requested",
                "checkpointBoundarySeq": None,
                "detail": "waiting for the shared pause",
                "startedAt": time.monotonic(),
            }
            return
        if action_type == "network.checkpoint_request":
            reason = str(action.get("reason", ""))
            self.host._track_checkpoint_boundary(sequence, reason)
            preparation_seq = int(action.get("preparationSeq", 0))
            if not self.current or int(self.current.get("preparationSeq", 0)) != preparation_seq:
                self.current = {
                    "preparationSeq": preparation_seq,
                    "originPeer": self.host.bridge.peer,
                    "startedAt": time.monotonic(),
                }
            self.current.update({
                "status": "checkpointing",
                "checkpointBoundarySeq": sequence,
                "detail": "waiting for both checkpoint exports",
            })
            return
        if action_type == "network.checkpoint_outcome" and self.current:
            boundary = int(action.get("boundarySeq", 0))
            if boundary != int(self.current.get("checkpointBoundarySeq") or 0):
                return
            self.current["status"] = "converged" if action.get("success") is True else "failed"
            self.current["detail"] = (
                "checkpoint converged; waiting for both games to consume it"
                if action.get("success") is True
                else str(action.get("errorCode") or "checkpoint consensus failed")
            )
            if action.get("success") is not True:
                self.last = dict(self.current)

    def admit_manual_checkpoint(self, payload: Mapping[str, Any]) -> dict[str, Any] | None:
        """Open the legacy two-click manual barrier only at a safe paused tip."""

        if payload.get("reason") != "manual-ui":
            return None
        boundary = int(payload["eventCursor"]["lastCommitSeq"])
        if boundary != self.host.next_seq - 1:
            raise ProtocolError("manual checkpoint does not name the latest ordered sequence")
        if self.current and self.current.get("status") in self.PENDING:
            raise ProtocolError("manual checkpoint conflicts with automatic preparation")
        if not self.host.synchronization.shared_pause_acknowledged():
            raise ProtocolError("manual checkpoint requires an acknowledged shared pause")
        if self.host.anchor._pending_work():
            raise ProtocolError("manual checkpoint arrived while ordered work was pending")
        return self.host._track_checkpoint_boundary(boundary, "manual-ui")

    def _quiescence_reasons(self) -> list[str]:
        reasons: list[str] = []
        if not self.host.synchronization.shared_pause_acknowledged():
            reasons.append("waiting for the shared pause")
        pending = self.host.anchor._pending_work()
        if pending:
            reasons.append(f"waiting for {pending} ordered action(s)")
        reasons.extend(self.host.anchor._health_reasons(0))
        latest = max(0, self.host.next_seq - 1)
        for peer in self.host.required_peers:
            sample = self.host.clock_health.get(peer)
            if isinstance(sample, Mapping) and int(sample.get("lastCommitSeq", -1)) < latest:
                reasons.append(f"{peer} has not consumed preparation sequence {latest}")
        if self.host.session_fault:
            reasons.append("the session faulted during restore point preparation")
        return reasons

    def _emit_checkpoint_request(self, preparation_seq: int) -> dict[str, Any]:
        reason = f"recovery-prepare:{preparation_seq}"
        action = validate_action({
            "type": "network.checkpoint_request",
            "preparationSeq": preparation_seq,
            "reason": reason,
        })
        sequence = self.host.next_seq
        self.host.next_seq += 1
        control = sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.host.bridge.session,
            "seq": sequence,
            "kind": "control",
            "origin_peer": self.host.bridge.peer,
            "tick": 0,
            "payload": {"action": action},
        })
        self.host.audit.append(control)
        self.host.commits[sequence] = control
        self.observe_ordered(control)
        self.host.bridge.write_inbound(control)
        self.host._broadcast(control)
        print(f"restore point preparation {preparation_seq} requested checkpoint {sequence}")
        return control

    def maintain(self) -> bool:
        """Advance without relying on simulation ticks (the world may be paused)."""

        with self.host.order_lock:
            active = self.current
            if not active:
                return False
            status = str(active.get("status", ""))
            if status == "pause-requested":
                active["status"] = "pausing"
                active["detail"] = "rendezvousing both games at pause"
                if not self.host.synchronization.shared_pause_acknowledged():
                    try:
                        ordered = self.host.emit_local_intent({
                            "type": "clock.request", "requestedSpeed": 0,
                        })
                        active["pauseCommitSeq"] = ordered and int(ordered.get("seq", 0))
                    except ProtocolError as exc:
                        active["status"] = "failed"
                        active["detail"] = str(exc)
                        self.last = dict(active)
                return True
            if status == "pausing":
                reasons = self._quiescence_reasons()
                active["detail"] = reasons[0] if reasons else "requesting matching checkpoints"
                if reasons:
                    return False
                self._emit_checkpoint_request(int(active["preparationSeq"]))
                return True
            if status == "checkpointing":
                boundary = int(active.get("checkpointBoundarySeq") or 0)
                tracker = self.host.checkpoint_consensus.get(boundary)
                if tracker and tracker.get("status") == "faulted":
                    active["status"] = "failed"
                    active["detail"] = str(
                        (tracker.get("outcome") or {}).get("errorCode")
                        or "checkpoint consensus failed"
                    )
                    self.last = dict(active)
                    return True
                return False
            if status == "converged" and self.host.anchor.readiness().get("ready") is True:
                active["status"] = "ready"
                active["detail"] = "restore boundary is READY; make the native saves now"
                self.last = dict(active)
                return True
            return False

    def readiness_reasons(self) -> list[str]:
        active = self.current
        if not active:
            return []
        status = str(active.get("status", ""))
        if status in self.PENDING:
            return [f"restore point preparation is {status}: {active.get('detail', '')}".rstrip()]
        if status == "failed":
            return [f"restore point preparation failed: {active.get('detail', 'unknown error')}"]
        return []

    def status(self) -> dict[str, Any]:
        active = self.current or self.last
        if not active:
            return {
                "anchorPreparationStatus": "idle",
                "anchorPreparationSeq": None,
                "anchorPreparationCheckpointSeq": None,
                "anchorPreparationDetail": None,
            }
        return {
            "anchorPreparationStatus": active.get("status"),
            "anchorPreparationSeq": active.get("preparationSeq"),
            "anchorPreparationCheckpointSeq": active.get("checkpointBoundarySeq"),
            "anchorPreparationDetail": active.get("detail"),
        }
