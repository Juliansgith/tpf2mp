"""Periodic host-authored restore points for ordinary multiplayer sessions."""

from __future__ import annotations

import time
from typing import Any, Callable, Mapping

from .automatic_recovery_actions import emit_action
from .automatic_recovery_restart import adopt_recovered_preparation
from .automatic_recovery_state import status_projection


class AutomaticRecoveryScheduler:
    """Request, bound, and retire explicit recovery preparations.

    A normal checkpoint is never promoted.  The scheduler orders the same
    ``recovery.prepare`` workflow as the manual button, waits for both signed
    save receipts, then restores the speed that was active before preparation.
    """

    FINALIZE_GRACE_SECONDS = 5.0
    RETRY_SECONDS = 60.0

    def __init__(
        self,
        host: Any,
        interval_seconds: float = 15 * 60,
        timeout_seconds: float = 3 * 60,
        *,
        monotonic: Callable[[], float] = time.monotonic,
        wall_time: Callable[[], float] = time.time,
    ) -> None:
        self.host = host
        self.interval_seconds = max(0.0, float(interval_seconds))
        self.timeout_seconds = max(30.0, float(timeout_seconds))
        self.monotonic = monotonic
        self.wall_time = wall_time
        now = self.monotonic()
        points = self.host.anchor.restorable()
        self.last_boundary = max(points, default=0)
        self.last_completed_at_unix: int | None = self._receipt_time(self.last_boundary)
        elapsed = max(
            0.0,
            self.wall_time() - self.last_completed_at_unix,
        ) if self.last_completed_at_unix is not None else 0.0
        self.next_due_at = now + max(0.0, self.interval_seconds - elapsed)
        self.preparation_seq: int | None = None
        self.started_at: float | None = None
        self.receipts_observed_at: float | None = None
        self.resume_speed = 0
        self.state = "scheduled" if self.enabled else "disabled"
        self.last_error: str | None = None
        self.attempts, self.next_cancel_at = 0, None
        adopt_recovered_preparation(
            self, self.host.anchor_preparation.current, points, now,
        )

    @property
    def enabled(self) -> bool:
        return self.interval_seconds > 0

    def _receipt_time(self, boundary: int) -> int | None:
        if boundary < 1:
            return None
        values: list[int] = []
        for peer in self.host.required_peers:
            receipt = self.host.anchor.history.receipt(boundary, peer)
            if receipt:
                values.append(max(0, int(receipt[1].get("savedAtUnix", 0))))
        return max(values, default=0) or None

    def _connected(self) -> bool:
        if not self.host.require_connected_peers:
            return True
        with self.host.peers_lock:
            connected = set(self.host.peers)
        return all(
            peer == self.host.bridge.peer or peer in connected
            for peer in self.host.required_peers
        )

    def _eligible_reason(self) -> str | None:
        if self.host.session_fault:
            return "session is faulted"
        if not self._connected():
            return "waiting for every required peer"
        if not self.host.last_agreed_checkpoint:
            return "waiting for the first converged checkpoint"
        if self.host.anchor._pending_work():
            return "waiting for ordered work to drain"
        preparation = self.host.anchor_preparation.current
        if preparation and str(preparation.get("status", "")) not in {
            "failed", "superseded",
        }:
            return "another restore-point preparation is active"
        restore = self.host.restore_session.status()
        if restore.get("restoreRequired") is True and restore.get("restoreReady") is not True:
            return "waiting for the restore/continuation fence"
        return None

    def _finish(self, boundary: int, now: float) -> bool:
        self.last_boundary = boundary
        self.last_completed_at_unix = self._receipt_time(boundary) or int(self.wall_time())
        self.next_due_at = now + self.interval_seconds
        self.last_error = None
        self.state = "scheduled" if self.enabled else "disabled"
        self.preparation_seq = None
        self.started_at = None
        self.receipts_observed_at = None
        if self.resume_speed > 0 and not self.host.session_fault:
            _, resume_error = emit_action(self.host, {
                "type": "clock.request", "requestedSpeed": self.resume_speed,
            })
            if resume_error:
                self.last_error = "restore point complete; shared clock remains paused: " \
                    + resume_error
        self.resume_speed = 0
        return True

    def _cancel(self, detail: str, now: float) -> bool:
        sequence = self.preparation_seq
        if sequence is not None:
            _, cancel_error = emit_action(self.host, {
                "type": "recovery.cancel",
                "preparationSeq": sequence,
                "errorCode": detail[:512],
            })
            if cancel_error:
                self.last_error = "automatic recovery cancellation was rejected: " + cancel_error
                self.state = "retry-wait"
                self.next_cancel_at = now + 5.0
                return True
        if self.resume_speed > 0 and not self.host.session_fault:
            _, resume_error = emit_action(self.host, {
                "type": "clock.request", "requestedSpeed": self.resume_speed,
            })
        else:
            resume_error = None
        self.last_error = detail[:512] + (
            "; shared clock remains paused: " + resume_error if resume_error else ""
        )
        self.state = "retry-wait" if self.enabled else "disabled"
        self.next_due_at = now + min(self.interval_seconds, self.RETRY_SECONDS)
        self.preparation_seq = None
        self.started_at = None
        self.receipts_observed_at = None
        self.resume_speed = 0
        self.next_cancel_at = None
        return True

    def maintain(self) -> bool:
        # Disabling future anchors must still retire an automatic preparation
        # recovered from the journal, otherwise its gameplay fence survives
        # the companion restart forever.
        if not self.enabled and self.preparation_seq is None:
            return False
        now = self.monotonic()
        newest = max(self.host.anchor.restorable(), default=0)
        active = self.host.anchor_preparation.current
        active_boundary = int(active.get("checkpointBoundarySeq") or 0) \
            if isinstance(active, Mapping) else 0
        completed_active_boundary = active_boundary > 0 \
            and active_boundary in self.host.anchor.restorable()
        if self.preparation_seq is not None \
                and (newest > self.last_boundary or completed_active_boundary):
            if self.receipts_observed_at is None:
                self.receipts_observed_at = now
                self.state = "finalizing"
                return True
            if now - self.receipts_observed_at >= self.FINALIZE_GRACE_SECONDS:
                return self._finish(newest, now)

        if self.preparation_seq is not None:
            if isinstance(active, Mapping) \
                    and int(active.get("preparationSeq", 0)) == self.preparation_seq:
                active_status = str(active.get("status", "preparing"))
                self.state = "saving" if active_status in {"converged", "ready"} \
                    else "preparing"
                if active_status in {"failed", "superseded"}:
                    detail = str(active.get("detail") or "restore preparation failed")
                    if self.next_cancel_at is not None and now < self.next_cancel_at:
                        return False
                    return self._cancel(detail, now)
            if self.started_at is not None and now - self.started_at >= self.timeout_seconds:
                if self.next_cancel_at is not None and now < self.next_cancel_at:
                    return False
                return self._cancel("automatic restore-point preparation timed out", now)
            return False

        if now < self.next_due_at:
            return False
        reason = self._eligible_reason()
        if reason:
            self.state = "waiting"
            self.last_error = reason
            self.next_due_at = now + min(15.0, self.interval_seconds)
            return True
        self.resume_speed = max(
            0, int(max(self.host.clock_requested_speed, self.host.clock_effective_speed))
        )
        commit, prepare_error = emit_action(self.host, {
            "type": "recovery.prepare", "automatic": True,
        })
        if not commit:
            self.last_error = prepare_error or "host did not order automatic recovery preparation"
            self.next_due_at = now + min(self.interval_seconds, self.RETRY_SECONDS)
            self.state = "retry-wait"
            return True
        self.preparation_seq = int(commit["seq"])
        self.started_at = now
        self.receipts_observed_at = None
        self.state = "preparing"
        self.last_error = None
        self.attempts += 1
        return True

    def status(self) -> dict[str, Any]:
        return status_projection(self)
