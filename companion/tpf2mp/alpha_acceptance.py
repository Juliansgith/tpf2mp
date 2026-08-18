"""One fail-closed verdict for the restricted two-player alpha profile."""

from __future__ import annotations

import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from .live_evidence import scan_live_audit
from .protocol import ProtocolError
from .restore_plan import RESTORE_PLAN_VERSION, verify_restore_plan


PROFILES = ("core", "playable", "alpha")


def _mapping(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, Mapping) else {}


def _array(value: Any) -> list[Any]:
    if isinstance(value, Mapping) and not value:
        return []
    return list(value) if isinstance(value, list) else []


def _positive(value: Any) -> int:
    return int(value) if isinstance(value, int) and not isinstance(value, bool) \
        and value > 0 else 0


def _checkpoint_facts(payload: Mapping[str, Any]) -> dict[str, int]:
    model = _mapping(payload.get("model"))
    economy = _mapping(model.get("economy"))
    services = _mapping(economy.get("services"))
    synchronization = _mapping(payload.get("vehicleSynchronization"))
    vehicles = _array(synchronization.get("vehicles"))
    passenger = _mapping(synchronization.get("passengerPresentation"))
    cargo = _mapping(synchronization.get("cargoPresentation"))
    cargo_lines = [_mapping(item) for item in _array(cargo.get("lines"))]

    passenger_paths: set[str] = set()
    cargo_legs: dict[str, set[int]] = {}
    cargo_leg_counts: dict[str, int] = {}
    service_count = 0
    for line_cid, raw in services.items():
        service = _mapping(raw)
        if service.get("enabled") is not False:
            service_count += 1
        metadata = _mapping(service.get("metadata"))
        if _positive(metadata.get("networkMaxTransfers")):
            for route in _array(metadata.get("networkOriginRoutes")):
                route_value = _mapping(route)
                lines = _array(route_value.get("lines"))
                if len(lines) > 1:
                    passenger_paths.add(str(route_value.get("digest") or line_cid))
        if service.get("enabled") is not False \
                and metadata.get("freightContractSchema") == 2 \
                and _positive(metadata.get("freightLegCount")) > 1:
            digest = str(metadata.get("freightPathDigest") or "")
            if digest:
                cargo_legs.setdefault(digest, set()).add(
                    int(metadata.get("freightLegIndex", -1))
                )
                cargo_leg_counts[digest] = int(metadata["freightLegCount"])

    complete_cargo_paths = sum(
        legs == set(range(cargo_leg_counts[digest]))
        for digest, legs in cargo_legs.items()
    )
    arrived = sum(
        _positive(line.get("deliveredTotal")) for line in cargo_lines
        if line.get("transportSchema") == 2
        and line.get("destinationKind") == "station"
    )
    forwarded = sum(
        _positive(line.get("boardedTotal")) for line in cargo_lines
        if line.get("transportSchema") == 2
        and line.get("sourceKind") == "station"
    )
    transfer_stock = sum(
        _positive(amount)
        for stocks in _mapping(cargo.get("stationStock")).values()
        for amount in _mapping(stocks).values()
    )
    return {
        "boundarySeq": int(_mapping(payload.get("eventCursor")).get("lastCommitSeq", 0)),
        "economyEpoch": int(economy.get("epoch", 0)),
        "serviceCount": service_count,
        "vehicleCount": len(vehicles),
        "passengerVehicleCount": len(_array(passenger.get("vehicles"))),
        "cargoVehicleCount": len(_array(cargo.get("vehicles"))),
        "passengerTransferRoutes": len(passenger_paths),
        "cargoTransferRoutes": complete_cargo_paths,
        "cargoArrivedAtTransfer": arrived,
        "cargoForwardedFromTransfer": forwarded,
        "cargoTransferStock": transfer_stock,
    }


def _status_facts(statuses: Mapping[str, Any] | None) -> dict[str, Any]:
    values = _mapping(statuses)
    host, client = _mapping(values.get("player1")), _mapping(values.get("player2"))
    reconnect = _mapping(host.get("reconnect"))
    synchronized = bool(
        host.get("connected") is True
        and client.get("connected") is True
        and client.get("synchronized") is True
    )
    healthy = bool(
        synchronized
        and not host.get("sessionFault")
        and not client.get("sessionFault")
        and reconnect.get("active") is not True
        and not _mapping(reconnect.get("synchronizingPeers"))
        and _positive(reconnect.get("timeouts")) == 0
    )
    return {
        "provided": bool(host and client), "synchronized": synchronized,
        "healthy": healthy, "reconnectEvents": _positive(reconnect.get("events")),
        "reconnectRecoveries": _positive(reconnect.get("recoveries")),
        "reconnectTimeouts": _positive(reconnect.get("timeouts")),
    }


def evaluate_alpha_evidence(
    shared: Mapping[str, Any], *, profile: str = "alpha",
    statuses: Mapping[str, Any] | None = None,
    restore_plan: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    if profile not in PROFILES:
        raise ValueError(f"unknown alpha evidence profile: {profile}")
    completed = list(shared.get("completed", []))
    peer = str(list(shared.get("requiredPeers", ["player1"]))[0])
    facts = [
        _checkpoint_facts(_mapping(_mapping(item).get("payloads")).get(peer, {}))
        for item in completed
    ]
    maxima = {
        field: max((row[field] for row in facts), default=0)
        for field in (
            "economyEpoch", "serviceCount", "vehicleCount", "passengerVehicleCount",
            "cargoVehicleCount", "passengerTransferRoutes", "cargoTransferRoutes",
            "cargoArrivedAtTransfer", "cargoForwardedFromTransfer", "cargoTransferStock",
        )
    }
    pending = _mapping(shared.get("pending"))
    quiescent = not any(bool(value) for value in pending.values())
    actions = _mapping(shared.get("actionCounts"))
    physical = _mapping(shared.get("physicalOutcomes"))
    status = _status_facts(statuses)
    verified_plan, plan_error = None, None
    if restore_plan is not None:
        try:
            verified_plan = verify_restore_plan(restore_plan)
        except (ProtocolError, TypeError, ValueError) as exc:
            plan_error = str(exc)

    required = {
        "core": {"fault-free", "quiescent", "checkpoint-convergence"},
        "playable": {
            "fault-free", "quiescent", "checkpoint-convergence", "peer-synchronized",
            "construction-replay", "operation-replay", "economy-running", "vehicles-running",
        },
        "alpha": {
            "fault-free", "quiescent", "checkpoint-convergence", "peer-synchronized",
            "construction-replay", "operation-replay", "economy-running", "vehicles-running",
            "town-development", "passenger-transfer", "cargo-route", "cargo-transfer",
            "reconnect-recovery", "receipt-bound-restore",
        },
    }[profile]
    minimum_checkpoints = {"core": 1, "playable": 2, "alpha": 3}[profile]
    boundaries = {int(_mapping(item).get("boundarySeq", 0)) for item in completed}
    plan_boundary = int(verified_plan.get("boundarySeq", -1)) if verified_plan else -1
    plan_checkpoint = next(
        (_mapping(item) for item in completed
         if int(_mapping(item).get("boundarySeq", 0)) == plan_boundary), {}
    )
    plan_payload = _mapping(_mapping(plan_checkpoint.get("payloads")).get(peer))
    plan_ok = bool(
        verified_plan
        and verified_plan.get("version") == RESTORE_PLAN_VERSION
        and verified_plan.get("session") == shared.get("session")
        and set(verified_plan.get("requiredPeers", []))
            == set(shared.get("requiredPeers", []))
        and plan_boundary in boundaries
        and verified_plan.get("coreDigest") == plan_payload.get("coreDigest")
        and verified_plan.get("convergenceKey") == plan_payload.get("convergenceKey")
        and _positive(actions.get("recovery.save_receipt"))
            >= len(shared.get("requiredPeers", []))
    )
    definitions = (
        ("fault-free", not shared.get("faults"), "no authored or consensus session fault"),
        ("quiescent", quiescent, "no pending work or missing/divergent acknowledgements"),
        ("checkpoint-convergence", len(completed) >= minimum_checkpoints,
         f"{len(completed)}/{minimum_checkpoints} completed all-peer checkpoints"),
        ("peer-synchronized", status["healthy"], "both companions connected, synchronized, and healthy"),
        ("construction-replay", _positive(physical.get("proposalsSuccessful")) > 0,
         f"{_positive(physical.get('proposalsSuccessful'))} successful physical proposal(s)"),
        ("operation-replay", _positive(physical.get("operationsSuccessful")) > 0,
         f"{_positive(physical.get('operationsSuccessful'))} successful line/vehicle operation(s)"),
        ("economy-running", maxima["economyEpoch"] > 0 and maxima["serviceCount"] > 0,
         f"epoch {maxima['economyEpoch']}, {maxima['serviceCount']} service(s)"),
        ("vehicles-running", maxima["vehicleCount"] >= (2 if profile == "alpha" else 1),
         f"maximum {maxima['vehicleCount']} synchronized vehicle(s)"),
        ("town-development", _positive(actions.get("town.develop")) > 0,
         f"{_positive(actions.get('town.develop'))} ordered town-development batch(es)"),
        ("passenger-transfer", maxima["passengerTransferRoutes"] > 0,
         f"{maxima['passengerTransferRoutes']} multi-line passenger route(s)"),
        ("cargo-route", maxima["cargoTransferRoutes"] > 0,
         f"{maxima['cargoTransferRoutes']} complete multi-line cargo route(s)"),
        ("cargo-transfer", maxima["cargoArrivedAtTransfer"] > 0
         and maxima["cargoForwardedFromTransfer"] > 0,
         f"arrived {maxima['cargoArrivedAtTransfer']}, forwarded {maxima['cargoForwardedFromTransfer']}"),
        ("reconnect-recovery", status["reconnectRecoveries"] > 0
         and status["reconnectTimeouts"] == 0,
         f"{status['reconnectRecoveries']} recovered reconnect(s), {status['reconnectTimeouts']} timeout(s)"),
        ("receipt-bound-restore", plan_ok,
         "current verified restore plan" if plan_ok else plan_error or "no matching current restore plan"),
    )
    checks = [
        {"code": code, "required": code in required, "passed": bool(passed), "detail": detail}
        for code, passed, detail in definitions
    ]
    problems = [item["code"] + ": " + item["detail"] for item in checks
                if item["required"] and not item["passed"]]
    return {
        "schemaVersion": 1, "profile": profile, "session": shared.get("session"),
        "passed": not problems, "problems": problems, "checks": checks,
        "requiredPeers": list(shared.get("requiredPeers", [])),
        "completedCheckpointCount": len(completed), "maxima": maxima,
        "status": status, "pending": pending, "faults": list(shared.get("faults", [])),
        "restorePlanBoundary": verified_plan.get("boundarySeq") if verified_plan else None,
    }


def _read(path: Path | None) -> dict[str, Any] | None:
    if path is None:
        return None
    return json.loads(path.read_text(encoding="utf-8-sig"))


def configure_cli(commands: Any) -> None:
    command = commands.add_parser(
        "alpha-live-report", help="produce one fail-closed two-player alpha verdict"
    )
    command.add_argument("audit", type=Path)
    command.add_argument("--session")
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--profile", choices=PROFILES, default="alpha")
    command.add_argument("--host-status", type=Path)
    command.add_argument("--client-status", type=Path)
    command.add_argument("--restore-plan", type=Path)


def run_cli(args: Any) -> int:
    statuses = None
    if args.host_status or args.client_status:
        if not args.host_status or not args.client_status:
            raise ProtocolError("both --host-status and --client-status are required")
        statuses = {"player1": _read(args.host_status), "player2": _read(args.client_status)}
    report = evaluate_alpha_evidence(
        scan_live_audit(args.audit, args.session, label="alpha evidence"),
        profile=args.profile, statuses=statuses, restore_plan=_read(args.restore_plan),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"alpha_live_report={args.output.resolve()}")
    print(f"alpha_profile={report['profile']} passed={str(report['passed']).lower()}")
    for check in report["checks"]:
        marker = "PASS" if check["passed"] else "MISS"
        scope = "required" if check["required"] else "optional"
        print(f"{marker} [{scope}] {check['code']}: {check['detail']}")
    if not report["passed"]:
        raise ProtocolError("alpha live acceptance failed: " + "; ".join(report["problems"]))
    return 0
