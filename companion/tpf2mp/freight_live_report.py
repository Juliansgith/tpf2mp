from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from .bridge import AuditLog
from .checkpoint import CHECKPOINT_VERSION, verify_checkpoint
from .protocol import ProtocolError, validate_envelope


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


def _checkpoint_summary(payload: Mapping[str, Any]) -> dict[str, Any]:
    model = payload["model"]
    freight = model["freightIndustry"]
    economy = model.get("economy", {})
    synchronization = payload["vehicleSynchronization"]
    cargo = synchronization["cargoPresentation"]
    lines = [dict(item) for item in _array(cargo.get("lines"))]
    vehicles = [dict(item) for item in _array(cargo.get("vehicles"))]
    active = [item for item in lines if item.get("retired") is not True]

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
        "aboard": aboard > 0,
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
    peer_roster = tuple(dict.fromkeys(str(peer) for peer in required_peers))
    if not peer_roster:
        raise ValueError("at least one required peer is needed")

    audit_path = Path(path).expanduser().resolve()
    messages = list(AuditLog(audit_path).messages())
    if not messages:
        raise ProtocolError("freight evidence audit is empty")
    selected_session = session or str(messages[0].get("session", ""))
    if not selected_session:
        raise ProtocolError("freight evidence audit has no session")

    ordered_expected = 1
    commits: dict[int, dict[str, Any]] = {}
    acknowledgements: dict[int, set[str]] = {}
    checkpoints: dict[int, dict[str, dict[str, Any]]] = {}
    checkpoint_outcomes: dict[int, dict[str, Any]] = {}
    proposal_prepares: set[int] = set()
    proposal_prepare_outcomes: set[int] = set()
    proposals: set[int] = set()
    proposal_outcomes: dict[int, dict[str, Any]] = {}
    operations: set[int] = set()
    operation_outcomes: dict[int, dict[str, Any]] = {}
    expected_checkpoints: set[int] = set()
    faults: list[str] = []

    for message in messages:
        if str(message.get("session", "")) != selected_session:
            if session is None:
                raise ProtocolError("freight evidence audit mixes sessions")
            continue
        validate_envelope(message, selected_session)
        kind = message.get("kind")
        if kind in {"commit", "control"}:
            seq = int(message.get("seq", 0))
            if seq != ordered_expected:
                raise ProtocolError(
                    f"ordered message sequence gap: expected {ordered_expected}, found {seq}"
                )
            ordered_expected += 1
            action = message.get("payload", {}).get("action", {})
            action_type = action.get("type")
            commits[seq] = dict(message)
            if kind == "commit":
                if action_type == "proposal.prepare":
                    proposal_prepares.add(seq)
                elif action_type == "proposal.build":
                    proposals.add(seq)
                elif action_type == "operation.execute":
                    operations.add(seq)
                elif action_type in {
                    "match.initialise", "town.develop", "freight.industry_bootstrap",
                    "probe.structural", "economy.settle",
                }:
                    expected_checkpoints.add(seq)
                elif action_type == "network.sync_fault":
                    faults.append(str(action.get("errorCode") or "network-sync-fault"))
            elif action_type == "network.proposal_prepare_outcome":
                prepare_seq = int(action.get("prepareSeq", 0))
                if prepare_seq not in proposal_prepares:
                    raise ProtocolError(
                        "freight audit prepare outcome references an unknown prepare"
                    )
                if prepare_seq in proposal_prepare_outcomes:
                    raise ProtocolError("freight audit contains duplicate prepare outcomes")
                proposal_prepare_outcomes.add(prepare_seq)
            elif action_type == "network.proposal_outcome":
                commit_seq = int(action.get("commitSeq", 0))
                if commit_seq not in proposals:
                    raise ProtocolError(
                        "freight audit proposal outcome references an unknown proposal"
                    )
                if commit_seq in proposal_outcomes:
                    raise ProtocolError("freight audit contains duplicate proposal outcomes")
                proposal_outcomes[commit_seq] = dict(action)
                recoverable = action.get("recoverable") is True and action.get("success") is not True
                if action.get("success") is True or recoverable:
                    expected_checkpoints.add(seq)
                else:
                    faults.append(str(action.get("errorCode") or "proposal-consensus-failed"))
            elif action_type == "network.operation_outcome":
                commit_seq = int(action.get("commitSeq", 0))
                if commit_seq not in operations:
                    raise ProtocolError(
                        "freight audit operation outcome references an unknown operation"
                    )
                if commit_seq in operation_outcomes:
                    raise ProtocolError("freight audit contains duplicate operation outcomes")
                operation_outcomes[commit_seq] = dict(action)
                if action.get("success") is True:
                    expected_checkpoints.add(seq)
                else:
                    faults.append(str(action.get("errorCode") or "operation-consensus-failed"))
            elif action_type == "network.checkpoint_outcome":
                boundary = int(action.get("boundarySeq", 0))
                if boundary < 1 or boundary >= seq:
                    raise ProtocolError("freight checkpoint outcome has an invalid boundary")
                if boundary in checkpoint_outcomes:
                    raise ProtocolError("freight audit contains duplicate checkpoint outcomes")
                expected_checkpoints.add(boundary)
                checkpoint_outcomes[boundary] = dict(action)
                if action.get("success") is not True:
                    faults.append(str(action.get("errorCode") or "checkpoint-consensus-failed"))
        elif kind == "record" and message.get("record_type") == "ack":
            payload = message.get("payload", {})
            commit_seq = int(payload.get("commitSeq", 0))
            peer = str(message.get("peer", ""))
            if commit_seq > 0 and peer:
                acknowledgements.setdefault(commit_seq, set()).add(peer)
        elif kind == "record" and message.get("record_type") == "checkpoint":
            payload = verify_checkpoint(message.get("payload", {}))
            if int(payload.get("checkpointVersion", 0)) != CHECKPOINT_VERSION:
                raise ProtocolError(
                    f"freight evidence requires checkpoint format {CHECKPOINT_VERSION}"
                )
            boundary = int(payload["eventCursor"]["lastCommitSeq"])
            peer = str(message.get("peer", ""))
            prior = checkpoints.setdefault(boundary, {}).get(peer)
            if prior is not None and prior != payload:
                raise ProtocolError(
                    f"peer {peer} sent conflicting freight checkpoints at boundary {boundary}"
                )
            checkpoints[boundary][peer] = payload

    pending_prepares = sorted(proposal_prepares - proposal_prepare_outcomes)
    pending_proposals = sorted(proposals - set(proposal_outcomes))
    pending_operations = sorted(operations - set(operation_outcomes))
    pending_checkpoints = sorted(expected_checkpoints - set(checkpoint_outcomes))
    completed: list[dict[str, Any]] = []
    required_set = set(peer_roster)
    for boundary in sorted(expected_checkpoints):
        outcome = checkpoint_outcomes.get(boundary)
        if not outcome or outcome.get("success") is not True:
            continue
        outcome_peers = set(str(peer) for peer in outcome.get("peers", []))
        if not required_set <= outcome_peers:
            raise ProtocolError(
                f"checkpoint boundary {boundary} does not require every expected peer"
            )
        records = checkpoints.get(boundary, {})
        if not required_set <= set(records):
            raise ProtocolError(
                f"checkpoint boundary {boundary} lacks freight evidence from every peer"
            )
        selected = [records[peer] for peer in peer_roster]
        convergence = {item["convergenceKey"] for item in selected}
        if len(convergence) != 1 or next(iter(convergence)) != outcome.get("convergenceKey"):
            raise ProtocolError(f"checkpoint freight convergence mismatch at boundary {boundary}")
        if any(item.get("reason") != outcome.get("reason") for item in selected):
            raise ProtocolError(f"checkpoint freight reason mismatch at boundary {boundary}")
        for field in ("coreDigest", "modelDigest", "canonicalDigest", "financialDigest"):
            if any(item.get(field) != outcome.get(field) for item in selected):
                raise ProtocolError(
                    f"checkpoint freight {field} mismatch at boundary {boundary}"
                )
        freight_views = [item["model"]["freightIndustry"] for item in selected]
        cargo_views = [
            item["vehicleSynchronization"]["cargoPresentation"] for item in selected
        ]
        delivery_views = [item["model"].get("economy", {}).get("deliveryCursors", {})
                          for item in selected]
        if (
            any(view != freight_views[0] for view in freight_views[1:])
            or any(view != cargo_views[0] for view in cargo_views[1:])
            or any(view != delivery_views[0] for view in delivery_views[1:])
        ):
            raise ProtocolError(
                f"checkpoint freight ledgers differ at boundary {boundary}"
            )
        summary = _checkpoint_summary(selected[0])
        summary["peers"] = list(peer_roster)
        completed.append(summary)

    observed = {stage: any(row["stages"][stage] for row in completed) for stage in STAGES}
    maxima_fields = (
        "activeCargoLines", "cargoVehicles", "allocatedThisEpoch", "waiting", "aboard",
        "boardedTotal", "deliveredTotal", "presentationRevenueCents",
        "freightTransportedTotal", "freightDeliveredTotal", "settledDeliveredTotal",
        "settledRevenueCents",
    )
    maxima = {
        field: max((int(row[field]) for row in completed), default=0)
        for field in maxima_fields
    }
    incomplete_acks = {
        str(seq): sorted(required_set - acknowledgements.get(seq, set()))
        for seq, message in sorted(commits.items())
        if message.get("kind") == "commit"
        and not required_set <= acknowledgements.get(seq, set())
    }
    problems: list[str] = []
    if faults:
        problems.append("session contains a fault: " + ", ".join(sorted(set(faults))))
    if pending_prepares:
        problems.append(f"pending proposal prepares: {pending_prepares}")
    if pending_proposals:
        problems.append(f"pending physical proposals: {pending_proposals}")
    if pending_operations:
        problems.append(f"pending physical operations: {pending_operations}")
    if pending_checkpoints:
        problems.append(f"pending checkpoint barriers: {pending_checkpoints}")
    if not completed:
        problems.append("no completed current-format two-peer checkpoint exists")
    if not observed[require_stage]:
        problems.append(f"required freight stage was not observed: {require_stage}")
    if require_observed_aboard and not observed["aboard"]:
        problems.append("no converged checkpoint captured cargo aboard a vehicle")

    return {
        "schemaVersion": 1,
        "session": selected_session,
        "audit": str(audit_path),
        "requiredPeers": list(peer_roster),
        "requiredStage": require_stage,
        "requireObservedAboard": bool(require_observed_aboard),
        "passed": not problems,
        "problems": problems,
        "faults": sorted(set(faults)),
        "pending": {
            "proposalPrepares": pending_prepares,
            "proposals": pending_proposals,
            "operations": pending_operations,
            "checkpoints": pending_checkpoints,
            "incompleteCommitAcknowledgements": incomplete_acks,
        },
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
        help="also require a converged checkpoint captured while cargo was on a vehicle",
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
