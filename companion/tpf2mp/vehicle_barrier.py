from __future__ import annotations

import math
import time
from typing import Any, Mapping

from .consensus import vehicle_sync_payload
from .paused_deadline import PausedDeadlineRegistry
from .protocol import ProtocolError, validate_action


class VehicleStationBarrier:
    """Host-owned stop rendezvous and departure-slot allocator."""

    ROUND_TIMEOUT = 180.0

    def __init__(self, host: Any, clock: Any) -> None:
        self.host = host
        self.clock = clock
        host.vehicle_sync_rounds = {}
        host.vehicle_sync_last_round = {}
        host.vehicle_sync_releases = 0
        host.vehicle_sync_faults = 0
        host.vehicle_sync_fault_reasons = set()
        host.vehicle_sync_last_release = None
        host.vehicle_sync_slot_reservations = {}
        host.vehicle_sync_reports = 0
        host.vehicle_sync_peak_pending = 0
        host.vehicle_sync_pruned_rounds = 0
        host.vehicle_sync_latency_samples = 0
        host.vehicle_sync_latency_total_ms = 0.0
        host.vehicle_sync_latency_max_ms = 0.0
        host.vehicle_sync_scheduled_releases = 0
        host.vehicle_sync_unscheduled_releases = 0
        host.sync_fault_emitted = False
        self.deadlines = PausedDeadlineRegistry(
            self.ROUND_TIMEOUT, self.clock.pause_deadlines_protected
        )

    def status(self) -> dict[str, Any]:
        pending = [
            item for item in self.host.vehicle_sync_rounds.values()
            if item.get("status") not in {"complete", "faulted"}
        ]
        pending_by_status: dict[str, int] = {}
        for item in pending:
            status = str(item.get("status") or "unknown")
            pending_by_status[status] = pending_by_status.get(status, 0) + 1
        result = {
            "trackedVehicles": len(self.host.vehicle_sync_last_round),
            "pendingRounds": len(pending),
            "pendingByStatus": pending_by_status,
            "releases": self.host.vehicle_sync_releases,
            "faults": self.host.vehicle_sync_faults,
            "lastRelease": self.host.vehicle_sync_last_release,
            "reports": self.host.vehicle_sync_reports,
            "peakPendingRounds": self.host.vehicle_sync_peak_pending,
            "prunedRounds": self.host.vehicle_sync_pruned_rounds,
            "slotReservations": len(self.host.vehicle_sync_slot_reservations),
            "scheduledReleases": self.host.vehicle_sync_scheduled_releases,
            "unscheduledReleases": self.host.vehicle_sync_unscheduled_releases,
            "averageRoundLatencyMs": (
                self.host.vehicle_sync_latency_total_ms / self.host.vehicle_sync_latency_samples
                if self.host.vehicle_sync_latency_samples else None
            ),
            "maxRoundLatencyMs": (
                self.host.vehicle_sync_latency_max_ms
                if self.host.vehicle_sync_latency_samples else None
            ),
        }
        result.update(self.deadlines.status(pending))
        return result

    def on_clock_pause_protection_changed(self, now: float) -> None:
        self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), now)

    def restore_round_cursors(self, cursors: list[Mapping[str, Any]]) -> None:
        """Seed receipt-bound station rounds before the restore fence opens."""

        if self.host.vehicle_sync_rounds or self.host.vehicle_sync_last_round:
            raise ProtocolError("vehicle station rounds were already initialized")
        self.host.vehicle_sync_last_round = {
            str(item["vehicleCid"]): int(item["lastAuthorizedRound"])
            for item in cursors
        }

    @staticmethod
    def _round_key(vehicle_cid: str, round_number: int) -> str:
        return f"{vehicle_cid}#{round_number}"

    @staticmethod
    def _disabled_schedule() -> dict[str, Any]:
        return {"schemaVersion": 1, "enabled": False}

    @classmethod
    def _schedule_policy(cls, value: Mapping[str, Any] | None) -> dict[str, Any]:
        if not value or value.get("enabled") is not True:
            return cls._disabled_schedule()
        return {
            "schemaVersion": 1,
            "enabled": True,
            "periodSeconds": int(value["periodSeconds"]),
            "phaseSeconds": int(value["phaseSeconds"]),
        }

    @staticmethod
    def _slot_key(line_cid: str, stop_index: int) -> str:
        return f"{line_cid}#{int(stop_index)}"

    def _remember_slot_reservation(self, action: Mapping[str, Any]) -> None:
        schedule = action.get("schedule") or self._disabled_schedule()
        key = self._slot_key(str(action["lineCid"]), int(action["stopIndex"]))
        if schedule.get("enabled") is not True:
            # Prompt release supersedes a reservation restored from the old
            # timetable-enforced station policy.
            self.host.vehicle_sync_slot_reservations.pop(key, None)
            return
        self.host.vehicle_sync_slot_reservations[key] = {
            "lineCid": str(action["lineCid"]),
            "stopIndex": int(action["stopIndex"]),
            "periodSeconds": int(schedule["periodSeconds"]),
            "phaseSeconds": int(schedule["phaseSeconds"]),
            "slotIndex": int(schedule["slotIndex"]),
            "scheduledDepartureAt": float(schedule["scheduledDepartureAt"]),
        }

    def _complete_round(
        self, key: str, tracker: dict[str, Any], *, restoring: bool
    ) -> None:
        completed_at = time.monotonic()
        self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), completed_at)
        paused_duration = self.deadlines.complete(tracker, completed_at)
        tracker["status"] = "complete"
        tracker["completedAt"] = completed_at
        self.host.vehicle_sync_releases += 1
        schedule = tracker.get("schedule") or self._disabled_schedule()
        self.host.vehicle_sync_last_release = {
            "vehicleCid": tracker["vehicleCid"],
            "lineCid": tracker["lineCid"],
            "round": tracker["round"],
            "stopIndex": tracker["stopIndex"],
            "releaseAtGameTime": tracker.get("releaseAtGameTime"),
            "schedule": dict(schedule),
        }
        if not restoring:
            latency_ms = max(
                0.0,
                (
                    float(tracker["completedAt"])
                    - float(tracker["startedAt"])
                    - paused_duration
                ) * 1000.0,
            )
            self.host.vehicle_sync_latency_samples += 1
            self.host.vehicle_sync_latency_total_ms += latency_ms
            self.host.vehicle_sync_latency_max_ms = max(
                self.host.vehicle_sync_latency_max_ms, latency_ms
            )
        self.host.vehicle_sync_rounds.pop(key, None)
        self.host.vehicle_sync_pruned_rounds += 1

    def record(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        now = time.monotonic()
        self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), now)
        peer = str(message.get("peer", "unknown"))
        if peer not in self.host.required_peers:
            raise ProtocolError(f"vehicle sync report came from unexpected peer {peer}")
        payload = vehicle_sync_payload(message.get("payload"))
        payload.setdefault("schedule", self._disabled_schedule())
        self.host.vehicle_sync_reports += 1
        if payload["state"] == "fault":
            reason = f"vehicle-sync-local-fault:{peer}:{payload['vehicleCid']}:{payload['detail']}"
            self._remember_fault(reason) if restoring else self._fault_session(reason)
            return
        key = self._round_key(payload["vehicleCid"], payload["round"])
        last_round = int(self.host.vehicle_sync_last_round.get(payload["vehicleCid"], 0))
        tracker = self.host.vehicle_sync_rounds.get(key)
        if tracker is None:
            if payload["round"] != last_round + 1:
                if payload["round"] <= last_round:
                    return
                reason = "vehicle-sync-round-gap:" + key
                self._remember_fault(reason) if restoring else self._fault_session(reason)
                return
            tracker = {
                "vehicleCid": payload["vehicleCid"],
                "lineCid": payload["lineCid"],
                "round": payload["round"],
                "stopIndex": payload["stopIndex"],
                "requiredPeers": self.host.required_peers,
                "held": {}, "released": {}, "status": "waiting-arrivals",
                "startedAt": now,
                "deadline": now + self.ROUND_TIMEOUT,
            }
            self.deadlines.register(tracker, now)
            self.host.vehicle_sync_rounds[key] = tracker
            pending = sum(
                item.get("status") not in {"complete", "faulted"}
                for item in self.host.vehicle_sync_rounds.values()
            )
            self.host.vehicle_sync_peak_pending = max(self.host.vehicle_sync_peak_pending, pending)
        if payload["lineCid"] != tracker["lineCid"] or payload["stopIndex"] != tracker["stopIndex"]:
            reason = "vehicle-sync-stop-mismatch:" + key
            self._remember_fault(reason) if restoring else self._fault_session(reason)
            return
        bucket = tracker["held"] if payload["state"] == "held" else tracker["released"]
        previous = bucket.get(peer)
        if previous and (
            previous["vehicleCid"] != payload["vehicleCid"]
            or previous["lineCid"] != payload["lineCid"]
            or previous["round"] != payload["round"]
            or previous["stopIndex"] != payload["stopIndex"]
            or previous["state"] != payload["state"]
            or previous.get("schedule") != payload.get("schedule")
        ):
            raise ProtocolError(f"peer {peer} sent conflicting vehicle sync reports")
        bucket[peer] = payload
        if tracker.get("schedule") is not None and self._schedule_policy(
            tracker["schedule"]
        ) != self._schedule_policy(payload.get("schedule")):
            reason = "vehicle-sync-schedule-changed:" + key
            self._remember_fault(reason) if restoring else self._fault_session(reason)
            return
        if payload["state"] == "held":
            if tracker.get("status") in {"release-ordered", "complete"}:
                return
            if set(tracker["requiredPeers"]) <= set(tracker["held"]):
                schedules = [tracker["held"][name]["schedule"] for name in tracker["requiredPeers"]]
                if any(item != schedules[0] for item in schedules[1:]):
                    reason = "vehicle-sync-schedule-mismatch:" + key
                    self._remember_fault(reason) if restoring else self._fault_session(reason)
                    return
                tracker["schedule"] = dict(schedules[0])
                tracker["status"] = "ready-to-release"
                if not restoring:
                    self._maybe_emit_release(tracker)
        elif tracker.get("status") not in {"release-ordered", "complete"}:
            reason = "vehicle-sync-release-before-authority:" + key
            self._remember_fault(reason) if restoring else self._fault_session(reason)
        elif tracker.get("status") != "complete" \
                and set(tracker["requiredPeers"]) <= set(tracker["released"]):
            self._complete_round(key, tracker, restoring=restoring)

    def _maybe_emit_release(self, tracker: dict[str, Any]) -> None:
        now = time.monotonic()
        self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), now)
        if tracker.get("status") not in {"ready-to-release", "waiting-clock"}:
            return
        if self.host.clock_rendezvous:
            tracker["status"] = "waiting-clock"
            return
        if self.host.clock_effective_speed > 0 \
                and self.clock.skew_requires_rendezvous(now):
            tracker["status"] = "waiting-clock"
            self.clock.begin_rendezvous(
                self.host.clock_requested_speed, self.host.clock_effective_speed,
                "vehicle-release-clock-skew",
            )
            return
        reports = [tracker["held"][peer] for peer in tracker["requiredPeers"]]
        paused = self.host.clock_effective_speed == 0
        release_time = max(float(item["gameTime"]) for item in reports)
        samples = self.clock._fresh_samples()
        if not paused:
            if samples:
                release_time = max(release_time, *self.clock._projected_game_times(samples))
            release_time += self.clock._guard_distance(samples or reports, 1.5)
        report_schedule = tracker.get("schedule") or self._disabled_schedule()
        release_schedule = self._disabled_schedule()
        release_while_paused = paused
        if report_schedule.get("enabled") is True:
            period = int(report_schedule["periodSeconds"])
            phase = int(report_schedule["phaseSeconds"])
            slot_index = math.floor((release_time - phase) / period) + 1
            reservation_key = self._slot_key(tracker["lineCid"], tracker["stopIndex"])
            previous = self.host.vehicle_sync_slot_reservations.get(reservation_key)
            if previous and previous["periodSeconds"] == period \
                    and previous["phaseSeconds"] == phase:
                slot_index = max(slot_index, int(previous["slotIndex"]) + 1)
            slot_index = max(0, slot_index)
            scheduled = phase + slot_index * period
            release_time = float(scheduled)
            release_while_paused = False
            release_schedule = {
                "schemaVersion": 1, "enabled": True,
                "periodSeconds": period, "phaseSeconds": phase,
                "slotIndex": slot_index, "scheduledDepartureAt": scheduled,
            }
        action = {
            "type": "vehicle.sync_release",
            "vehicleCid": tracker["vehicleCid"], "lineCid": tracker["lineCid"],
            "round": tracker["round"], "stopIndex": tracker["stopIndex"],
            "releaseAtGameTime": release_time,
            "releaseWhilePaused": release_while_paused,
            "schedule": release_schedule,
        }
        message = self.clock._emit_action(action, "vehicle_sync_control")
        self._remember_slot_reservation(action)
        tracker.update({
            "controlSeq": message["seq"], "status": "release-ordered",
            "releaseAtGameTime": release_time,
            "releaseWhilePaused": release_while_paused,
            "schedule": release_schedule,
        })
        self.deadlines.reset(tracker, now)
        self.host.vehicle_sync_last_round[tracker["vehicleCid"]] = tracker["round"]
        print(
            f"vehicle sync release {tracker['vehicleCid']} round={tracker['round']} "
            f"stop={tracker['stopIndex']} at gameTime={release_time:.3f}"
        )

    def track_release(self, commit: Mapping[str, Any]) -> None:
        now = time.monotonic()
        self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), now)
        action = validate_action(commit.get("payload", {}).get("action"))
        key = self._round_key(action["vehicleCid"], action["round"])
        tracker = self.host.vehicle_sync_rounds.get(key)
        if tracker is None:
            tracker = {
                "vehicleCid": action["vehicleCid"], "lineCid": action["lineCid"],
                "round": action["round"], "stopIndex": action["stopIndex"],
                "requiredPeers": self.host.required_peers, "held": {}, "released": {},
                "startedAt": now, "deadline": now + self.ROUND_TIMEOUT,
            }
            self.deadlines.register(tracker, now)
            self.host.vehicle_sync_rounds[key] = tracker
        schedule = action.get("schedule") or self._disabled_schedule()
        if not tracker.get("releaseCounted"):
            if schedule["enabled"]:
                self.host.vehicle_sync_scheduled_releases += 1
            else:
                self.host.vehicle_sync_unscheduled_releases += 1
            tracker["releaseCounted"] = True
        tracker.update({
            "controlSeq": int(commit["seq"]), "status": "release-ordered",
            "releaseAtGameTime": action["releaseAtGameTime"],
            "releaseWhilePaused": action["releaseWhilePaused"],
            "schedule": dict(schedule), "acks": tracker.get("acks", {}),
        })
        self._remember_slot_reservation(action)
        self.host.vehicle_sync_last_round[action["vehicleCid"]] = max(
            int(self.host.vehicle_sync_last_round.get(action["vehicleCid"], 0)),
            int(action["round"]),
        )

    def flush(self) -> None:
        for tracker in list(self.host.vehicle_sync_rounds.values()):
            if tracker.get("status") in {"ready-to-release", "waiting-clock"}:
                self._maybe_emit_release(tracker)

    def resolve_ack(
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
                self._remember_fault(reason) if restoring else self._fault_session(reason)
            return

    def _remember_fault(self, reason: str) -> None:
        reason = str(reason)
        if reason not in self.host.vehicle_sync_fault_reasons:
            self.host.vehicle_sync_fault_reasons.add(reason)
            self.host.vehicle_sync_faults += 1
        self.host.session_fault = self.host.session_fault or reason
        self.host.last_error = reason

    def _fault_session(self, reason: str) -> None:
        self._remember_fault(reason)
        if not self.host.sync_fault_emitted:
            self.host.sync_fault_emitted = True
            self.clock._emit_action({
                "type": "network.sync_fault", "scope": "vehicle",
                "errorCode": str(reason)[:512],
            }, "synchronization_fault")
        self.clock.emergency_pause(str(reason))

    def restore_fault(self) -> None:
        if self.host.session_fault and not self.host.sync_fault_emitted \
                and str(self.host.session_fault).startswith("vehicle-sync-"):
            self._fault_session(str(self.host.session_fault))

    def expire(self, now: float) -> None:
        if self.deadlines.synchronize(self.host.vehicle_sync_rounds.values(), now):
            return
        for tracker in list(self.host.vehicle_sync_rounds.values()):
            if tracker.get("status") not in {"complete", "faulted"} \
                    and now >= float(tracker["deadline"]):
                tracker["status"] = "faulted"
                self._fault_session(
                    f"vehicle-sync-timeout:{tracker['vehicleCid']}:{tracker['round']}"
                )
