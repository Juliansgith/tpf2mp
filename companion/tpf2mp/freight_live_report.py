from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from .aboard_witness import verify_aboard_witness
from .live_evidence import scan_live_audit
from .protocol import ProtocolError


STAGES = ("ready", "service", "waiting", "aboard", "delivered", "settled")


def _array(value: Any) -> list[Any]:
    if isinstance(value, Mapping) and not value:
        return []
    return list(value) if isinstance(value, list) else []


def _counter_total(value: Any) -> int:
    if not isinstance(value, Mapping):
        return 0
    return sum(
        int(item) for item in value.values()
        if isinstance(item, int) and not isinstance(item, bool) and item > 0
    )


def _count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError(f"freight live evidence has an invalid {label}")
    return value


def _checkpoint_summary(
    payload: Mapping[str, Any], action: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    model = payload["model"]
    freight = model["freightIndustry"]
    economy = model.get("economy", {})
    synchronization = payload["vehicleSynchronization"]
    cargo = synchronization["cargoPresentation"]
    lines = [dict(item) for item in _array(cargo.get("lines"))]
    vehicles = [dict(item) for item in _array(cargo.get("vehicles"))]
    active = [item for item in lines if item.get("retired") is not True]
    witness = verify_aboard_witness(
        action or {}, "freight.milestone", lines, vehicles, reject_retired=True,
    )

    allocated = sum(_count(item.get("allocated"), "line allocation") for item in active)
    boarded_epoch = sum(
        _count(item.get("boardedThisEpoch"), "line epoch boarding") for item in active
    )
    boarded = sum(_count(item.get("boardedTotal"), "line boarded total") for item in lines)
    delivered = sum(
        _count(item.get("deliveredTotal"), "line delivered total") for item in lines
    )
    discarded = sum(
        _count(item.get("discardedTotal"), "line discarded total") for item in lines
    )
    aboard = sum(_count(item.get("aboard"), "vehicle cargo load") for item in vehicles)
    presentation_revenue = sum(
        _count(item.get("earnedRevenueCents"), "line cargo revenue") for item in lines
    )

    delivery_cursors = economy.get("deliveryCursors", {})
    cursor_delivered = cursor_revenue = 0
    if isinstance(delivery_cursors, Mapping):
        for line in active:
            cursor = delivery_cursors.get(line.get("lineCid"), {})
            if isinstance(cursor, Mapping):
                cursor_delivered += _count(
                    cursor.get("deliveredCargo", 0), "economy cargo delivery cursor"
                )
                cursor_revenue += _count(
                    cursor.get("earnedRevenueCents", 0), "economy cargo revenue cursor"
                )

    transported_total = _counter_total(freight.get("totalTransported"))
    freight_delivered = _counter_total(freight.get("totalDelivered"))
    waiting = max(0, allocated - boarded_epoch)
    stages = {
        "ready": freight.get("ready") is True,
        "service": len(active) > 0,
        "waiting": waiting > 0,
        "aboard": aboard > 0 or witness is not None,
        "delivered": (
            delivered > 0
            and freight_delivered > 0
            and presentation_revenue > 0
        ),
        "settled": (
            cursor_delivered > 0
            and cursor_revenue > 0
            and freight_delivered >= cursor_delivered
        ),
    }
    return {
        "boundarySeq": int(payload["eventCursor"]["lastCommitSeq"]),
        "reason": str(payload.get("reason", "")),
        "checkpointDigest": str(payload["checkpointDigest"]),
        "convergenceKey": str(payload["convergenceKey"]),
        "economyEpoch": int(economy.get("epoch", 0)),
        "cargoEpoch": int(cargo.get("epoch", 0)),
        "freightReady": freight.get("ready") is True,
        "activeCargoLines": len(active),
        "cargoVehicles": len(vehicles),
        "allocatedThisEpoch": allocated,
        "boardedThisEpoch": boarded_epoch,
        "waiting": waiting,
        "aboard": aboard,
        "witnessedAboard": int(witness["aboard"]) if witness else 0,
        "aboardWitness": witness,
        "boardedTotal": boarded,
        "deliveredTotal": delivered,
        "discardedTotal": discarded,
        "presentationRevenueCents": presentation_revenue,
        "freightTransportedTotal": transported_total,
        "freightDeliveredTotal": freight_delivered,
        "settledDeliveredTotal": cursor_delivered,
        "settledRevenueCents": cursor_revenue,
        "stages": stages,
    }


def analyse_freight_audit(
    path: Path | str,
    session: str | None = None,
    *,
    require_stage: str = "settled",
    require_observed_aboard: bool = False,
    required_peers: Sequence[str] = ("player1", "player2"),
) -> dict[str, Any]:
    if require_stage not in STAGES:
        raise ValueError(f"unknown freight evidence stage: {require_stage}")
    shared = scan_live_audit(
        path, session, required_peers=required_peers, label="freight evidence"
    )
    peer_roster = tuple(shared["requiredPeers"])
    completed: list[dict[str, Any]] = []
    for item in shared["completed"]:
        payload = item["payloads"][peer_roster[0]]
        summary = _checkpoint_summary(payload, item.get("action"))
        summary["peers"] = list(peer_roster)
        completed.append(summary)

    observed = {stage: any(row["stages"][stage] for row in completed) for stage in STAGES}
    maxima_fields = (
        "activeCargoLines", "cargoVehicles", "allocatedThisEpoch", "waiting", "aboard",
        "witnessedAboard",
        "boardedTotal", "deliveredTotal", "presentationRevenueCents",
        "freightTransportedTotal", "freightDeliveredTotal", "settledDeliveredTotal",
        "settledRevenueCents",
    )
    maxima = {
        field: max((int(row[field]) for row in completed), default=0)
        for field in maxima_fields
    }
    pending = shared["pending"]
    faults = shared["faults"]
    problems: list[str] = []
    if faults:
        problems.append("session contains a fault: " + ", ".join(faults))
    if pending["proposalPrepares"]:
        problems.append(f"pending proposal prepares: {pending['proposalPrepares']}")
    if pending["proposals"]:
        problems.append(f"pending physical proposals: {pending['proposals']}")
    if pending["operations"]:
        problems.append(f"pending physical operations: {pending['operations']}")
    if pending["checkpoints"]:
        problems.append(f"pending checkpoint barriers: {pending['checkpoints']}")
    if pending["divergentCommitAcknowledgements"]:
        problems.append("commit acknowledgement digests diverged")
    if not completed:
        problems.append("no completed current-format two-peer checkpoint exists")
    if not observed[require_stage]:
        problems.append(f"required freight stage was not observed: {require_stage}")
    if require_observed_aboard and not observed["aboard"]:
        problems.append("no converged checkpoint captured or witnessed cargo aboard")

    return {
        "schemaVersion": 1,
        "session": shared["session"],
        "audit": shared["audit"],
        "requiredPeers": list(peer_roster),
        "requiredStage": require_stage,
        "requireObservedAboard": bool(require_observed_aboard),
        "passed": not problems,
        "problems": problems,
        "faults": faults,
        "pending": pending,
        "observedStages": observed,
        "maxima": maxima,
        "completedCheckpointCount": len(completed),
        "completedCheckpoints": completed,
    }


def write_freight_live_report(
    path: Path | str,
    output: Path | str,
    session: str | None = None,
    *,
    require_stage: str = "settled",
    require_observed_aboard: bool = False,
) -> dict[str, Any]:
    report = analyse_freight_audit(
        path,
        session,
        require_stage=require_stage,
        require_observed_aboard=require_observed_aboard,
    )
    destination = Path(output).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return report


def configure_cli(commands: Any) -> None:
    command = commands.add_parser(
        "freight-live-report",
        help="verify an audit and require converged authoritative freight evidence",
    )
    command.add_argument("audit", type=Path)
    command.add_argument("--session")
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--require-stage", choices=STAGES, default="settled")
    command.add_argument(
        "--require-observed-aboard", action="store_true",
        help="also require a converged checkpoint with a verified cargo-aboard witness",
    )


def run_cli(args: Any, replay_validator: Any) -> int:
    replay_validator(args.audit, args.session)
    report = write_freight_live_report(
        args.audit,
        args.output,
        args.session,
        require_stage=args.require_stage,
        require_observed_aboard=args.require_observed_aboard,
    )
    print(f"freight_live_report={args.output.resolve()}")
    print(f"required_stage={report['requiredStage']}")
    print(
        "freight_maxima="
        f"waiting:{report['maxima']['waiting']},"
        f"aboard:{report['maxima']['aboard']},"
        f"delivered:{report['maxima']['deliveredTotal']},"
        f"revenue_cents:{report['maxima']['settledRevenueCents']}"
    )
    if report["passed"] is not True:
        raise ProtocolError("freight live acceptance failed: " + "; ".join(report["problems"]))
    return 0
