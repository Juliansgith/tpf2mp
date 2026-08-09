from __future__ import annotations

from collections.abc import Mapping
from typing import Any

from .protocol import ProtocolError, checksum

MAX_COUNT = 1_000_000_000
MAX_CENTS = 1_000_000_000_000_000


def _mapping(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ProtocolError(f"checkpoint {label} is not an object")
    return dict(value)


def _array(value: Any, label: str) -> list[Any]:
    if isinstance(value, Mapping) and not value:
        return []
    if not isinstance(value, list):
        raise ProtocolError(f"checkpoint {label} is not an array")
    return value


def _cid(value: Any, prefix: str, label: str) -> str:
    if not isinstance(value, str) or not value.startswith(prefix + ":") \
            or not len(prefix) + 1 < len(value) <= 320:
        raise ProtocolError(f"checkpoint {label} is invalid")
    return value


def _integer(value: Any, label: str, maximum: int = MAX_COUNT) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise ProtocolError(f"checkpoint {label} is invalid")
    return value


def validate_cargo_presentation(
    value: Any,
    synchronized_vehicles: Mapping[str, Mapping[str, Any]],
    model: Mapping[str, Any],
) -> dict[str, Any]:
    presentation = _mapping(value, "cargo presentation")
    if set(presentation) != {"schemaVersion", "epoch", "lines", "vehicles"} \
            or presentation.get("schemaVersion") != 1:
        raise ProtocolError("checkpoint cargo presentation header is invalid")
    epoch = _integer(presentation["epoch"], "cargo presentation epoch")
    economy = model.get("economy") if isinstance(model.get("economy"), Mapping) else {}
    if _integer(economy.get("epoch", 0), "economy epoch") != epoch:
        raise ProtocolError("checkpoint cargo presentation epoch disagrees with economy")
    services = economy.get("services") if isinstance(economy.get("services"), Mapping) else {}
    freight = model.get("freightIndustry") \
        if isinstance(model.get("freightIndustry"), Mapping) else {}
    cursors = freight.get("transportCursors") \
        if isinstance(freight.get("transportCursors"), Mapping) else {}

    line_fields = {
        "lineCid", "companyCid", "marketCid", "contractDigest",
        "sourceIndustryCid", "destinationIndustryCid", "destinationStockIndex",
        "cargoType", "sourceStationGroupCid", "destinationStationGroupCid",
        "sourceStopIndex", "destinationStopIndex", "stops", "routeDigest",
        "epoch", "allocated", "boardedThisEpoch", "capacityPerVehicle",
        "boardedTotal", "deliveredTotal", "earnedRevenueCents", "discardedTotal",
        "retired",
    }
    lines: dict[str, dict[str, Any]] = {}
    previous: str | None = None
    for raw in _array(presentation["lines"], "cargo lines"):
        item = _mapping(raw, "cargo line")
        if set(item) != line_fields:
            raise ProtocolError("checkpoint cargo line fields are invalid")
        line_cid = _cid(item["lineCid"], "line", "cargo line id")
        _cid(item["companyCid"], "company", "cargo line company")
        _cid(item["marketCid"], "market", "cargo line market")
        _cid(item["sourceIndustryCid"], "industry", "cargo source")
        _cid(item["destinationIndustryCid"], "industry", "cargo destination")
        _cid(item["sourceStationGroupCid"], "station_group", "cargo source station")
        _cid(item["destinationStationGroupCid"], "station_group", "cargo destination station")
        if previous is not None and line_cid <= previous:
            raise ProtocolError("checkpoint cargo lines are duplicated or unordered")
        previous, lines[line_cid] = line_cid, item
        if not isinstance(item["retired"], bool) or _integer(item["epoch"], "cargo line epoch") > epoch:
            raise ProtocolError("checkpoint cargo line epoch/status is invalid")
        stops = _array(item["stops"], "cargo line stops")
        for stop in stops:
            _cid(stop, "station_group", "cargo line stop")
        source_index = _integer(item["sourceStopIndex"], "cargo source stop", 255)
        destination_index = _integer(item["destinationStopIndex"], "cargo destination stop", 255)
        if len(stops) < 2 or source_index >= len(stops) or destination_index >= len(stops) \
                or source_index == destination_index \
                or stops[source_index] != item["sourceStationGroupCid"] \
                or stops[destination_index] != item["destinationStationGroupCid"] \
                or item["routeDigest"] != checksum(stops):
            raise ProtocolError("checkpoint cargo route is inconsistent")
        if not isinstance(item["contractDigest"], str) or len(item["contractDigest"]) != 8 \
                or any(char not in "0123456789abcdef" for char in item["contractDigest"]):
            raise ProtocolError("checkpoint cargo contract digest is invalid")
        if not isinstance(item["cargoType"], str) or not item["cargoType"]:
            raise ProtocolError("checkpoint cargo type is invalid")
        for field in ("destinationStockIndex", "allocated", "boardedThisEpoch",
                      "capacityPerVehicle", "boardedTotal", "deliveredTotal", "discardedTotal"):
            _integer(item[field], f"cargo line {field}", 31 if field == "destinationStockIndex" else MAX_COUNT)
        _integer(item["earnedRevenueCents"], "cargo line earned revenue", MAX_CENTS)
        if item["deliveredTotal"] > item["boardedTotal"] \
                or item["boardedThisEpoch"] > item["boardedTotal"] \
                or item["deliveredTotal"] + item["discardedTotal"] > item["boardedTotal"]:
            raise ProtocolError("checkpoint cargo line conservation is invalid")
        service = services.get(line_cid)
        if not item["retired"]:
            metadata = service.get("metadata") if isinstance(service, Mapping) \
                and isinstance(service.get("metadata"), Mapping) else {}
            expected = {
                "companyCid": item["companyCid"], "marketCid": item["marketCid"],
                "freightContractDigest": item["contractDigest"],
                "sourceIndustryCid": item["sourceIndustryCid"],
                "destinationIndustryCid": item["destinationIndustryCid"],
                "destinationStockIndex": item["destinationStockIndex"],
                "cargoType": item["cargoType"], "stationGroupCids": stops,
            }
            if not isinstance(service, Mapping) or service.get("companyCid") != expected["companyCid"] \
                    or service.get("marketCid") != expected["marketCid"] \
                    or any(metadata.get(key) != expected[key] for key in expected if key not in {"companyCid", "marketCid"}):
                raise ProtocolError("checkpoint cargo line disagrees with its economy service")
        cursor = cursors.get(line_cid)
        if isinstance(cursor, Mapping) and (
            cursor.get("contractDigest") != item["contractDigest"]
            or cursor.get("sourceIndustryCid") != item["sourceIndustryCid"]
            or cursor.get("destinationIndustryCid") != item["destinationIndustryCid"]
            or cursor.get("destinationStockIndex") != item["destinationStockIndex"]
            or cursor.get("cargoType") != item["cargoType"]
            or int(cursor.get("boardedUnits", 0)) > item["boardedTotal"]
            or int(cursor.get("deliveredUnits", 0)) > item["deliveredTotal"]
        ):
            raise ProtocolError("checkpoint cargo line disagrees with its freight cursor")

    required_vehicle = {
        "vehicleCid", "lineCid", "companyCid", "capacity", "aboard", "lastRound",
        "boardedTotal", "deliveredTotal", "earnedRevenueCents", "discardedTotal",
    }
    optional_vehicle = {
        "boardedEpoch", "lastStopIndex", "lastStationGroupCid",
        "boardedFareCents", "boardedDistanceMeters",
    }
    aboard_by_line: dict[str, int] = {line_cid: 0 for line_cid in lines}
    previous = None
    for raw in _array(presentation["vehicles"], "cargo vehicles"):
        item = _mapping(raw, "cargo vehicle")
        if not required_vehicle <= set(item) or set(item) - required_vehicle - optional_vehicle:
            raise ProtocolError("checkpoint cargo vehicle fields are invalid")
        vehicle_cid = _cid(item["vehicleCid"], "vehicle", "cargo vehicle id")
        line_cid = _cid(item["lineCid"], "line", "cargo vehicle line")
        if (previous is not None and vehicle_cid <= previous) or line_cid not in lines:
            raise ProtocolError("checkpoint cargo vehicles are duplicated or unordered")
        previous = vehicle_cid
        line = lines[line_cid]
        if _cid(item["companyCid"], "company", "cargo vehicle company") != line["companyCid"]:
            raise ProtocolError("checkpoint cargo vehicle company disagrees with its line")
        capacity = _integer(item["capacity"], "cargo vehicle capacity")
        aboard = _integer(item["aboard"], "cargo vehicle load")
        aboard_by_line[line_cid] += aboard
        last_round = _integer(item["lastRound"], "cargo vehicle round")
        if aboard > capacity:
            raise ProtocolError("checkpoint cargo vehicle exceeds capacity")
        for field in ("boardedTotal", "deliveredTotal", "discardedTotal"):
            _integer(item[field], f"cargo vehicle {field}")
        _integer(item["earnedRevenueCents"], "cargo vehicle earned revenue", MAX_CENTS)
        if item["boardedTotal"] != item["deliveredTotal"] + item["discardedTotal"] + aboard:
            raise ProtocolError("checkpoint cargo vehicle conservation is invalid")
        if "boardedEpoch" in item:
            if _integer(item["boardedEpoch"], "cargo vehicle boarded epoch") > epoch:
                raise ProtocolError("checkpoint cargo vehicle boarded epoch is in the future")
        if "lastStopIndex" in item:
            stop_index = _integer(item["lastStopIndex"], "cargo vehicle stop", 255)
            if stop_index >= len(line["stops"]):
                raise ProtocolError("checkpoint cargo vehicle stop is outside its route")
        if "lastStationGroupCid" in item:
            _cid(item["lastStationGroupCid"], "station_group", "cargo vehicle station")
        if "boardedFareCents" in item:
            _integer(item["boardedFareCents"], "cargo vehicle boarded fare", MAX_CENTS)
        if "boardedDistanceMeters" in item:
            _integer(item["boardedDistanceMeters"], "cargo vehicle boarded distance")
        synchronized = synchronized_vehicles.get(vehicle_cid)
        if synchronized is None or synchronized.get("lineCid") != line_cid \
                or synchronized.get("companyCid") != item["companyCid"] \
                or synchronized.get("lastAuthorizedRound") != last_round:
            raise ProtocolError("checkpoint cargo vehicle disagrees with synchronization")
        if last_round > 0 and (
            "lastStopIndex" not in item
            or synchronized.get("stopIndex") != item["lastStopIndex"]
            or item.get("lastStationGroupCid") != line["stops"][item["lastStopIndex"]]
        ):
            raise ProtocolError("checkpoint cargo vehicle stop disagrees with synchronization")
    for line_cid, line in lines.items():
        if line["boardedTotal"] != line["deliveredTotal"] \
                + line["discardedTotal"] + aboard_by_line[line_cid]:
            raise ProtocolError("checkpoint cargo line conservation is invalid")
    return presentation
