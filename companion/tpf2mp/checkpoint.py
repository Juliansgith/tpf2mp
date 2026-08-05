from __future__ import annotations

import copy
from pathlib import Path
from typing import Any, Mapping

from .protocol import ProtocolError, checksum, decode_line, validate_envelope

CHECKPOINT_VERSION = 2
SUPPORTED_CHECKPOINT_VERSIONS = {1, CHECKPOINT_VERSION}
EVENT_RECORD_VERSION = 1


def _mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ProtocolError(f"{name} is not an object")
    return dict(value)


def _positive_int(value: Any, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool):
        raise ProtocolError(f"{name} is not an integer")
    try:
        result = int(value)
    except (TypeError, ValueError) as exc:
        raise ProtocolError(f"{name} is not an integer") from exc
    if result < minimum:
        raise ProtocolError(f"{name} is below {minimum}")
    return result


def verify_checkpoint(payload: Mapping[str, Any]) -> dict[str, Any]:
    checkpoint = _mapping(payload, "checkpoint")
    checkpoint_version = _positive_int(checkpoint.get("checkpointVersion"), "checkpointVersion", 1)
    if checkpoint_version not in SUPPORTED_CHECKPOINT_VERSIONS:
        raise ProtocolError(f"unsupported checkpoint version: {checkpoint.get('checkpointVersion')}")

    model = _mapping(checkpoint.get("model"), "checkpoint model")
    canonical = checkpoint.get("canonical")
    if not isinstance(canonical, (list, Mapping)) or (isinstance(canonical, Mapping) and canonical):
        raise ProtocolError("checkpoint canonical registry is not an array (or Lua's empty-table representation)")
    event_cursor = _mapping(checkpoint.get("eventCursor"), "checkpoint event cursor")

    actual_model = checksum(model)
    if checkpoint.get("modelDigest") != actual_model:
        raise ProtocolError(
            f"checkpoint model digest mismatch: expected {checkpoint.get('modelDigest')}, calculated {actual_model}"
        )
    actual_canonical = checksum(canonical)
    if checkpoint.get("canonicalDigest") != actual_canonical:
        raise ProtocolError(
            "checkpoint canonical digest mismatch: "
            f"expected {checkpoint.get('canonicalDigest')}, calculated {actual_canonical}"
        )

    core = copy.deepcopy(model)
    core["canonical"] = copy.deepcopy(canonical)
    actual_core = checksum(core)
    if checkpoint.get("coreDigest") != actual_core:
        raise ProtocolError(
            f"checkpoint core digest mismatch: expected {checkpoint.get('coreDigest')}, calculated {actual_core}"
        )

    if checkpoint_version >= 2:
        financial = _mapping(checkpoint.get("financial"), "checkpoint financial state")
        if set(financial) != {"companies"}:
            raise ProtocolError("checkpoint financial state must contain exactly companies")
        accounts = _mapping(financial.get("companies"), "checkpoint company accounts")
        for company_cid, account_value in accounts.items():
            if not isinstance(company_cid, str) or not company_cid.startswith("company:"):
                raise ProtocolError("checkpoint financial state has an invalid company id")
            account = _mapping(account_value, f"checkpoint account {company_cid}")
            if set(account) != {"balance", "loan"}:
                raise ProtocolError(f"checkpoint account {company_cid} has invalid fields")
            for field in ("balance", "loan"):
                if not isinstance(account[field], int) or isinstance(account[field], bool):
                    raise ProtocolError(f"checkpoint account {company_cid} {field} is not an integer")
        actual_financial = checksum(financial)
        if checkpoint.get("financialDigest") != actual_financial:
            raise ProtocolError(
                "checkpoint financial digest mismatch: "
                f"expected {checkpoint.get('financialDigest')}, calculated {actual_financial}"
            )

    last_event = _positive_int(event_cursor.get("lastEventSeq"), "lastEventSeq")
    next_event = _positive_int(event_cursor.get("nextEventSeq"), "nextEventSeq", 1)
    first_retained = _positive_int(event_cursor.get("firstRetainedSeq"), "firstRetainedSeq", 1)
    retained = _positive_int(event_cursor.get("retainedCount"), "retainedCount")
    _positive_int(event_cursor.get("lastCommitSeq"), "lastCommitSeq")
    if next_event != last_event + 1:
        raise ProtocolError(f"checkpoint event cursor is inconsistent: last={last_event}, next={next_event}")
    if retained == 0 and first_retained != next_event:
        raise ProtocolError("empty checkpoint event cursor has the wrong first retained sequence")
    if retained > 0 and first_retained + retained - 1 != last_event:
        raise ProtocolError("checkpoint retained event range is inconsistent")

    convergence_view: dict[str, Any] = {
        "checkpointVersion": checkpoint["checkpointVersion"],
        "stateVersion": checkpoint.get("stateVersion"),
        "protocol": checkpoint.get("protocol"),
        "sessionId": checkpoint.get("sessionId"),
        "lastCommitSeq": event_cursor["lastCommitSeq"],
        "modelDigest": checkpoint["modelDigest"],
        "canonicalDigest": checkpoint["canonicalDigest"],
        "coreDigest": checkpoint["coreDigest"],
    }
    if checkpoint_version >= 2:
        convergence_view["financialDigest"] = checkpoint["financialDigest"]
    if "structuralDigest" in checkpoint:
        convergence_view["structuralDigest"] = checkpoint["structuralDigest"]
    if "worldManifestDigest" in checkpoint:
        manifest_digest = checkpoint["worldManifestDigest"]
        if not isinstance(manifest_digest, str) or len(manifest_digest) != 8:
            raise ProtocolError("checkpoint worldManifestDigest is not an eight-character digest")
        convergence_view["worldManifestDigest"] = manifest_digest
    actual_convergence = checksum(convergence_view)
    if checkpoint.get("convergenceKey") != actual_convergence:
        raise ProtocolError(
            "checkpoint convergence key mismatch: "
            f"expected {checkpoint.get('convergenceKey')}, calculated {actual_convergence}"
        )

    core_payload = dict(checkpoint)
    expected_checkpoint = core_payload.pop("checkpointDigest", None)
    actual_checkpoint = checksum(core_payload)
    if expected_checkpoint != actual_checkpoint:
        raise ProtocolError(
            f"checkpoint digest mismatch: expected {expected_checkpoint}, calculated {actual_checkpoint}"
        )
    return checkpoint


def verify_event_record(payload: Mapping[str, Any]) -> dict[str, Any]:
    record = _mapping(payload, "event record")
    if _positive_int(record.get("recordVersion"), "recordVersion", 1) != EVENT_RECORD_VERSION:
        raise ProtocolError(f"unsupported event record version: {record.get('recordVersion')}")
    _positive_int(record.get("localEventSeq"), "localEventSeq", 1)
    _mapping(record.get("action"), "event action")
    for field in ("preDigest", "postDigest", "preModelDigest", "postModelDigest"):
        value = record.get(field)
        if not isinstance(value, str) or len(value) != 8:
            raise ProtocolError(f"event {field} is not an eight-character digest")
    if not isinstance(record.get("success"), bool) or not isinstance(record.get("portable"), bool):
        raise ProtocolError("event success/portable flags are malformed")
    core = dict(record)
    expected = core.pop("recordDigest", None)
    actual = checksum(core)
    if expected != actual:
        raise ProtocolError(f"event record digest mismatch: expected {expected}, calculated {actual}")
    return record


def _integer(value: Any, fallback: int, low: int | None = None, high: int | None = None) -> int:
    # Lua's util.integer treats a boolean as absent; Python's int(True) is 1.
    # Match Lua so a malformed payload cannot replay to different numbers on
    # the two sides and turn a validation problem into a replay divergence.
    if isinstance(value, bool):
        value = None
    try:
        number = int(value)
    except (TypeError, ValueError, OverflowError):
        number = fallback
    if low is not None:
        number = max(low, number)
    if high is not None:
        number = min(high, number)
    return number


def _upsert_market(economy: dict[str, Any], market: Mapping[str, Any]) -> None:
    cid = str(market["cid"])
    economy.setdefault("markets", {})[cid] = {
        "cid": cid,
        "name": str(market.get("name", cid)),
        "demand": _integer(market.get("demand"), 100, 0, 1_000_000_000),
        "outsideWeight": _integer(market.get("outsideWeight"), 2500, 1, 1_000_000_000),
        "metadata": copy.deepcopy(market.get("metadata", {})),
    }


def _upsert_service(economy: dict[str, Any], service: Mapping[str, Any]) -> None:
    line_cid = str(service["lineCid"])
    market_cid = str(service["marketCid"])
    if market_cid not in economy.setdefault("markets", {}):
        raise ProtocolError(f"replay service references unknown market: {market_cid}")
    economy.setdefault("services", {})[line_cid] = {
        "lineCid": line_cid,
        "marketCid": market_cid,
        "companyCid": str(service["companyCid"]),
        "name": str(service.get("name", line_cid)),
        "headwaySeconds": _integer(service.get("headwaySeconds"), 1800, 30, 86400),
        "journeySeconds": _integer(service.get("journeySeconds"), 3600, 30, 604800),
        "fareCents": _integer(service.get("fareCents"), 1000, 0, 100_000_000),
        "capacity": _integer(service.get("capacity"), 100, 0, 1_000_000_000),
        "quality": _integer(service.get("quality"), 100, 0, 1000),
        "enabled": service.get("enabled") is not False,
    }


_SHARE_SCALE = 1_000_000
_ACCUMULATOR_LIMIT = 1_000_000_000_000_000

# Pinned integer exponential shared byte-for-byte with the Lua model:
# _EXP_TABLE[k] = round(65536 * exp(-k / 10)) for k = 0..80. Both languages
# interpolate this table so no platform libm can enter a digest.
_EXP_TABLE = [
    65536, 59299, 53656, 48550, 43930, 39750, 35967, 32544, 29447,
    26645, 24109, 21815, 19739, 17861, 16161, 14623, 13231, 11972,
    10833, 9802, 8869, 8025, 7262, 6571, 5945, 5380, 4868,
    4404, 3985, 3606, 3263, 2952, 2671, 2417, 2187, 1979,
    1791, 1620, 1466, 1327, 1200, 1086, 983, 889, 805,
    728, 659, 596, 539, 488, 442, 400, 362, 327,
    296, 268, 242, 219, 198, 180, 162, 147, 133,
    120, 109, 99, 89, 81, 73, 66, 60, 54,
    49, 44, 40, 36, 33, 30, 27, 24, 22,
]


def _economy_version(economy: Mapping[str, Any]) -> int:
    return _integer(economy.get("version"), 1)


def _economy_params(economy: Mapping[str, Any]) -> dict[str, int]:
    params = economy.get("params") if isinstance(economy.get("params"), Mapping) else {}
    return {
        "alphaUpPm": _integer(params.get("alphaUpPm"), 80),
        "alphaDownPm": _integer(params.get("alphaDownPm"), 250),
        "maxWaitSeconds": _integer(params.get("maxWaitSeconds"), 1800),
        "transferSeconds": _integer(params.get("transferSeconds"), 480),
        "crowdThresholdPpm": _integer(params.get("crowdThresholdPpm"), 700_000),
    }


# Mirrors economy.lua's M.MARKET_KINDS exactly; kind weighting is market data
# so the shared evaluator stays branch-free.
_MARKET_KINDS = {
    "passenger": {
        "waitWeightPm": 2000,
        "transferSeconds": 480,
        "votCentsPerHour": 450,
        "gcOutsideCents": 2500,
    },
    "cargo": {
        "waitWeightPm": 1000,
        "transferSeconds": 1800,
        "votCentsPerHour": 60,
        "gcOutsideCents": 1800,
    },
}


def _upsert_market_v2(economy: dict[str, Any], market: Mapping[str, Any]) -> None:
    cid = str(market["cid"])
    v4 = _economy_version(economy) >= 4
    kind = "passenger"
    if v4 and isinstance(market.get("kind"), str) and market["kind"] in _MARKET_KINDS:
        kind = market["kind"]
    kind_defaults = _MARKET_KINDS[kind]
    gc_outside = _integer(
        market.get("gcOutsideCents"),
        kind_defaults["gcOutsideCents"] if v4 else 2500,
        1,
        100_000_000,
    )
    record: dict[str, Any] = {
        "cid": cid,
        "name": str(market.get("name", cid)),
        "demand": _integer(market.get("demand"), 100, 0, 1_000_000_000),
        "votCentsPerHour": _integer(
            market.get("votCentsPerHour"),
            kind_defaults["votCentsPerHour"] if v4 else 450,
            30,
            100_000,
        ),
        "gcOutsideCents": gc_outside,
        "thetaCents": _integer(market.get("thetaCents"), max(200, gc_outside * 8 // 100), 50, 1_000_000),
        "metadata": copy.deepcopy(market.get("metadata", {})),
    }
    if v4:
        record["kind"] = kind
        record["waitWeightPm"] = _integer(market.get("waitWeightPm"), kind_defaults["waitWeightPm"], 0, 10_000)
        record["transferSeconds"] = _integer(
            market.get("transferSeconds"), kind_defaults["transferSeconds"], 0, 14_400
        )
    economy.setdefault("markets", {})[cid] = record


def _upsert_service_v2(economy: dict[str, Any], service: Mapping[str, Any]) -> None:
    line_cid = str(service["lineCid"])
    market_cid = str(service["marketCid"])
    if market_cid not in economy.setdefault("markets", {}):
        raise ProtocolError(f"replay service references unknown market: {market_cid}")
    existing = economy.setdefault("services", {}).get(line_cid)
    fare_cents = _integer(service.get("fareCents"), 1000, 0, 100_000_000)
    if isinstance(existing, dict) and existing.get("sharePpm") is not None:
        share_ppm = int(existing["sharePpm"])
        share_resid = int(existing.get("shareResid", 0))
        lag_load_ppm = int(existing.get("lagLoadPpm", 0))
    else:
        share_ppm = _integer(service.get("sharePpm"), 0, 0, _SHARE_SCALE)
        share_resid = 0
        lag_load_ppm = 0
    if isinstance(existing, dict):
        last_fare_cents = existing.get("lastFareCents")
    else:
        last_fare_cents = _integer(
            service.get("lastFareCents"), fare_cents, 0, 100_000_000
        )
    economy["services"][line_cid] = {
        "lineCid": line_cid,
        "marketCid": market_cid,
        "companyCid": str(service["companyCid"]),
        "name": str(service.get("name", line_cid)),
        "headwaySeconds": _integer(service.get("headwaySeconds"), 1800, 30, 86400),
        "journeySeconds": _integer(service.get("journeySeconds"), 3600, 30, 604800),
        "fareCents": fare_cents,
        "capacity": _integer(service.get("capacity"), 100, 0, 1_000_000_000),
        "quality": _integer(service.get("quality"), 100, 0, 1000),
        "transfers": _integer(service.get("transfers"), 0, 0, 8),
        "enabled": service.get("enabled") is not False,
        "sharePpm": share_ppm,
        "shareResid": share_resid,
        "lagLoadPpm": lag_load_ppm,
    }
    if _economy_version(economy) >= 3:
        economy["services"][line_cid]["lastFareCents"] = last_fare_cents


def _clamp(value: int, low: int, high: int) -> int:
    return max(low, min(high, value))


def _saturating_add(left: int, right: int) -> int:
    return min(_ACCUMULATOR_LIMIT, max(0, int(left)) + max(0, int(right)))


def _saturating_multiply(left: int, right: int) -> int:
    return min(_ACCUMULATOR_LIMIT, max(0, int(left)) * max(0, int(right)))


def _generalized_cost(
    params: Mapping[str, int], market: Mapping[str, Any], service: Mapping[str, Any]
) -> tuple[int, dict[str, int]]:
    vot = int(market["votCentsPerHour"])
    # Markets recorded before version 4 carry no kind fields; the explicit
    # None checks keep a legitimate zero weight distinct from absence.
    wait_weight_pm = market.get("waitWeightPm")
    if wait_weight_pm is None:
        wait_weight_pm = 2000
    transfer_seconds = market.get("transferSeconds")
    if transfer_seconds is None:
        transfer_seconds = int(params["transferSeconds"])
    wait_seconds = min(int(service["headwaySeconds"]) // 2, int(params["maxWaitSeconds"]))
    time_cost = vot * int(service["journeySeconds"]) // 3600
    wait_cost = vot * wait_seconds * int(wait_weight_pm) // 3_600_000
    transfer_cost = vot * int(service.get("transfers", 0)) * int(transfer_seconds) // 3600
    crowd_span = _SHARE_SCALE - int(params["crowdThresholdPpm"])
    crowd_excess = _clamp(int(service.get("lagLoadPpm", 0)) - int(params["crowdThresholdPpm"]), 0, crowd_span)
    crowd_cost = time_cost * crowd_excess // crowd_span
    comfort = int(service["quality"])
    gc = max(1, int(service["fareCents"]) + time_cost + wait_cost + transfer_cost + crowd_cost - comfort)
    return gc, {
        "fareCents": int(service["fareCents"]),
        "timeCostCents": time_cost,
        "waitCostCents": wait_cost,
        "transferCostCents": transfer_cost,
        "crowdCostCents": crowd_cost,
        "comfortCents": comfort,
        "gcCents": gc,
    }


def _logit_weight_with_cutoff(
    gc_cents: int, gc_min_cents: int, theta_cents: int, cutoff_weight: int
) -> int:
    centinats = (gc_cents - gc_min_cents) * 100 // theta_cents
    if centinats >= 800:
        return cutoff_weight
    if centinats < 0:
        centinats = 0
    index, fraction = centinats // 10, centinats % 10
    left, right = _EXP_TABLE[index], _EXP_TABLE[index + 1]
    return max(cutoff_weight, left + (right - left) * fraction // 10)


def _logit_weight(gc_cents: int, gc_min_cents: int, theta_cents: int) -> int:
    return _logit_weight_with_cutoff(gc_cents, gc_min_cents, theta_cents, 0)


def _glide_step(actual: int, equilibrium: int, alpha_pm: int, resid: int) -> tuple[int, int]:
    delta = (equilibrium - actual) * alpha_pm + resid
    # Lua's math.floor(delta / 1000) floors toward negative infinity, which is
    # exactly Python's // on integers — do not "simplify" into C truncation.
    step = delta // 1000
    return actual + step, delta - step * 1000


def _evaluate_market_v2(economy: Mapping[str, Any], market_cid: str) -> dict[str, Any]:
    market = economy["markets"][market_cid]
    params = _economy_params(economy)
    services: list[dict[str, Any]] = []
    for line_cid in sorted(economy.get("services", {})):
        service = economy["services"][line_cid]
        if service.get("enabled") is not False and service.get("marketCid") == market_cid:
            gc_cents, factors = _generalized_cost(params, market, service)
            services.append({"cid": line_cid, "service": service, "gcCents": gc_cents, "factors": factors})

    gc_min = int(market["gcOutsideCents"])
    for option in services:
        gc_min = min(gc_min, option["gcCents"])
    theta = int(market["thetaCents"])
    cutoff_weight = 0 if _economy_version(economy) >= 3 else 1
    weight_items = [{
        "cid": "~outside",
        "weight": _logit_weight_with_cutoff(
            int(market["gcOutsideCents"]), gc_min, theta, cutoff_weight
        ),
    }]
    for option in services:
        option["weight"] = _logit_weight_with_cutoff(
            option["gcCents"], gc_min, theta, cutoff_weight
        )
        weight_items.append({"cid": option["cid"], "weight": option["weight"]})
    equilibrium_ppm = _proportional(_SHARE_SCALE, weight_items)

    service_share_ppm = 0
    for option in services:
        service = option["service"]
        equilibrium = equilibrium_ppm.get(option["cid"], 0)
        option["equilibriumPpm"] = equilibrium
        if service.get("sharePpm") is None:
            service["sharePpm"], service["shareResid"] = equilibrium, 0
        else:
            fare_shock = _economy_version(economy) >= 3 and (
                service.get("lastFareCents") is None
                or int(service["fareCents"]) > int(service["lastFareCents"])
            )
            alpha = (
                params["alphaUpPm"]
                if equilibrium >= int(service["sharePpm"])
                else (1000 if fare_shock else params["alphaDownPm"])
            )
            share, resid = _glide_step(
                int(service["sharePpm"]), equilibrium, alpha, int(service.get("shareResid", 0))
            )
            service["sharePpm"] = _clamp(share, 0, _SHARE_SCALE)
            service["shareResid"] = resid
        if _economy_version(economy) >= 3:
            service["lastFareCents"] = int(service["fareCents"])
        service_share_ppm += int(service["sharePpm"])
    outside_ppm = max(0, _SHARE_SCALE - service_share_ppm)

    active = list(services)
    allocations: dict[str, int] = {}
    remaining = int(market["demand"])
    while remaining > 0 and active:
        preview_items = [{"cid": "~outside", "weight": outside_ppm}]
        preview_items.extend(
            {"cid": option["cid"], "weight": int(option["service"]["sharePpm"])} for option in active
        )
        preview = _proportional(remaining, preview_items)
        capped = [option for option in active if preview.get(option["cid"], 0) > int(option["service"]["capacity"])]
        if not capped:
            for cid, amount in preview.items():
                allocations[cid] = allocations.get(cid, 0) + amount
            remaining = 0
        else:
            capped_ids = {option["cid"] for option in capped}
            for option in capped:
                amount = int(option["service"]["capacity"])
                allocations[option["cid"]] = amount
                remaining -= amount
            active = [option for option in active if option["cid"] not in capped_ids]
    if remaining > 0:
        allocations["~outside"] = allocations.get("~outside", 0) + remaining

    result: dict[str, Any] = {
        "marketCid": market_cid,
        "name": market["name"],
        "demand": int(market["demand"]),
        "gcOutsideCents": int(market["gcOutsideCents"]),
        "thetaCents": theta,
        "outside": allocations.get("~outside", 0),
        "outsidePpm": outside_ppm,
        "services": {},
    }
    if market.get("kind") is not None:
        result["kind"] = market["kind"]
    for option in services:
        service = option["service"]
        amount = allocations.get(option["cid"], 0)
        if int(service["capacity"]) > 0:
            service["lagLoadPpm"] = amount * _SHARE_SCALE // int(service["capacity"])
        else:
            service["lagLoadPpm"] = _SHARE_SCALE
        result["services"][option["cid"]] = {
            "lineCid": option["cid"],
            "companyCid": service["companyCid"],
            "name": service["name"],
            "allocated": amount,
            "capacity": service["capacity"],
            "fareCents": service["fareCents"],
            "revenueCents": _saturating_multiply(amount, int(service["fareCents"])),
            "shareBasisPoints": amount * 10000 // int(market["demand"]) if int(market["demand"]) > 0 else 0,
            "sharePpm": int(service["sharePpm"]),
            "shareResid": int(service["shareResid"]),
            "equilibriumPpm": option["equilibriumPpm"],
            "lagLoadPpm": int(service["lagLoadPpm"]),
            "factors": option["factors"],
        }
    return result


def _evaluate_all_v2(economy: dict[str, Any]) -> dict[str, Any]:
    results: dict[str, Any] = {"markets": {}, "companies": {}, "totalDemand": 0, "totalRevenueCents": 0}
    for market_cid in sorted(economy.get("markets", {})):
        market = _evaluate_market_v2(economy, market_cid)
        results["markets"][market_cid] = market
        results["totalDemand"] = _saturating_add(results["totalDemand"], market["demand"])
        for line_cid in sorted(market["services"]):
            service = market["services"][line_cid]
            company_cid = service["companyCid"]
            company = results["companies"].setdefault(
                company_cid, {"companyCid": company_cid, "demand": 0, "revenueCents": 0}
            )
            company["demand"] = _saturating_add(company["demand"], service["allocated"])
            company["revenueCents"] = _saturating_add(company["revenueCents"], service["revenueCents"])
            results["totalRevenueCents"] = _saturating_add(
                results["totalRevenueCents"], service["revenueCents"]
            )
    economy["epoch"] = int(economy.get("epoch", 0)) + 1
    results["epoch"] = economy["epoch"]
    economy["lastResults"] = copy.deepcopy(results)
    return results


def _attractiveness(service: Mapping[str, Any]) -> tuple[int, dict[str, int]]:
    frequency = 3_600_000 // max(30, int(service["headwaySeconds"]))
    journey = 7_200_000 // max(30, int(service["journeySeconds"]))
    quality = int(service["quality"]) * 25
    fare_penalty = int(service["fareCents"]) * 2
    weight = max(1, min(1_000_000_000, 100 + frequency + journey + quality - fare_penalty))
    return weight, {
        "frequency": frequency,
        "journey": journey,
        "quality": quality,
        "farePenalty": fare_penalty,
    }


def _proportional(total: int, items: list[dict[str, Any]]) -> dict[str, int]:
    weight_sum = sum(int(item["weight"]) for item in items)
    if total <= 0 or weight_sum <= 0:
        return {}
    allocations: dict[str, int] = {}
    ranked: list[tuple[int, str]] = []
    used = 0
    for item in items:
        cid = str(item["cid"])
        numerator = total * int(item["weight"])
        base = numerator // weight_sum
        allocations[cid] = base
        used += base
        ranked.append((numerator % weight_sum, cid))
    ranked.sort(key=lambda item: (-item[0], item[1]))
    for index in range(total - used):
        cid = ranked[index % len(ranked)][1]
        allocations[cid] += 1
    return allocations


def _evaluate_market(economy: Mapping[str, Any], market_cid: str) -> dict[str, Any]:
    market = economy["markets"][market_cid]
    services: list[dict[str, Any]] = []
    for line_cid in sorted(economy.get("services", {})):
        service = economy["services"][line_cid]
        if service.get("enabled") is not False and service.get("marketCid") == market_cid:
            weight, factors = _attractiveness(service)
            services.append({"cid": line_cid, "service": service, "weight": weight, "factors": factors})

    active = list(services)
    allocations: dict[str, int] = {}
    remaining = int(market["demand"])
    while remaining > 0 and active:
        preview_items = [{"cid": "~outside", "weight": int(market["outsideWeight"])}]
        preview_items.extend({"cid": option["cid"], "weight": option["weight"]} for option in active)
        preview = _proportional(remaining, preview_items)
        capped = [option for option in active if preview.get(option["cid"], 0) > int(option["service"]["capacity"])]
        if not capped:
            for cid, amount in preview.items():
                allocations[cid] = allocations.get(cid, 0) + amount
            remaining = 0
        else:
            capped_ids = {option["cid"] for option in capped}
            for option in capped:
                amount = int(option["service"]["capacity"])
                allocations[option["cid"]] = amount
                remaining -= amount
            active = [option for option in active if option["cid"] not in capped_ids]
    if remaining > 0:
        allocations["~outside"] = allocations.get("~outside", 0) + remaining

    result: dict[str, Any] = {
        "marketCid": market_cid,
        "name": market["name"],
        "demand": int(market["demand"]),
        "outside": allocations.get("~outside", 0),
        "services": {},
    }
    for option in services:
        service = option["service"]
        amount = allocations.get(option["cid"], 0)
        result["services"][option["cid"]] = {
            "lineCid": option["cid"],
            "companyCid": service["companyCid"],
            "name": service["name"],
            "allocated": amount,
            "capacity": service["capacity"],
            "fareCents": service["fareCents"],
            "revenueCents": amount * int(service["fareCents"]),
            "shareBasisPoints": amount * 10000 // int(market["demand"]) if int(market["demand"]) > 0 else 0,
            "weight": option["weight"],
            "factors": option["factors"],
        }
    return result


def _evaluate_all(economy: dict[str, Any]) -> dict[str, Any]:
    results: dict[str, Any] = {"markets": {}, "companies": {}, "totalDemand": 0, "totalRevenueCents": 0}
    for market_cid in sorted(economy.get("markets", {})):
        market = _evaluate_market(economy, market_cid)
        results["markets"][market_cid] = market
        results["totalDemand"] += market["demand"]
        for line_cid in sorted(market["services"]):
            service = market["services"][line_cid]
            company_cid = service["companyCid"]
            company = results["companies"].setdefault(
                company_cid, {"companyCid": company_cid, "demand": 0, "revenueCents": 0}
            )
            company["demand"] += service["allocated"]
            company["revenueCents"] += service["revenueCents"]
            results["totalRevenueCents"] += service["revenueCents"]
    economy["epoch"] = int(economy.get("epoch", 0)) + 1
    results["epoch"] = economy["epoch"]
    economy["lastResults"] = copy.deepcopy(results)
    return results


def _record_settlement(economy: dict[str, Any], results: Mapping[str, Any]) -> None:
    ledger = economy.setdefault(
        "ledger",
        {"settledEpochs": {}, "companies": {}, "settlementCount": 0, "totalDemand": 0, "totalRevenueCents": 0},
    )
    epoch_key = str(int(results["epoch"]))
    if ledger.setdefault("settledEpochs", {}).get(epoch_key):
        raise ProtocolError(f"replay settlement epoch already exists: {epoch_key}")
    ledger["settledEpochs"][epoch_key] = True
    ledger["settlementCount"] = int(ledger.get("settlementCount", 0)) + 1
    if _economy_version(economy) >= 2:
        ledger["totalDemand"] = _saturating_add(ledger.get("totalDemand", 0), results.get("totalDemand", 0))
        ledger["totalRevenueCents"] = _saturating_add(
            ledger.get("totalRevenueCents", 0), results.get("totalRevenueCents", 0)
        )
    else:
        ledger["totalDemand"] = int(ledger.get("totalDemand", 0)) + int(results.get("totalDemand", 0))
        ledger["totalRevenueCents"] = int(ledger.get("totalRevenueCents", 0)) + int(
            results.get("totalRevenueCents", 0)
        )
    companies = ledger.setdefault("companies", {})
    for company_cid in sorted(results.get("companies", {})):
        item = results["companies"][company_cid]
        total = companies.setdefault(
            company_cid, {"companyCid": company_cid, "demand": 0, "revenueCents": 0, "wins": 0}
        )
        if _economy_version(economy) >= 2:
            total["demand"] = _saturating_add(total.get("demand", 0), item.get("demand", 0))
            total["revenueCents"] = _saturating_add(
                total.get("revenueCents", 0), item.get("revenueCents", 0)
            )
        else:
            total["demand"] += int(item.get("demand", 0))
            total["revenueCents"] += int(item.get("revenueCents", 0))
    for market in results.get("markets", {}).values():
        best_company: str | None = None
        best_demand = -1
        for service in market.get("services", {}).values():
            company_cid = str(service["companyCid"])
            demand = int(service["allocated"])
            if demand > best_demand or (demand == best_demand and company_cid < (best_company or "~")):
                best_company, best_demand = company_cid, demand
        if best_company is not None and best_company in companies:
            companies[best_company]["wins"] = int(companies[best_company].get("wins", 0)) + 1


def _scoreboard(model: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
    economy = model["economy"]
    markets_by_company: dict[str, set[str]] = {}
    lines_by_company: dict[str, int] = {}
    for service in economy.get("services", {}).values():
        if service.get("enabled") is not False:
            company_cid = str(service["companyCid"])
            lines_by_company[company_cid] = lines_by_company.get(company_cid, 0) + 1
            markets_by_company.setdefault(company_cid, set()).add(str(service["marketCid"]))
    result: dict[str, dict[str, Any]] = {}
    ledger_companies = economy.get("ledger", {}).get("companies", {})
    for company_cid in sorted(model.get("companies", {})):
        totals = ledger_companies.get(company_cid, {})
        reach = len(markets_by_company.get(company_cid, set()))
        lines = lines_by_company.get(company_cid, 0)
        revenue = int(totals.get("revenueCents", 0))
        demand = int(totals.get("demand", 0))
        if _economy_version(economy) >= 2:
            model_value = _saturating_add(
                _saturating_add(_saturating_multiply(revenue, 10), _saturating_multiply(demand, 100)),
                _saturating_add(_saturating_multiply(reach, 500_000), _saturating_multiply(lines, 250_000)),
            )
        else:
            model_value = revenue * 10 + demand * 100 + reach * 500_000 + lines * 250_000
        result[company_cid] = {
            "companyCid": company_cid,
            "name": model["companies"][company_cid].get("name", company_cid),
            "settledDemand": demand,
            "settledRevenueCents": revenue,
            "marketsReached": reach,
            "activeLines": lines,
            "marketWins": int(totals.get("wins", 0)),
            "modelValueCents": model_value,
        }
    return result


def _ranked_winner(model: Mapping[str, Any]) -> tuple[str | None, list[dict[str, Any]]]:
    ranked = list(_scoreboard(model).values())
    ranked.sort(
        key=lambda item: (
            -int(item["modelValueCents"]),
            -int(item["settledRevenueCents"]),
            -int(item["settledDemand"]),
            -int(item["marketWins"]),
            str(item["companyCid"]),
        )
    )
    return (str(ranked[0]["companyCid"]) if ranked else None), ranked


def _evaluate_match_end(model: dict[str, Any], event_tick: int | None = None) -> None:
    match = model.get("match")
    if not isinstance(match, dict) or match.get("status") != "running":
        return
    rules = match.get("rules", {})
    winner_cid, ranked = _ranked_winner(model)
    leader = ranked[0] if ranked else None
    target = int(rules.get("valuationTargetCents", 0))
    max_epochs = int(rules.get("maxEpochs", 0))
    reason: str | None = None
    if target > 0 and leader is not None and int(leader["modelValueCents"]) >= target:
        reason = "valuation-target"
    elif max_epochs > 0 and int(model["economy"].get("epoch", 0)) >= max_epochs:
        reason = "epoch-limit"
    if reason:
        match["status"] = "finished"
        match["finishReason"] = reason
        match["winnerCid"] = winner_cid


def _apply_portable_action(model: dict[str, Any], action: Mapping[str, Any], event_tick: int | None = None) -> None:
    action_type = action.get("type")
    economy = _mapping(model.get("economy"), "replay economy")
    model["economy"] = economy
    if action_type == "world.freeze":
        model["autonomyFrozen"] = action.get("freeze") is not False
    elif action_type == "line.register":
        if not isinstance(action.get("market"), Mapping) or not isinstance(action.get("service"), Mapping):
            raise ProtocolError("portable line.register lacks authoritative facts")
        if _economy_version(economy) >= 2:
            _upsert_market_v2(economy, action["market"])
            _upsert_service_v2(economy, action["service"])
        else:
            _upsert_market(economy, action["market"])
            _upsert_service(economy, action["service"])
    elif action_type == "fare.adjust":
        line_cid = str(action.get("lineCid", ""))
        service = economy.get("services", {}).get(line_cid)
        if not isinstance(service, dict):
            raise ProtocolError(f"replay fare references unknown line: {line_cid}")
        service["fareCents"] = _integer(
            int(service["fareCents"]) + _integer(action.get("deltaCents"), 0),
            int(service["fareCents"]),
            0,
            100_000_000,
        )
    elif action_type == "economy.seed_demo":
        order = model.get("companyOrder", [])
        if not isinstance(order, list) or len(order) < 2:
            raise ProtocolError("demo replay requires two companies")
        first, second = str(order[0]), str(order[1])
        companies = _mapping(model.get("companies"), "replay companies")
        if _economy_version(economy) >= 4:
            _upsert_market_v2(
                economy,
                {"cid": "market:prototype-corridor", "name": "Prototype intercity corridor",
                 "demand": 1000, "votCentsPerHour": 450, "gcOutsideCents": 2500, "thetaCents": 250},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-company-1", "marketCid": "market:prototype-corridor",
                 "companyCid": first, "name": str(companies[first]["name"]) + " service",
                 "headwaySeconds": 900, "journeySeconds": 2400, "fareCents": 1000, "capacity": 600,
                 "quality": 100, "transfers": 0},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-company-2", "marketCid": "market:prototype-corridor",
                 "companyCid": second, "name": str(companies[second]["name"]) + " service",
                 "headwaySeconds": 1100, "journeySeconds": 2200, "fareCents": 900, "capacity": 600,
                 "quality": 100, "transfers": 0},
            )
            _upsert_market_v2(
                economy,
                {"cid": "market:prototype-freight", "name": "Prototype freight corridor",
                 "kind": "cargo", "demand": 800},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-freight-1", "marketCid": "market:prototype-freight",
                 "companyCid": first, "name": str(companies[first]["name"]) + " freight",
                 "headwaySeconds": 3600, "journeySeconds": 5400, "fareCents": 700, "capacity": 400,
                 "quality": 100, "transfers": 0},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-freight-2", "marketCid": "market:prototype-freight",
                 "companyCid": second, "name": str(companies[second]["name"]) + " freight",
                 "headwaySeconds": 2700, "journeySeconds": 4800, "fareCents": 800, "capacity": 400,
                 "quality": 100, "transfers": 0},
            )
            preview_state = copy.deepcopy(economy)
            preview = _evaluate_all_v2(preview_state)
        elif _economy_version(economy) >= 2:
            _upsert_market_v2(
                economy,
                {"cid": "market:prototype-corridor", "name": "Prototype intercity corridor",
                 "demand": 1000, "votCentsPerHour": 450, "gcOutsideCents": 2500, "thetaCents": 250},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-company-1", "marketCid": "market:prototype-corridor",
                 "companyCid": first, "name": str(companies[first]["name"]) + " service",
                 "headwaySeconds": 900, "journeySeconds": 2400, "fareCents": 1000, "capacity": 600,
                 "quality": 100, "transfers": 0},
            )
            _upsert_service_v2(
                economy,
                {"lineCid": "line:prototype-company-2", "marketCid": "market:prototype-corridor",
                 "companyCid": second, "name": str(companies[second]["name"]) + " service",
                 "headwaySeconds": 1100, "journeySeconds": 2200, "fareCents": 900, "capacity": 600,
                 "quality": 100, "transfers": 0},
            )
            preview_state = copy.deepcopy(economy)
            preview = _evaluate_all_v2(preview_state)
        else:
            _upsert_market(
                economy,
                {"cid": "market:prototype-corridor", "name": "Prototype intercity corridor", "demand": 1000,
                 "outsideWeight": 2500},
            )
            _upsert_service(
                economy,
                {"lineCid": "line:prototype-company-1", "marketCid": "market:prototype-corridor",
                 "companyCid": first, "name": str(companies[first]["name"]) + " service", "headwaySeconds": 900,
                 "journeySeconds": 2400, "fareCents": 1000, "capacity": 600, "quality": 100},
            )
            _upsert_service(
                economy,
                {"lineCid": "line:prototype-company-2", "marketCid": "market:prototype-corridor",
                 "companyCid": second, "name": str(companies[second]["name"]) + " service", "headwaySeconds": 1100,
                 "journeySeconds": 2200, "fareCents": 900, "capacity": 600, "quality": 100},
            )
            preview_state = copy.deepcopy(economy)
            preview = _evaluate_all(preview_state)
        preview["epoch"] = int(economy.get("epoch", 0))
        preview["preview"] = True
        economy["lastResults"] = preview
    elif action_type == "economy.settle":
        if _economy_version(economy) >= 2:
            # Version-2 share/crowding stocks live in the authored model, so
            # replay must advance them by deterministic re-evaluation; embedded
            # host results are verified against it by canonical checksum.
            results = _evaluate_all_v2(economy)
            if isinstance(action.get("results"), Mapping):
                if checksum(copy.deepcopy(dict(action["results"]))) != checksum(results):
                    raise ProtocolError(
                        "economy.settle results diverge from deterministic model replay"
                    )
        elif isinstance(action.get("results"), Mapping):
            results = copy.deepcopy(dict(action["results"]))
            economy["epoch"] = int(results["epoch"])
            economy["lastResults"] = copy.deepcopy(results)
        else:
            results = _evaluate_all(economy)
        _record_settlement(economy, results)
        # Network checkpoints include the canonical cash ledger in their
        # authored model. Native journal commands are deliberately excluded;
        # replay applies only the deterministic ordered payout amounts.
        network_finance = model.get("networkFinance")
        if isinstance(network_finance, dict) and network_finance.get("initialized") is True:
            accounts = _mapping(network_finance.get("accounts"), "replay network finance accounts")
            result_companies = _mapping(results.get("companies"), "settlement result companies")
            for company_cid in sorted(result_companies):
                account = accounts.get(str(company_cid))
                if not isinstance(account, dict):
                    raise ProtocolError(f"settlement finance references unknown company: {company_cid}")
                revenue_cents = int(result_companies[company_cid].get("revenueCents", 0))
                account["balance"] = int(account.get("balance", 0)) + revenue_cents // 100
        _evaluate_match_end(model, event_tick)
    elif action_type == "match.finish":
        match = model.get("match")
        if not isinstance(match, dict):
            raise ProtocolError("portable match.finish requires lifecycle state")
        winner_cid, _ = _ranked_winner(model)
        match["status"] = "finished"
        match["finishReason"] = str(action.get("reason", "manual"))
        match["winnerCid"] = str(action.get("winnerCid") or winner_cid)
    else:
        raise ProtocolError(f"portable replay does not implement action: {action_type}")


def _outbox_messages(bridge_root: Path | str, session: str, peer: str | None = None) -> list[dict[str, Any]]:
    outbox = Path(bridge_root).expanduser().resolve() / "game_outbox"
    messages: list[dict[str, Any]] = []
    for path in sorted(outbox.glob("*.json")):
        try:
            message = decode_line(path.read_bytes())
            validate_envelope(message, session)
        except (OSError, ProtocolError) as exc:
            raise ProtocolError(f"cannot read checkpoint stream at {path}: {exc}") from exc
        if peer is not None and str(message.get("peer")) != peer:
            continue
        message = dict(message)
        message["_source_mtime_ns"] = path.stat().st_mtime_ns
        messages.append(message)
    return messages


def analyse_bridge(
    bridge_root: Path | str,
    session: str,
    peer: str | None = None,
    anchor: str = "latest",
) -> dict[str, Any]:
    if anchor not in {"first", "latest"}:
        raise ValueError("checkpoint anchor must be 'first' or 'latest'")
    messages = _outbox_messages(bridge_root, session, peer)
    checkpoints = sorted(
        (message for message in messages if message.get("kind") == "checkpoint"),
        key=lambda message: (
            int(message.get("_source_mtime_ns", -1)),
            int(message.get("local_seq", -1)),
        ),
    )
    if not checkpoints:
        raise ValueError(f"no checkpoint export for session {session!r}")
    selected = checkpoints[0] if anchor == "first" else checkpoints[-1]
    checkpoint = verify_checkpoint(_mapping(selected.get("payload"), "checkpoint message payload"))
    selected_seq = _positive_int(selected.get("local_seq"), "checkpoint local sequence", 1)
    selected_mtime = int(selected.get("_source_mtime_ns", -1))
    event_messages = sorted(
        (
            message
            for message in messages
            if message.get("kind") == "event"
            and _positive_int(message.get("local_seq"), "event local sequence", 1) > selected_seq
            and int(message.get("_source_mtime_ns", -1)) >= selected_mtime
        ),
        key=lambda message: int(
            _mapping(message.get("payload"), "event message payload").get("localEventSeq", -1)
        ),
    )
    events = [
        verify_event_record(_mapping(message.get("payload"), "event message payload"))
        for message in event_messages
    ]

    expected_core = str(checkpoint["coreDigest"])
    expected_model = str(checkpoint["modelDigest"])
    previous_event_seq = int(checkpoint["eventCursor"]["lastEventSeq"])
    model = copy.deepcopy(checkpoint["model"])
    replay_status = "verified"
    replay_blocker: str | None = None
    portable_changes = canonical_changes = noops = 0

    for event in events:
        event_seq = int(event["localEventSeq"])
        if event_seq != previous_event_seq + 1:
            raise ProtocolError(f"event sequence gap after checkpoint: expected {previous_event_seq + 1}, found {event_seq}")
        if event["preDigest"] != expected_core:
            raise ProtocolError(
                f"core digest discontinuity at event {event_seq}: expected {expected_core}, found {event['preDigest']}"
            )
        if event["preModelDigest"] != expected_model:
            raise ProtocolError(
                f"model digest discontinuity at event {event_seq}: expected {expected_model}, "
                f"found {event['preModelDigest']}"
            )

        model_changed = event["preModelDigest"] != event["postModelDigest"]
        core_changed = event["preDigest"] != event["postDigest"]
        if not model_changed:
            noops += 1
            if core_changed:
                canonical_changes += 1
        elif replay_status == "verified":
            if not event["success"]:
                replay_status = "blocked"
                replay_blocker = f"failed event {event_seq} partially changed model state"
            elif not event["portable"]:
                replay_status = "blocked"
                replay_blocker = f"event {event_seq} ({event['action'].get('type')}) is not portable"
            else:
                _apply_portable_action(model, event["action"], int(event.get("tick", 0)))
                actual_model = checksum(model)
                if actual_model != event["postModelDigest"]:
                    raise ProtocolError(
                        f"model replay divergence at event {event_seq}: expected {event['postModelDigest']}, "
                        f"calculated {actual_model}"
                    )
                portable_changes += 1

        expected_core = str(event["postDigest"])
        expected_model = str(event["postModelDigest"])
        previous_event_seq = event_seq

    if replay_status == "verified" and checksum(model) != expected_model:
        raise ProtocolError("final replay model digest does not match the recorded event stream")

    return {
        "session": session,
        "peer": selected.get("peer"),
        "anchor": anchor,
        "checkpointLocalSeq": selected_seq,
        "checkpoint": checkpoint,
        "eventsVerified": len(events),
        "lastEventSeq": previous_event_seq,
        "finalCoreDigest": expected_core,
        "finalModelDigest": expected_model,
        "modelReplay": {
            "status": replay_status,
            "blocker": replay_blocker,
            "portableChanges": portable_changes,
            "canonicalOnlyChanges": canonical_changes,
            "unchangedModelEvents": noops,
        },
    }


def render_markdown(analysis: Mapping[str, Any]) -> str:
    checkpoint = analysis["checkpoint"]
    replay = analysis["modelReplay"]
    cursor = checkpoint["eventCursor"]
    lines = [
        "# TPF2MP checkpoint and replay report",
        "",
        f"- Session: `{analysis.get('session')}`",
        f"- Peer: `{analysis.get('peer')}`",
        f"- Anchor: `{analysis.get('anchor')}` checkpoint at outbox sequence `{analysis.get('checkpointLocalSeq')}`",
        f"- Reason: `{checkpoint.get('reason')}`",
        f"- State/checkpoint format: `{checkpoint.get('stateVersion')}` / `{checkpoint.get('checkpointVersion')}`",
        f"- Last committed network event at anchor: `{cursor.get('lastCommitSeq')}`",
        "",
        "## Integrity",
        "",
        f"- Checkpoint digest: `{checkpoint.get('checkpointDigest')}`",
        f"- Convergence key: `{checkpoint.get('convergenceKey')}`",
        f"- Anchored model digest: `{checkpoint.get('modelDigest')}`",
        f"- Anchored canonical-registry digest: `{checkpoint.get('canonicalDigest')}`",
        f"- Anchored core digest: `{checkpoint.get('coreDigest')}`",
        f"- Anchored financial digest: `{checkpoint.get('financialDigest', 'legacy format: not captured')}`",
        f"- Anchored structural digest: `{checkpoint.get('structuralDigest', 'not captured yet')}`",
        "",
        "## Replay verification",
        "",
        f"- Event records verified after anchor: `{analysis.get('eventsVerified')}`",
        f"- Last local event: `{analysis.get('lastEventSeq')}`",
        f"- Hash-chain final core digest: `{analysis.get('finalCoreDigest')}`",
        f"- Recomputed model final digest: `{analysis.get('finalModelDigest')}`",
        f"- Model replay: `{replay.get('status')}`",
        f"- Portable model-changing events replayed: `{replay.get('portableChanges')}`",
        f"- Canonical/native-only state changes observed: `{replay.get('canonicalOnlyChanges')}`",
        f"- Events that left model state unchanged: `{replay.get('unchangedModelEvents')}`",
    ]
    if replay.get("blocker"):
        lines.append(f"- Replay blocker: {replay.get('blocker')}")
    lines.extend(
        [
            "",
            "## Boundary",
            "",
            "This report recomputes the deterministic, mod-authored economic state and verifies the recorded core hash chain. "
            "It does not recreate native map geometry. Canonical/native-only changes remain evidence for the separate "
            "physical world-replay gate.",
            "",
        ]
    )
    return "\n".join(lines)


def write_report(
    bridge_root: Path | str,
    session: str,
    output: Path | str,
    peer: str | None = None,
    anchor: str = "latest",
) -> dict[str, Any]:
    analysis = analyse_bridge(bridge_root, session, peer=peer, anchor=anchor)
    target = Path(output).expanduser().resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(render_markdown(analysis), encoding="utf-8")
    return analysis
