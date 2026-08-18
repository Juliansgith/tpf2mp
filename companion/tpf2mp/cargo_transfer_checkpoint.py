from __future__ import annotations

import re
from collections.abc import Callable, Mapping
from typing import Any


def validate_stock(
    value: Any,
    mapping: Callable[[Any, str], dict[str, Any]],
    cid: Callable[[Any, str, str], str],
    integer: Callable[[Any, str, int], int],
    error: type[Exception],
    maximum: int,
) -> dict[str, dict[str, Any]]:
    station_stock = mapping(value, "cargo transfer stock")
    for station_cid, stocks_value in station_stock.items():
        cid(station_cid, "station_group", "cargo transfer station")
        stocks = mapping(stocks_value, "cargo transfer station stocks")
        station_stock[station_cid] = stocks
        for cargo_type, amount in stocks.items():
            if not isinstance(cargo_type, str) \
                    or re.fullmatch(r"[A-Z][A-Z0-9_]{0,127}", cargo_type) is None:
                raise error("checkpoint cargo transfer type is invalid")
            integer(amount, "cargo transfer stock", maximum)
    return station_stock


def validate_conservation(
    station_stock: Mapping[str, Mapping[str, Any]],
    lines: Mapping[str, Mapping[str, Any]],
    error: type[Exception],
) -> None:
    balance: dict[str, dict[str, int]] = {}
    for line in lines.values():
        if line.get("destinationKind") == "station":
            station = balance.setdefault(str(line["destinationStationGroupCid"]), {})
            cargo = str(line["cargoType"])
            station[cargo] = station.get(cargo, 0) + int(line["deliveredTotal"])
        if line.get("sourceKind") == "station":
            station = balance.setdefault(str(line["sourceStationGroupCid"]), {})
            cargo = str(line["cargoType"])
            station[cargo] = station.get(cargo, 0) - int(line["boardedTotal"])
    for station_cid in set(station_stock) | set(balance):
        stored, expected = station_stock.get(station_cid, {}), balance.get(station_cid, {})
        for cargo_type in set(stored) | set(expected):
            if expected.get(cargo_type, 0) < 0 \
                    or stored.get(cargo_type, 0) != expected.get(cargo_type, 0):
                raise error("checkpoint cargo transfer inventory violates leg conservation")
