from __future__ import annotations

from typing import Any, Mapping

from .completion_validation import (
    operation_completion_result_view,
    proposal_completion_result_view,
)
from .protocol import validate_action


class FaultRecoveryEvidence:
    """Select and bind the one physical rejection a fault may safely requalify."""

    def __init__(self, host: Any) -> None:
        self.host = host

    def candidate(self) -> tuple[str, dict[str, Any] | None]:
        fault = str(self.host.session_fault or "")
        if fault.startswith("proposal-completion-timeout:"):
            for _, tracker in sorted(self.host.proposal_consensus.items(), reverse=True):
                outcome = tracker.get("outcome") or {}
                if tracker.get("status") == "faulted" and outcome.get("errorCode") == fault:
                    return "proposal", tracker
        if fault in {
            "peer-native-operation-failed", "operation-rejection-proof-unavailable",
        }:
            for _, tracker in sorted(self.host.operation_consensus.items(), reverse=True):
                outcome = tracker.get("outcome") or {}
                if tracker.get("status") == "faulted" \
                        and tracker.get("operationKind") == "vehicle.assign" \
                        and outcome.get("errorCode") == fault:
                    return "operation", tracker
        return "", None

    def outcome_sequence(self, tracker: Mapping[str, Any], kind: str) -> int:
        recorded = int(tracker.get("outcomeSeq", 0))
        if recorded > 0:
            return recorded
        commit_seq = int(tracker.get("commitSeq", 0))
        for sequence, message in self.host.commits.items():
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") == f"network.{kind}_outcome" \
                    and int(action.get("commitSeq", 0)) == commit_seq:
                return int(sequence)
        return 0

    @staticmethod
    def late_rejection(
        tracker: Mapping[str, Any], kind: str
    ) -> tuple[dict[str, Any] | None, str]:
        required = tuple(str(peer) for peer in tracker.get("requiredPeers", ()))
        completions = tracker.get("completions") or {}
        missing = [peer for peer in required if peer not in completions]
        if missing:
            return None, "waiting for late native completion from " + ", ".join(missing)
        selected = [completions[peer] for peer in required]
        if not selected or any(item.get("success") is not False for item in selected):
            return None, "late peers did not all report the same failed native action"
        if any(item.get("outputs") or "financeDelta" in item for item in selected):
            return None, "late failure contains native outputs or a finance mutation"
        if len({item.get("errorCode") for item in selected}) != 1:
            return None, "late native failure codes differ between peers"
        if not isinstance(selected[0].get("errorCode"), str) or not selected[0]["errorCode"]:
            return None, "late native failure has no stable error identity"
        result_view = proposal_completion_result_view \
            if kind == "proposal" else operation_completion_result_view
        first_view = result_view(selected[0])
        if any(result_view(item) != first_view for item in selected[1:]):
            return None, "late physical result digests differ between peers"
        if len({item.get("coreDigest") for item in selected}) != 1:
            return None, "late authored core digests differ between peers"
        expected_core = str(tracker.get("preparedCoreDigest") or "") \
            if kind == "proposal" else FaultRecoveryEvidence._operation_core(tracker, required)
        if not expected_core or selected[0].get("coreDigest") != expected_core:
            return None, "late rejection did not preserve the prepared core digest"
        return dict(selected[0]), f"late {kind} rejection is identical and non-mutating"

    @staticmethod
    def _operation_core(tracker: Mapping[str, Any], required: tuple[str, ...]) -> str:
        acknowledgements = tracker.get("acks") or {}
        if not set(required) <= set(acknowledgements):
            return ""
        if any(acknowledgements[peer].get("success") is not True for peer in required):
            return ""
        digests = {
            acknowledgements[peer].get("digest")
            for peer in required
        }
        return str(next(iter(digests))) if len(digests) == 1 else ""

    def bound_action(
        self, tracker: Mapping[str, Any], outcome_seq: int,
        completion: Mapping[str, Any], requested_by: str, kind: str,
    ) -> dict[str, Any]:
        commit_seq = int(tracker["commitSeq"])
        shared = {
            "type": "recovery.requalify", "faultCommitSeq": commit_seq,
            "recoveryId": f"fault-recovery:{outcome_seq}:{commit_seq}",
            "faultOutcomeSeq": outcome_seq, "faultCode": str(self.host.session_fault),
            "resultDigest": str(completion["resultDigest"]),
            "expectedCoreDigest": str(completion["coreDigest"]),
            "nativeErrorCode": str(completion["errorCode"]),
            "requestedBy": str(requested_by),
        }
        if kind == "operation":
            return validate_action({
                **shared, "schemaVersion": 2, "faultType": "operation-rejection",
                "operationId": str(tracker["operationId"]),
                "operationDigest": str(tracker["operationDigest"]),
            })
        return validate_action({
            **shared, "schemaVersion": 1, "faultType": "proposal-timeout",
            "proposalId": str(tracker["proposalId"]),
            "proposalDigest": str(tracker["proposalDigest"]),
        })

    def registry(self, fault_type: str) -> dict[int, dict[str, Any]]:
        return self.host.proposal_consensus if fault_type == "proposal-timeout" \
            else self.host.operation_consensus

    @staticmethod
    def proof_fields(value: Mapping[str, Any]) -> tuple[str, ...]:
        identity = "proposalId" if value.get("faultType") == "proposal-timeout" \
            else "operationId"
        return (
            "schemaVersion", "recoveryId", "faultType", "faultCommitSeq",
            "faultOutcomeSeq", "faultCode", identity, "expectedCoreDigest",
        )
