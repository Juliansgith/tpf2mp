from __future__ import annotations

from pathlib import Path
from typing import Any

from .audit_consensus import verify_physical_consensus
from .bridge import AuditLog
from .checkpoint import verify_checkpoint, verify_event_record
from .completion_validation import operation_completion_payload
from .fault_recovery_audit import verified_fault_recoveries
from .live_evidence import CHECKPOINTED_COMMIT_TYPES
from .network import CommitHost
from .protocol import ProtocolError, validate_envelope


def replay(
    path: Path,
    session: str | None,
    require_settled: bool = False,
) -> int:
    commits = controls = records = 0
    expected = 1
    commit_sequences: list[int] = []
    peers: set[str] = set()
    acknowledgements: dict[int, dict[str, str]] = {}
    proposal_commits: dict[int, dict[str, Any]] = {}
    proposal_completions: dict[int, dict[str, dict[str, Any]]] = {}
    proposal_outcomes: dict[int, dict[str, Any]] = {}
    operation_commits: dict[int, dict[str, Any]] = {}
    operation_completions: dict[int, dict[str, dict[str, Any]]] = {}
    operation_outcomes: dict[int, dict[str, Any]] = {}
    checkpoint_records: dict[int, dict[str, dict[str, Any]]] = {}
    checkpoint_outcomes: dict[int, dict[str, Any]] = {}
    checkpoint_expected_boundaries: set[int] = set()
    checkpoint_chains: dict[str, dict[str, Any]] = {}
    ordered: dict[int, dict[str, Any]] = {}
    checkpoints = event_records = replayed_events = 0
    selected_session = session
    for message in AuditLog(path).messages():
        message_session = str(message.get("session", ""))
        if selected_session is None:
            selected_session = message_session
        if message_session != selected_session:
            if session is None:
                raise ProtocolError("audit mixes sessions")
            continue
        validate_envelope(message, selected_session)
        if message.get("kind") in {"commit", "control"}:
            seq = int(message["seq"])
            if seq != expected:
                raise ProtocolError(
                    f"ordered message sequence gap: expected {expected}, found {seq}"
                )
            expected += 1
            ordered[seq] = dict(message)
            action = message.get("payload", {}).get("action", {})
            if message.get("kind") == "commit":
                commits += 1
                commit_sequences.append(seq)
                peers.add(str(message.get("origin_peer")))
                if action.get("type") == "proposal.build":
                    proposal_commits[seq] = {
                        "proposalId": (
                            f"{message.get('session')}:{message.get('origin_peer')}:{seq}"
                        ),
                        "proposalDigest": action.get("transaction", {}).get("digest"),
                        "preparedFromSeq": int(message.get("prepared_from_seq", 0)),
                        "originPeer": str(message.get("origin_peer", "")),
                    }
                elif action.get("type") == "operation.execute":
                    operation_commits[seq] = {
                        "operationId": (
                            f"{message.get('session')}:{message.get('origin_peer')}:{seq}"
                        ),
                        "operationDigest": action.get("transaction", {}).get("digest"),
                        "operationKind": action.get("transaction", {}).get("kind"),
                        "transaction": dict(action.get("transaction", {})),
                        "originPeer": str(message.get("origin_peer", "")),
                    }
                elif action.get("type") in CHECKPOINTED_COMMIT_TYPES:
                    checkpoint_expected_boundaries.add(seq)
            else:
                controls += 1
                if action.get("type") == "network.proposal_outcome":
                    commit_seq = int(action.get("commitSeq", 0))
                    if commit_seq not in proposal_commits:
                        raise ProtocolError(
                            "proposal outcome references an unknown proposal commit"
                        )
                    if commit_seq in proposal_outcomes:
                        raise ProtocolError("audit contains duplicate proposal outcomes")
                    proposal_outcomes[commit_seq] = dict(action)
                    if action.get("success") is True or action.get("recoverable") is True:
                        checkpoint_expected_boundaries.add(seq)
                elif action.get("type") == "network.operation_outcome":
                    commit_seq = int(action.get("commitSeq", 0))
                    if commit_seq not in operation_commits:
                        raise ProtocolError(
                            "operation outcome references an unknown operation commit"
                        )
                    if commit_seq in operation_outcomes:
                        raise ProtocolError("audit contains duplicate operation outcomes")
                    operation_outcomes[commit_seq] = dict(action)
                    if action.get("success") is True or action.get("recoverable") is True:
                        checkpoint_expected_boundaries.add(seq)
                elif action.get("type") == "network.checkpoint_outcome":
                    boundary_seq = int(action.get("boundarySeq", 0))
                    if boundary_seq < 1 or boundary_seq >= seq:
                        raise ProtocolError(
                            "checkpoint outcome references an invalid ordered boundary"
                        )
                    if boundary_seq in checkpoint_outcomes:
                        raise ProtocolError("audit contains duplicate checkpoint outcomes")
                    checkpoint_outcomes[boundary_seq] = dict(action)
        else:
            records += 1
            if message.get("kind") == "record" and message.get("record_type") == "ack":
                payload = message.get("payload", {})
                commit_seq = int(payload.get("commitSeq", 0))
                digest = payload.get("digest")
                peer = str(message.get("peer", "unknown"))
                if commit_seq > 0 and isinstance(digest, str):
                    peer_acks = acknowledgements.setdefault(commit_seq, {})
                    if peer in peer_acks and peer_acks[peer] != digest:
                        raise ProtocolError("audit contains conflicting commit acknowledgements")
                    peer_acks[peer] = digest
            elif message.get("kind") == "record" \
                    and message.get("record_type") == "completion":
                payload = CommitHost._completion_payload(message.get("payload", {}))
                commit_seq = int(payload["commitSeq"])
                peer = str(message.get("peer", "unknown"))
                peer_completions = proposal_completions.setdefault(commit_seq, {})
                previous = peer_completions.get(peer)
                if previous is not None and previous != payload:
                    raise ProtocolError("audit contains conflicting proposal completions")
                peer_completions[peer] = payload
            elif message.get("kind") == "record" \
                    and message.get("record_type") == "operation_completion":
                payload = operation_completion_payload(message.get("payload", {}))
                commit_seq = int(payload["commitSeq"])
                peer = str(message.get("peer", "unknown"))
                peer_completions = operation_completions.setdefault(commit_seq, {})
                previous = peer_completions.get(peer)
                if previous is not None and previous != payload:
                    raise ProtocolError("audit contains conflicting operation completions")
                peer_completions[peer] = payload
            elif message.get("kind") == "record" \
                    and message.get("record_type") == "checkpoint":
                payload = verify_checkpoint(message.get("payload", {}))
                peer = str(message.get("peer", "unknown"))
                boundary_seq = int(payload["eventCursor"]["lastCommitSeq"])
                peer_checkpoints = checkpoint_records.setdefault(boundary_seq, {})
                if peer in peer_checkpoints and peer_checkpoints[peer] != payload:
                    raise ProtocolError("audit contains conflicting peer checkpoints")
                peer_checkpoints[peer] = payload
                checkpoint_chains[peer] = {
                    "core": payload["coreDigest"],
                    "model": payload["modelDigest"],
                    "event": int(payload["eventCursor"]["lastEventSeq"]),
                }
                checkpoints += 1
            elif message.get("kind") == "record" \
                    and message.get("record_type") == "event":
                payload = verify_event_record(message.get("payload", {}))
                event_records += 1
                peer = str(message.get("peer", "unknown"))
                chain = checkpoint_chains.get(peer)
                if chain:
                    event_seq = int(payload["localEventSeq"])
                    if event_seq != chain["event"] + 1:
                        raise ProtocolError(
                            f"checkpoint event gap for {peer}: "
                            f"expected {chain['event'] + 1}, found {event_seq}"
                        )
                    if payload["preDigest"] != chain["core"] \
                            or payload["preModelDigest"] != chain["model"]:
                        raise ProtocolError(
                            f"checkpoint digest discontinuity for {peer} at event {event_seq}"
                        )
                    chain.update(
                        core=payload["postDigest"], model=payload["postModelDigest"],
                        event=event_seq,
                    )
                    replayed_events += 1
    converged = incomplete = 0
    for seq in commit_sequences:
        values = acknowledgements.get(seq, {})
        unique = set(values.values())
        if len(unique) > 1:
            raise ProtocolError(f"digest divergence at commit {seq}: {values}")
        if len(values) >= 2:
            converged += 1
        else:
            incomplete += 1
    recoveries = verified_fault_recoveries(
        ordered, checkpoint_outcomes, checkpoint_records
    )
    physical = verify_physical_consensus(
        proposal_commits, proposal_completions, proposal_outcomes,
        operation_commits, operation_completions, operation_outcomes,
        acknowledgements, recoveries,
    )
    physical_complete, physical_rejected, physical_faulted, physical_pending = (
        physical["proposals"]
    )
    operation_complete, operation_rejected, operation_faulted, operation_pending = physical["operations"]
    checkpoint_complete = checkpoint_faulted = checkpoint_pending = 0
    for boundary_seq in sorted(checkpoint_expected_boundaries):
        outcome = checkpoint_outcomes.get(boundary_seq)
        if not outcome:
            checkpoint_pending += 1
            continue
        if outcome.get("success") is not True:
            checkpoint_faulted += 1
            continue
        records_at_boundary = checkpoint_records.get(boundary_seq, {})
        required = set(outcome.get("peers", []))
        if not required or not required <= set(records_at_boundary):
            raise ProtocolError(
                f"successful checkpoint outcome lacks peer records at boundary {boundary_seq}"
            )
        selected = [records_at_boundary[peer] for peer in sorted(required)]
        if any(item.get("convergenceKey") != outcome.get("convergenceKey")
               for item in selected):
            raise ProtocolError(f"checkpoint convergence mismatch at boundary {boundary_seq}")
        for field in ("coreDigest", "modelDigest", "canonicalDigest", "financialDigest"):
            if any(item.get(field) != outcome.get(field) for item in selected):
                raise ProtocolError(f"checkpoint {field} mismatch at boundary {boundary_seq}")
        checkpoint_complete += 1
    summary = (
        f"audit valid: {commits} commits, {controls} controls, {records} telemetry records, "
        f"{converged} converged, {incomplete} awaiting peer digests, "
        "physical proposals complete/rejected/faulted/pending="
        f"{physical_complete}/{physical_rejected}/{physical_faulted}/{physical_pending}, "
        "physical operations complete/rejected/faulted/pending="
        f"{operation_complete}/{operation_rejected}/{operation_faulted}/{operation_pending}, "
        "checkpoint barriers complete/faulted/pending="
        f"{checkpoint_complete}/{checkpoint_faulted}/{checkpoint_pending}, "
        f"{checkpoints} checkpoints, {event_records} event records "
        f"({replayed_events} chained), peers={sorted(peers)}"
    )
    print(summary)
    if require_settled:
        problems: list[str] = []
        if commits == 0:
            problems.append("the audit contains no committed actions")
        if incomplete:
            problems.append(f"{incomplete} commit(s) await peer digests")
        if physical_faulted or physical_pending:
            problems.append(
                "physical proposals faulted/pending="
                f"{physical_faulted}/{physical_pending}"
            )
        if operation_faulted or operation_pending:
            problems.append(
                "physical operations faulted/pending="
                f"{operation_faulted}/{operation_pending}"
            )
        if checkpoint_faulted or checkpoint_pending:
            problems.append(
                "checkpoint barriers faulted/pending="
                f"{checkpoint_faulted}/{checkpoint_pending}"
            )
        if problems:
            raise ProtocolError("audit is valid but not settled: " + "; ".join(problems))
    return 0
