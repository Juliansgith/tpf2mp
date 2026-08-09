from __future__ import annotations

from collections.abc import Mapping, Sequence, Set
from typing import Any

from .protocol import MAX_EXACT_INTEGER, ProtocolError


def _count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) \
            or not 0 <= value <= MAX_EXACT_INTEGER:
        raise ProtocolError(f"aboard witness has an invalid {label}")
    return value


def verify_aboard_witness(
    action: Mapping[str, Any],
    action_type: str,
    lines: Sequence[Mapping[str, Any]],
    vehicles: Sequence[Mapping[str, Any]],
    *,
    allowed_line_cids: Set[str] | None = None,
    reject_retired: bool = False,
) -> dict[str, Any] | None:
    """Bind a milestone's bounded observation to a later exact checkpoint.

    The vehicle may have alighted by checkpoint time. Monotonic round and
    boarding cursors prove that both peers' current authored ledgers include
    the release observed by the host, without trusting native position.
    """

    if action.get("type") != action_type or "observedRound" not in action:
        return None
    line_cid = action.get("lineCid")
    vehicle_cid = action.get("vehicleCid")
    if allowed_line_cids is not None and line_cid not in allowed_line_cids:
        return None
    observed_round = _count(action.get("observedRound"), "round")
    boarded_total = _count(action.get("boardedTotal"), "boarded total")
    aboard = _count(action.get("aboard"), "aboard count")
    line = next((item for item in lines if item.get("lineCid") == line_cid), None)
    vehicle = next(
        (
            item for item in vehicles
            if item.get("vehicleCid") == vehicle_cid
            and item.get("lineCid") == line_cid
        ),
        None,
    )
    if not line or not vehicle or (reject_retired and line.get("retired") is True) \
            or aboard < 1 or boarded_total < aboard \
            or _count(vehicle.get("lastRound"), "vehicle round") < observed_round \
            or _count(vehicle.get("boardedTotal"), "vehicle boarding") < boarded_total \
            or _count(line.get("boardedTotal"), "line boarding") < boarded_total:
        return None
    return {
        "lineCid": line_cid,
        "vehicleCid": vehicle_cid,
        "observedRound": observed_round,
        "boardedTotal": boarded_total,
        "aboard": aboard,
    }
