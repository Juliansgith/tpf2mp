"""Pre-pause drain mechanics for coordinated recovery anchors."""

from __future__ import annotations

import time
from typing import Any, Mapping

from .protocol import ProtocolError


class AnchorPreparationDrain:
    """Drain durable work and move the shared clock without player input."""

    def __init__(self, host: Any) -> None:
        self.host = host

    def vehicle_pending(self) -> int:
        return sum(
            1 for item in self.host.vehicle_sync_rounds.values()
            if isinstance(item, Mapping) and item.get("status") not in {"complete", "faulted"}
        )

    def observe_clock(
        self,
        active: dict[str, Any] | None,
        message: Mapping[str, Any],
        action: Mapping[str, Any],
        sequence: int,
    ) -> bool:
        if action.get("type") not in {"clock.set", "clock.rendezvous"} \
                or not active or active.get("status") != "draining" \
                or str(message.get("origin_peer")) != self.host.bridge.peer \
                or int(message.get("origin_local_seq", 0)) >= 0:
            return False
        requested = int(action.get("requestedSpeed", 0))
        if requested > 0:
            # Intermediate resync-pause controls retain the requested running
            # speed and reconstruct the same recovery-owned transition.
            active["resumeSpeed"] = requested
            active["drainResumeCommitSeq"] = sequence
        return True

    def quiescence_reasons(self) -> list[str]:
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
            if isinstance(sample, Mapping) \
                    and int(sample.get("lastCommitSeq", -1)) < latest:
                reasons.append(f"{peer} has not consumed preparation sequence {latest}")
        if self.host.session_fault:
            reasons.append("the session faulted during restore point preparation")
        return reasons

    def pause_skew_requires_resync(self) -> bool:
        skew = self.host.anchor.paused_game_time_skew()
        return skew is not None and skew > float(
            self.host.synchronization.CLOCK_RENDEZVOUS_TOLERANCE
        )

    def resynchronize_pause(self, active: dict[str, Any]) -> bool:
        skew = self.host.anchor.paused_game_time_skew()
        active["status"] = "pausing"
        active["detail"] = (
            f"rendezvousing paused peer game times ({float(skew or 0.0):.3f}s skew)"
        )
        return self.request_clock(active, 0, active["detail"])

    def reasons(self) -> list[str]:
        """Prove the running worlds have consumed all pre-pause work.

        AnchorCoordinator's normal health check deliberately requires a
        paused native game.  The drain phase needs the complementary proof:
        fresh schema-3 health, no local/deferred work, and consumption of the
        latest ordered sequence while the clock is still allowed to advance.
        """

        reasons: list[str] = []
        pending = self.host.anchor._pending_work()
        if pending:
            reasons.append(f"waiting for {pending} ordered action(s) to drain")
        now = time.monotonic()
        latest = max(0, self.host.next_seq - 1)
        for peer in self.host.required_peers:
            sample = self.host.clock_health.get(peer)
            if not isinstance(sample, Mapping):
                reasons.append(f"{peer} has not reported drain health")
                continue
            if now - float(sample.get("receivedAt", 0.0)) > self.host.anchor.HEALTH_MAX_AGE:
                reasons.append(f"{peer} drain health is stale")
                continue
            if int(sample.get("schemaVersion", 0)) < 3:
                reasons.append(f"{peer} health cannot prove its local queue is empty")
                continue
            if sample.get("localWorkPending") is not False \
                    or sample.get("proposalPending") is not False \
                    or int(sample.get("deferredIntentCount", 0)) != 0:
                reasons.append(f"{peer} still has local ordered work pending")
            if int(sample.get("lastCommitSeq", -1)) < latest:
                reasons.append(f"{peer} has not consumed drain sequence {latest}")
        if self.host.session_fault:
            reasons.append("the session faulted during restore point preparation")
        return reasons

    def can_pause_after_completed_resume(
        self, active: Mapping[str, Any], reasons: list[str]
    ) -> bool:
        """Allow only the pause half of a proven completed drain rendezvous.

        Older installed game scripts can phase-lock their running heartbeat.
        A recovery-owned resume still proves both peers reached its target via
        clock-reached records. Once every durable lane is empty, ordering a
        pause is safe; normal paused health remains mandatory before READY.
        """

        if not active.get("drainResumeCommitSeq") \
                or self.host.anchor._pending_work() != 0 \
                or self.host.clock_effective_speed <= 0 \
                or self.host.clock_rendezvous is not None \
                or self.host.session_fault:
            return False
        allowed = (
            " has not reported drain health",
            " drain health is stale",
            " has not consumed drain sequence ",
        )
        return bool(reasons) and all(any(token in reason for token in allowed) for reason in reasons)

    def request_clock(self, active: dict[str, Any], speed: int, detail: str) -> bool:
        active["detail"] = detail
        try:
            ordered = self.host.emit_local_intent({
                "type": "clock.request", "requestedSpeed": int(speed),
            })
        except ProtocolError as exc:
            # A reconnect can race this maintenance pass. Keep the workflow
            # fenced and retry after health/connection state catches up.
            active["detail"] = str(exc)
            return False
        if speed == 0:
            active["pauseCommitSeq"] = ordered and int(ordered.get("seq", 0))
        else:
            active["drainResumeCommitSeq"] = ordered and int(ordered.get("seq", 0))
        return ordered is not None

    def begin_pause(self, active: dict[str, Any]) -> bool:
        active["status"] = "pausing"
        active["detail"] = "rendezvousing both games at pause"
        if self.host.synchronization.shared_pause_acknowledged():
            return True
        if self.request_clock(active, 0, active["detail"]):
            return True
        active["status"] = "draining"
        return False

    def resume(self, active: dict[str, Any]) -> bool:
        speed = max(1, int(active.get("resumeSpeed", 1)))
        active["status"] = "draining"
        active["resumeSpeed"] = speed
        active["drainRetries"] = int(active.get("drainRetries", 0)) + 1
        return self.request_clock(
            active,
            speed,
            "temporarily resuming the shared clock to drain station barriers",
        )
