"""Paused native-vehicle phase proof for coordinated recovery anchors."""

from __future__ import annotations

import time
from typing import Any, Mapping

from .protocol import ProtocolError
from .anchor_prepare_phase_recovery import AnchorPreparationPhaseRecovery
from .mobility_telemetry import vehicle_round_cursors


class AnchorPreparationPhase:
    """Refuse a native save unless every peer targets the same next stop.

    Canonical checkpoints deliberately exclude moving vehicle coordinates. A
    pair of worlds can therefore agree financially and structurally while one
    copy of a train is on the opposite leg. Saving that pair only postpones
    the mismatch until the next station barrier. One ordered mobility probe,
    pair of consecutive ordered samples taken after the shared clock is paused binds
    the portable terminal/stop/barrier view without treating exact metres or
    native passengers as authority.
    """

    RESULT_TIMEOUT_SECONDS = 15.0
    REQUIRED_CONSECUTIVE_SAMPLES = 2

    def __init__(self, host: Any) -> None:
        self.host = host
        self.recovery = AnchorPreparationPhaseRecovery(host)

    def internal_probe(
        self,
        active: Mapping[str, Any] | None,
        action_type: str,
        origin: str,
        local_seq: int,
    ) -> bool:
        return bool(
            active
            and active.get("status") == "pausing"
            and action_type == "probe.mobility"
            and origin == self.host.bridge.peer
            and local_seq < 0
        )

    def observe_ordered(
        self,
        active: dict[str, Any] | None,
        message: Mapping[str, Any],
        action: Mapping[str, Any],
    ) -> bool:
        if not active or active.get("status") != "pausing" \
                or action.get("type") != "probe.mobility" \
                or str(message.get("origin_peer")) != self.host.bridge.peer \
                or int(message.get("origin_local_seq", 0)) >= 0:
            return False
        sequence = int(message.get("seq", 0))
        active.update({
            "phaseProbeSeq": sequence,
            "phaseProbeKey": (
                f"{self.host.bridge.session}:{self.host.bridge.peer}:{sequence}"
            ),
            "phaseProbeStartedAt": time.monotonic(),
            "phaseVerified": False,
            "detail": "comparing paused native vehicle restore phases",
        })
        return True

    def _emit(self, active: dict[str, Any]) -> bool:
        active["detail"] = "requesting a paused native vehicle route-phase sample"
        try:
            ordered = self.host.emit_local_intent({"type": "probe.mobility"})
        except ProtocolError as exc:
            active["detail"] = str(exc)
            return False
        if not ordered:
            return False
        # ``observe_ordered`` normally installs these fields synchronously.
        # Retain a defensive assignment for simple migration/test hosts.
        sequence = int(ordered.get("seq", 0))
        active.setdefault("phaseProbeSeq", sequence)
        active.setdefault(
            "phaseProbeKey",
            f"{self.host.bridge.session}:{self.host.bridge.peer}:{sequence}",
        )
        active.setdefault("phaseProbeStartedAt", time.monotonic())
        active.setdefault("phaseVerified", False)
        return True

    def maintain(self, active: dict[str, Any]) -> tuple[bool, bool]:
        """Return ``(handled, changed)`` before checkpoint creation."""

        if active.get("phaseVerified") is True:
            return False, False
        if not active.get("phaseProbeSeq"):
            return True, self._emit(active)

        sample_key = str(active.get("phaseProbeKey") or "")
        outcome = self.host.vehicle_phase_outcomes.get(sample_key)
        if outcome == "converged":
            safety = self.host.vehicle_restore_safety.get(sample_key, {})
            if len(safety) >= len(self.host.required_peers):
                unsafe = sorted(peer for peer in self.host.required_peers if safety.get(peer) is not True)
                if unsafe:
                    return True, self.recovery.begin(active, sample_key)
                phase_digests = self.host.vehicle_phase_digests.get(sample_key, {})
                required_digests = {
                    str(phase_digests.get(peer) or "")
                    for peer in self.host.required_peers
                }
                if "" in required_digests or len(required_digests) != 1:
                    active["status"] = "failed"
                    active["detail"] = (
                        "paused native vehicle phase proof has incomplete peer digests"
                    )
                    return True, True
                phase_digest = next(iter(required_digests))
                round_cursors = vehicle_round_cursors(
                    self.host.vehicle_phase_details.get(sample_key, {}),
                    set(self.host.required_peers),
                )
                if round_cursors is None:
                    active["status"] = "failed"
                    active["detail"] = (
                        "paused native vehicle phase proof has incomplete "
                        "station-round cursors"
                    )
                    return True, True
                samples = list(active.get("phaseProofSamples") or [])
                if samples and (
                    samples[0]["vehiclePhaseDigest"] != phase_digest
                    or samples[0]["vehicleRounds"] != round_cursors
                ):
                    active["status"] = "failed"
                    active["detail"] = (
                        "native vehicle route phase changed between paused samples"
                    )
                    return True, True
                samples.append({
                    "sampleKey": sample_key,
                    "vehiclePhaseDigest": phase_digest,
                    "vehicleRounds": round_cursors,
                })
                active["phaseProofSamples"] = samples
                verified = int(active.get("phaseSamplesVerified", 0)) + 1
                active["phaseSamplesVerified"] = verified
                if verified >= self.REQUIRED_CONSECUTIVE_SAMPLES:
                    active["phaseVerified"] = True
                    active["vehiclePhaseProof"] = {
                        "schemaVersion": 1,
                        "sampleKeys": [item["sampleKey"] for item in samples],
                        "vehiclePhaseDigest": phase_digest,
                        "vehicleRounds": round_cursors,
                    }
                    active["detail"] = "paused native vehicle restore phases are stable"
                    return False, True
                for field in ("phaseProbeSeq", "phaseProbeKey", "phaseProbeStartedAt"):
                    active.pop(field, None)
                active["detail"] = "repeating paused native vehicle restore-phase proof"
                return True, self._emit(active)
        if outcome == "diverged":
            safety = self.host.vehicle_restore_safety.get(sample_key, {})
            if len(safety) >= len(self.host.required_peers) and all(
                safety.get(peer) is False for peer in self.host.required_peers
            ):
                return True, self.recovery.begin(
                    active, sample_key, allow_local_phase_divergence=True,
                )
            active["status"] = "failed"
            active["detail"] = (
                "native vehicle route phases differ across peers; resume and "
                "synchronize trains before preparing another restore point"
            )
            return True, True

        started = float(active.get("phaseProbeStartedAt", time.monotonic()))
        if time.monotonic() - started >= self.RESULT_TIMEOUT_SECONDS:
            active["status"] = "failed"
            active["detail"] = (
                "timed out waiting for both paused vehicle route-phase samples"
            )
            return True, True
        active["detail"] = "waiting for both paused native vehicle restore-phase samples"
        return True, False
