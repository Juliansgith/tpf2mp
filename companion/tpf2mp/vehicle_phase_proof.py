"""Strict schema shared by checkpoint and restore vehicle-phase attestations."""

from __future__ import annotations

import re
from typing import Any


class VehiclePhaseProofError(ValueError):
    """The proof cannot safely identify two stable paused route-phase samples."""


def normalise(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "sampleKeys", "vehiclePhaseDigest", "vehicleRounds",
    } or value.get("schemaVersion") != 1 or isinstance(value.get("schemaVersion"), bool):
        raise VehiclePhaseProofError("native vehicle phase proof is malformed")
    sample_keys = value.get("sampleKeys")
    if not isinstance(sample_keys, list) or len(sample_keys) != 2 \
            or len(set(sample_keys)) != 2 or any(
                not isinstance(item, str) or not re.fullmatch(
                    r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}", item
                ) for item in sample_keys
            ):
        raise VehiclePhaseProofError(
            "native vehicle phase proof requires two valid samples"
        )
    digest = value.get("vehiclePhaseDigest")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{8}", digest):
        raise VehiclePhaseProofError("native vehicle phase proof digest is invalid")
    source_rounds = value.get("vehicleRounds")
    if not isinstance(source_rounds, list) or len(source_rounds) > 4096:
        raise VehiclePhaseProofError("native vehicle phase proof rounds are malformed")
    vehicle_rounds: list[dict[str, Any]] = []
    previous = ""
    for item in source_rounds:
        if not isinstance(item, dict) or set(item) != {
            "vehicleCid", "lineCid", "lastAuthorizedRound",
        }:
            raise VehiclePhaseProofError("native vehicle phase proof round is malformed")
        vehicle_cid, line_cid = item.get("vehicleCid"), item.get("lineCid")
        round_number = item.get("lastAuthorizedRound")
        if not _canonical(vehicle_cid, "vehicle:") or not _canonical(line_cid, "line:") \
                or vehicle_cid <= previous or not isinstance(round_number, int) \
                or isinstance(round_number, bool) or not 0 <= round_number <= 1_000_000_000:
            raise VehiclePhaseProofError("native vehicle phase proof round is invalid")
        previous = vehicle_cid
        vehicle_rounds.append({
            "vehicleCid": vehicle_cid,
            "lineCid": line_cid,
            "lastAuthorizedRound": round_number,
        })
    return {
        "schemaVersion": 1,
        "sampleKeys": list(sample_keys),
        "vehiclePhaseDigest": digest,
        "vehicleRounds": vehicle_rounds,
    }


def _canonical(value: Any, prefix: str) -> bool:
    return isinstance(value, str) and value.startswith(prefix) and bool(
        re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}", value)
    )
