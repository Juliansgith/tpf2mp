from __future__ import annotations

import re
from typing import Any, Mapping


def validation_error(action: Mapping[str, Any], maximum: int) -> str | None:
    expected = {
        "type", "schemaVersion", "recoveryId", "faultType", "faultCommitSeq",
        "faultOutcomeSeq", "faultCode", "operationId", "operationDigest",
        "resultDigest", "expectedCoreDigest", "nativeErrorCode", "requestedBy",
    }
    if set(action) != expected or action.get("faultType") != "operation-rejection":
        return "operation recovery.requalify has unknown or missing fields"
    commit_seq, outcome_seq = action.get("faultCommitSeq"), action.get("faultOutcomeSeq")
    if any(isinstance(value, bool) or not isinstance(value, int)
           for value in (commit_seq, outcome_seq)) \
            or not 1 <= commit_seq < outcome_seq <= maximum:
        return "operation recovery.requalify has invalid ordered boundaries"
    if action.get("recoveryId") != f"fault-recovery:{outcome_seq}:{commit_seq}":
        return "operation recovery.requalify identity is invalid"
    if action.get("faultCode") not in {
        "peer-native-operation-failed", "operation-rejection-proof-unavailable",
    }:
        return "operation recovery.requalify fault code is unsupported"
    operation_id = action.get("operationId")
    if not isinstance(operation_id, str) or not operation_id or len(operation_id) > 320:
        return "operation recovery.requalify operation identity is invalid"
    for field in ("operationDigest", "resultDigest", "expectedCoreDigest"):
        if not isinstance(action.get(field), str) \
                or not re.fullmatch(r"[0-9a-f]{8}", action[field]):
            return f"operation recovery.requalify {field} is invalid"
    native_error, requested_by = action.get("nativeErrorCode"), action.get("requestedBy")
    if not isinstance(native_error, str) or not native_error or len(native_error) > 512:
        return "operation recovery.requalify native error is invalid"
    if not isinstance(requested_by, str) \
            or not re.fullmatch(r"player[1-9][0-9]*", requested_by):
        return "operation recovery.requalify requester is invalid"
    return None
