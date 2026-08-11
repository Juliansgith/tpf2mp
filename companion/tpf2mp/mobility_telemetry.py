"""Bound machine-local mobility diagnostics before host-side retention."""

from __future__ import annotations

from typing import Any, Mapping


def unsafe_vehicle_details(payload: Mapping[str, Any]) -> dict[str, str]:
    items = payload.get("vehicleRestoreUnsafeVehicles")
    if not isinstance(items, list):
        return {}
    parsed: dict[str, str] = {}
    for item in items[:1024]:
        if not isinstance(item, Mapping):
            continue
        vehicle_cid, reason = item.get("vehicleCid"), item.get("reason")
        if isinstance(vehicle_cid, str) and vehicle_cid \
                and isinstance(reason, str) and reason:
            parsed[vehicle_cid] = reason[:320]
    return parsed


def vehicle_phase_details(payload: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    """Retain only the discrete portable/native fields needed for recovery."""

    items = payload.get("vehiclePhases")
    if not isinstance(items, list):
        return {}
    parsed: dict[str, dict[str, Any]] = {}
    for item in items[:1024]:
        if not isinstance(item, Mapping):
            continue
        vehicle_cid, line_cid = item.get("vehicleCid"), item.get("lineCid")
        stop_index = item.get("nativeStopIndex")
        if not isinstance(vehicle_cid, str) or not vehicle_cid \
                or not isinstance(line_cid, str) or not line_cid \
                or not isinstance(stop_index, int) or isinstance(stop_index, bool) \
                or stop_index < 0 or stop_index > 255:
            continue
        parsed[vehicle_cid] = {
            "lineCid": line_cid,
            "authorizedRound": (
                item.get("authorizedRound")
                if isinstance(item.get("authorizedRound"), int)
                and not isinstance(item.get("authorizedRound"), bool)
                and 0 <= item["authorizedRound"] <= 1_000_000_000 else None
            ),
            "atTerminal": item.get("atTerminal") is True,
            "nativeStopIndex": stop_index,
            "nativeUserStopped": item.get("nativeUserStopped") is True,
            "requestedStopped": item.get("requestedStopped") is True,
            "syncPhase": str(item.get("syncPhase") or "")[:40],
        }
    return parsed


def shares_enroute_native_leg(
    peer_phases: Mapping[str, Mapping[str, Mapping[str, Any]]],
    required_peers: set[str],
    vehicle_cids: set[str],
) -> bool:
    """Prove phase divergence is local bookkeeping, not a different route leg."""

    if not required_peers or not vehicle_cids:
        return False
    reference: dict[str, tuple[Any, ...]] = {}
    for peer in required_peers:
        phases = peer_phases.get(peer)
        if not isinstance(phases, Mapping) or not vehicle_cids.issubset(phases):
            return False
        for vehicle_cid in vehicle_cids:
            phase = phases.get(vehicle_cid)
            if not isinstance(phase, Mapping) or phase.get("atTerminal") is not False \
                    or phase.get("nativeUserStopped") != phase.get("requestedStopped"):
                return False
            native_leg = (
                phase.get("lineCid"), phase.get("nativeStopIndex"),
                phase.get("atTerminal"), phase.get("nativeUserStopped"),
                phase.get("requestedStopped"),
            )
            if vehicle_cid in reference and reference[vehicle_cid] != native_leg:
                return False
            reference[vehicle_cid] = native_leg
    return True


def vehicle_round_cursors(
    peer_phases: Mapping[str, Mapping[str, Mapping[str, Any]]],
    required_peers: set[str],
) -> list[dict[str, Any]] | None:
    """Return the identical signed station-round cursor set, or fail closed."""

    reference: list[dict[str, Any]] | None = None
    for peer in sorted(required_peers):
        phases = peer_phases.get(peer)
        if not isinstance(phases, Mapping) or len(phases) > 4096:
            return None
        cursors: list[dict[str, Any]] = []
        for vehicle_cid in sorted(phases):
            phase = phases[vehicle_cid]
            round_number = phase.get("authorizedRound") if isinstance(phase, Mapping) else None
            if not isinstance(round_number, int) or isinstance(round_number, bool):
                return None
            cursors.append({
                "vehicleCid": vehicle_cid,
                "lineCid": phase.get("lineCid"),
                "lastAuthorizedRound": round_number,
            })
        if reference is not None and cursors != reference:
            return None
        reference = cursors
    return reference if reference is not None else None
