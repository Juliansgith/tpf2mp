from __future__ import annotations

from typing import Any, Mapping, Sequence

from .completion_validation import operation_completion_result_view


RECOVERABLE_KINDS = frozenset({"vehicle.assign"})
_STATE_FIELDS = {
    "schemaVersion", "targetCid", "lineCid", "stopIndex",
    "userStopped", "sellOnArrival",
}


def proof_error(
    tracker: Mapping[str, Any],
    selected: Sequence[Mapping[str, Any]],
) -> str | None:
    """Validate an all-peer, atomic, physically unchanged assignment rejection."""

    if tracker.get("operationKind") not in RECOVERABLE_KINDS:
        return "peer-native-operation-failed"
    if any(item.get("success") is not False for item in selected):
        return "mixed-native-operation-results"
    if any(item.get("outputs") or "financeDelta" in item for item in selected):
        return "failed-native-operation-left-mutation-residue"
    if len({item.get("errorCode") for item in selected}) != 1 \
            or not isinstance(selected[0].get("errorCode"), str) \
            or not selected[0].get("errorCode"):
        return "native-operation-rejection-error-mismatch"
    first_result = operation_completion_result_view(selected[0])
    if any(operation_completion_result_view(item) != first_result for item in selected[1:]):
        return "operation-physical-result-digest-mismatch"
    if len({item.get("coreDigest") for item in selected}) != 1:
        return "operation-physical-core-digest-mismatch"
    required = set(str(peer) for peer in tracker.get("requiredPeers", ()))
    acknowledgements = tracker.get("acks") or {}
    if not required <= set(acknowledgements):
        return "operation-rejection-acknowledgement-missing"
    selected_acks = [acknowledgements[peer] for peer in required]
    if any(item.get("success") is not True for item in selected_acks):
        return "operation-rejection-queue-acknowledgement-failed"
    ack_digests = {item.get("digest") for item in selected_acks}
    if len(ack_digests) != 1 or selected[0].get("coreDigest") not in ack_digests:
        return "operation-rejection-mutated-committed-core"
    transaction = tracker.get("transaction") or {}
    target_cid = (transaction.get("data") or {}).get("targetCid")
    proof = selected[0].get("postcondition")
    if not _valid_proof(proof, target_cid):
        return "operation-rejection-proof-unavailable"
    return None


def _valid_proof(value: Any, target_cid: Any) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "kind", "targetCid", "before", "after",
    } or value.get("schemaVersion") != 1 \
            or value.get("kind") != "vehicle.assign.rejection" \
            or value.get("targetCid") != target_cid:
        return False
    before, after = value.get("before"), value.get("after")
    if not isinstance(before, dict) or not isinstance(after, dict) \
            or set(before) != _STATE_FIELDS or set(after) != _STATE_FIELDS \
            or before != after:
        return False
    return (
        before.get("schemaVersion") == 1
        and before.get("targetCid") == target_cid
        and isinstance(before.get("lineCid"), str)
        and isinstance(before.get("stopIndex"), int)
        and not isinstance(before.get("stopIndex"), bool)
        and isinstance(before.get("userStopped"), bool)
        and isinstance(before.get("sellOnArrival"), bool)
    )
