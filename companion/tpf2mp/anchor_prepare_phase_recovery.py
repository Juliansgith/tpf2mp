"""Bounded station-boundary search for an unsafe paused recovery phase."""

from __future__ import annotations

import time
from typing import Any, Mapping

from .mobility_telemetry import shares_enroute_native_leg


class AnchorPreparationPhaseRecovery:
    """Resume only long enough for every unsafe vehicle to cross a barrier."""

    TIMEOUT_SECONDS = 240.0
    MAX_ATTEMPTS = 4
    RECOVERABLE_REASONS = (
        "canonical station synchronization is not bound to the line",
        "local station synchronization has no matching line state",
        "local station synchronization phase is transient",
        "native terminal state disagrees with the station phase",
        "local and authorized station rounds differ",
        "terminal and synchronized stop indices differ",
        "station release report is still pending",
        "armed station release is not natively held",
        "native stop actuator disagrees with canonical stop intent",
    )

    def __init__(self, host: Any) -> None:
        self.host = host

    def begin(
        self, active: dict[str, Any], sample_key: str,
        allow_local_phase_divergence: bool = False,
    ) -> bool:
        peer_details = self.host.vehicle_restore_unsafe_details.get(sample_key, {})
        safety = self.host.vehicle_restore_safety.get(sample_key, {})
        unsafe_peers = [
            peer for peer in self.host.required_peers if safety.get(peer) is False
        ]
        required = [peer_details.get(peer) for peer in unsafe_peers]
        detail_sets = [set(item) if isinstance(item, Mapping) else set() for item in required]
        matching_targets = bool(detail_sets) and bool(detail_sets[0]) \
            and all(items == detail_sets[0] for items in detail_sets[1:])
        matching_details = matching_targets and all(
            dict(item) == dict(required[0]) for item in required[1:]
        )
        native_leg_matches = allow_local_phase_divergence and matching_targets \
            and shares_enroute_native_leg(
                self.host.vehicle_phase_details.get(sample_key, {}),
                set(self.host.required_peers), detail_sets[0],
            )
        if any(not isinstance(item, Mapping) or not item for item in required) \
                or not matching_targets or not (matching_details or native_leg_matches):
            active["status"] = "failed"
            active["detail"] = (
                "native vehicle state is unsafe and peers did not provide one "
                "matching recoverable vehicle set on the same enroute native leg"
            )
            return True
        details = dict(required[0])
        reasons = [
            part.strip() for item in required for reason in item.values()
            for part in reason.split(";")
        ]
        if any(reason not in self.RECOVERABLE_REASONS for reason in reasons):
            active["status"] = "failed"
            active["detail"] = (
                "native vehicle state is unsafe for a non-recoverable reason: "
                + "; ".join(sorted(set(reasons)))
            )
            return True
        attempts = int(active.get("phaseRecoveryAttempts", 0)) + 1
        if attempts > self.MAX_ATTEMPTS:
            active["status"] = "failed"
            active["detail"] = "native vehicle state did not stabilize after station-boundary retries"
            return True
        active.update({
            "status": "draining",
            "phaseRecoveryAttempts": attempts,
            "phaseRecovery": {
                "startedAt": time.monotonic(),
                "targets": {
                    cid: int(self.host.vehicle_sync_last_round.get(cid, 0))
                    for cid in sorted(details)
                },
            },
            "resumeSpeed": max(1, int(active.get("resumeSpeed", 0))),
            "detail": "resuming to the next synchronized station boundary",
        })
        for field in (
            "phaseProbeSeq", "phaseProbeKey", "phaseProbeStartedAt",
            "phaseVerified", "phaseProofSamples", "phaseSamplesVerified",
            "vehiclePhaseProof", "drainResumeCommitSeq",
        ):
            active.pop(field, None)
        return True

    def maintain(self, active: dict[str, Any], drain: Any) -> tuple[bool, bool]:
        recovery = active.get("phaseRecovery")
        if not isinstance(recovery, Mapping):
            return False, False
        if time.monotonic() - float(recovery.get("startedAt", 0.0)) \
                >= self.TIMEOUT_SECONDS:
            active["status"] = "failed"
            active["detail"] = "timed out reaching a synchronized station boundary"
            return True, True
        targets = recovery.get("targets")
        if not isinstance(targets, Mapping) or not targets:
            active["status"] = "failed"
            active["detail"] = "station-boundary recovery lost its vehicle targets"
            return True, True
        advanced = all(
            int(self.host.vehicle_sync_last_round.get(cid, 0)) > int(round_number)
            for cid, round_number in targets.items()
        )
        if advanced:
            active.pop("phaseRecovery", None)
            active["detail"] = "target vehicles crossed a synchronized station boundary"
            return False, True
        if self.host.clock_effective_speed <= 0:
            if self.host.anchor._pending_work():
                active["detail"] = "waiting for the temporary clock resume"
                return True, False
            return True, drain.resume(active)
        active["detail"] = "waiting for unsafe vehicles to cross a synchronized station boundary"
        return True, False
