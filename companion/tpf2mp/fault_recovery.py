from __future__ import annotations

import time
from typing import Any, Mapping

from .fault_recovery_evidence import FaultRecoveryEvidence
from .protocol import ProtocolError, validate_action


SAFE_POST_FAULT_ACTIONS = frozenset({
    "clock.set",
    "clock.rendezvous",
    "network.intent_rejected",
})


class FaultRecoveryCoordinator:
    """Requalify one proven non-mutating timeout without erasing its audit trail."""

    def __init__(self, host: Any) -> None:
        self.host = host
        self.evidence = FaultRecoveryEvidence(host)
        self.current: dict[str, Any] | None = None
        self.last: dict[str, Any] | None = None

    def _post_fault_work_reason(self, outcome_seq: int) -> str | None:
        for sequence in sorted(self.host.commits):
            if sequence <= outcome_seq:
                continue
            action = (self.host.commits[sequence].get("payload") or {}).get("action") or {}
            action_type = str(action.get("type", ""))
            if action_type not in SAFE_POST_FAULT_ACTIONS:
                return f"ordered action {sequence} ({action_type or 'unknown'}) followed the fault"
        return None

    def _quiescence_reason(self, outcome_seq: int, now: float) -> str | None:
        if not self.host.synchronization.shared_pause_acknowledged():
            return "waiting for both games to acknowledge the shared pause"
        latest_seq = max(0, self.host.next_seq - 1)
        for peer in self.host.required_peers:
            sample = self.host.clock_health.get(peer)
            if not sample:
                return f"waiting for recovery health from {peer}"
            if now - float(sample.get("receivedAt", 0.0)) > 6.0:
                return f"recovery health from {peer} is stale"
            if int(sample.get("schemaVersion", 0)) < 4:
                return f"waiting for recovery-capable health from {peer}"
            if int(sample.get("lastCommitSeq", -1)) < max(outcome_seq, latest_seq):
                return f"{peer} has not consumed the complete fault boundary"
            if sample.get("localWorkPending") is True \
                    or int(sample.get("deferredIntentCount", 0)) > 0:
                return f"{peer} still has local ordered work pending"
            if sample.get("proposalPending") is True:
                return f"{peer} still reports a native proposal in progress"
            if abs(float(sample.get("observedSpeed") or 0.0)) > 0.01 \
                    or int(sample.get("effectiveSpeed", 0)) != 0:
                return f"{peer} is not natively paused"
            if str(sample.get("faultCode") or "") != str(self.host.session_fault or ""):
                return f"{peer} does not attest the same session fault"
            if int(sample.get("originResidueCount", -1)) != 0:
                return f"{peer} reports unowned native mutation residue"
        return None

    def assessment(self) -> dict[str, Any]:
        if self.current and self.current.get("status") == "probing":
            return {
                "status": "probing", "eligible": False,
                "detail": "fresh all-peer structural checkpoint is in progress",
                **self._identity(self.current),
            }
        if not self.host.session_fault:
            record = self.last if self.last and self.last.get("status") == "recovered" else None
            return {
                "status": "recovered" if record else "healthy",
                "eligible": False,
                "detail": "the prior timeout was requalified; session remains paused"
                if record else "no session fault is active",
                **self._identity(record),
            }
        if self.host.audit_failure.is_set():
            return self._blocked("authority audit is unavailable; restore is required")
        kind, tracker = self.evidence.candidate()
        if not tracker:
            return self._blocked("this fault is ambiguous and requires a verified restore")
        outcome_seq = self.evidence.outcome_sequence(tracker, kind)
        if outcome_seq < 1:
            return self._blocked("the timeout outcome has no durable ordered identity")
        unsafe = self._post_fault_work_reason(outcome_seq)
        if unsafe:
            return self._blocked(unsafe)
        completion, detail = self.evidence.late_rejection(tracker, kind)
        if not completion:
            status = "waiting-evidence" if detail.startswith("waiting") else "rollback-required"
            return self._blocked(detail, status=status)
        waiting = self._quiescence_reason(outcome_seq, time.monotonic())
        if waiting:
            status = "rollback-required" if "mutation residue" in waiting else "waiting-quiescence"
            return self._blocked(waiting, status=status)
        recovery = self.evidence.bound_action(
            tracker, outcome_seq, completion, str(self.host.bridge.peer), kind
        )
        return {
            "status": "ready", "eligible": True,
            "detail": "safe retry is ready; a fresh checkpoint will prove both worlds",
            **self._identity(recovery),
        }

    @staticmethod
    def _identity(value: Mapping[str, Any] | None) -> dict[str, Any]:
        value = value or {}
        return {
            "recoveryId": value.get("recoveryId"),
            "boundarySeq": value.get("boundarySeq"),
            "faultCode": value.get("faultCode"),
        }

    def _blocked(self, detail: str, *, status: str = "rollback-required") -> dict[str, Any]:
        return {
            "status": status, "eligible": False, "detail": str(detail)[:512],
            "recoveryId": None, "boundarySeq": None,
            "faultCode": self.host.session_fault,
        }

    def prepare_action(self, origin: str) -> dict[str, Any]:
        assessment = self.assessment()
        if assessment.get("eligible") is not True:
            raise ProtocolError("session cannot be recovered in place: " + str(assessment["detail"]))
        kind, tracker = self.evidence.candidate()
        assert tracker is not None
        completion, _ = self.evidence.late_rejection(tracker, kind)
        assert completion is not None
        return self.evidence.bound_action(
            tracker, self.evidence.outcome_sequence(tracker, kind), completion,
            str(origin), kind,
        )

    def observe_ordered(self, message: Mapping[str, Any], restoring: bool = False) -> None:
        action = (message.get("payload") or {}).get("action") or {}
        if action.get("type") != "recovery.requalify":
            return
        validated = validate_action(action)
        boundary = int(message.get("seq", 0))
        self.current = {
            **validated, "status": "probing", "boundarySeq": boundary,
            "reason": f"fault-recovery:{validated['recoveryId']}",
        }
        self.host._track_checkpoint_boundary(boundary, self.current["reason"])
        registry = self.evidence.registry(str(validated["faultType"]))
        tracker = registry.get(int(validated["faultCommitSeq"]))
        if tracker:
            tracker["recovery"] = dict(self.current)

    def decorate_checkpoint(self, tracker: Mapping[str, Any], action: dict[str, Any]) -> None:
        current = self.current
        if not current or current.get("status") != "probing" \
                or int(current.get("boundarySeq", 0)) != int(tracker.get("boundarySeq", -1)):
            return
        action["faultRecovery"] = {
            key: current[key] for key in self.evidence.proof_fields(current)
        }

    def checkpoint_failure(self, tracker: Mapping[str, Any]) -> str | None:
        current = self.current
        if not current or current.get("status") != "probing" \
                or int(current.get("boundarySeq", 0)) != int(tracker.get("boundarySeq", -1)):
            return None
        selected = [
            (tracker.get("checkpoints") or {}).get(peer)
            for peer in tracker.get("requiredPeers", ())
        ]
        if any(not isinstance(item, Mapping) for item in selected):
            return "fault-recovery-checkpoint-missing-peer"
        for field in ("structuralDigest", "worldManifestDigest"):
            values = {item.get(field) for item in selected if item}
            if len(values) != 1 or not isinstance(next(iter(values), None), str) \
                    or len(next(iter(values))) != 8:
                return f"fault-recovery-{field}-mismatch"
        if any(item.get("coreDigest") != current.get("expectedCoreDigest") for item in selected):
            return "fault-recovery-core-changed"
        return None

    def observe_checkpoint_outcome(
        self, action: Mapping[str, Any], outcome_seq: int | None = None
    ) -> None:
        proof = action.get("faultRecovery")
        if not isinstance(proof, Mapping):
            return
        current = self.current
        fields = self.evidence.proof_fields(current or {})
        if not current or set(proof) != set(fields) \
                or any(proof.get(key) != current.get(key) for key in fields) \
                or int(action.get("boundarySeq", 0)) != int(current.get("boundarySeq", -1)) \
                or action.get("reason") != f"fault-recovery:{current.get('recoveryId')}":
            raise ProtocolError("fault recovery checkpoint does not match its ordered probe")
        if action.get("success") is not True:
            current["status"] = "rollback-required"
            current["detail"] = str(action.get("errorCode") or "recovery checkpoint failed")
            self.last, self.current = dict(current), None
            return
        if action.get("coreDigest") != current.get("expectedCoreDigest"):
            raise ProtocolError("fault recovery checkpoint changed the expected authored core")
        if str(self.host.session_fault or "") != str(current["faultCode"]):
            raise ProtocolError("fault recovery tried to clear a different session fault")
        registry = self.evidence.registry(str(current["faultType"]))
        tracker = registry.get(int(current["faultCommitSeq"]))
        if not tracker:
            raise ProtocolError("fault recovery tracker is unavailable")
        tracker["status"] = "rejected"
        tracker["recovered"] = True
        tracker["recovery"] = {**dict(current), "checkpointOutcomeSeq": outcome_seq}
        current.update({
            "status": "recovered", "checkpointOutcomeSeq": outcome_seq,
            "detail": "late rejection and fresh checkpoint converged",
        })
        self.host.session_fault = None
        self.host.last_error = None
        self.host.sync_fault_emitted = False
        self.last, self.current = dict(current), None

    def status(self) -> dict[str, Any]:
        return {"faultRecovery": self.assessment()}
