"""One-action preparation of a coordinated native-save restore point.

The companion makes both worlds safe to save: it fences new work, rendezvouses
both simulations at pause, orders one checkpoint request at a shared sequence,
and waits for checkpoint consensus.  At READY, each game issues Build 35924's
native ``SaveGame`` command; the watcher hashes it and files its ordered receipt.
"""

from __future__ import annotations

import time
from typing import Any, Mapping
from .anchor_prepare_checkpoint import AnchorPreparationCheckpoint
from .anchor_prepare_drain import AnchorPreparationDrain
from .anchor_prepare_phase import AnchorPreparationPhase
from .protocol import ProtocolError


class AnchorPreparationCoordinator:
    """Host-side state machine behind ``Prepare & Save Restore Point``."""

    PENDING = {"draining", "pause-requested", "pausing", "checkpointing"}

    def __init__(self, host: Any) -> None:
        self.host = host
        self.checkpoint = AnchorPreparationCheckpoint(host)
        self.drain = AnchorPreparationDrain(host)
        self.phase = AnchorPreparationPhase(host)
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
        internal_clock = action_type == "clock.request" \
            and origin == self.host.bridge.peer and local_seq < 0
        requested_speed = int(action.get("requestedSpeed", -1)) if internal_clock else -1
        synthetic_pause = internal_clock and requested_speed == 0
        synthetic_drain_resume = internal_clock and status == "draining" \
            and requested_speed == int(active.get("resumeSpeed", -1))
        synthetic_phase_probe = self.phase.internal_probe(
            active, action_type, origin, local_seq
        )
        # A save receipt attests the already-prepared boundary; it is not new
        # authored work and AnchorCoordinator deliberately excludes it from
        # readiness's commits-since-boundary check.  Superseding here would
        # leave the same boundary simultaneously READY and "superseded".
        if action_type == "recovery.save_receipt":
            return
        if status in self.PENDING and not (
            synthetic_pause or synthetic_drain_resume or synthetic_phase_probe
        ):
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
            resume_speed = max(
                0,
                int(max(
                    self.host.clock_requested_speed,
                    self.host.clock_effective_speed,
                )),
            )
            # A user may request a restore point while manually paused even
            # though a station round was authored just before the pause.  A
            # short speed-1 drain is the only safe way to let that durable
            # round finish before manufacturing the save boundary.
            if resume_speed == 0 and self.host.anchor._pending_work():
                resume_speed = 1
            self.current = {
                "preparationSeq": sequence,
                "originPeer": str(message.get("origin_peer") or self.host.bridge.peer),
                "status": "draining",
                "checkpointBoundarySeq": None,
                "resumeSpeed": resume_speed,
                "drainRetries": 0,
                "detail": "draining ordered work before the shared pause",
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
        if self.drain.observe_clock(self.current, message, action, sequence):
            return
        if self.phase.observe_ordered(self.current, message, action):
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

    def maintain(self) -> bool:
        """Advance without relying on simulation ticks (the world may be paused)."""

        with self.host.order_lock:
            active = self.current
            if not active:
                return False
            status = str(active.get("status", ""))
            if status in self.PENDING and self.host.session_fault:
                active["status"] = "failed"
                active["detail"] = "the session faulted during restore point preparation"
                self.last = dict(active)
                return True
            if status == "draining":
                handled, changed = self.phase.recovery.maintain(active, self.drain)
                if handled:
                    if active.get("status") == "failed":
                        self.last = dict(active)
                    return changed
                vehicle_pending = self.drain.vehicle_pending()
                pending = self.host.anchor._pending_work()
                if self.host.synchronization.shared_pause_acknowledged() \
                        and vehicle_pending > 0 and pending == vehicle_pending:
                    return self.drain.resume(active)
                reasons = self.drain.reasons()
                active["detail"] = reasons[0] if reasons \
                    else "ordered work drained; requesting the shared pause"
                if reasons:
                    if self.drain.can_pause_after_completed_resume(active, reasons):
                        active["detail"] = (
                            "running health became stale after the completed drain; "
                            "requesting a telemetry-failsafe pause"
                        )
                        return self.drain.begin_pause(active)
                    return False
                return self.drain.begin_pause(active)
            if status == "pause-requested":
                # Backward-compatible recovery of an audit written by the
                # pre-drain coordinator.
                active["status"] = "draining"
                active.setdefault("resumeSpeed", max(
                    0, int(max(self.host.clock_requested_speed, self.host.clock_effective_speed)),
                ))
                return True
            if status == "pausing":
                vehicle_pending = self.drain.vehicle_pending()
                pending = self.host.anchor._pending_work()
                if self.host.synchronization.shared_pause_acknowledged() \
                        and vehicle_pending > 0 and pending == vehicle_pending:
                    return self.drain.resume(active)
                if self.host.synchronization.shared_pause_acknowledged() \
                        and pending == 0 and self.drain.pause_skew_requires_resync():
                    return self.drain.resynchronize_pause(active)
                reasons = self.drain.quiescence_reasons()
                active["detail"] = reasons[0] if reasons \
                    else "verifying paused native vehicle route phases"
                if reasons:
                    return False
                handled, changed = self.phase.maintain(active)
                if handled:
                    if active.get("status") == "failed":
                        self.last = dict(active)
                    return changed
                self.checkpoint.emit(
                    int(active["preparationSeq"]), active.get("vehiclePhaseProof"),
                )
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
            if status == "converged":
                if self.host.anchor.readiness().get("ready") is True:
                    active["status"] = "ready"
                    active["detail"] = "restore boundary is READY; make the native saves now"
                    self.last = dict(active)
                    return True
                # A delayed/off-screen native resume can be consumed only
                # after a checkpoint has already converged. Matching authored
                # digests do not include engine time, so supersede that
                # candidate boundary and rendezvous before checkpointing again.
                if self.host.anchor._pending_work() == 0 \
                        and self.drain.pause_skew_requires_resync():
                    active["checkpointBoundarySeq"] = None
                    return self.drain.resynchronize_pause(active)
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
