from __future__ import annotations

from typing import Any, Mapping

from .protocol import ProtocolError, validate_action


PROOF_FIELDS = (
    "schemaVersion", "recoveryId", "faultType", "faultCommitSeq",
    "faultOutcomeSeq", "faultCode", "proposalId", "expectedCoreDigest",
)


def verified_fault_recoveries(
    ordered: Mapping[int, Mapping[str, Any]],
    checkpoint_outcomes: Mapping[int, Mapping[str, Any]],
    checkpoint_records: Mapping[int, Mapping[str, Mapping[str, Any]]],
) -> dict[int, dict[str, Any]]:
    """Return only timeout recoveries closed by their exact successful checkpoint."""

    recovered: dict[int, dict[str, Any]] = {}
    for boundary, outcome in checkpoint_outcomes.items():
        proof = outcome.get("faultRecovery")
        if proof is None:
            continue
        if not isinstance(proof, dict) or set(proof) != set(PROOF_FIELDS):
            raise ProtocolError("fault recovery checkpoint proof is malformed")
        message = ordered.get(int(boundary))
        action = (message.get("payload") or {}).get("action") if message else None
        if not message or message.get("kind") != "commit" \
                or not isinstance(action, dict) or action.get("type") != "recovery.requalify":
            raise ProtocolError("fault recovery checkpoint does not name its ordered probe")
        validated = validate_action(action)
        if any(proof.get(field) != validated.get(field) for field in PROOF_FIELDS):
            raise ProtocolError("fault recovery checkpoint proof differs from its ordered probe")
        if outcome.get("reason") != f"fault-recovery:{validated['recoveryId']}":
            raise ProtocolError("fault recovery checkpoint reason is not bound to its probe")
        fault_message = ordered.get(int(validated["faultOutcomeSeq"]))
        fault = (fault_message.get("payload") or {}).get("action") if fault_message else None
        if not fault_message or fault_message.get("kind") != "control" \
                or not isinstance(fault, dict) or fault.get("type") != "network.proposal_outcome":
            raise ProtocolError("fault recovery references an unknown proposal timeout")
        if fault.get("success") is True or fault.get("recoverable") is True \
                or int(fault.get("commitSeq", 0)) != validated["faultCommitSeq"] \
                or fault.get("proposalId") != validated["proposalId"] \
                or fault.get("proposalDigest") != validated["proposalDigest"] \
                or fault.get("errorCode") != validated["faultCode"]:
            raise ProtocolError("fault recovery does not match its original timeout outcome")
        if outcome.get("success") is not True:
            continue
        if outcome.get("coreDigest") != validated["expectedCoreDigest"]:
            raise ProtocolError("fault recovery checkpoint changed the expected authored core")
        required = set(str(peer) for peer in outcome.get("peers", []))
        records = checkpoint_records.get(int(boundary), {})
        if not required or not required <= set(records):
            raise ProtocolError("fault recovery checkpoint lacks all-peer records")
        for field in ("structuralDigest", "worldManifestDigest"):
            values = {records[peer].get(field) for peer in required}
            if len(values) != 1 or outcome.get(field) != next(iter(values)):
                raise ProtocolError(f"fault recovery checkpoint {field} does not converge")
        commit_seq = int(validated["faultCommitSeq"])
        if commit_seq in recovered:
            raise ProtocolError("proposal timeout has more than one successful recovery")
        recovered[commit_seq] = dict(validated)
    return recovered
