"""Run the exact economy-v8 evaluator against an era calibration matrix.

The runtime never reads this file and never hardcodes a vehicle name.  This is
an offline balance instrument: replace or extend the JSON rows with facts read
from any vanilla or modded consist, then compare throughput, net income and
capital payback under the same corridor assumptions and difficulty presets.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import sys
from pathlib import Path
from typing import Any, Mapping


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "companion"))

from tpf2mp.checkpoint import (  # noqa: E402
    _evaluate_all_v2,
    _upsert_market_v2,
    _upsert_service_v2,
)


DIFFICULTIES = {
    "hard": 600_000,
    "normal": 1_000_000,
    "easy": 1_500_000,
    "relaxed": 2_000_000,
}


def _positive_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def load_matrix(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError("era matrix must be a schemaVersion 1 object")
    corridor = value.get("corridor")
    consists = value.get("consists")
    if not isinstance(corridor, dict) or not isinstance(consists, list) or not consists:
        raise ValueError("era matrix requires corridor and non-empty consists")
    _positive_int(corridor.get("straightLineMeters"), "straightLineMeters")
    _positive_int(corridor.get("stationCount"), "stationCount")
    for index, row in enumerate(consists, 1):
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            raise ValueError(f"consist {index} requires a name")
        for field in (
            "year", "seats", "topSpeedKmh", "purchasePriceDollars",
            "annualUpkeepDollars", "townSizeEach",
        ):
            _positive_int(row.get(field), f"consist {index} {field}")
    return value


def service_facts(corridor: Mapping[str, Any], consist: Mapping[str, Any]) -> dict[str, int]:
    """Mirror corridor_binding.computedServiceFacts for one consist."""

    straight = int(corridor["straightLineMeters"])
    route = math.floor(straight * 125 / 100)
    station_count = int(corridor["stationCount"])
    vehicles = int(consist.get("vehicleCount", 1))
    cruise_ms = int(consist["topSpeedKmh"]) * 1000 / 3600 * 70 / 100
    journey = max(60, math.floor(route / cruise_ms) + 45 * station_count)
    cycle = journey * 2 + 240
    headway = max(60, math.floor(cycle / max(1, vehicles)))
    departures = max(1, math.floor(3600 / headway))
    return {
        "distanceMeters": route,
        "journeySeconds": journey,
        "cycleSeconds": cycle,
        "headwaySeconds": headway,
        "departuresPerHourPerDirection": departures,
        "capacity": int(consist["seats"]) * departures * 2 if vehicles > 0 else 0,
    }


def _new_economy(
    difficulty: str, corridor: Mapping[str, Any], consist: Mapping[str, Any]
) -> tuple[dict[str, Any], dict[str, int]]:
    facts = service_facts(corridor, consist)
    town_size = int(consist["townSizeEach"])
    distance_km = max(1, facts["distanceMeters"] // 1000)
    demand = max(50, min(100_000, town_size * town_size // (25 * distance_km)))
    economy: dict[str, Any] = {
        "version": 8,
        "epoch": 0,
        "params": {
            "alphaUpPm": 350,
            "alphaDownPm": 500,
            "maxWaitSeconds": 1800,
            "transferSeconds": 480,
            "crowdThresholdPpm": 700_000,
            "economyDifficulty": difficulty,
            "revenueMultiplierPpm": DIFFICULTIES[difficulty],
        },
        "markets": {},
        "towns": {},
        "services": {},
        "companyCosts": {},
        "vehicleCosts": {},
        "deliveryCursors": {},
        "payoutResidCents": {},
        "lastResults": {},
        "ledger": {},
    }
    _upsert_market_v2(economy, {
        "cid": "market:era-audit",
        "name": "Era audit corridor",
        "kind": "passenger",
        "demand": demand,
        "gcOutsideCents": 100_000_000,
        "thetaCents": 200,
        "metadata": {
            "townA": "town:era:a",
            "townB": "town:era:b",
            "townSizeA": town_size,
            "townSizeB": town_size,
            "corridorMeters": facts["distanceMeters"],
        },
    })
    fare_cents = 500 + 150 * distance_km
    _upsert_service_v2(economy, {
        "lineCid": "line:era-audit",
        "marketCid": "market:era-audit",
        "companyCid": "company:1",
        "name": str(consist["name"]),
        "headwaySeconds": facts["headwaySeconds"],
        "journeySeconds": facts["journeySeconds"],
        "fareCents": fare_cents,
        "capacity": facts["capacity"],
        "quality": 120,
        "transfers": 0,
        "annualVehicleUpkeepCents": int(consist["annualUpkeepDollars"]) * 100,
        "metadata": {"distanceMeters": facts["distanceMeters"]},
    })
    return economy, facts


def evaluate_row(
    difficulty: str, corridor: Mapping[str, Any], consist: Mapping[str, Any]
) -> dict[str, Any]:
    economy, facts = _new_economy(difficulty, corridor, consist)
    totals = {"delivered": 0, "grossCents": 0, "upkeepCents": 0, "netCents": 0}
    for _ in range(12):
        result = _evaluate_all_v2(economy)
        service = result["markets"]["market:era-audit"]["services"]["line:era-audit"]
        totals["delivered"] += int(service["delivered"])
        totals["grossCents"] += int(service["grossRevenueCents"])
        totals["upkeepCents"] += int(service["vehicleUpkeepCents"])
        totals["netCents"] += int(service["netRevenueCents"])
    net_dollars = totals["netCents"] / 100
    purchase = int(consist["purchasePriceDollars"])
    return {
        "year": int(consist["year"]),
        "name": str(consist["name"]),
        "difficulty": difficulty,
        **facts,
        **totals,
        "purchasePriceDollars": purchase,
        "paybackHours": purchase / net_dollars if net_dollars > 0 else None,
        "endingTownSize": int(economy["towns"]["town:era:a"]["size"]),
        "endingHourlyDemand": int(economy["markets"]["market:era-audit"]["demand"]),
    }


def audit(matrix: Mapping[str, Any], difficulty: str) -> list[dict[str, Any]]:
    rows = [evaluate_row(difficulty, matrix["corridor"], row) for row in matrix["consists"]]
    rows.sort(key=lambda row: (row["year"], row["name"]))
    return rows


def assert_envelope(matrix: Mapping[str, Any]) -> None:
    by_mode = {key: audit(matrix, key) for key in DIFFICULTIES}
    normal = by_mode["normal"]
    if any(row["netCents"] <= 0 for row in normal):
        raise AssertionError("reference era matrix contains a loss-making Normal service")
    if any(right["capacity"] <= left["capacity"] for left, right in zip(normal, normal[1:])):
        raise AssertionError("newer reference tiers must add real hourly capacity")
    if any(right["netCents"] <= left["netCents"] for left, right in zip(normal, normal[1:])):
        raise AssertionError("newer reference tiers must create a positive upgrade incentive")
    for index in range(len(normal)):
        gross = [by_mode[key][index]["grossCents"] for key in DIFFICULTIES]
        if not gross[0] < gross[1] < gross[2] < gross[3]:
            raise AssertionError("difficulty presets do not order gross revenue monotonically")
        signature = {
            (rows[index]["delivered"], rows[index]["capacity"], rows[index]["upkeepCents"])
            for rows in by_mode.values()
        }
        if len(signature) != 1:
            raise AssertionError("difficulty changed demand, capacity or upkeep")


def _money(cents: int) -> str:
    return f"${cents / 100:,.0f}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--facts", type=Path,
        default=PROJECT / "investigation" / "economy_era_reference.json",
        help="schemaVersion 1 era/consist matrix",
    )
    parser.add_argument("--difficulty", choices=tuple(DIFFICULTIES), default="normal")
    parser.add_argument("--check", action="store_true", help="enforce the calibration envelope")
    parser.add_argument("--json", action="store_true", help="emit machine-readable rows")
    args = parser.parse_args()
    matrix = load_matrix(args.facts)
    if args.check:
        assert_envelope(matrix)
    rows = audit(matrix, args.difficulty)
    if args.json:
        print(json.dumps(rows, indent=2, sort_keys=True))
    else:
        print("year  consist                    cap/h  pax/h  gross/h       upkeep/h      net/h          payback")
        for row in rows:
            payback = "never" if row["paybackHours"] is None else f"{row['paybackHours']:.2f}h"
            print(
                f"{row['year']:4d}  {row['name'][:25]:25s} "
                f"{row['capacity']:6d} {row['delivered']:6d} "
                f"{_money(row['grossCents']):13s} {_money(row['upkeepCents']):13s} "
                f"{_money(row['netCents']):13s} {payback:>8s}"
            )
    if args.check:
        print("PASS economy-v8 era envelope and all four difficulty invariants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
