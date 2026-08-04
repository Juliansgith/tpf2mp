from __future__ import annotations

import copy
import json
import re
import sys
from decimal import Decimal, ROUND_HALF_UP, localcontext
from pathlib import Path
from typing import Any


PROJECT_ROOT = Path(sys.argv[1]).resolve()
VECTOR_PATH = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(PROJECT_ROOT / "companion"))

from tpf2mp import checkpoint  # noqa: E402
from tpf2mp.protocol import canonical_json  # noqa: E402


def _digest_view(economy: dict[str, Any]) -> dict[str, Any]:
    markets: dict[str, Any] = {}
    for cid in sorted(economy.get("markets", {})):
        value = economy["markets"][cid]
        market = {
            "cid": value.get("cid"),
            "name": value.get("name"),
            "demand": value.get("demand"),
            "votCentsPerHour": value.get("votCentsPerHour"),
            "gcOutsideCents": value.get("gcOutsideCents"),
            "thetaCents": value.get("thetaCents"),
            "metadata": copy.deepcopy(value.get("metadata", {})),
        }
        if value.get("outsideWeight") is not None:
            market["outsideWeight"] = value["outsideWeight"]
        markets[cid] = market
    services: dict[str, Any] = {}
    for cid in sorted(economy.get("services", {})):
        value = economy["services"][cid]
        service = {
            "lineCid": value.get("lineCid"),
            "marketCid": value.get("marketCid"),
            "companyCid": value.get("companyCid"),
            "name": value.get("name"),
            "headwaySeconds": value.get("headwaySeconds"),
            "journeySeconds": value.get("journeySeconds"),
            "fareCents": value.get("fareCents"),
            "capacity": value.get("capacity"),
            "quality": value.get("quality"),
            "transfers": value.get("transfers"),
            "enabled": value.get("enabled"),
            "shareResid": value.get("shareResid"),
            "lagLoadPpm": value.get("lagLoadPpm"),
        }
        if value.get("sharePpm") is not None:
            service["sharePpm"] = value["sharePpm"]
        if "lastFareCents" in value:
            service["lastFareCents"] = value["lastFareCents"]
        services[cid] = service
    return {
        "version": economy.get("version"),
        "epoch": economy.get("epoch"),
        "params": copy.deepcopy(economy.get("params")),
        "markets": markets,
        "services": services,
        "lastResults": copy.deepcopy(economy.get("lastResults")),
        "ledger": copy.deepcopy(economy.get("ledger")),
    }


def _same(label: str, actual: Any, expected: Any) -> None:
    actual_json = canonical_json(actual)
    expected_json = canonical_json(expected)
    if actual_json != expected_json:
        limit = 1200
        raise AssertionError(
            f"{label} diverged\npython={actual_json[:limit]}\nlua={expected_json[:limit]}"
        )


def _apply_overrides(economy: dict[str, Any], overrides: dict[str, Any]) -> None:
    for line_cid, values in overrides.items():
        service = economy["services"][line_cid]
        if values.get("sharePpmNull"):
            service["sharePpm"] = None
        elif "sharePpm" in values:
            service["sharePpm"] = int(values["sharePpm"])
        if "shareResid" in values:
            service["shareResid"] = int(values["shareResid"])
        if "lagLoadPpm" in values:
            service["lagLoadPpm"] = int(values["lagLoadPpm"])


def _new_economy(version: int) -> dict[str, Any]:
    return {
        "version": version,
        "epoch": 0,
        "params": {
            "alphaUpPm": 80,
            "alphaDownPm": 250,
            "maxWaitSeconds": 1800,
            "transferSeconds": 480,
            "crowdThresholdPpm": 700_000,
        },
        "markets": {},
        "services": {},
        "lastResults": {"markets": {}, "companies": {}, "totalDemand": 0, "totalRevenueCents": 0},
        "ledger": {
            "settledEpochs": {},
            "companies": {},
            "settlementCount": 0,
            "totalDemand": 0,
            "totalRevenueCents": 0,
        },
    }


def _verify_exp_tables() -> None:
    source = (PROJECT_ROOT / "tpf2_mp_1/res/scripts/tpf2_mp/economy.lua").read_text(encoding="utf-8")
    match = re.search(r"local EXP_TABLE = \{(.*?)\n\}", source, re.DOTALL)
    if match is None:
        raise AssertionError("Lua pinned exponential table was not found")
    lua_table = [int(value) for value in re.findall(r"\d+", match.group(1))]
    with localcontext() as context:
        context.prec = 80
        expected = [
            int((Decimal(65536) * (-Decimal(index) / Decimal(10)).exp()).to_integral_value(
                rounding=ROUND_HALF_UP
            ))
            for index in range(81)
        ]
    if lua_table != checkpoint._EXP_TABLE:
        raise AssertionError("Lua and Python pinned exponential tables differ")
    if lua_table != expected:
        raise AssertionError("pinned exponential table differs from round(65536*exp(-k/10))")


def main() -> None:
    _verify_exp_tables()
    vectors = json.loads(VECTOR_PATH.read_text(encoding="utf-8"))
    if vectors.get("schema") != 1:
        raise AssertionError("unsupported economy parity vector schema")
    for scenario in vectors["scenarios"]:
        economy = _new_economy(int(scenario["initial"]["version"]))
        economy["params"].update(scenario.get("params", {}))
        for market in scenario["markets"]:
            checkpoint._upsert_market_v2(economy, market)
        for service in scenario["services"]:
            checkpoint._upsert_service_v2(economy, service)
        _apply_overrides(economy, scenario.get("overrides", {}))
        for service in scenario.get("reupserts", []):
            checkpoint._upsert_service_v2(economy, service)

        label = scenario["id"]
        _same(f"{label} initial state", _digest_view(economy), scenario["initial"])
        for index, expected in enumerate(scenario["results"], start=1):
            schedule = scenario.get("fareSchedule", [])
            if index <= len(schedule):
                for line_cid, fare_cents in schedule[index - 1].items():
                    economy["services"][line_cid]["fareCents"] = checkpoint._integer(
                        fare_cents,
                        economy["services"][line_cid]["fareCents"],
                        0,
                        100_000_000,
                    )
            actual = checkpoint._evaluate_all_v2(economy)
            _same(f"{label} epoch {index}", actual, expected)
            checkpoint._record_settlement(economy, actual)
        _same(f"{label} final state", _digest_view(economy), scenario["final"])
        model = {"economy": economy, "companies": scenario["companies"]}
        _same(f"{label} scoreboard", checkpoint._scoreboard(model), scenario["scoreboard"])
    print(f"PASS {len(vectors['scenarios'])} cross-language v2/v3 economy parity scenarios")


if __name__ == "__main__":
    main()
