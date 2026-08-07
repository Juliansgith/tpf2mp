from __future__ import annotations

import math
import time
from typing import Any, Mapping

from .consensus import (
    clock_health_payload,
    clock_rendezvous_payload,
)
from .protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_action
from .paused_deadline import SharedPauseProtection
from .vehicle_barrier import VehicleStationBarrier


class SynchronizationCoordinator:
    """Host authority for simulation-time rendezvous and station-leg barriers.

    Native vehicle positions remain engine-owned.  The coordinator instead
    bounds clock skew and makes every replicated vehicle wait at each canonical
    stop until all peers have reached the same leg boundary.
    """

    CLOCK_SKEW_LIMIT = 2.0
    CLOCK_RENDEZVOUS_TOLERANCE = 0.35
    CLOCK_MAX_CATCHUP_SPAN = 1_800.0
    CLOCK_RENDEZVOUS_TIMEOUT = 60.0
    NATIVE_PAUSE_SAMPLE_MAX_AGE = 2.5
    QUIESCENT_PAUSE_ENTRY_MAX_AGE = 15.0

    def __init__(self, host: Any) -> None:
        self.host = host
        host.clock_rendezvous = None
        host.clock_last_rendezvous = None
        host.clock_game_time_skew = None
        host.clock_projected_game_time_skew = None
        host.clock_skew_samples_comparable = False
        host.clock_pause_acknowledged = False
        host.clock_pause_acknowledged_at = None
        host.clock_pause_acknowledged_generation = 0
        self.pause = SharedPauseProtection(host)
        self.clock_pause_fence: dict[str, Any] | None = None
        self.clock_last_pause_fence: dict[str, Any] | None = None
        self.vehicle = VehicleStationBarrier(host, self)

    def status(self) -> dict[str, Any]:
        rendezvous = self.host.clock_rendezvous
        return {
            "clock": {
                "requestedSpeed": self.host.clock_requested_speed,
                "effectiveSpeed": self.host.clock_effective_speed,
                "generation": self.host.clock_generation,
                "pendingSeq": self.host.consensus.pending_clock_seq(),
                "healthPeers": sorted(self.host.clock_health),
                "gameTimeSkew": self.host.clock_game_time_skew,
                "projectedGameTimeSkew": self.host.clock_projected_game_time_skew,
                "skewSamplesComparable": self.host.clock_skew_samples_comparable,
                "pauseAcknowledged": self.shared_pause_acknowledged(),
                "pauseAcknowledgedGeneration": self.host.clock_pause_acknowledged_generation,
                **self.pause.status(),
                "rendezvous": self._public_rendezvous(rendezvous),
                "lastRendezvous": self._public_rendezvous(self.host.clock_last_rendezvous),
                "pauseFence": self._public_pause_fence(self.clock_pause_fence),
                "lastPauseFence": self._public_pause_fence(self.clock_last_pause_fence),
            },
            "vehicleSync": self.vehicle.status(),
        }

    @staticmethod
    def _public_rendezvous(value: Mapping[str, Any] | None) -> dict[str, Any] | None:
        if not value:
            return None
        return {
            key: value.get(key)
            for key in (
                "generation", "targetGameTime", "requestedSpeed", "approachSpeed",
                "releaseSpeed", "reason", "status", "observedSkew", "correctionCount",
            )
        }

    @staticmethod
    def _public_pause_fence(value: Mapping[str, Any] | None) -> dict[str, Any] | None:
        if not value:
            return None
        return {
            key: value.get(key)
            for key in (
                "status", "peers", "requestedSpeed", "releaseSpeed",
                "fenceGeneration", "observedSkew", "reason",
            )
        }

    def shared_pause_acknowledged(self) -> bool:
        return self.host.clock_pause_acknowledged is True

    def pause_deadlines_protected(self) -> bool:
        return self.pause.active()

    def _set_pause_acknowledged(
        self, paused: bool, generation: int, now: float | None = None
    ) -> None:
        paused = bool(paused)
        generation = int(generation)
        current_generation = int(self.host.clock_pause_acknowledged_generation)
        if generation < current_generation:
            return
        if generation == current_generation:
            if self.host.clock_pause_acknowledged is not paused:
                raise ProtocolError("clock generation has conflicting acknowledged pause states")
            return
        now = time.monotonic() if now is None else now
        state_changed = self.host.clock_pause_acknowledged is not paused
        self.host.clock_pause_acknowledged_generation = generation
        self.host.clock_pause_acknowledged = paused
        self.host.clock_pause_acknowledged_at = now if paused else None
        protection_changed = self.pause.set_acknowledged(paused, generation, now)
        if state_changed or protection_changed:
            self.vehicle.on_clock_pause_protection_changed(now)

    def _peer_companion_connected(self, peer: str) -> bool:
        if not self.host.require_connected_peers or peer == self.host.bridge.peer:
            return True
        with self.host.peers_lock:
            return peer in self.host.peers

    def _refresh_quiescent_pause(self, now: float) -> int | None:
        protected_seq, changed = self.pause.refresh_quiescent(
            self.host.clock_controls.values(),
            self.host.clock_health,
            now,
            self._peer_companion_connected,
            stale_after=self.NATIVE_PAUSE_SAMPLE_MAX_AGE,
            entry_max_age=self.QUIESCENT_PAUSE_ENTRY_MAX_AGE,
        )
        if changed:
            self.vehicle.on_clock_pause_protection_changed(now)
        return protected_seq

    def _fresh_samples(self, now: float | None = None) -> list[dict[str, Any]] | None:
        now = time.monotonic() if now is None else now
        samples = [self.host.clock_health.get(peer) for peer in self.host.required_peers]
        if any(sample is None for sample in samples):
            return None
        typed = [sample for sample in samples if sample is not None]
        if any(now - float(sample.get("receivedAt", 0.0)) > 6.0 for sample in typed):
            return None
        if any(sample.get("gameTime") is None for sample in typed):
            return None
        return typed

    def _guard_distance(self, samples: list[Mapping[str, Any]], seconds: float = 2.0) -> float:
        rates = [
            abs(float(sample["gameRate"]))
            for sample in samples
            if sample.get("gameRate") is not None
            and math.isfinite(float(sample["gameRate"]))
            and abs(float(sample["gameRate"])) > 0.1
        ]
        if not rates:
            speed = max(1, int(self.host.clock_effective_speed or 1))
            rates = [12.0 * (2 ** (speed - 1))]
        return max(3.0, min(480.0, max(rates) * seconds))

    def _projected_game_times(
        self, samples: list[Mapping[str, Any]], now: float | None = None
    ) -> list[float]:
        """Project staggered heartbeats to one host-monotonic instant.

        Comparing their raw game times would mistake ordinary heartbeat phase
        and transport latency for simulation skew.  Paused samples never
        advance; running samples use their measured rate with the configured
        speed as a first-sample fallback.
        """
        now = time.monotonic() if now is None else now
        projected: list[float] = []
        for sample in samples:
            observed = int(float(sample.get("observedSpeed") or 0))
            rate_value = sample.get("gameRate")
            rate = float(rate_value) if rate_value is not None else math.nan
            expected_rate = 12.0 * (2 ** (max(1, min(4, observed)) - 1))
            if observed <= 0:
                rate = 0.0
            elif not math.isfinite(rate) or rate < 0:
                rate = expected_rate
            else:
                rate = min(rate, expected_rate * 2.0)
            age = max(0.0, now - float(sample.get("receivedAt", now)))
            projected.append(float(sample["gameTime"]) + rate * age)
        return projected

    def _skew_samples_match_authority(
        self, samples: list[Mapping[str, Any]] | None
    ) -> bool:
        """Return whether every peer sample describes the current clock order.

        Clock health arrives independently.  Immediately after a rendezvous or
        release, one peer can already report the new running generation while
        the other peer's latest sample still describes the previous paused
        generation.  Those values are individually valid but are not a clock
        skew measurement; comparing them created a self-sustaining sequence of
        unnecessary rendezvous orders in the first restore/resume live run.

        Older synthetic tests and restored in-memory records can omit the
        generation.  Treat an omitted value as the current generation, while
        production health payloads continue to be checked strictly.
        """
        if samples is None or len(samples) != len(self.host.required_peers):
            return False
        generation = int(self.host.clock_generation)
        return all(
            int(sample.get("generation", generation)) == generation
            for sample in samples
        )

    def prepare_clock_request(self, requested_speed: int, origin: str) -> dict[str, Any]:
        requested = max(0, min(4, int(requested_speed)))
        samples = self._fresh_samples()
        if samples is None:
            if requested != 0:
                raise ProtocolError("cannot resume/change the shared clock without fresh all-peer time samples")
            self.host.clock_generation += 1
            action = validate_action({
                "type": "clock.set",
                "requestedSpeed": 0,
                "effectiveSpeed": 0,
                "generation": self.host.clock_generation,
                "reason": f"player-request:{origin}:telemetry-failsafe",
            })
            self._retire_pause_fence("superseded-by-player-request")
            return action
        times = self._projected_game_times(samples)
        current = max(0, min(4, int(self.host.clock_effective_speed)))
        skew = max(times) - min(times)
        if current == 0:
            # A paused peer cannot advance even a sub-tolerance remainder.
            # Let both peers arm speed 1; the leading peer immediately pauses
            # again while only the lagging peer advances to the common target.
            approach = 1 if skew > 1e-6 else 0
            target = max(times)
        else:
            approach = current
            target = max(times) + self._guard_distance(samples)
        action = self._new_rendezvous_action(
            requested, approach, requested, target, f"player-request:{origin}"
        )
        self._retire_pause_fence("superseded-by-player-request")
        return action

    def _new_rendezvous_action(
        self,
        requested: int,
        approach: int,
        release: int,
        target: float,
        reason: str,
    ) -> dict[str, Any]:
        active = self.host.clock_rendezvous
        if active and active.get("status") not in {"complete", "faulted", "superseded"}:
            active["status"] = "superseded"
            self.host.clock_last_rendezvous = dict(active)
        self.host.clock_generation += 1
        return validate_action({
            "type": "clock.rendezvous",
            "requestedSpeed": int(requested),
            "approachSpeed": int(approach),
            "releaseSpeed": int(release),
            "generation": self.host.clock_generation,
            "targetGameTime": float(target),
            "reason": str(reason)[:160] or "host-rendezvous",
        })

    def _emit_action(
        self, action: Mapping[str, Any], marker: str, correction_count: int = 0
    ) -> dict[str, Any]:
        validated = validate_action(dict(action))
        seq = self.host.next_seq
        self.host.next_seq += 1
        local_seq = self.host._allocate_host_local_seq()
        message = sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.host.bridge.session,
            "seq": seq,
            "kind": "commit",
            "origin_peer": self.host.bridge.peer,
            "origin_local_seq": local_seq,
            marker: True,
            "tick": 0,
            "payload": {"action": validated},
        })
        self.host.audit.append(message)
        self.host.commits[seq] = message
        self.host.seen.add((self.host.bridge.peer, local_seq))
        if validated["type"] in {"clock.set", "clock.rendezvous"}:
            self.track_clock(message, correction_count=correction_count)
        elif validated["type"] == "vehicle.sync_release":
            self.track_vehicle_release(message)
        self.host.bridge.write_inbound(message)
        self.host._broadcast(message)
        return message

    def track_clock(
        self, commit: Mapping[str, Any], correction_count: int = 0
    ) -> dict[str, Any]:
        seq = int(commit["seq"])
        created = seq not in self.host.clock_controls
        tracker = self.host.consensus.track_clock(commit)
        action = commit.get("payload", {}).get("action", {})
        if created:
            self.host.clock_last_adjustment = time.monotonic()
        self.host.clock_requested_speed = tracker["requestedSpeed"]
        self.host.clock_effective_speed = tracker["effectiveSpeed"]
        self.host.clock_generation = max(self.host.clock_generation, tracker["generation"])
        if action.get("type") == "clock.rendezvous":
            current = self.host.clock_rendezvous
            if current and int(current.get("generation", -1)) == tracker["generation"]:
                return tracker
            if current and current.get("status") not in {"complete", "faulted", "superseded"}:
                current["status"] = "superseded"
                self.host.clock_last_rendezvous = dict(current)
            self.host.clock_rendezvous = {
                "commitSeq": seq,
                "generation": tracker["generation"],
                "targetGameTime": float(tracker["targetGameTime"]),
                "requestedSpeed": tracker["requestedSpeed"],
                "approachSpeed": tracker["effectiveSpeed"],
                "releaseSpeed": tracker["releaseSpeed"],
                "reason": tracker["reason"],
                "requiredPeers": self.host.required_peers,
                "reached": {},
                "status": "armed",
                "correctionCount": correction_count,
                "deadline": time.monotonic() + self.CLOCK_RENDEZVOUS_TIMEOUT,
            }
        elif action.get("type") == "clock.set":
            current = self.host.clock_rendezvous
            if current and tracker["generation"] > int(current.get("generation", 0)):
                current["status"] = "complete"
                self.host.clock_last_rendezvous = dict(current)
                self.host.clock_rendezvous = None
        return tracker

    def emit_clock_set(self, requested: int, effective: int, reason: str) -> dict[str, Any]:
        requested = max(0, min(4, int(requested)))
        effective = max(0, min(requested, int(effective)))
        self.host.clock_generation += 1
        message = self._emit_action({
            "type": "clock.set",
            "requestedSpeed": requested,
            "effectiveSpeed": effective,
            "generation": self.host.clock_generation,
            "reason": str(reason)[:160] or "host-adjustment",
        }, "clock_control")
        self.host.clock_last_adjustment = time.monotonic()
        print(f"shared clock requested={requested} effective={effective}: {reason}")
        if self.host.session_fault is None:
            self.flush_vehicle_rounds()
        return message

    def begin_rendezvous(self, requested: int, release: int, reason: str) -> dict[str, Any] | None:
        active = self.host.clock_rendezvous
        if active and active.get("status") not in {"complete", "faulted", "superseded"}:
            return None
        samples = self._fresh_samples()
        if not samples:
            return self.emit_clock_set(requested, 0, reason + ":missing-time-failsafe")
        times = self._projected_game_times(samples)
        approach = max(1, int(self.host.clock_effective_speed or 1))
        action = self._new_rendezvous_action(
            requested, approach, release,
            max(times) + self._guard_distance(samples), reason,
        )
        message = self._emit_action(action, "clock_control")
        print(
            f"shared clock rendezvous generation={action['generation']} "
            f"target={action['targetGameTime']:.3f}: {reason}"
        )
        return message

    def resolve_clock_ack(
        self, tracker: dict[str, Any], peer: str, acknowledgement: dict[str, Any]
    ) -> None:
        previous = tracker["acks"].get(peer)
        if previous and previous != acknowledgement:
            raise ProtocolError(f"peer {peer} sent conflicting clock acknowledgements")
        tracker["acks"][peer] = acknowledgement
        failed = [
            name for name in tracker["requiredPeers"]
            if name in tracker["acks"] and tracker["acks"][name].get("success") is not True
        ]
        if failed:
            tracker["status"] = "faulted"
            self.host.last_error = "clock-command-rejected:" + ",".join(failed)
            self.emergency_pause(self.host.last_error)
            return
        if set(tracker["requiredPeers"]) <= set(tracker["acks"]):
            tracker["status"] = "complete"
            self._set_pause_acknowledged(
                int(tracker["effectiveSpeed"]) == 0,
                int(tracker["generation"]),
            )

    def record_clock_health(self, message: Mapping[str, Any]) -> None:
        peer = str(message.get("peer", "unknown"))
        if peer not in self.host.required_peers:
            raise ProtocolError(f"clock health came from unexpected peer {peer}")
        payload = clock_health_payload(message.get("payload"))
        now = time.monotonic()
        prior = self.host.clock_health.get(peer)
        sample: dict[str, Any] = dict(payload)
        sample["receivedAt"] = now
        if prior:
            elapsed = now - float(prior["receivedAt"])
            if elapsed > 0:
                sample["tickRate"] = max(
                    0.0, (payload["engineTick"] - prior["engineTick"]) / elapsed
                )
                if payload.get("gameTime") is not None and prior.get("gameTime") is not None:
                    sample["gameRate"] = (
                        float(payload["gameTime"]) - float(prior["gameTime"])
                    ) / elapsed
        self.host.clock_health[peer] = sample
        self.maybe_adjust_clock(now)

    def record_clock_reached(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        peer = str(message.get("peer", "unknown"))
        if peer not in self.host.required_peers:
            raise ProtocolError(f"clock rendezvous report came from unexpected peer {peer}")
        payload = clock_rendezvous_payload(message.get("payload"))
        active = self.host.clock_rendezvous
        if not active or payload["generation"] != active.get("generation"):
            if payload["generation"] <= self.host.clock_generation:
                return
            raise ProtocolError("clock rendezvous report references an unknown generation")
        if abs(float(payload["targetGameTime"]) - float(active["targetGameTime"])) > 1e-6:
            raise ProtocolError("clock rendezvous report target differs from its authority order")
        previous = active["reached"].get(peer)
        if previous and previous != payload:
            raise ProtocolError(f"peer {peer} sent conflicting rendezvous reports")
        active["reached"][peer] = payload
        active["status"] = "waiting-peers"
        if payload["success"] is not True:
            active["status"] = "faulted"
            self.host.last_error = "clock-rendezvous-failed:" + peer + ":" + payload["error"]
            if not restoring:
                self.emergency_pause(self.host.last_error)
            return
        if set(active["requiredPeers"]) <= set(active["reached"]):
            tracker = self.host.clock_controls.get(int(active.get("commitSeq", -1)))
            if tracker and tracker.get("status") == "pending":
                tracker["status"] = "complete"
            if not restoring:
                self._complete_rendezvous(active)

    def _complete_rendezvous(self, active: dict[str, Any]) -> None:
        actual = [float(active["reached"][peer]["actualGameTime"]) for peer in active["requiredPeers"]]
        skew = max(actual) - min(actual)
        active["observedSkew"] = skew
        if skew > self.CLOCK_RENDEZVOUS_TOLERANCE:
            if skew > self.CLOCK_MAX_CATCHUP_SPAN or int(active.get("correctionCount", 0)) >= 3:
                active["status"] = "faulted"
                self.host.last_error = f"clock-rendezvous-skew-unrecoverable:{skew:.3f}"
                self.emergency_pause(self.host.last_error)
                return
            active["status"] = "correcting"
            self.host.clock_last_rendezvous = dict(active)
            action = self._new_rendezvous_action(
                active["requestedSpeed"], 1, active["releaseSpeed"], max(actual),
                active["reason"] + ":catch-up",
            )
            self._emit_action(
                action, "clock_control", int(active.get("correctionCount", 0)) + 1
            )
            return
        active["status"] = "reached"
        self.host.clock_last_rendezvous = dict(active)
        requested, release = active["requestedSpeed"], active["releaseSpeed"]
        self.host.clock_rendezvous = None
        self.emit_clock_set(requested, release, active["reason"] + ":all-peers-ready")

    def _retire_pause_fence(self, status: str) -> None:
        if not self.clock_pause_fence:
            return
        retired = dict(self.clock_pause_fence)
        retired["status"] = status
        self.clock_last_pause_fence = retired
        self.clock_pause_fence = None

    def _unexpected_native_pause_peers(self, now: float) -> list[str]:
        if self.host.clock_effective_speed <= 0:
            return []
        result: list[str] = []
        for peer in self.host.required_peers:
            sample = self.host.clock_health.get(peer)
            if not sample or now - float(sample.get("receivedAt", 0.0)) \
                    > self.NATIVE_PAUSE_SAMPLE_MAX_AGE:
                continue
            if int(sample.get("generation", -1)) != self.host.clock_generation \
                    or int(sample.get("effectiveSpeed", -1)) != self.host.clock_effective_speed:
                continue
            observed = sample.get("observedSpeed")
            if observed is not None and abs(float(observed)) <= 0.1:
                result.append(peer)
        return result

    def _begin_native_pause_fence(self, peers: list[str], now: float) -> None:
        if self.clock_pause_fence or not peers:
            return
        requested = max(1, int(self.host.clock_requested_speed))
        release = max(1, int(self.host.clock_effective_speed))
        reason = "native-peer-pause-fence:" + ",".join(peers)
        self.clock_pause_fence = {
            "status": "fence-ordered",
            "peers": list(peers),
            "requestedSpeed": requested,
            "releaseSpeed": release,
            "observedSkew": self.host.clock_game_time_skew,
            "reason": reason,
            "startedAt": now,
        }
        message = self.emit_clock_set(requested, 0, reason)
        self.clock_pause_fence["fenceGeneration"] = self.host.clock_generation
        self.clock_pause_fence["commitSeq"] = int(message["seq"])

    def _maybe_resume_native_pause_fence(self, now: float) -> None:
        fence = self.clock_pause_fence
        if not fence or self.host.clock_rendezvous \
                or self.host.consensus.pending_clock_seq() is not None:
            return
        samples = self._fresh_samples(now)
        if not samples:
            return
        generation = int(fence.get("fenceGeneration", self.host.clock_generation))
        if any(int(sample.get("generation", -1)) < generation for sample in samples):
            return
        # Keep both worlds paused while an Esc/modal pause remains open.  A
        # direct native resume that bypasses the visitor is still observable;
        # the ordinary captured clock.request path handles visitor-gated resumes.
        if not any(abs(float(sample.get("observedSpeed") or 0)) > 0.1 for sample in samples):
            return
        times = self._projected_game_times(samples, now)
        action = self._new_rendezvous_action(
            int(fence["requestedSpeed"]), 1, int(fence["releaseSpeed"]),
            max(times), str(fence["reason"]) + ":resume-observed",
        )
        self._retire_pause_fence("catch-up-ordered")
        self._emit_action(action, "clock_control")

    def maybe_adjust_clock(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        samples = [self.host.clock_health.get(peer) for peer in self.host.required_peers]
        timed_samples = [
            sample for sample in samples
            if sample is not None and sample.get("gameTime") is not None
        ]
        times = self._projected_game_times(timed_samples, now)
        projected_skew = max(times) - min(times) if len(times) >= 2 else None
        self.host.clock_projected_game_time_skew = projected_skew
        fresh_samples = self._fresh_samples(now)
        comparable = self._skew_samples_match_authority(fresh_samples)
        self.host.clock_skew_samples_comparable = comparable
        self.host.clock_game_time_skew = projected_skew if comparable else None
        if self.host.session_fault:
            self._retire_pause_fence("faulted-session")
            observed_running = any(
                sample is not None and sample.get("observedSpeed") is not None
                and abs(float(sample["observedSpeed"])) > 0.1
                for sample in samples
            )
            pending_clock = self.host.consensus.pending_clock_seq()
            # A hard session fault cancels the requested speed as well as the
            # current effective speed.  Supersede an older in-flight recovery
            # order once; after this order is tracked both authority fields are
            # zero, so heartbeat retries remain bounded while its ACKs arrive.
            if self.host.clock_requested_speed != 0 \
                    or self.host.clock_effective_speed != 0 \
                    or (observed_running and pending_clock is None):
                self.emit_clock_set(0, 0, "faulted-session-pause-enforcement")
            return
        if self.clock_pause_fence:
            self._maybe_resume_native_pause_fence(now)
            return
        if self.host.clock_rendezvous or self.host.consensus.pending_clock_seq() is not None:
            return
        if self.host.clock_requested_speed == 0:
            observed_running = any(
                sample is not None and sample.get("observedSpeed") is not None
                and abs(float(sample["observedSpeed"])) > 0.1
                for sample in samples
            )
            if observed_running and now - self.host.clock_last_adjustment >= 1.0:
                self.emit_clock_set(0, 0, "authoritative-pause-enforcement")
            return
        paused_peers = self._unexpected_native_pause_peers(now)
        if paused_peers:
            self._begin_native_pause_fence(paused_peers, now)
            return
        missing = any(sample is None for sample in samples)
        stale = [now - float(sample["receivedAt"]) for sample in samples if sample is not None]
        max_stale = max(stale, default=0.0)
        latest_seq = max(0, self.host.next_seq - 1)
        backlogs = [
            max(0, latest_seq - int(sample.get("lastCommitSeq", 0)))
            for sample in samples if sample is not None
        ]
        max_backlog = max(backlogs, default=0)
        rates = [
            float(sample["tickRate"])
            for sample in samples if sample is not None and sample.get("tickRate") is not None
        ]
        rate_ratio = min(rates) / max(rates) if len(rates) >= 2 and max(rates) > 0 else 1.0
        observed_mismatch = any(
            sample is not None and sample.get("observedSpeed") is not None
            and abs(float(sample["observedSpeed"]) - self.host.clock_effective_speed) > 0.1
            for sample in samples
        )
        low_rate = any(rate < 2.0 for rate in rates)
        absolute_skew = float(self.host.clock_game_time_skew or 0.0)
        if absolute_skew > self.CLOCK_SKEW_LIMIT:
            self.host.clock_healthy_since = None
            if now - self.host.clock_last_adjustment >= 1.0:
                self.begin_rendezvous(
                    self.host.clock_requested_speed, self.host.clock_effective_speed,
                    f"absolute-skew-rendezvous:{absolute_skew:.3f}",
                )
            return
        unhealthy = (
            missing and now - self.host.clock_last_adjustment > 9.0
        ) or max_stale > 6.0 or max_backlog > 2 or rate_ratio < 0.65 or low_rate or observed_mismatch
        severe = max_stale > 12.0 or max_backlog > 6
        if unhealthy:
            self.host.clock_healthy_since = None
            if now - self.host.clock_last_adjustment < 3.0:
                return
            target = 0 if severe else max(1, self.host.clock_effective_speed - 1)
            if target != self.host.clock_effective_speed:
                reason = "adaptive-resync-pause" if severe else "adaptive-slowest-peer-cap"
                if severe:
                    self.emit_clock_set(self.host.clock_requested_speed, 0, reason)
                else:
                    self.begin_rendezvous(self.host.clock_requested_speed, target, reason)
            return
        if self.host.clock_healthy_since is None:
            self.host.clock_healthy_since = now
            return
        if self.host.clock_effective_speed < self.host.clock_requested_speed \
                and now - self.host.clock_healthy_since >= 12.0 \
                and now - self.host.clock_last_adjustment >= 4.0:
            self.begin_rendezvous(
                self.host.clock_requested_speed, self.host.clock_effective_speed + 1,
                "adaptive-recovery-step",
            )
            self.host.clock_healthy_since = now
        elif str(self.host.last_error or "").startswith("clock-ack-timeout:"):
            self.host.last_error = None

    def emergency_pause(self, reason: str) -> None:
        self._retire_pause_fence("faulted:" + str(reason)[:120])
        active = self.host.clock_rendezvous
        if active:
            active["status"] = "faulted"
            self.host.clock_last_rendezvous = dict(active)
            self.host.clock_rendezvous = None
        if self.host.clock_effective_speed != 0 or self.host.clock_requested_speed != 0:
            self.emit_clock_set(self.host.clock_requested_speed, 0, reason + ":resync-pause")

    def fault_session(self, scope: str, reason: str) -> None:
        """Order one durable fault and fence simulation after an unsafe rejection."""
        reason = str(reason)[:512]
        self.host.session_fault = self.host.session_fault or reason
        self.host.last_error = reason
        if not self.host.sync_fault_emitted:
            self.host.sync_fault_emitted = True
            self._emit_action({
                "type": "network.sync_fault", "scope": str(scope),
                "errorCode": reason,
            }, "synchronization_fault")
        self.emergency_pause(reason)

    def record_vehicle_sync(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        self.vehicle.record(message, restoring=restoring)

    def track_vehicle_release(self, commit: Mapping[str, Any]) -> None:
        self.vehicle.track_release(commit)

    def flush_vehicle_rounds(self) -> None:
        self.vehicle.flush()

    def resolve_vehicle_ack(
        self, commit_seq: int, peer: str, success: bool, error: str,
        restoring: bool = False,
    ) -> None:
        self.vehicle.resolve_ack(commit_seq, peer, success, error, restoring=restoring)

    def finalize_restore(self) -> None:
        self.vehicle.restore_fault()
        latest_clock = max(
            self.host.clock_controls.values(),
            key=lambda item: int(item.get("generation", 0)),
            default=None,
        )
        latest_complete = max(
            (
                item for item in self.host.clock_controls.values()
                if item.get("status") == "complete"
            ),
            key=lambda item: int(item.get("generation", 0)),
            default=None,
        )
        if latest_complete:
            self._set_pause_acknowledged(
                int(latest_complete.get("effectiveSpeed", 0)) == 0,
                int(latest_complete.get("generation", 0)),
            )
        if latest_clock and latest_clock.get("status") == "faulted" \
                and int(latest_clock.get("generation", -1)) == self.host.clock_generation:
            failed = sorted(
                peer for peer, item in latest_clock.get("acks", {}).items()
                if item.get("success") is not True
            )
            self.host.last_error = "clock-command-rejected:" + ",".join(failed)
            self.emergency_pause(self.host.last_error)
        active = self.host.clock_rendezvous
        if active and set(active["requiredPeers"]) <= set(active["reached"]):
            self._complete_rendezvous(active)
        self.vehicle.flush()

    def expire(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        protected_clock_seq = self._refresh_quiescent_pause(now)
        for tracker in list(self.host.clock_controls.values()):
            if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                if int(tracker.get("commitSeq", -1)) == protected_clock_seq:
                    continue
                tracker["status"] = "faulted"
                missing = sorted(set(tracker["requiredPeers"]) - set(tracker["acks"]))
                self.host.last_error = "clock-ack-timeout:" + ",".join(missing)
                self.emergency_pause(self.host.last_error)
        active = self.host.clock_rendezvous
        if active and active.get("status") not in {"complete", "faulted", "superseded"} \
                and now >= float(active["deadline"]):
            missing = sorted(set(active["requiredPeers"]) - set(active["reached"]))
            active["status"] = "faulted"
            self.host.last_error = "clock-rendezvous-timeout:" + ",".join(missing)
            self.emergency_pause(self.host.last_error)
        self.vehicle.expire(now)
