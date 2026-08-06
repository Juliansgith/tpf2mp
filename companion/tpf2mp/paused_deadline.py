from __future__ import annotations

from collections.abc import Callable, Iterable
from typing import Any


class SharedPauseProtection:
    """Distinguish durable timeout protection from strict clock acknowledgement."""

    def __init__(self, host: Any) -> None:
        self.host = host
        host.clock_pause_protected = False
        host.clock_pause_protection_mode = None
        host.clock_pause_protection_generation = 0
        host.clock_pause_protected_at = None
        host.clock_pause_quiescent_peers = ()

    def active(self) -> bool:
        return self.host.clock_pause_protected is True

    def status(self) -> dict[str, Any]:
        return {
            "pauseProtected": self.active(),
            "pauseProtectionMode": self.host.clock_pause_protection_mode,
            "pauseProtectionGeneration": self.host.clock_pause_protection_generation,
            "pauseProtectedAt": self.host.clock_pause_protected_at,
            "pauseQuiescentPeers": list(self.host.clock_pause_quiescent_peers),
        }

    def _set(
        self,
        active: bool,
        generation: int,
        mode: str | None,
        peers: tuple[str, ...],
        now: float,
    ) -> bool:
        generation = int(generation)
        if generation < int(self.host.clock_pause_protection_generation):
            return False
        changed = self.active() is not bool(active)
        self.host.clock_pause_protected = bool(active)
        self.host.clock_pause_protection_generation = generation
        self.host.clock_pause_protection_mode = mode if active else None
        self.host.clock_pause_quiescent_peers = tuple(peers) if active else ()
        if changed:
            self.host.clock_pause_protected_at = float(now) if active else None
        return changed

    def set_acknowledged(self, paused: bool, generation: int, now: float) -> bool:
        if paused:
            return self._set(True, generation, "acknowledged", (), now)
        return self._set(False, generation, None, (), now)

    def refresh_quiescent(
        self,
        trackers: Iterable[dict[str, Any]],
        health: dict[str, dict[str, Any]],
        now: float,
        peer_connected: Callable[[str], bool],
        *,
        stale_after: float,
        entry_max_age: float,
    ) -> tuple[int | None, bool]:
        if self.host.clock_pause_acknowledged is True:
            return None, False
        ordered = sorted(
            trackers,
            key=lambda tracker: int(tracker.get("generation", 0)),
            reverse=True,
        )
        for tracker in ordered:
            if tracker.get("status") != "pending" \
                    or tracker.get("actionType") != "clock.set" \
                    or int(tracker.get("effectiveSpeed", -1)) != 0:
                continue
            started_at = float(tracker.get("startedAt", now))
            if now - started_at < stale_after:
                continue
            required = set(tracker.get("requiredPeers", ()))
            acknowledgements = tracker.get("acks", {})
            if any(item.get("success") is not True for item in acknowledgements.values()):
                continue
            missing = sorted(required - set(acknowledgements))
            if not missing or not acknowledgements:
                continue
            eligible = True
            for peer in missing:
                sample = health.get(peer)
                received_at = float(sample.get("receivedAt", 0.0)) if sample else 0.0
                if not sample or started_at - received_at > entry_max_age \
                        or now - received_at < stale_after or not peer_connected(peer):
                    eligible = False
                    break
            if not eligible:
                continue
            changed = self._set(
                True,
                int(tracker.get("generation", 0)),
                "connected-quiescent-modal",
                tuple(missing),
                now,
            )
            return int(tracker.get("commitSeq", 0)), changed
        if self.host.clock_pause_protection_mode == "connected-quiescent-modal":
            generation = int(self.host.clock_pause_protection_generation)
            return None, self._set(False, generation, None, (), now)
        return None, False


class PausedDeadlineRegistry:
    """Wall-clock deadlines suspended by a protected shared-pause interval."""

    _TERMINAL_STATES = {"complete", "faulted"}

    def __init__(self, timeout: float, pause_active: Callable[[], bool]) -> None:
        self.timeout = float(timeout)
        self.pause_active = pause_active
        self.pause_started_at: float | None = None

    @classmethod
    def _pending(cls, trackers: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
        return [
            tracker for tracker in trackers
            if tracker.get("status") not in cls._TERMINAL_STATES
        ]

    @staticmethod
    def _settle(
        tracker: dict[str, Any], now: float, *, extend_deadline: bool
    ) -> float:
        paused_at = tracker.pop("timeoutPausedAt", None)
        if paused_at is None:
            return 0.0
        duration = max(0.0, float(now) - float(paused_at))
        tracker["pausedDuration"] = float(tracker.get("pausedDuration", 0.0)) + duration
        if extend_deadline:
            tracker["deadline"] = float(tracker["deadline"]) + duration
        return duration

    def synchronize(self, trackers: Iterable[dict[str, Any]], now: float) -> bool:
        pending = self._pending(trackers)
        paused = self.pause_active()
        if paused:
            if self.pause_started_at is None:
                self.pause_started_at = float(now)
            for tracker in pending:
                tracker.setdefault("timeoutPausedAt", float(now))
        elif self.pause_started_at is not None or any(
            tracker.get("timeoutPausedAt") is not None for tracker in pending
        ):
            for tracker in pending:
                self._settle(tracker, now, extend_deadline=True)
            self.pause_started_at = None
        return paused

    def register(self, tracker: dict[str, Any], now: float) -> None:
        tracker.setdefault("pausedDuration", 0.0)
        if self.pause_started_at is not None:
            tracker.setdefault("timeoutPausedAt", float(now))

    def reset(self, tracker: dict[str, Any], now: float) -> None:
        self._settle(tracker, now, extend_deadline=False)
        tracker["deadline"] = float(now) + self.timeout
        if self.pause_started_at is not None:
            tracker["timeoutPausedAt"] = float(now)

    def complete(self, tracker: dict[str, Any], now: float) -> float:
        self._settle(tracker, now, extend_deadline=False)
        return float(tracker.get("pausedDuration", 0.0))

    def status(self, trackers: Iterable[dict[str, Any]]) -> dict[str, Any]:
        pending = self._pending(trackers)
        return {
            "timeoutPaused": self.pause_started_at is not None,
            "timeoutPausedSince": self.pause_started_at,
            "timeoutPausedRounds": sum(
                tracker.get("timeoutPausedAt") is not None for tracker in pending
            ),
        }
