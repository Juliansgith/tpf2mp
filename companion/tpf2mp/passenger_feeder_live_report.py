from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from .aboard_witness import verify_aboard_witness
from .live_evidence import scan_live_audit
from .protocol import ProtocolError


STAGES = (
    "ready",
    "local-service",
    "corridor-service",
    "benefit",
    "aboard",
    "delivered",
    "settled",
)
CARRIERS = ("ANY", "ROAD", "TRAM")


def _array(value: Any) -> list[Any]:
    if isinstance(value, Mapping) and not value:
        return []
    return list(value) if isinstance(value, list) else []


def _mapping(value: Any) -> dict[str, Any]:
    return dict(value) if isinstance(value, Mapping) else {}


def _count(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ProtocolError(f"passenger-feeder evidence has an invalid {label}")
    return value


def _service_result(economy: Mapping[str, Any], service: Mapping[str, Any]) -> dict[str, Any]:
    market = _mapping(
        _mapping(economy.get("lastResults")).get("markets")
    ).get(service.get("marketCid"))
    return _mapping(_mapping(_mapping(market).get("services")).get(service.get("lineCid")))


def _service_rows(payload: Mapping[str, Any]) -> list[dict[str, Any]]:
    model = payload["model"]
    economy = _mapping(model.get("economy"))
    markets = _mapping(economy.get("markets"))
    services = _mapping(economy.get("services"))
    presentation = payload["vehicleSynchronization"]["passengerPresentation"]
    lines = {
        item.get("lineCid"): dict(item)
        for value in _array(presentation.get("lines"))
        if isinstance(value, Mapping)
        for item in (dict(value),)
        if isinstance(item.get("lineCid"), str)
    }
    vehicles: dict[str, list[dict[str, Any]]] = {}
    for value in _array(presentation.get("vehicles")):
        if not isinstance(value, Mapping):
            continue
        item = dict(value)
        line_cid = item.get("lineCid")
        if isinstance(line_cid, str):
            vehicles.setdefault(line_cid, []).append(item)

    rows: list[dict[str, Any]] = []
    for key in sorted(services):
        service = _mapping(services[key])
        line_cid = service.get("lineCid")
        if not isinstance(line_cid, str) or line_cid != key:
            continue
        market = _mapping(markets.get(service.get("marketCid")))
        if market.get("kind", "passenger") == "cargo":
            continue
        metadata = _mapping(service.get("metadata"))
        market_metadata = _mapping(market.get("metadata"))
        station_groups = [
            str(item) for item in _array(metadata.get("stationGroupCids"))
            if isinstance(item, str)
        ]
        endpoint_towns = [
            str(item) for item in _array(metadata.get("endpointTownCids"))
            if isinstance(item, str)
        ]
        carrier = str(metadata.get("carrier") or "UNKNOWN").upper()
        scope = str(
            metadata.get("marketScope")
            or market_metadata.get("marketScope")
            or "unknown"
        ).lower()
        result = _service_result(economy, service)
        factors = _mapping(result.get("factors"))
        line = lines.get(line_cid)
        line_vehicles = vehicles.get(line_cid, [])
        cursor = _mapping(_mapping(economy.get("deliveryCursors")).get(line_cid))
        rows.append({
            "lineCid": line_cid,
            "companyCid": str(service.get("companyCid") or ""),
            "marketCid": str(service.get("marketCid") or ""),
            "carrier": carrier,
            "marketScope": scope,
            "factsSource": str(metadata.get("factsSource") or "unknown"),
            "stationGroupCids": station_groups,
            "distinctStationGroups": len(set(station_groups)),
            "endpointTownCids": endpoint_towns,
            "marketTownA": market_metadata.get("townA"),
            "marketTownB": market_metadata.get("townB"),
            "registeredVehicleCount": _count(
                metadata.get("vehicleCount", 0), "registered vehicle count"
            ),
            "passengerVehicleCount": len(line_vehicles),
            "capacity": _count(service.get("capacity", 0), "service capacity"),
            "enabled": service.get("enabled") is not False,
            "presentationLine": line is not None,
            "waiting": _count(line.get("waitingAToB", 0), "line waiting A to B")
                + _count(line.get("waitingBToA", 0), "line waiting B to A")
                if line else 0,
            "aboard": sum(
                _count(item.get("aboard", 0), "passenger vehicle load")
                for item in line_vehicles
            ),
            "boardedTotal": _count(line.get("boardedTotal", 0), "line boarded total")
                if line else 0,
            "deliveredPassengers": _count(
                line.get("alightedTotal", 0), "line alighted total"
            ) if line else 0,
            "presentationRevenueCents": _count(
                line.get("earnedRevenueCents", 0), "line passenger revenue"
            ) if line else 0,
            "settledPassengers": _count(
                cursor.get("deliveredPassengers", 0), "passenger delivery cursor"
            ),
            "settledRevenueCents": _count(
                cursor.get("earnedRevenueCents", 0), "passenger revenue cursor"
            ),
            "allocated": _count(result.get("allocated", 0), "service allocation"),
            "resultDelivered": _count(result.get("delivered", 0), "service delivery"),
            "feederAccessCents": _count(
                factors.get("feederAccessCents", 0), "feeder access benefit"
            ),
            "feederAccessEndpoints": _count(
                factors.get("feederAccessEndpoints", 0), "feeder access endpoints"
            ),
        })
    return rows


def _operational(row: Mapping[str, Any]) -> bool:
    return (
        row.get("enabled") is True
        and row.get("presentationLine") is True
        and int(row.get("distinctStationGroups", 0)) >= 2
        and int(row.get("registeredVehicleCount", 0)) > 0
        and int(row.get("passengerVehicleCount", 0)) > 0
        and int(row.get("capacity", 0)) > 0
    )


def _local(row: Mapping[str, Any], carrier: str) -> bool:
    endpoints = row.get("endpointTownCids", [])
    return (
        _operational(row)
        and row.get("marketScope") == "local"
        and row.get("carrier") in {"ROAD", "TRAM"}
        and (carrier == "ANY" or row.get("carrier") == carrier)
        and len(endpoints) == 2
        and endpoints[0] == endpoints[1]
        and row.get("marketTownA") == endpoints[0]
        and row.get("marketTownB") == endpoints[0]
    )


def _corridor(row: Mapping[str, Any]) -> bool:
    endpoints = row.get("endpointTownCids", [])
    return (
        _operational(row)
        and row.get("marketScope") == "corridor"
        and len(endpoints) == 2
        and endpoints[0] != endpoints[1]
        and row.get("marketTownA") in endpoints
        and row.get("marketTownB") in endpoints
        and row.get("marketTownA") != row.get("marketTownB")
    )


def _checkpoint_summary(
    payload: Mapping[str, Any], carrier: str,
    action: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    economy = _mapping(payload["model"].get("economy"))
    passenger = payload["vehicleSynchronization"]["passengerPresentation"]
    rows = _service_rows(payload)
    local = [row for row in rows if _local(row, carrier)]
    corridor = [row for row in rows if _corridor(row)]
    links: list[dict[str, Any]] = []
    for feeder in local:
        town_cid = feeder["endpointTownCids"][0]
        for mainline in corridor:
            if (
                feeder["companyCid"] == mainline["companyCid"]
                and town_cid in mainline["endpointTownCids"]
                and mainline["feederAccessCents"] > 0
                and mainline["feederAccessEndpoints"] > 0
            ):
                links.append({
                    "localLineCid": feeder["lineCid"],
                    "corridorLineCid": mainline["lineCid"],
                    "companyCid": feeder["companyCid"],
                    "townCid": town_cid,
                    "feederAccessCents": mainline["feederAccessCents"],
                    "feederAccessEndpoints": mainline["feederAccessEndpoints"],
                })

    linked_line_cids = {link["localLineCid"] for link in links}
    linked_local = [row for row in local if row["lineCid"] in linked_line_cids]
    presentation = payload["vehicleSynchronization"]["passengerPresentation"]
    witness = verify_aboard_witness(
        action or {}, "passenger.milestone",
        [dict(item) for item in _array(presentation.get("lines"))],
        [dict(item) for item in _array(presentation.get("vehicles"))],
        allowed_line_cids=linked_line_cids,
    )
    completed_local = [
        row for row in linked_local
        if row["deliveredPassengers"] > 0
        and row["presentationRevenueCents"] > 0
    ]
    settled_local = [
        row for row in completed_local
        if row["settledPassengers"] > 0
        and row["settledRevenueCents"] > 0
        and row["settledPassengers"] <= row["deliveredPassengers"]
        and row["settledRevenueCents"] <= row["presentationRevenueCents"]
    ]
    local_aboard = sum(row["aboard"] for row in linked_local)
    local_delivered = sum(row["deliveredPassengers"] for row in linked_local)
    local_revenue = sum(row["presentationRevenueCents"] for row in linked_local)
    settled_passengers = sum(row["settledPassengers"] for row in linked_local)
    settled_revenue = sum(row["settledRevenueCents"] for row in linked_local)
    ready = int(economy.get("version", 0)) >= 8 \
        and int(passenger.get("schemaVersion", 0)) >= 2
    local_service = ready and bool(local)
    corridor_service = local_service and bool(corridor)
    benefit = corridor_service and bool(links)
    stages = {
        "ready": ready,
        "local-service": local_service,
        "corridor-service": corridor_service,
        "benefit": benefit,
        "aboard": benefit and (local_aboard > 0 or witness is not None),
        "delivered": benefit and bool(completed_local),
        "settled": benefit and bool(settled_local),
    }
    return {
        "boundarySeq": int(payload["eventCursor"]["lastCommitSeq"]),
        "reason": str(payload.get("reason", "")),
        "checkpointDigest": str(payload["checkpointDigest"]),
        "convergenceKey": str(payload["convergenceKey"]),
        "economyVersion": int(economy.get("version", 0)),
        "economyEpoch": int(economy.get("epoch", 0)),
        "passengerSchemaVersion": int(passenger.get("schemaVersion", 0)),
        "passengerEpoch": int(passenger.get("epoch", 0)),
        "localServices": local,
        "corridorServices": corridor,
        "links": links,
        "linkedLocalLineCids": sorted(linked_line_cids),
        "linkedCompletedLinesSettled": len(settled_local) == len(completed_local)
            if completed_local else True,
        "localAboard": local_aboard,
        "localWitnessedAboard": int(witness["aboard"]) if witness else 0,
        "aboardWitness": witness,
        "localDeliveredPassengers": local_delivered,
        "localPresentationRevenueCents": local_revenue,
        "localSettledPassengers": settled_passengers,
        "localSettledRevenueCents": settled_revenue,
        "stages": stages,
    }


def analyse_passenger_feeder_audit(
    path: Path | str,
    session: str | None = None,
    *,
    require_stage: str = "settled",
    carrier: str = "ANY",
    require_observed_aboard: bool = False,
    required_peers: Sequence[str] = ("player1", "player2"),
) -> dict[str, Any]:
    carrier = str(carrier).upper()
    if require_stage not in STAGES:
        raise ValueError(f"unknown passenger-feeder evidence stage: {require_stage}")
    if carrier not in CARRIERS:
        raise ValueError(f"unknown passenger-feeder carrier: {carrier}")
    shared = scan_live_audit(
        path,
        session,
        required_peers=required_peers,
        label="passenger-feeder evidence",
    )
    peer_roster = tuple(shared["requiredPeers"])
    completed: list[dict[str, Any]] = []
    for item in shared["completed"]:
        payload = item["payloads"][peer_roster[0]]
        summary = _checkpoint_summary(payload, carrier, item.get("action"))
        summary["peers"] = list(peer_roster)
        completed.append(summary)

    observed = {stage: any(row["stages"][stage] for row in completed) for stage in STAGES}
    maxima_fields = (
        "localAboard",
        "localWitnessedAboard",
        "localDeliveredPassengers",
        "localPresentationRevenueCents",
        "localSettledPassengers",
        "localSettledRevenueCents",
    )
    maxima = {
        field: max((int(row[field]) for row in completed), default=0)
        for field in maxima_fields
    }
    maxima.update({
        "localServices": max((len(row["localServices"]) for row in completed), default=0),
        "corridorServices": max(
            (len(row["corridorServices"]) for row in completed), default=0
        ),
        "feederLinks": max((len(row["links"]) for row in completed), default=0),
        "feederAccessCents": max(
            (
                link["feederAccessCents"]
                for row in completed
                for link in row["links"]
            ),
            default=0,
        ),
        "feederAccessEndpoints": max(
            (
                link["feederAccessEndpoints"]
                for row in completed
                for link in row["links"]
            ),
            default=0,
        ),
    })

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
        problems.append(
            f"required passenger-feeder stage was not observed: {require_stage}"
        )
    if require_observed_aboard and not observed["aboard"]:
        problems.append(
            "no converged checkpoint captured or witnessed local feeder passengers aboard"
        )

    return {
        "schemaVersion": 1,
        "session": shared["session"],
        "audit": shared["audit"],
        "requiredPeers": list(peer_roster),
        "requiredStage": require_stage,
        "carrier": carrier,
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


def write_passenger_feeder_live_report(
    path: Path | str,
    output: Path | str,
    session: str | None = None,
    *,
    require_stage: str = "settled",
    carrier: str = "ANY",
    require_observed_aboard: bool = False,
) -> dict[str, Any]:
    report = analyse_passenger_feeder_audit(
        path,
        session,
        require_stage=require_stage,
        carrier=carrier,
        require_observed_aboard=require_observed_aboard,
    )
    destination = Path(output).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return report


def configure_cli(commands: Any) -> None:
    command = commands.add_parser(
        "passenger-feeder-live-report",
        help="verify converged local passenger feeder and corridor evidence",
    )
    command.add_argument("audit", type=Path)
    command.add_argument("--session")
    command.add_argument("--output", type=Path, required=True)
    command.add_argument("--require-stage", choices=STAGES, default="settled")
    command.add_argument("--carrier", choices=CARRIERS, default="ANY")
    command.add_argument(
        "--require-observed-aboard",
        action="store_true",
        help="also require a converged checkpoint while the feeder carried passengers",
    )


def run_cli(args: Any, replay_validator: Any) -> int:
    replay_validator(args.audit, args.session)
    report = write_passenger_feeder_live_report(
        args.audit,
        args.output,
        args.session,
        require_stage=args.require_stage,
        carrier=args.carrier,
        require_observed_aboard=args.require_observed_aboard,
    )
    print(f"passenger_feeder_live_report={args.output.resolve()}")
    print(f"required_stage={report['requiredStage']}")
    print(
        "passenger_feeder_maxima="
        f"local_services:{report['maxima']['localServices']},"
        f"corridors:{report['maxima']['corridorServices']},"
        f"links:{report['maxima']['feederLinks']},"
        f"aboard:{report['maxima']['localAboard']},"
        f"delivered:{report['maxima']['localDeliveredPassengers']},"
        f"settled_revenue_cents:{report['maxima']['localSettledRevenueCents']}"
    )
    if report["passed"] is not True:
        raise ProtocolError(
            "passenger-feeder live acceptance failed: " + "; ".join(report["problems"])
        )
    return 0
