from __future__ import annotations

import re
from typing import Any, Mapping


def validation_error(action: Mapping[str, Any], maximum: int) -> str | None:
    if set(action) == {"type"}:
        return None
    expected = {
        "type", "schemaVersion", "recoveryId", "faultType", "faultCommitSeq",
        "faultOutcomeSeq", "faultCode", "proposalId", "proposalDigest",
        "resultDigest", "expectedCoreDigest", "nativeErrorCode", "requestedBy",
    }
    if set(action) != expected or action.get("schemaVersion") != 1:
        return "recovery.requalify has unknown or missing fields"
    commit_seq, outcome_seq = action.get("faultCommitSeq"), action.get("faultOutcomeSeq")
    if any(isinstance(value, bool) or not isinstance(value, int)
           for value in (commit_seq, outcome_seq)) \
            or not 1 <= commit_seq < outcome_seq <= maximum:
        return "recovery.requalify has invalid ordered boundaries"
    if action.get("faultType") != "proposal-timeout":
        return "recovery.requalify fault type is unsupported"
    if action.get("recoveryId") != f"fault-recovery:{outcome_seq}:{commit_seq}":
        return "recovery.requalify identity is invalid"
    fault_code = action.get("faultCode")
    if not isinstance(fault_code, str) \
            or not fault_code.startswith("proposal-completion-timeout:") \
            or len(fault_code) > 512:
        return "recovery.requalify fault code is invalid"
    proposal_id = action.get("proposalId")
    if not isinstance(proposal_id, str) or not proposal_id or len(proposal_id) > 320:
        return "recovery.requalify proposal identity is invalid"
    for field in ("proposalDigest", "resultDigest", "expectedCoreDigest"):
        if not isinstance(action.get(field), str) \
                or not re.fullmatch(r"[0-9a-f]{8}", action[field]):
            return f"recovery.requalify {field} is invalid"
    native_error, requested_by = action.get("nativeErrorCode"), action.get("requestedBy")
    if not isinstance(native_error, str) or not native_error or len(native_error) > 512:
        return "recovery.requalify native error is invalid"
    if not isinstance(requested_by, str) \
            or not re.fullmatch(r"player[1-9][0-9]*", requested_by):
        return "recovery.requalify requester is invalid"
    return None

