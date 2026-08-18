from __future__ import annotations

import copy
import math
import re
from collections.abc import Callable, Mapping
from typing import Any

from .protocol import checksum

SCHEMA_VERSION = 1
MAX_LEGS = 4
TRANSFER_SECONDS = 480
CARGO_TRANSFER_SECONDS = 1800
MAX_COUNT = 1_000_000_000


def _integer(value: Any, fallback: int, low: int = 0, high: int = MAX_COUNT) -> int:
    if isinstance(value, bool):
        result = fallback
    elif isinstance(value, int):
        result = value
    else:
        try:
            number = float(value)
            result = math.floor(number + 0.0000001) if number >= 0 \
                else math.ceil(number - 0.0000001)
        except (TypeError, ValueError, OverflowError):
            result = fallback
    return max(low, min(high, result))


def _edge_capacity(service: Mapping[str, Any], cargo_type: str | None = None) -> int:
    metadata = service.get("metadata") if isinstance(service.get("metadata"), Mapping) else {}
    if cargo_type is not None:
        capacities = metadata.get("cargoHourlyCapacityByType")
        value = capacities.get(cargo_type) if isinstance(capacities, Mapping) else None
        return _integer(value, 0)
    return _integer(service.get("capacity"), 0)


def _directed_edges(economy: Mapping[str, Any], kind: str) \
        -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    edges: list[dict[str, Any]] = []
    by_node: dict[str, list[dict[str, Any]]] = {}
    markets = economy.get("markets") if isinstance(economy.get("markets"), Mapping) else {}
    services = economy.get("services") if isinstance(economy.get("services"), Mapping) else {}
    for line_cid in sorted(services):
        service = services[line_cid]
        if not isinstance(service, dict):
            continue
        metadata = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
        stops = metadata.get("stationGroupCids")
        market = markets.get(service.get("marketCid"))
        cargo = isinstance(market, Mapping) and market.get("kind") == "cargo"
        eligible = kind == "cargo" and metadata.get("freightNetworkSchema") == 1 \
            or kind == "passenger" and isinstance(market, Mapping) and not cargo \
            and isinstance(metadata.get("endpointTownCids"), list) \
            and len(metadata["endpointTownCids"]) == 2
        if service.get("enabled") is False or not isinstance(stops, list) \
                or len(stops) < 2 or not eligible:
            continue
        for from_index in range(len(stops)):
            for to_index in range(len(stops)):
                if from_index == to_index:
                    continue
                segment_count, total_segments = abs(to_index - from_index), len(stops) - 1
                towns = metadata.get("endpointTownCids", [])
                edge = {
                    "lineCid": line_cid,
                    "marketCid": service.get("marketCid"),
                    "fromStationGroupCid": stops[from_index],
                    "toStationGroupCid": stops[to_index],
                    "fromStopIndex": from_index,
                    "toStopIndex": to_index,
                    "fromTownCid": (towns[0] if from_index == 0 else
                        towns[1] if from_index == len(stops) - 1 else None)
                        if kind == "passenger" else None,
                    "toTownCid": (towns[0] if to_index == 0 else
                        towns[1] if to_index == len(stops) - 1 else None)
                        if kind == "passenger" else None,
                    "costSeconds": max(30, _integer(
                        service.get("journeySeconds"), 3600, 30, 604800
                    ) * segment_count // total_segments)
                        + _integer(service.get("headwaySeconds"), 1800, 30, 86400) // 2,
                    "distanceMeters": _integer(metadata.get("distanceMeters"), 0)
                        * segment_count // total_segments,
                    "service": service,
                }
                edges.append(edge)
                by_node.setdefault(str(edge["fromStationGroupCid"]), []).append(edge)
    for rows in by_node.values():
        rows.sort(key=lambda edge: f'{edge["lineCid"]}|{edge["toStationGroupCid"]}|'
                                   f'{edge["fromStopIndex"]}|{edge["toStopIndex"]}')
    return edges, by_node


def _paths(
    by_node: Mapping[str, list[dict[str, Any]]], start: str,
    accept: Callable[[str, list[dict[str, Any]]], Any], cargo_type: str | None,
) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []

    def visit(node: str, path: list[dict[str, Any]], used_lines: set[str],
              visited: set[str], cost: int, capacity: int) -> None:
        accepted = accept(node, path) if path else None
        if accepted is not None:
            result.append({"edges": list(path), "accepted": copy.deepcopy(accepted),
                           "costSeconds": cost, "capacity": capacity})
        if len(path) >= MAX_LEGS:
            return
        for edge in by_node.get(node, []):
            next_node, line_cid = str(edge["toStationGroupCid"]), str(edge["lineCid"])
            if line_cid in used_lines or next_node in visited:
                continue
            available = _edge_capacity(edge["service"], cargo_type)
            if cargo_type is not None and available <= 0:
                continue
            transfer = (CARGO_TRANSFER_SECONDS if cargo_type else TRANSFER_SECONDS) \
                if path else 0
            visit(next_node, path + [edge], used_lines | {line_cid}, visited | {next_node},
                  cost + int(edge["costSeconds"]) + transfer,
                  min(capacity, available))

    visit(start, [], set(), {start}, 0, MAX_COUNT)
    return result


def _route_key(path: Mapping[str, Any]) -> str:
    lines = ">".join(str(edge["lineCid"]) for edge in path.get("edges", []))
    return "|".join((str(path.get("kind", "")), str(path.get("sourceCid", "")),
                     str(path.get("destinationCid", "")),
                     str(path.get("cargoType", "")), lines))


def _pin_path(economy: dict[str, Any], path_digest: str) -> int:
    if re.fullmatch(r"[0-9a-f]{8}", path_digest) is None:
        raise ValueError("freight path pin identity is invalid")
    services = economy.get("services")
    if not isinstance(services, dict):
        raise ValueError("freight path pin has no service map")
    targets: list[dict[str, Any]] = []
    for line_cid in sorted(services):
        service = services[line_cid]
        metadata = service.get("metadata") if isinstance(service, dict) else None
        if isinstance(metadata, dict) and metadata.get("freightPathDigest") == path_digest:
            pinned = metadata.get("freightPinnedPathDigest")
            if metadata.get("freightContractSchema") != 2 \
                    or pinned is not None and pinned != path_digest:
                raise ValueError("freight path pin conflicts with the active contract")
            targets.append(metadata)
    if not targets:
        raise ValueError("freight path pin has no active legs")
    for metadata in targets:
        metadata["freightPinnedPathDigest"] = path_digest
    return len(targets)


def pin_cargo_line(economy: dict[str, Any], line_cid: str) -> int:
    services = economy.get("services") if isinstance(economy.get("services"), dict) else {}
    service = services.get(line_cid)
    metadata = service.get("metadata") if isinstance(service, dict) else None
    if not isinstance(metadata, dict) or metadata.get("freightContractSchema") != 2:
        return 0
    return _pin_path(economy, str(metadata.get("freightPathDigest", "")))


def pin_moved_cargo(economy: dict[str, Any], cargo_lines: Mapping[str, Any]) -> int:
    paths: set[str] = set()
    services = economy.get("services") if isinstance(economy.get("services"), dict) else {}
    for line_cid in sorted(cargo_lines):
        row = cargo_lines[line_cid]
        if isinstance(row, Mapping) and row.get("transportSchema") == 2 \
                and (int(row.get("boardedUnits", 0)) > 0
                     or int(row.get("deliveredUnits", 0)) > 0):
            service = services.get(line_cid)
            metadata = service.get("metadata") if isinstance(service, dict) else None
            if not isinstance(metadata, dict) or metadata.get("freightContractSchema") != 2 \
                    or metadata.get("freightPathDigest") != row.get("pathDigest"):
                raise ValueError("moved freight path disagrees with its active service")
            paths.add(str(row["pathDigest"]))
    return sum(_pin_path(economy, digest) for digest in sorted(paths))


def rebuild_passenger(economy: dict[str, Any]) -> dict[str, Any]:
    markets, services = economy.setdefault("markets", {}), economy.setdefault("services", {})
    for market_cid in sorted(markets):
        market = markets[market_cid]
        metadata = market.get("metadata") if isinstance(market.get("metadata"), dict) else {}
        if market.get("kind") != "cargo" and isinstance(metadata.get("townA"), str) \
                and isinstance(metadata.get("townB"), str):
            prior = _integer(metadata.get("networkDemand"), 0)
            observed = max(0, _integer(market.get("demand"), 0) - prior)
            metadata["directDemand"] = max(
                _integer(metadata.get("directDemand"), observed), observed
            )
            metadata["networkDemand"], metadata["networkRouteCount"] = 0, 0
            market["demand"], market["metadata"] = metadata["directDemand"], metadata
    for service in services.values():
        if not isinstance(service, dict):
            continue
        metadata = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
        market = markets.get(service.get("marketCid"))
        if isinstance(market, Mapping) and market.get("kind") != "cargo" \
                and isinstance(metadata.get("endpointTownCids"), list) \
                and len(metadata["endpointTownCids"]) == 2:
            metadata.pop("networkPathDigests", None)
            metadata.pop("networkOriginRoutes", None)
            metadata["networkPathCount"], metadata["networkMaxTransfers"] = 0, 0

    edges, by_node = _directed_edges(economy, "passenger")
    best: dict[str, dict[str, Any]] = {}
    origins = {f'{edge.get("fromTownCid")}\0{edge.get("fromStationGroupCid")}': edge
               for edge in edges if isinstance(edge.get("fromTownCid"), str)}
    for origin_key in sorted(origins):
        source = origins[origin_key]
        def accept(_: str, path: list[dict[str, Any]]) -> Any:
            last = path[-1] if path else None
            if len(path) >= 2 and last and isinstance(last.get("toTownCid"), str) \
                    and last.get("toTownCid") != source.get("fromTownCid"):
                return {"destinationTownCid": last.get("toTownCid")}
            return None

        for path in _paths(by_node, str(source["fromStationGroupCid"]), accept, None):
            path["kind"], path["sourceCid"] = "passenger", source.get("fromTownCid")
            path["destinationCid"] = path["accepted"]["destinationTownCid"]
            pair = "|".join(sorted((str(path["sourceCid"]), str(path["destinationCid"]))))
            sort_key = f'{int(path["costSeconds"]):012d}|{_route_key(path)}'
            if pair not in best or sort_key < best[pair]["sortKey"]:
                path["sortKey"], best[pair] = sort_key, path

    routes: list[dict[str, Any]] = []
    towns = economy.get("towns") if isinstance(economy.get("towns"), Mapping) else {}
    for pair in sorted(best):
        path, distance = best[pair], sum(int(edge["distanceMeters"]) for edge in best[pair]["edges"])
        first = _integer(towns.get(path["sourceCid"], {}).get("size")
                         if isinstance(towns.get(path["sourceCid"]), Mapping) else None, 200, 1, 100000)
        second = _integer(towns.get(path["destinationCid"], {}).get("size")
                          if isinstance(towns.get(path["destinationCid"]), Mapping) else None, 200, 1, 100000)
        demand = max(10, min(100000, first * second //
                     (50 * max(1, distance // 1000) * max(1, len(path["edges"]) - 1 + 1))))
        lines = [edge["lineCid"] for edge in path["edges"]]
        segments = [[edge["fromStopIndex"], edge["toStopIndex"]]
                    for edge in path["edges"]]
        stations = [path["edges"][0]["fromStationGroupCid"]] \
            + [edge["toStationGroupCid"] for edge in path["edges"]]
        digest = checksum({"schemaVersion": SCHEMA_VERSION, "kind": "passenger",
                           "sourceTownCid": path["sourceCid"],
                           "destinationTownCid": path["destinationCid"], "lines": lines,
                           "segments": segments})
        route = {"schemaVersion": SCHEMA_VERSION, "kind": "passenger", "digest": digest,
                 "sourceTownCid": path["sourceCid"], "destinationTownCid": path["destinationCid"],
                 "transfers": len(lines) - 1, "demand": demand,
                 "costSeconds": path["costSeconds"], "lines": lines,
                 "stations": stations, "segments": segments}
        for index, edge in enumerate(path["edges"]):
            market, metadata = markets[edge["marketCid"]], edge["service"]["metadata"]
            metadata_market = market["metadata"]
            metadata_market["networkDemand"] = min(
                MAX_COUNT, _integer(metadata_market.get("networkDemand"), 0) + demand
            )
            metadata_market["networkRouteCount"] = _integer(
                metadata_market.get("networkRouteCount"), 0
            ) + 1
            market["demand"] = min(MAX_COUNT, _integer(
                metadata_market.get("directDemand"), market.get("demand", 0)
            ) + metadata_market["networkDemand"])
            metadata.setdefault("networkPathDigests", []).append(digest)
            metadata["networkPathCount"] = _integer(metadata.get("networkPathCount"), 0) + 1
            metadata["networkMaxTransfers"] = max(
                _integer(metadata.get("networkMaxTransfers"), 0, 0, 8), route["transfers"]
            )
            if index == 0:
                metadata.setdefault("networkOriginRoutes", []).append(copy.deepcopy(route))
        routes.append(route)
    return {"schemaVersion": SCHEMA_VERSION, "routes": routes if routes else {},
            "routeCount": len(routes)}


def _cargo_endpoints(edges: list[dict[str, Any]]) \
        -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    sources: dict[str, dict[str, Any]] = {}
    sinks: dict[str, dict[str, Any]] = {}
    for edge in edges:
        metadata = edge["service"].get("metadata", {})
        for endpoint in metadata.get("cargoEndpointFacts", []):
            if endpoint.get("stationGroupCid") != edge["fromStationGroupCid"]:
                continue
            for source in endpoint.get("sources", []):
                key = "|".join((str(edge["fromStationGroupCid"]), str(source.get("industryCid")),
                                str(source.get("cargoType"))))
                sources.setdefault(key, copy.deepcopy(source) | {
                    "stationGroupCid": edge["fromStationGroupCid"]})
            for sink in endpoint.get("destinations", []):
                key = "|".join((str(edge["fromStationGroupCid"]), str(sink.get("industryCid")),
                                str(sink.get("cargoType")), str(sink.get("stockIndex"))))
                sinks.setdefault(key, copy.deepcopy(sink) | {
                    "stationGroupCid": edge["fromStationGroupCid"]})
    source_rows = sorted(sources.values(), key=lambda row:
                         f'{row.get("cargoType")}|{row.get("industryCid")}|{row.get("stationGroupCid")}')
    sink_rows = sorted(sinks.values(), key=lambda row:
                       f'{row.get("cargoType")}|{row.get("industryCid")}|{row.get("stockIndex")}|'
                       f'{row.get("stationGroupCid")}')
    return source_rows, sink_rows


def rebuild_cargo(economy: dict[str, Any]) -> dict[str, Any]:
    markets, services = economy.setdefault("markets", {}), economy.setdefault("services", {})
    cleared = ("freightContractSchema", "freightContractDigest", "freightPathDigest",
               "freightLegIndex", "freightLegCount", "sourceIndustryCid",
               "destinationIndustryCid", "destinationStockIndex", "cargoType",
               "sourceStationGroupCid", "destinationStationGroupCid", "sourceStopIndex",
               "destinationStopIndex", "sourceTransportKind", "destinationTransportKind",
               "networkOriginRoute")
    for line_cid in sorted(services):
        service = services[line_cid]
        metadata = service.get("metadata") if isinstance(service.get("metadata"), dict) else {}
        if metadata.get("freightNetworkSchema") != 1:
            continue
        service["capacity"], service["transfers"] = 0, 0
        for key in cleared:
            metadata.pop(key, None)
        status = "pinned-path-unavailable" if metadata.get("freightPinnedPathDigest") \
            else "awaiting-compatible-path"
        metadata["networkStatus"] = status
        market = markets.get(service.get("marketCid"))
        if isinstance(market, dict):
            market["demand"] = 0
            market_metadata = market.get("metadata") if isinstance(market.get("metadata"), dict) else {}
            market_metadata["networkStatus"] = status
            market_metadata.pop("routeDigest", None)
            market["metadata"] = market_metadata

    edges, by_node = _directed_edges(economy, "cargo")
    sources, sinks = _cargo_endpoints(edges)
    sinks_by_key: dict[str, list[dict[str, Any]]] = {}
    for sink in sinks:
        sinks_by_key.setdefault(f'{sink.get("cargoType")}\0{sink.get("stationGroupCid")}', []).append(sink)
    choices: list[dict[str, Any]] = []
    for source in sources:
        cargo_type = str(source.get("cargoType"))

        def accept(node: str, _: list[dict[str, Any]]) -> Any:
            for sink in sinks_by_key.get(f"{cargo_type}\0{node}", []):
                if sink.get("industryCid") != source.get("industryCid"):
                    return sink
            return None

        for path in _paths(by_node, str(source["stationGroupCid"]), accept, cargo_type):
            sink = path["accepted"]
            path.update({"kind": "cargo", "sourceCid": source.get("industryCid"),
                         "destinationCid": sink.get("industryCid"), "cargoType": cargo_type,
                         "source": source, "sink": sink,
                         "demand": min(_integer(source.get("ratePerHour"), 0, 1),
                                       _integer(sink.get("ratePerHour"), 0, 1))})
            lines = [edge["lineCid"] for edge in path["edges"]]
            segments = [[edge["fromStopIndex"], edge["toStopIndex"]]
                        for edge in path["edges"]]
            stations = [path["edges"][0]["fromStationGroupCid"]] \
                + [edge["toStationGroupCid"] for edge in path["edges"]]
            digest = checksum({"schemaVersion": SCHEMA_VERSION, "kind": "cargo",
                               "sourceIndustryCid": path["sourceCid"],
                               "destinationIndustryCid": path["destinationCid"],
                               "destinationStockIndex": sink.get("stockIndex"),
                               "cargoType": cargo_type, "lines": lines, "stations": stations,
                               "segments": segments})
            path.update({"digest": digest, "lines": lines, "stations": stations,
                         "segments": segments})
            allowed = all(edge["service"].get("metadata", {}).get("freightPinnedPathDigest")
                          in {None, digest} for edge in path["edges"])
            if path["capacity"] > 0 and allowed:
                choices.append(path)
    choices.sort(key=lambda path: f'{int(path["costSeconds"]):012d}|{_route_key(path)}')

    claimed: set[str] = set()
    routes: list[dict[str, Any]] = []
    for path in choices:
        if any(str(edge["lineCid"]) in claimed for edge in path["edges"]):
            continue
        route = {"schemaVersion": SCHEMA_VERSION, "kind": "cargo", "digest": path["digest"],
                 "sourceIndustryCid": path["sourceCid"],
                 "destinationIndustryCid": path["destinationCid"],
                 "destinationStockIndex": path["sink"].get("stockIndex"),
                 "cargoType": path["cargoType"], "transfers": len(path["edges"]) - 1,
                 "demand": path["demand"], "capacity": path["capacity"],
                 "costSeconds": path["costSeconds"], "lines": path["lines"],
                 "stations": path["stations"], "segments": path["segments"]}
        for index, edge in enumerate(path["edges"]):
            line_cid, service = str(edge["lineCid"]), edge["service"]
            claimed.add(line_cid)
            metadata = service["metadata"]
            service["capacity"] = min(path["capacity"], _edge_capacity(service, path["cargoType"]))
            service["transfers"] = route["transfers"] if index == 0 else 0
            metadata.update({
                "freightContractSchema": 2,
                "freightContractDigest": checksum({"pathDigest": path["digest"],
                    "legIndex": index, "lineCid": line_cid,
                    "from": edge["fromStationGroupCid"], "to": edge["toStationGroupCid"],
                    "fromStopIndex": edge["fromStopIndex"],
                    "toStopIndex": edge["toStopIndex"]}),
                "freightPathDigest": path["digest"],
                "freightLegIndex": index, "freightLegCount": len(path["edges"]),
                "sourceIndustryCid": path["sourceCid"],
                "destinationIndustryCid": path["destinationCid"],
                "destinationStockIndex": path["sink"].get("stockIndex"),
                "cargoType": path["cargoType"],
                "sourceStationGroupCid": edge["fromStationGroupCid"],
                "destinationStationGroupCid": edge["toStationGroupCid"],
                "sourceStopIndex": edge["fromStopIndex"],
                "destinationStopIndex": edge["toStopIndex"],
                "sourceTransportKind": "industry" if index == 0 else "station",
                "destinationTransportKind": "industry"
                    if index == len(path["edges"]) - 1 else "station",
                "networkStatus": "routed", "contractAlternatives": len(choices),
                "factsSource": "computed-direct-freight-contract" if len(path["edges"]) == 1
                    else "computed-multihop-freight-contract",
            })
            if index == 0:
                metadata["networkOriginRoute"] = copy.deepcopy(route)
            market = markets[service["marketCid"]]
            market["demand"] = path["demand"]
            market["name"] = f'{path["cargoType"]} leg {index + 1}/{len(path["edges"])}'
            market["metadata"] = {"freightPathDigest": path["digest"],
                "freightLegIndex": index, "freightLegCount": len(path["edges"]),
                "sourceIndustryCid": path["sourceCid"],
                "destinationIndustryCid": path["destinationCid"],
                "destinationStockIndex": path["sink"].get("stockIndex"),
                "cargoType": path["cargoType"], "corridorMeters": metadata.get("distanceMeters"),
                "networkStatus": "routed"}
        routes.append(route)
    unrouted = sum(1 for service in services.values()
                   if isinstance(service, Mapping)
                   and service.get("metadata", {}).get("freightNetworkSchema") == 1
                   and service.get("metadata", {}).get("networkStatus") != "routed")
    return {"schemaVersion": SCHEMA_VERSION, "routes": routes if routes else {},
            "routeCount": len(routes), "unroutedLines": unrouted}


def rebuild(economy: dict[str, Any]) -> dict[str, Any]:
    return {"schemaVersion": SCHEMA_VERSION, "passenger": rebuild_passenger(economy),
            "cargo": rebuild_cargo(economy)}
