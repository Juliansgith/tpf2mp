from __future__ import annotations

from typing import Any, Mapping


VALID_SCOPES = {None, "local", "corridor"}
VALID_CARRIERS = {None, "RAIL", "ROAD", "TRAM", "WATER", "AIR", "UNKNOWN", "MIXED"}


def _canonical(value: Any, kind: str) -> bool:
    return isinstance(value, str) and value.startswith(f"{kind}:") and len(value) <= 240


def validate_metadata(
    market_value: Any, service_value: Any, service_enabled: Any = True,
) -> str | None:
    if not isinstance(market_value, Mapping) or not isinstance(service_value, Mapping):
        return "line.register metadata must be objects"
    market_scope = market_value.get("marketScope")
    service_scope = service_value.get("marketScope")
    if market_scope not in VALID_SCOPES or service_scope not in VALID_SCOPES \
            or market_scope != service_scope:
        return "line.register passenger market scope is inconsistent"
    if service_value.get("carrier") not in VALID_CARRIERS:
        return "line.register service carrier is invalid"
    if market_scope is None:
        return None

    town_a, town_b = market_value.get("townA"), market_value.get("townB")
    if not _canonical(town_a, "town") or not _canonical(town_b, "town"):
        return "line.register passenger market towns are invalid"
    if (market_scope == "local") != (town_a == town_b):
        return "line.register passenger market scope disagrees with its towns"
    endpoint_towns = service_value.get("endpointTownCids")
    if not isinstance(endpoint_towns, list) or endpoint_towns != [town_a, town_b]:
        return "line.register endpoint towns disagree with its market"
    station_groups = service_value.get("stationGroupCids")
    if not isinstance(station_groups, list) or not 2 <= len(station_groups) <= 256 \
            or not all(_canonical(value, "station_group") for value in station_groups):
        return "line.register station groups are invalid"
    if service_value.get("stationAccessSchema") != 1:
        return "line.register passenger service lacks station access proof"
    ready = service_value.get("endpointAccessReady")
    reachable = service_value.get("endpointReachableBuildings")
    totals = service_value.get("endpointTownBuildings")
    eligible = service_value.get("stationAccessEligible")
    source = service_value.get("stationAccessSource")
    if not isinstance(ready, list) or len(ready) != 2 \
            or not all(isinstance(value, bool) for value in ready):
        return "line.register endpoint access readiness is invalid"
    for label, values in (("reachable", reachable), ("town", totals)):
        if not isinstance(values, list) or len(values) != 2 or any(
            isinstance(value, bool) or not isinstance(value, int)
            or not 0 <= value <= 1_000_000 for value in values
        ):
            return f"line.register endpoint {label} building counts are invalid"
    if any(reachable[index] > totals[index] for index in range(2)):
        return "line.register reachable buildings exceed endpoint town buildings"
    expected = all(ready) and all(value > 0 for value in reachable)
    if not isinstance(eligible, bool) or eligible != expected:
        return "line.register station access eligibility is inconsistent"
    if (service_enabled is not False) != expected:
        return "line.register service enabled state disagrees with station access"
    expected_source = "native-street-catchment" if all(ready) else "unavailable"
    if source != expected_source:
        return "line.register station access source is inconsistent"
    return None
