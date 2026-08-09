from __future__ import annotations

from collections.abc import Mapping
from typing import Any


class AboardMilestoneError(ValueError):
    pass


def _cid(value: Any, kind: str) -> bool:
    return isinstance(value, str) and 0 < len(value) <= 240 \
        and value.startswith(kind + ":") and not any(ord(char) < 32 for char in value)


def _integer(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate(action: Mapping[str, Any], action_type: str, maximum: int) -> None:
    legacy = {"type", "stage", "lineCid", "vehicleCid"}
    witnessed = legacy | {"observedRound", "boardedTotal", "aboard"}
    fields = frozenset(action)
    if fields not in {frozenset(legacy), frozenset(witnessed)} \
            or action.get("stage") != "aboard" \
            or not _cid(action.get("lineCid"), "line") \
            or not _cid(action.get("vehicleCid"), "vehicle"):
        label = "passenger" if action_type == "passenger.milestone" else "freight"
        raise AboardMilestoneError(f"{label} aboard milestone is invalid")
    if fields == witnessed:
        observed_round = action.get("observedRound")
        boarded_total = action.get("boardedTotal")
        aboard = action.get("aboard")
        if not all(_integer(value) for value in (observed_round, boarded_total, aboard)) \
                or not 1 <= observed_round <= maximum \
                or not 1 <= aboard <= boarded_total <= maximum:
            raise AboardMilestoneError("aboard milestone load witness is invalid")
