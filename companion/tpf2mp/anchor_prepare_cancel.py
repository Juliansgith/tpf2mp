"""Ordered cancellation of a timed-out native-save preparation."""

from __future__ import annotations

from typing import Any, Mapping


def is_internal_cancel(
    host: Any, active: Mapping[str, Any], action: Mapping[str, Any],
    origin: str, local_seq: int,
) -> bool:
    return action.get("type") == "recovery.cancel" \
        and origin == host.bridge.peer and local_seq < 0 \
        and int(action.get("preparationSeq", 0)) == int(active.get("preparationSeq", -1))


def observe_cancel(
    host: Any, current: dict[str, Any] | None, action: Mapping[str, Any],
) -> bool:
    if action.get("type") != "recovery.cancel":
        return False
    preparation_seq = int(action.get("preparationSeq", 0))
    if current and int(current.get("preparationSeq", -1)) == preparation_seq:
        boundary = int(current.get("checkpointBoundarySeq") or 0)
        tracker = host.checkpoint_consensus.get(boundary)
        if tracker and tracker.get("status") == "pending":
            tracker["status"] = "superseded"
        current["status"] = "failed"
        current["detail"] = str(
            action.get("errorCode") or "restore-point preparation cancelled"
        )
    return True
