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
        for field in ("kind", "waitWeightPm", "transferSeconds", "demandResid"):
            if value.get(field) is not None:
                market[field] = value[field]
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
            "annualVehicleUpkeepCents": value.get("annualVehicleUpkeepCents"),
            "upkeepResid": value.get("upkeepResid"),
            "metadata": copy.deepcopy(value.get("metadata", {})),
        }
        if value.get("capacityResid") is not None:
            service["capacityResid"] = value["capacityResid"]
        if value.get("revenueMultiplierResid") is not None:
            service["revenueMultiplierResid"] = value["revenueMultiplierResid"]
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
        "towns": copy.deepcopy(economy.get("towns", {})),
        "services": services,
        "companyCosts": copy.deepcopy(economy.get("companyCosts", {})),
        "vehicleCosts": copy.deepcopy(economy.get("vehicleCosts", {})),
        "deliveryCursors": copy.deepcopy(economy.get("deliveryCursors", {})),
        "payoutResidCents": copy.deepcopy(economy.get("payoutResidCents", {})),
        "scheduler": copy.deepcopy(economy.get("scheduler", {})),
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
            "alphaUpPm": 350,
            "alphaDownPm": 250 if version == 2 else 500,
            "maxWaitSeconds": 1800,
            "transferSeconds": 480,
            "crowdThresholdPpm": 700_000,
            "economyDifficulty": "normal",
            "revenueMultiplierPpm": 1_000_000,
        },
        "markets": {},
        "towns": {},
        "services": {},
        "companyCosts": {},
        "vehicleCosts": {},
        "deliveryCursors": {},
        "payoutResidCents": {},
        "scheduler": {
            "schemaVersion": 2,
            "automatic": True,
            "epochSeconds": 300,
        },
        "lastResults": {
            "markets": {}, "companies": {}, "totalDemand": 0, "totalRevenueCents": 0,
            "totalGrossRevenueCents": 0, "totalVehicleUpkeepCents": 0,
            "totalInfrastructureUpkeepCents": 0, "totalOperatingCostCents": 0,
            "totalNetRevenueCents": 0,
        },
        "ledger": {
            "settledEpochs": {},
            "companies": {},
            "settlementCount": 0,
            "totalDemand": 0,
            "totalRevenueCents": 0,
            "totalGrossRevenueCents": 0,
            "totalVehicleUpkeepCents": 0,
            "totalInfrastructureUpkeepCents": 0,
            "totalOperatingCostCents": 0,
            "totalNetRevenueCents": 0,
        },
    }


def _verify_exp_tables() -> None:
    source = (PROJECT_ROOT / "tpf2_mp_1/res/scripts/tpf2_mp/economy_flow.lua").read_text(encoding="utf-8")
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
        for vehicle_cid, value in scenario.get("vehicleCosts", {}).items():
            economy["vehicleCosts"][vehicle_cid] = {
                "vehicleCid": vehicle_cid,
                "companyCid": str(value["companyCid"]),
                "annualVehicleUpkeepCents": int(value.get("annualVehicleUpkeepCents", 0)),
                "upkeepResid": int(value.get("upkeepResid", 0)),
            }
        for company_cid, value in scenario.get("companyCosts", {}).items():
            if isinstance(value, dict):
                capital = int(value.get("infrastructureCapitalCents", 0))
                residual = int(value.get("upkeepResid", 0))
            else:
                capital, residual = int(value), 0
            economy["companyCosts"][company_cid] = {
                "companyCid": company_cid,
                "infrastructureCapitalCents": capital,
                "annualInfrastructureUpkeepCents": capital // 10,
                "upkeepResid": residual,
            }
        scheduler = scenario.get("scheduler")
        if isinstance(scheduler, dict):
            start = max(0, int(scheduler.get("startGameTimeSeconds", 0)))
            period = checkpoint._integer(scheduler.get("epochSeconds"), 300, 60, 86400)
            economy["scheduler"] = {
                "schemaVersion": 2,
                "automatic": True,
                "epochSeconds": period,
                "startGameTimeSeconds": start,
                "lastBoundaryGameTimeSeconds": start,
                "nextBoundaryGameTimeSeconds": start + period,
            }
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
            boundary = economy.get("scheduler", {}).get("nextBoundaryGameTimeSeconds")
            actual = checkpoint._evaluate_all_v2(economy, boundary)
            _same(f"{label} epoch {index}", actual, expected)
            checkpoint._record_settlement(economy, actual)
            for company_cid in sorted(actual.get("companies", {})):
                company = actual["companies"][company_cid]
                checkpoint._wallet_delta_dollars(
                    economy,
                    company_cid,
                    int(company.get("netRevenueCents", company.get("revenueCents", 0))),
                )
        _same(f"{label} final state", _digest_view(economy), scenario["final"])
        model = {"economy": economy, "companies": scenario["companies"]}
        _same(f"{label} scoreboard", checkpoint._scoreboard(model), scenario["scoreboard"])
    print(f"PASS {len(vectors['scenarios'])} cross-language v2-v8 economy parity scenarios")


if __name__ == "__main__":
    main()
