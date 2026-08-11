from __future__ import annotations

import math
import time
from typing import Any


class AdaptiveClockGovernor:
    """Hysteretic game-time speed policy for the shared native clock."""

    SKEW_LIMIT = 2.0
    HARD_SKEW_LIMIT = 8.0
    SKEW_CONFIRM_SECONDS = 4.0
    DEGRADE_CONFIRM_SECONDS = 8.0
    RECOVERY_STABLE_SECONDS = 30.0

    @staticmethod
    def nominal_game_rate(speed: int | float) -> float:
        """Return Build 35924 getGameTime units advanced per wall second.

        getGameSpeed already exposes the Build 35924 speed value in the same
        scale as the observed game-time rate; it is not an index that needs a
        12 * 2**n conversion.  Keeping this
        unit contract beside the governor prevents release guards and clock
        projections from silently drifting onto engine-tick units again.
        """
        value = float(speed)
        return max(0.0, min(4.0, value)) if math.isfinite(value) else 0.0

    def __init__(self, host: Any, clock: Any) -> None:
        self.host = host
        self.clock = clock
        host.clock_skew_exceeded_since = None
        host.clock_degraded_since = None
        host.clock_progress_rate_ratio = None
        host.clock_adaptive_step_downs = 0
        host.clock_adaptive_recoveries = 0
        host.clock_skew_corrections = 0

    @staticmethod
    def _elapsed_since(started: float | None) -> float | None:
        if started is None:
            return None
        return max(0.0, time.monotonic() - float(started))

    def status(self) -> dict[str, Any]:
        return {
            "progressRateRatio": self.host.clock_progress_rate_ratio,
            "skewExceededForSeconds": self._elapsed_since(
                self.host.clock_skew_exceeded_since
            ),
            "degradedForSeconds": self._elapsed_since(
                self.host.clock_degraded_since
            ),
            "adaptiveStepDowns": self.host.clock_adaptive_step_downs,
            "adaptiveRecoveries": self.host.clock_adaptive_recoveries,
            "skewCorrections": self.host.clock_skew_corrections,
        }

    def _skew_requires_rendezvous(self, skew: float, now: float) -> bool:
        """Debounce small projected skew while retaining a hard safety path."""

        if skew <= self.SKEW_LIMIT:
            self.host.clock_skew_exceeded_since = None
            return False
        if skew >= self.HARD_SKEW_LIMIT:
            return True
        if self.host.clock_skew_exceeded_since is None:
            self.host.clock_skew_exceeded_since = now
            return False
        return now - float(self.host.clock_skew_exceeded_since) \
            >= self.SKEW_CONFIRM_SECONDS

    def skew_requires_rendezvous(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        if not self.host.clock_skew_samples_comparable:
            self.host.clock_skew_exceeded_since = None
            return False
        return self._skew_requires_rendezvous(
            float(self.host.clock_game_time_skew or 0.0), now
        )

    def observe_rendezvous(self, reason: str) -> None:
        if reason.startswith("absolute-skew-rendezvous") \
                or reason == "vehicle-release-clock-skew":
            self.host.clock_skew_corrections += 1
            self.host.clock_skew_exceeded_since = None
        elif reason == "adaptive-slowest-peer-cap":
            self.host.clock_adaptive_step_downs += 1
        elif reason == "adaptive-recovery-step":
            self.host.clock_adaptive_recoveries += 1

    def adjust(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        host, clock = self.host, self.clock
        samples = [host.clock_health.get(peer) for peer in host.required_peers]
        timed = [
            sample for sample in samples
            if sample is not None and sample.get("gameTime") is not None
        ]
        times = clock._projected_game_times(timed, now)
        projected_skew = max(times) - min(times) if len(times) >= 2 else None
        host.clock_projected_game_time_skew = projected_skew
        fresh = clock._fresh_samples(now)
        comparable = clock._skew_samples_match_authority(fresh)
        host.clock_skew_samples_comparable = comparable
        host.clock_game_time_skew = projected_skew if comparable else None
        if host.session_fault:
            clock._retire_pause_fence("faulted-session")
            observed_running = any(
                sample is not None and sample.get("observedSpeed") is not None
                and abs(float(sample["observedSpeed"])) > 0.1
                for sample in samples
            )
            pending_clock = host.consensus.pending_clock_seq()
            if host.clock_requested_speed != 0 or host.clock_effective_speed != 0 \
                    or (observed_running and pending_clock is None):
                clock.emit_clock_set(0, 0, "faulted-session-pause-enforcement")
            return
        if clock.clock_pause_fence:
            clock._maybe_resume_native_pause_fence(now)
            return
        if host.clock_rendezvous or host.consensus.pending_clock_seq() is not None:
            return
        if host.clock_requested_speed == 0:
            observed_running = any(
                sample is not None and sample.get("observedSpeed") is not None
                and abs(float(sample["observedSpeed"])) > 0.1
                for sample in samples
            )
            if observed_running and now - host.clock_last_adjustment >= 1.0:
                clock.emit_clock_set(0, 0, "authoritative-pause-enforcement")
            return
        paused_peers = clock._unexpected_native_pause_peers(now)
        if paused_peers:
            clock._begin_native_pause_fence(paused_peers, now)
            return

        missing = any(sample is None for sample in samples)
        stale = [
            now - float(sample["receivedAt"])
            for sample in samples if sample is not None
        ]
        max_stale = max(stale, default=0.0)
        latest_seq = max(0, host.next_seq - 1)
        backlogs = [
            max(0, latest_seq - int(sample.get("lastCommitSeq", 0)))
            for sample in samples if sample is not None
        ]
        max_backlog = max(backlogs, default=0)
        # Render/update FPS may differ while game time progresses identically.
        progress_samples = [
            (
                max(0.0, float(sample["gameRate"])),
                max(1, min(4, int(round(float(sample["observedSpeed"]))))),
            )
            for sample in samples
            if sample is not None and sample.get("gameRate") is not None
            and math.isfinite(float(sample["gameRate"]))
            and abs(float(sample.get("observedSpeed") or 0)) > 0.1
        ]
        # A peer is healthy when game time--not frames or update callbacks--keeps
        # up with the nominal rate of its observed native speed.  Comparing
        # peers only to one another would miss two equally overloaded machines;
        # normalising each one also ignores harmless fast-peer overshoot.
        progress_ratio = min((
            min(1.0, rate / self.nominal_game_rate(speed))
            for rate, speed in progress_samples
        ), default=1.0)
        host.clock_progress_rate_ratio = progress_ratio
        observed_mismatch = any(
            sample is not None and sample.get("observedSpeed") is not None
            and abs(float(sample["observedSpeed"]) - host.clock_effective_speed) > 0.1
            for sample in samples
        )
        absolute_skew = float(host.clock_game_time_skew or 0.0)
        if comparable and self._skew_requires_rendezvous(absolute_skew, now):
            host.clock_healthy_since = None
            if now - host.clock_last_adjustment >= 1.0:
                clock.begin_rendezvous(
                    host.clock_requested_speed, host.clock_effective_speed,
                    f"absolute-skew-rendezvous:{absolute_skew:.3f}",
                )
            return
        if not comparable or absolute_skew <= self.SKEW_LIMIT:
            host.clock_skew_exceeded_since = None

        degraded = len(progress_samples) >= 2 and progress_ratio < 0.65
        if degraded:
            if host.clock_degraded_since is None:
                host.clock_degraded_since = now
        else:
            host.clock_degraded_since = None
        sustained = host.clock_degraded_since is not None \
            and now - float(host.clock_degraded_since) >= self.DEGRADE_CONFIRM_SECONDS
        unhealthy = (
            missing and now - host.clock_last_adjustment > 9.0
        ) or max_stale > 6.0 or max_backlog > 2 or observed_mismatch or sustained
        severe = max_stale > 12.0 or max_backlog > 6
        if unhealthy:
            host.clock_healthy_since = None
            if now - host.clock_last_adjustment < 3.0:
                return
            target = 0 if severe else max(1, host.clock_effective_speed - 1)
            if target != host.clock_effective_speed:
                reason = "adaptive-resync-pause" if severe else "adaptive-slowest-peer-cap"
                if severe:
                    clock.emit_clock_set(host.clock_requested_speed, 0, reason)
                else:
                    clock.begin_rendezvous(host.clock_requested_speed, target, reason)
            return
        if host.clock_healthy_since is None:
            host.clock_healthy_since = now
            return
        if host.clock_effective_speed < host.clock_requested_speed \
                and now - host.clock_healthy_since >= self.RECOVERY_STABLE_SECONDS \
                and now - host.clock_last_adjustment >= 4.0:
            clock.begin_rendezvous(
                host.clock_requested_speed, host.clock_effective_speed + 1,
                "adaptive-recovery-step",
            )
            host.clock_healthy_since = now
        elif str(host.last_error or "").startswith("clock-ack-timeout:"):
            host.last_error = None
