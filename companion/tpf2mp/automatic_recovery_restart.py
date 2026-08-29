"""Journal restart adoption for automatic recovery preparation."""

from __future__ import annotations

from typing import Any, Mapping


def adopt_recovered_preparation(
    scheduler: Any,
    active: Mapping[str, Any] | None,
    points: list[int],
    now: float,
) -> None:
    """Resume ownership of an unfinished host-authored preparation."""

    if not isinstance(active, Mapping) or active.get("automatic") is not True \
            or str(active.get("status", "")) in {"failed", "superseded"}:
        return
    scheduler.preparation_seq = int(active.get("preparationSeq", 0)) or None
    scheduler.started_at = now
    scheduler.resume_speed = max(0, int(active.get("resumeSpeed", 0)))
    boundary = int(active.get("checkpointBoundarySeq") or 0)
    if scheduler.preparation_seq is not None and boundary in points:
        scheduler.receipts_observed_at = now
        scheduler.state = "finalizing"
    else:
        status = str(active.get("status", "preparing"))
        scheduler.state = "saving" if status in {"converged", "ready"} else "preparing"
    scheduler.attempts = 1
