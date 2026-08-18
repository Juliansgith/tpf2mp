from __future__ import annotations

import time
from typing import Any


class ReconnectCoordinator:
    """Bound a transient peer outage without pretending it never happened.

    A missing peer cannot acknowledge clock, vehicle, proposal, operation, or
    checkpoint work.  The host therefore pauses immediately and suspends those
    wall-clock deadlines for one finite grace interval.  Re-entry becomes
    usable only after the socket backlog has been sent in order.  The human
    still chooses when to resume the shared clock.
    """

    DEFAULT_GRACE_SECONDS = 120.0

    def __init__(self, host: Any, grace_seconds: float = DEFAULT_GRACE_SECONDS) -> None:
        self.host = host
        self.grace_seconds = max(10.0, min(600.0, float(grace_seconds)))
        self.waiting: dict[str, dict[str, Any]] = {}
        self.syncing: dict[str, dict[str, Any]] = {}
        self.last: dict[str, dict[str, Any]] = {}
        self.events = 0
        self.recoveries = 0
        self.timeouts = 0

    def active(self, now: float | None = None) -> bool:
        del now
        return bool(self.waiting)

    def status(self) -> dict[str, Any]:
        now = time.monotonic()
        waiting = {
            peer: {
                "status": item["status"],
                "reason": item["reason"],
                "startedAt": item["startedAt"],
                "graceDeadline": item["graceDeadline"],
                "secondsRemaining": max(0.0, float(item["graceDeadline"]) - now),
            }
            for peer, item in sorted(self.waiting.items())
        }
        return {
            "reconnect": {
                "graceSeconds": self.grace_seconds,
                "active": bool(waiting),
                "waitingPeers": waiting,
                "synchronizingPeers": {
                    peer: dict(item) for peer, item in sorted(self.syncing.items())
                },
                "events": self.events,
                "recoveries": self.recoveries,
                "timeouts": self.timeouts,
                "last": {
                    peer: dict(item) for peer, item in sorted(self.last.items())
                },
                "resumeRequired": bool(waiting)
                or (
                    self.recoveries > 0
                    and int(self.host.clock_effective_speed) == 0
                    and int(self.host.clock_requested_speed) > 0
                ),
            }
        }

    def disconnected(
        self, peer: str, reason: str, now: float | None = None
    ) -> None:
        peer = str(peer)
        if not self.host.require_connected_peers \
                or peer == self.host.bridge.peer \
                or peer not in self.host.required_peers:
            return
        now = time.monotonic() if now is None else float(now)
        if peer not in self.waiting:
            self.events += 1
            self.waiting[peer] = {
                "status": "waiting",
                "reason": str(reason)[:240] or "connection-lost",
                "startedAt": now,
                "graceDeadline": now + self.grace_seconds,
            }
        self.syncing.pop(peer, None)
        # Old health must never satisfy a post-reconnect resume request.
        self.host.clock_health.pop(peer, None)
        self.host.synchronization.emergency_pause(
            f"peer-disconnected:{peer}"
        )

    def synchronizing(
        self, peer: str, from_seq: int, now: float | None = None
    ) -> None:
        peer = str(peer)
        now = time.monotonic() if now is None else float(now)
        self.syncing[peer] = {
            "status": "replaying",
            "fromSeq": int(from_seq),
            "startedAt": now,
        }
        if peer in self.waiting:
            self.waiting[peer]["status"] = "replaying"

    def _reset_pending_deadlines(self, now: float) -> None:
        timeout = float(self.host.completion_timeout)
        for registry in (
            self.host.proposal_prepares,
            self.host.proposal_consensus,
            self.host.operation_consensus,
            self.host.checkpoint_consensus,
        ):
            for tracker in registry.values():
                if tracker.get("status") == "pending":
                    tracker["deadline"] = now + timeout
        for tracker in self.host.clock_controls.values():
            if tracker.get("status") == "pending":
                tracker["deadline"] = now + min(timeout, 10.0)
        rendezvous = self.host.clock_rendezvous
        if rendezvous and rendezvous.get("status") not in {
            "complete", "faulted", "superseded"
        }:
            rendezvous["deadline"] = now + self.host.synchronization.CLOCK_RENDEZVOUS_TIMEOUT

    def ready(
        self, peer: str, through_seq: int, now: float | None = None
    ) -> None:
        peer = str(peer)
        now = time.monotonic() if now is None else float(now)
        # Let the vehicle deadline registry observe the protected interval
        # before clearing it, then settle that interval immediately afterward.
        self.host.synchronization.vehicle.deadlines.synchronize(
            self.host.vehicle_sync_rounds.values(), now
        )
        waiting = self.waiting.pop(peer, None)
        syncing = self.syncing.pop(peer, None)
        self.host.synchronization.vehicle.deadlines.synchronize(
            self.host.vehicle_sync_rounds.values(), now
        )
        if waiting:
            self.recoveries += 1
            self._reset_pending_deadlines(now)
            self.last[peer] = {
                "status": "recovered",
                "reason": waiting["reason"],
                "durationSeconds": max(0.0, now - float(waiting["startedAt"])),
                "throughSeq": int(through_seq),
            }
        elif syncing:
            self.last[peer] = {
                "status": "initial-sync",
                "durationSeconds": max(0.0, now - float(syncing["startedAt"])),
                "throughSeq": int(through_seq),
            }

    def expire(self, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else float(now)
        expired = [
            peer for peer, item in self.waiting.items()
            if now >= float(item["graceDeadline"])
        ]
        if expired:
            for peer in sorted(expired):
                item = self.waiting.pop(peer)
                self.syncing.pop(peer, None)
                self.timeouts += 1
                self.last[peer] = {
                    "status": "timed-out",
                    "reason": item["reason"],
                    "durationSeconds": max(0.0, now - float(item["startedAt"])),
                }
            self.host.synchronization.fault_session(
                "clock", "peer-reconnect-timeout:" + ",".join(sorted(expired))
            )
        return self.active(now)
