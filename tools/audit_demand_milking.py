"""Search demand-v2 fare hysteresis for repeatable hike/harvest cycles.

This is intentionally a model-level adversarial tool, not a gameplay test.
It imports the companion's exact deterministic evaluator, begins from a
settled two-service market, and compares periodic one-epoch fare hikes plus a
recovery interval with the best constant fare found on the same grid.
"""

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path
from typing import Any, Iterable


PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "companion"))

from tpf2mp.checkpoint import (  # noqa: E402
    _evaluate_market_v2,
    _upsert_market_v2,
    _upsert_service_v2,
)


MARKET_CID = "market:audit"
TARGET_LINE = "line:a"


def new_economy(*, alpha_down: int, capacity: int) -> dict[str, Any]:
    economy: dict[str, Any] = {
        "version": 3,
        "epoch": 0,
        "params": {
            "alphaUpPm": 80,
            "alphaDownPm": alpha_down,
            "maxWaitSeconds": 1800,
            "transferSeconds": 480,
            "crowdThresholdPpm": 700_000,
        },
        "markets": {},
        "services": {},
    }
    _upsert_market_v2(
        economy,
        {
            "cid": MARKET_CID,
            "name": "Adversarial corridor",
            "demand": 1000,
            "votCentsPerHour": 450,
            "gcOutsideCents": 2500,
            "thetaCents": 200,
        },
    )
    _upsert_service_v2(
        economy,
        {
            "lineCid": TARGET_LINE,
            "marketCid": MARKET_CID,
            "companyCid": "company:1",
            "name": "Target",
            "headwaySeconds": 900,
            "journeySeconds": 2400,
            "fareCents": 1000,
            "capacity": capacity,
            "quality": 100,
        },
    )
    _upsert_service_v2(
        economy,
        {
            "lineCid": "line:b",
            "marketCid": MARKET_CID,
            "companyCid": "company:2",
            "name": "Rival",
            "headwaySeconds": 1100,
            "journeySeconds": 2200,
            "fareCents": 900,
            "capacity": capacity,
            "quality": 100,
        },
    )
    return economy


def settle(economy: dict[str, Any], fare_cents: int) -> tuple[int, int, int, int]:
    economy["services"][TARGET_LINE]["fareCents"] = fare_cents
    result = _evaluate_market_v2(economy, MARKET_CID)
    target = result["services"][TARGET_LINE]
    return (
        int(target["revenueCents"]),
        int(target["allocated"]),
        int(target["sharePpm"]),
        int(target["equilibriumPpm"]),
    )


def warmed_state(*, alpha_down: int, capacity: int, fare_cents: int = 1000) -> dict[str, Any]:
    economy = new_economy(alpha_down=alpha_down, capacity=capacity)
    for _ in range(600):
        settle(economy, fare_cents)
    return economy


def average_constant(start: dict[str, Any], fare_cents: int) -> float:
    economy = copy.deepcopy(start)
    for _ in range(600):
        settle(economy, fare_cents)
    revenue = 0
    for _ in range(200):
        revenue += settle(economy, fare_cents)[0]
    return revenue / 200


def average_cycle(
    start: dict[str, Any], hike_fare: int, recovery_epochs: int
) -> tuple[float, int, int]:
    economy = copy.deepcopy(start)
    schedule = [hike_fare] + [1000] * recovery_epochs
    for _ in range(80):
        for fare in schedule:
            settle(economy, fare)
    revenue = 0
    allocation = 0
    samples = 0
    for _ in range(40):
        for fare in schedule:
            epoch_revenue, epoch_allocation, _, _ = settle(economy, fare)
            revenue += epoch_revenue
            allocation += epoch_allocation
            samples += 1
    return revenue / samples, revenue, allocation


def constant_fares() -> Iterable[int]:
    yield from range(0, 5001, 50)
    yield from (7500, 10_000, 25_000, 100_000, 1_000_000, 100_000_000)


def hike_fares() -> Iterable[int]:
    yield from range(1100, 2001, 100)
    yield from (2500, 3000, 5000, 10_000, 100_000, 1_000_000, 100_000_000)


def audit(*, alpha_down: int, capacity: int) -> dict[str, Any]:
    start = warmed_state(alpha_down=alpha_down, capacity=capacity)
    baseline = average_constant(start, 1000)
    best_constant_fare = 0
    best_constant_revenue = -1.0
    for fare in constant_fares():
        revenue = average_constant(start, fare)
        if revenue > best_constant_revenue:
            best_constant_fare = fare
            best_constant_revenue = revenue

    best_cycle: dict[str, Any] | None = None
    recoveries = tuple(range(1, 41)) + (60, 80, 100)
    for fare in hike_fares():
        for recovery in recoveries:
            average, total, allocation = average_cycle(start, fare, recovery)
            candidate = {
                "hikeFareCents": fare,
                "recoveryEpochs": recovery,
                "averageRevenueCents": average,
                "measuredRevenueCents": total,
                "measuredAllocation": allocation,
            }
            if best_cycle is None or average > best_cycle["averageRevenueCents"]:
                best_cycle = candidate

    one_shot_state = copy.deepcopy(start)
    before = settle(one_shot_state, 1000)
    after = settle(one_shot_state, 100_000_000)
    return {
        "alphaDownPm": alpha_down,
        "capacity": capacity,
        "baselineRevenueCents": baseline,
        "bestConstantFareCents": best_constant_fare,
        "bestConstantRevenueCents": best_constant_revenue,
        "bestCycle": best_cycle,
        "cycleVsBestConstantRatio": (
            best_cycle["averageRevenueCents"] / best_constant_revenue
            if best_cycle and best_constant_revenue > 0
            else 0.0
        ),
        "oneShot": {
            "beforeRevenueCents": before[0],
            "beforeAllocated": before[1],
            "beforeSharePpm": before[2],
            "hikeRevenueCents": after[0],
            "hikeAllocated": after[1],
            "hikeSharePpm": after[2],
            "hikeEquilibriumPpm": after[3],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--alpha-down", type=int, default=250)
    parser.add_argument("--capacity", type=int, default=5000)
    args = parser.parse_args()
    result = audit(alpha_down=args.alpha_down, capacity=args.capacity)
    cycle = result["bestCycle"]
    shot = result["oneShot"]
    print(f"alphaDownPm={result['alphaDownPm']} capacity={result['capacity']}")
    print(f"baseline fare $10.00: {result['baselineRevenueCents']:.2f} cents/epoch")
    print(
        "best constant: "
        f"${result['bestConstantFareCents'] / 100:.2f} => "
        f"{result['bestConstantRevenueCents']:.2f} cents/epoch"
    )
    print(
        "best repeating hike/recover cycle: "
        f"one epoch at ${cycle['hikeFareCents'] / 100:.2f}, "
        f"{cycle['recoveryEpochs']} at $10.00 => "
        f"{cycle['averageRevenueCents']:.2f} cents/epoch "
        f"({result['cycleVsBestConstantRatio']:.3f}x best constant)"
    )
    print(
        "one-shot max-fare hike: "
        f"allocation {shot['beforeAllocated']}->{shot['hikeAllocated']}, "
        f"share {shot['beforeSharePpm']}->{shot['hikeSharePpm']} ppm, "
        f"equilibrium {shot['hikeEquilibriumPpm']} ppm, "
        f"revenue {shot['beforeRevenueCents']}->{shot['hikeRevenueCents']} cents"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
