"""Wire projection and validation for periodic recovery preparation."""

from __future__ import annotations

from typing import Any, Mapping

from .protocol import ProtocolError


DEFAULT_AUTOMATIC_RECOVERY: dict[str, Any] = {
    "enabled": False,
    "intervalSeconds": 0,
    "timeoutSeconds": 0,
    "status": "disabled",
    "preparationSeq": None,
    "lastBoundarySeq": None,
    "lastCompletedAtUnix": None,
    "lastCompletedAgeSeconds": None,
    "nextDueInSeconds": None,
    "attempts": 0,
    "lastError": None,
}


def status_projection(scheduler: Any) -> dict[str, Any]:
    now = scheduler.monotonic()
    age = None
    if scheduler.last_completed_at_unix is not None:
        age = max(0, int(scheduler.wall_time()) - scheduler.last_completed_at_unix)
    return {"automaticRecovery": {
        "enabled": scheduler.enabled,
        "intervalSeconds": int(scheduler.interval_seconds),
        "timeoutSeconds": int(scheduler.timeout_seconds),
        "status": scheduler.state,
        "preparationSeq": scheduler.preparation_seq,
        "lastBoundarySeq": scheduler.last_boundary or None,
        "lastCompletedAtUnix": scheduler.last_completed_at_unix,
        "lastCompletedAgeSeconds": age,
        "nextDueInSeconds": max(0, int(scheduler.next_due_at - now))
        if scheduler.enabled else None,
        "attempts": scheduler.attempts,
        "lastError": scheduler.last_error,
    }}


def validate_automatic_recovery(value: Any) -> dict[str, Any]:
    expected = set(DEFAULT_AUTOMATIC_RECOVERY)
    if not isinstance(value, Mapping) or set(value) != expected \
            or not isinstance(value.get("enabled"), bool):
        raise ProtocolError("automatic recovery state is invalid")
    if value.get("status") not in {
        "disabled", "scheduled", "waiting", "preparing", "saving",
        "finalizing", "retry-wait",
    }:
        raise ProtocolError("automatic recovery status is invalid")
    for field in ("intervalSeconds", "timeoutSeconds", "attempts"):
        item = value.get(field)
        if not isinstance(item, int) or isinstance(item, bool) or item < 0:
            raise ProtocolError(f"automatic recovery {field} is invalid")
    for field in (
        "preparationSeq", "lastBoundarySeq", "lastCompletedAtUnix",
        "lastCompletedAgeSeconds", "nextDueInSeconds",
    ):
        item = value.get(field)
        if item is not None and (
            not isinstance(item, int) or isinstance(item, bool) or item < 0
        ):
            raise ProtocolError(f"automatic recovery {field} is invalid")
    error = value.get("lastError")
    if error is not None and (not isinstance(error, str) or len(error) > 512):
        raise ProtocolError("automatic recovery lastError is invalid")
    return dict(value)
