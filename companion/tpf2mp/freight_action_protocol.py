from __future__ import annotations

import re
from collections.abc import Callable, Mapping
from typing import Any


def validate_registration(
    metadata: Mapping[str, Any], vehicle_values: list[Any], vehicles: set[Any],
    cid: Callable[[Any, str | None], bool], error: type[Exception],
) -> None:
    schema = metadata.get("freightContractSchema")
    if schema is None:
        return
    if schema not in {1, 2} \
            or re.fullmatch(r"[0-9a-f]{8}", metadata.get("freightContractDigest", "")) is None \
            or not cid(metadata.get("sourceIndustryCid"), "industry") \
            or not cid(metadata.get("destinationIndustryCid"), "industry") \
            or metadata["sourceIndustryCid"] == metadata["destinationIndustryCid"] \
            or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", metadata.get("cargoType", "")) is None:
        raise error("line.register freight contract identity is invalid")
    capacities = metadata.get("cargoCapacityByVehicleCid")
    if not isinstance(capacities, dict) or set(capacities) != vehicles:
        raise error("line.register freight vehicle capacities are incomplete")
    if schema == 1:
        if any(isinstance(value, bool) or not isinstance(value, int)
               or not 0 <= value <= 1_000_000_000 for value in capacities.values()):
            raise error("line.register freight vehicle capacity is invalid")
        fleet = sum(capacities.values())
        average = fleet // len(vehicle_values) if vehicle_values else 0
        if fleet <= 0 or metadata.get("cargoFleetCapacity") != fleet \
                or metadata.get("cargoCapacityPerVehicle") != average:
            raise error("line.register freight fleet capacity is inconsistent")
        return
    if re.fullmatch(r"[0-9a-f]{8}", metadata.get("freightPathDigest", "")) is None \
            or metadata.get("sourceTransportKind") not in {"industry", "station"} \
            or metadata.get("destinationTransportKind") not in {"industry", "station"} \
            or not cid(metadata.get("sourceStationGroupCid"), "station_group") \
            or not cid(metadata.get("destinationStationGroupCid"), "station_group"):
        raise error("line.register multi-hop freight path is invalid")
    leg_index, leg_count = metadata.get("freightLegIndex"), metadata.get("freightLegCount")
    source_stop = metadata.get("sourceStopIndex")
    destination_stop = metadata.get("destinationStopIndex")
    if isinstance(leg_index, bool) or not isinstance(leg_index, int) \
            or isinstance(leg_count, bool) or not isinstance(leg_count, int) \
            or not 0 <= leg_index < leg_count <= 16 \
            or isinstance(source_stop, bool) or not isinstance(source_stop, int) \
            or isinstance(destination_stop, bool) or not isinstance(destination_stop, int) \
            or not 0 <= source_stop <= 255 or not 0 <= destination_stop <= 255 \
            or source_stop == destination_stop:
        raise error("line.register multi-hop freight leg is invalid")
    selected_capacity = 0
    for capacity in capacities.values():
        if not isinstance(capacity, dict) or any(
            not isinstance(cargo, str)
            or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", cargo) is None
            or isinstance(value, bool)
            or not isinstance(value, int) or not 0 <= value <= 1_000_000_000
            for cargo, value in capacity.items()
        ):
            raise error("line.register multi-hop freight capacity is invalid")
        selected_capacity += capacity.get(metadata["cargoType"], 0)
    if selected_capacity <= 0:
        raise error("line.register multi-hop freight capacity is invalid")


def validate_delivery_rows(
    rows: Mapping[str, Any], cid: Callable[[Any, str | None], bool],
    error: type[Exception],
) -> None:
    legacy = {"contractDigest", "sourceIndustryCid", "destinationIndustryCid",
              "destinationStockIndex", "cargoType", "boardedUnits",
              "deliveredUnits", "earnedRevenueCents"}
    extended = legacy | {"transportSchema", "pathDigest", "legIndex", "legCount",
                         "sourceKind", "destinationKind", "sourceStationGroupCid",
                         "destinationStationGroupCid"}
    for line_cid, row in rows.items():
        multihop = isinstance(row, dict) and row.get("transportSchema") == 2
        if not cid(line_cid, "line") or not isinstance(row, dict) \
                or set(row) != (extended if multihop else legacy):
            raise error("economy.settle cargo delivery line is malformed")
        if re.fullmatch(r"[0-9a-f]{8}", row.get("contractDigest", "")) is None \
                or not cid(row.get("sourceIndustryCid"), "industry") \
                or not cid(row.get("destinationIndustryCid"), "industry") \
                or row["sourceIndustryCid"] == row["destinationIndustryCid"] \
                or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", row.get("cargoType", "")) is None:
            raise error("economy.settle cargo delivery identity is invalid")
        for field, maximum in (("destinationStockIndex", 31),
                               ("boardedUnits", 1_000_000_000),
                               ("deliveredUnits", 1_000_000_000),
                               ("earnedRevenueCents", 1_000_000_000_000_000)):
            value = row[field]
            if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
                raise error("economy.settle cargo delivery values are invalid")
        if row["deliveredUnits"] > row["boardedUnits"]:
            raise error("economy.settle cargo delivered more than was boarded")
        if multihop and (
            re.fullmatch(r"[0-9a-f]{8}", row.get("pathDigest", "")) is None
            or isinstance(row.get("legIndex"), bool) or not isinstance(row.get("legIndex"), int)
            or isinstance(row.get("legCount"), bool) or not isinstance(row.get("legCount"), int)
            or not 0 <= row["legIndex"] < row["legCount"] <= 16
            or row.get("sourceKind") not in {"industry", "station"}
            or row.get("destinationKind") not in {"industry", "station"}
            or not cid(row.get("sourceStationGroupCid"), "station_group")
            or not cid(row.get("destinationStationGroupCid"), "station_group")
        ):
            raise error("economy.settle multi-hop cargo identity is invalid")
