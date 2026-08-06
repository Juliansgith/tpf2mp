from __future__ import annotations

import math
import time
from typing import Any, Mapping

from .consensus import (
    clock_health_payload,
    clock_rendezvous_payload,
    vehicle_sync_payload,
)
from .protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_action


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
    VEHICLE_ROUND_TIMEOUT = 180.0

    def __init__(self, host: Any) -> None:
        self.host = host
        host.clock_rendezvous = None
        host.clock_last_rendezvous = None
        host.clock_game_time_skew = None
        host.vehicle_sync_rounds = {}
        host.vehicle_sync_last_round = {}
        host.vehicle_sync_releases = 0
        host.vehicle_sync_faults = 0
        host.vehicle_sync_fault_reasons = set()
        host.vehicle_sync_last_release = None
        host.sync_fault_emitted = False

    def status(self) -> dict[str, Any]:
        rendezvous = self.host.clock_rendezvous
        pending_rounds = [
            item for item in self.host.vehicle_sync_rounds.values()
            if item.get("status") not in {"complete", "faulted"}
        ]
        return {
            "clock": {
                "requestedSpeed": self.host.clock_requested_speed,
                "effectiveSpeed": self.host.clock_effective_speed,
                "generation": self.host.clock_generation,
                "pendingSeq": self.host.consensus.pending_clock_seq(),
                "healthPeers": sorted(self.host.clock_health),
                "gameTimeSkew": self.host.clock_game_time_skew,
                "rendezvous": self._public_rendezvous(rendezvous),
                "lastRendezvous": self._public_rendezvous(self.host.clock_last_rendezvous),
            },
            "vehicleSync": {
                "trackedVehicles": len(self.host.vehicle_sync_last_round),
                "pendingRounds": len(pending_rounds),
                "releases": self.host.vehicle_sync_releases,
                "faults": self.host.vehicle_sync_faults,
                "lastRelease": self.host.vehicle_sync_last_release,
            },
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

    def prepare_clock_request(self, requested_speed: int, origin: str) -> dict[str, Any]:
        requested = max(0, min(4, int(requested_speed)))
        samples = self._fresh_samples()
        if samples is None:
            if requested != 0:
                raise ProtocolError("cannot resume/change the shared clock without fresh all-peer time samples")
            self.host.clock_generation += 1
            return validate_action({
                "type": "clock.set",
                "requestedSpeed": 0,
                "effectiveSpeed": 0,
                "generation": self.host.clock_generation,
                "reason": f"player-request:{origin}:telemetry-failsafe",
            })
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
        return self._new_rendezvous_action(
            requested, approach, requested, target, f"player-request:{origin}"
        )

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
        message = sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.host.bridge.session,
            "seq": seq,
            "kind": "commit",
            "origin_peer": self.host.bridge.peer,
            "origin_local_seq": -seq,
            marker: True,
            "tick": 0,
            "payload": {"action": validated},
        })
        self.host.audit.append(message)
        self.host.commits[seq] = message
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

    def maybe_adjust_clock(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        samples = [self.host.clock_health.get(peer) for peer in self.host.required_peers]
        timed_samples = [
            sample for sample in samples
            if sample is not None and sample.get("gameTime") is not None
        ]
        times = self._projected_game_times(timed_samples, now)
        self.host.clock_game_time_skew = max(times) - min(times) if len(times) >= 2 else None
        if self.host.session_fault:
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

    def emergency_pause(self, reason: str) -> None:
        active = self.host.clock_rendezvous
        if active:
            active["status"] = "faulted"
            self.host.clock_last_rendezvous = dict(active)
            self.host.clock_rendezvous = None
        if self.host.clock_effective_speed != 0 or self.host.clock_requested_speed != 0:
            self.emit_clock_set(self.host.clock_requested_speed, 0, reason + ":resync-pause")

    @staticmethod
    def _round_key(vehicle_cid: str, round_number: int) -> str:
        return f"{vehicle_cid}#{round_number}"

    def record_vehicle_sync(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        peer = str(message.get("peer", "unknown"))
        if peer not in self.host.required_peers:
            raise ProtocolError(f"vehicle sync report came from unexpected peer {peer}")
        payload = vehicle_sync_payload(message.get("payload"))
        if payload["state"] == "fault":
            reason = f"vehicle-sync-local-fault:{peer}:{payload['vehicleCid']}:{payload['detail']}"
            if restoring:
                self._remember_vehicle_fault(reason)
            else:
                self._fault_vehicle_session(reason)
            return
        key = self._round_key(payload["vehicleCid"], payload["round"])
        last_round = int(self.host.vehicle_sync_last_round.get(payload["vehicleCid"], 0))
        tracker = self.host.vehicle_sync_rounds.get(key)
        if tracker is None:
            if payload["round"] != last_round + 1:
                if payload["round"] <= last_round:
                    return
                reason = "vehicle-sync-round-gap:" + key
                if restoring:
                    self._remember_vehicle_fault(reason)
                else:
                    self._fault_vehicle_session(reason)
                return
            tracker = {
                "vehicleCid": payload["vehicleCid"],
                "lineCid": payload["lineCid"],
                "round": payload["round"],
                "stopIndex": payload["stopIndex"],
                "requiredPeers": self.host.required_peers,
                "held": {},
                "released": {},
                "status": "waiting-arrivals",
                "deadline": time.monotonic() + self.VEHICLE_ROUND_TIMEOUT,
            }
            self.host.vehicle_sync_rounds[key] = tracker
        if payload["lineCid"] != tracker["lineCid"] or payload["stopIndex"] != tracker["stopIndex"]:
            reason = "vehicle-sync-stop-mismatch:" + key
            if restoring:
                self._remember_vehicle_fault(reason)
            else:
                self._fault_vehicle_session(reason)
            return
        bucket = tracker["held"] if payload["state"] == "held" else tracker["released"]
        previous = bucket.get(peer)
        if previous and (
            previous["vehicleCid"] != payload["vehicleCid"]
            or previous["lineCid"] != payload["lineCid"]
            or previous["round"] != payload["round"]
            or previous["stopIndex"] != payload["stopIndex"]
            or previous["state"] != payload["state"]
        ):
            raise ProtocolError(f"peer {peer} sent conflicting vehicle sync reports")
        bucket[peer] = payload
        if payload["state"] == "held":
            if tracker.get("status") in {"release-ordered", "complete"}:
                return
            if set(tracker["requiredPeers"]) <= set(tracker["held"]):
                tracker["status"] = "ready-to-release"
                if not restoring:
                    self._maybe_emit_vehicle_release(tracker)
        elif tracker.get("status") not in {"release-ordered", "complete"}:
            reason = "vehicle-sync-release-before-authority:" + key
            if restoring:
                self._remember_vehicle_fault(reason)
            else:
                self._fault_vehicle_session(reason)
        elif tracker.get("status") != "complete" \
                and set(tracker["requiredPeers"]) <= set(tracker["released"]):
            tracker["status"] = "complete"
            tracker["completedAt"] = time.monotonic()
            self.host.vehicle_sync_releases += 1
            self.host.vehicle_sync_last_release = {
                "vehicleCid": tracker["vehicleCid"],
                "lineCid": tracker["lineCid"],
                "round": tracker["round"],
                "stopIndex": tracker["stopIndex"],
                "releaseAtGameTime": tracker.get("releaseAtGameTime"),
            }

    def _maybe_emit_vehicle_release(self, tracker: dict[str, Any]) -> None:
        if tracker.get("status") not in {"ready-to-release", "waiting-clock"}:
            return
        if self.host.clock_rendezvous:
            tracker["status"] = "waiting-clock"
            return
        if float(self.host.clock_game_time_skew or 0.0) > self.CLOCK_SKEW_LIMIT \
                and self.host.clock_effective_speed > 0:
            tracker["status"] = "waiting-clock"
            self.begin_rendezvous(
                self.host.clock_requested_speed, self.host.clock_effective_speed,
                "vehicle-release-clock-skew",
            )
            return
        reports = [tracker["held"][peer] for peer in tracker["requiredPeers"]]
        paused = self.host.clock_effective_speed == 0
        release_time = max(float(item["gameTime"]) for item in reports)
        samples = self._fresh_samples()
        if not paused:
            if samples:
                release_time = max(release_time, *self._projected_game_times(samples))
            release_time += self._guard_distance(samples or reports, 1.5)
        action = {
            "type": "vehicle.sync_release",
            "vehicleCid": tracker["vehicleCid"],
            "lineCid": tracker["lineCid"],
            "round": tracker["round"],
            "stopIndex": tracker["stopIndex"],
            "releaseAtGameTime": release_time,
            "releaseWhilePaused": paused,
        }
        message = self._emit_action(action, "vehicle_sync_control")
        tracker["controlSeq"] = message["seq"]
        tracker["status"] = "release-ordered"
        tracker["releaseAtGameTime"] = release_time
        tracker["releaseWhilePaused"] = paused
        tracker["deadline"] = time.monotonic() + self.VEHICLE_ROUND_TIMEOUT
        self.host.vehicle_sync_last_round[tracker["vehicleCid"]] = tracker["round"]
        print(
            f"vehicle sync release {tracker['vehicleCid']} round={tracker['round']} "
            f"stop={tracker['stopIndex']} at gameTime={release_time:.3f}"
        )

    def track_vehicle_release(self, commit: Mapping[str, Any]) -> None:
        action = validate_action(commit.get("payload", {}).get("action"))
        key = self._round_key(action["vehicleCid"], action["round"])
        tracker = self.host.vehicle_sync_rounds.setdefault(key, {
            "vehicleCid": action["vehicleCid"],
            "lineCid": action["lineCid"],
            "round": action["round"],
            "stopIndex": action["stopIndex"],
            "requiredPeers": self.host.required_peers,
            "held": {},
            "released": {},
            "deadline": time.monotonic() + self.VEHICLE_ROUND_TIMEOUT,
        })
        tracker.update({
            "controlSeq": int(commit["seq"]),
            "status": "release-ordered",
            "releaseAtGameTime": action["releaseAtGameTime"],
            "releaseWhilePaused": action["releaseWhilePaused"],
            "acks": tracker.get("acks", {}),
        })
        self.host.vehicle_sync_last_round[action["vehicleCid"]] = max(
            int(self.host.vehicle_sync_last_round.get(action["vehicleCid"], 0)),
            int(action["round"]),
        )

    def flush_vehicle_rounds(self) -> None:
        for tracker in list(self.host.vehicle_sync_rounds.values()):
            if tracker.get("status") in {"ready-to-release", "waiting-clock"}:
                self._maybe_emit_vehicle_release(tracker)

    def resolve_vehicle_ack(
        self, commit_seq: int, peer: str, success: bool, error: str,
        restoring: bool = False,
    ) -> None:
        for tracker in self.host.vehicle_sync_rounds.values():
            if int(tracker.get("controlSeq", -1)) != int(commit_seq):
                continue
            acknowledgements = tracker.setdefault("acks", {})
            current = {"success": bool(success), "error": str(error)}
            previous = acknowledgements.get(peer)
            if previous and previous != current:
                raise ProtocolError(f"peer {peer} sent conflicting vehicle release acknowledgements")
            acknowledgements[peer] = current
            if not success:
                tracker["status"] = "faulted"
                reason = f"vehicle-sync-release-rejected:{peer}:{tracker['vehicleCid']}:{error}"
                if restoring:
                    self._remember_vehicle_fault(reason)
                else:
                    self._fault_vehicle_session(reason)
            return

    def _remember_vehicle_fault(self, reason: str) -> None:
        reason = str(reason)
        if reason not in self.host.vehicle_sync_fault_reasons:
            self.host.vehicle_sync_fault_reasons.add(reason)
            self.host.vehicle_sync_faults += 1
        self.host.session_fault = self.host.session_fault or reason
        self.host.last_error = reason

    def _fault_vehicle_session(self, reason: str) -> None:
        self._remember_vehicle_fault(reason)
        if not self.host.sync_fault_emitted:
            self.host.sync_fault_emitted = True
            self._emit_action({
                "type": "network.sync_fault",
                "scope": "vehicle",
                "errorCode": str(reason)[:512],
            }, "synchronization_fault")
        self.emergency_pause(str(reason))

    def finalize_restore(self) -> None:
        if self.host.session_fault and not self.host.sync_fault_emitted \
                and str(self.host.session_fault).startswith("vehicle-sync-"):
            self._fault_vehicle_session(str(self.host.session_fault))
        latest_clock = max(
            self.host.clock_controls.values(),
            key=lambda item: int(item.get("generation", 0)),
            default=None,
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
        self.flush_vehicle_rounds()

    def expire(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        for tracker in list(self.host.clock_controls.values()):
            if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
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
        for tracker in list(self.host.vehicle_sync_rounds.values()):
            if tracker.get("status") not in {"complete", "faulted"} \
                    and now >= float(tracker["deadline"]):
                tracker["status"] = "faulted"
                self._fault_vehicle_session(
                    f"vehicle-sync-timeout:{tracker['vehicleCid']}:{tracker['round']}"
                )
