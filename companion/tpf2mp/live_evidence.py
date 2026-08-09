from __future__ import annotations

from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

from .bridge import AuditLog
from .checkpoint import CHECKPOINT_VERSION, verify_checkpoint
from .protocol import ProtocolError, validate_envelope


CHECKPOINTED_COMMIT_TYPES = frozenset({
    "match.initialise",
    "town.develop",
    "freight.industry_bootstrap",
    "freight.milestone",
    "probe.structural",
    "economy.settle",
    "recovery.resume",
})


def _error(label: str, detail: str) -> ProtocolError:
    return ProtocolError(f"{label} {detail}")


def scan_live_audit(
    path: Path | str,
    session: str | None = None,
    *,
    required_peers: Sequence[str] = ("player1", "player2"),
    label: str = "live evidence",
) -> dict[str, Any]:
    """Verify shared audit mechanics and return completed checkpoint payloads.

    This is deliberately transport/economy agnostic.  A domain report consumes
    ``completed[*].payloads`` and proves its own facts, while every report uses
    this one definition of ordered sequencing, physical-outcome completion and
    two-peer checkpoint convergence.
    """

    peer_roster = tuple(dict.fromkeys(str(peer) for peer in required_peers))
    if not peer_roster or any(not peer for peer in peer_roster):
        raise ValueError("at least one non-empty required peer is needed")

    audit_path = Path(path).expanduser().resolve()
    messages = list(AuditLog(audit_path).messages())
    if not messages:
        raise _error(label, "audit is empty")
    selected_session = session or str(messages[0].get("session", ""))
    if not selected_session:
        raise _error(label, "audit has no session")

    ordered_expected = 1
    ordered: dict[int, dict[str, Any]] = {}
    acknowledgements: dict[int, dict[str, str]] = {}
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
                raise _error(label, "audit mixes sessions")
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
            ordered[seq] = dict(message)
            action = message.get("payload", {}).get("action", {})
            action_type = action.get("type")
            if action_type == "network.sync_fault":
                faults.append(str(action.get("errorCode") or "network-sync-fault"))
            if kind == "commit":
                if action_type == "proposal.prepare":
                    proposal_prepares.add(seq)
                elif action_type == "proposal.build":
                    proposals.add(seq)
                elif action_type == "operation.execute":
                    operations.add(seq)
                elif action_type in CHECKPOINTED_COMMIT_TYPES:
                    expected_checkpoints.add(seq)
            elif action_type == "network.proposal_prepare_outcome":
                prepare_seq = int(action.get("prepareSeq", 0))
                if prepare_seq not in proposal_prepares:
                    raise _error(label, "prepare outcome references an unknown prepare")
                if prepare_seq in proposal_prepare_outcomes:
                    raise _error(label, "contains duplicate prepare outcomes")
                proposal_prepare_outcomes.add(prepare_seq)
            elif action_type == "network.proposal_outcome":
                commit_seq = int(action.get("commitSeq", 0))
                if commit_seq not in proposals:
                    raise _error(label, "proposal outcome references an unknown proposal")
                if commit_seq in proposal_outcomes:
                    raise _error(label, "contains duplicate proposal outcomes")
                proposal_outcomes[commit_seq] = dict(action)
                recoverable = (
                    action.get("recoverable") is True
                    and action.get("success") is not True
                )
                if action.get("success") is True or recoverable:
                    expected_checkpoints.add(seq)
                else:
                    faults.append(
                        str(action.get("errorCode") or "proposal-consensus-failed")
                    )
            elif action_type == "network.operation_outcome":
                commit_seq = int(action.get("commitSeq", 0))
                if commit_seq not in operations:
                    raise _error(label, "operation outcome references an unknown operation")
                if commit_seq in operation_outcomes:
                    raise _error(label, "contains duplicate operation outcomes")
                operation_outcomes[commit_seq] = dict(action)
                if action.get("success") is True:
                    expected_checkpoints.add(seq)
                else:
                    faults.append(
                        str(action.get("errorCode") or "operation-consensus-failed")
                    )
            elif action_type == "network.checkpoint_outcome":
                boundary = int(action.get("boundarySeq", 0))
                if boundary < 1 or boundary >= seq:
                    raise _error(label, "checkpoint outcome has an invalid boundary")
                if boundary in checkpoint_outcomes:
                    raise _error(label, "contains duplicate checkpoint outcomes")
                expected_checkpoints.add(boundary)
                checkpoint_outcomes[boundary] = dict(action)
                if action.get("success") is not True:
                    faults.append(
                        str(action.get("errorCode") or "checkpoint-consensus-failed")
                    )
        elif kind == "record" and message.get("record_type") == "ack":
            payload = message.get("payload", {})
            commit_seq = int(payload.get("commitSeq", 0))
            peer = str(message.get("peer", ""))
            digest = payload.get("digest")
            if commit_seq < 1 or not peer or not isinstance(digest, str):
                raise _error(label, "contains an invalid commit acknowledgement")
            prior = acknowledgements.setdefault(commit_seq, {}).get(peer)
            if prior is not None and prior != digest:
                raise _error(label, "contains conflicting commit acknowledgements")
            acknowledgements[commit_seq][peer] = digest
        elif kind == "record" and message.get("record_type") == "checkpoint":
            payload = verify_checkpoint(message.get("payload", {}))
            if int(payload.get("checkpointVersion", 0)) != CHECKPOINT_VERSION:
                raise _error(
                    label, f"requires checkpoint format {CHECKPOINT_VERSION}"
                )
            boundary = int(payload["eventCursor"]["lastCommitSeq"])
            peer = str(message.get("peer", ""))
            if not peer:
                raise _error(label, "contains a checkpoint without a peer")
            prior = checkpoints.setdefault(boundary, {}).get(peer)
            if prior is not None and prior != payload:
                raise _error(
                    label,
                    f"peer {peer} sent conflicting checkpoints at boundary {boundary}",
                )
            checkpoints[boundary][peer] = payload

    pending_prepares = sorted(proposal_prepares - proposal_prepare_outcomes)
    pending_proposals = sorted(proposals - set(proposal_outcomes))
    pending_operations = sorted(operations - set(operation_outcomes))
    pending_checkpoints = sorted(expected_checkpoints - set(checkpoint_outcomes))
    required_set = set(peer_roster)
    completed: list[dict[str, Any]] = []
    for boundary in sorted(expected_checkpoints):
        outcome = checkpoint_outcomes.get(boundary)
        if not outcome or outcome.get("success") is not True:
            continue
        outcome_peers = set(str(peer) for peer in outcome.get("peers", []))
        if not required_set <= outcome_peers:
            raise _error(
                label, f"checkpoint boundary {boundary} omits an expected peer"
            )
        records = checkpoints.get(boundary, {})
        if not required_set <= set(records):
            raise ProtocolError(
                f"checkpoint boundary {boundary} lacks {label} from every peer"
            )
        selected = [records[peer] for peer in peer_roster]
        convergence = {item["convergenceKey"] for item in selected}
        if len(convergence) != 1 or next(iter(convergence)) != outcome.get(
            "convergenceKey"
        ):
            raise _error(
                label, f"checkpoint convergence mismatch at boundary {boundary}"
            )
        if any(item.get("reason") != outcome.get("reason") for item in selected):
            raise _error(label, f"checkpoint reason mismatch at boundary {boundary}")
        for field in ("coreDigest", "modelDigest", "canonicalDigest", "financialDigest"):
            if any(item.get(field) != outcome.get(field) for item in selected):
                raise _error(
                    label, f"checkpoint {field} mismatch at boundary {boundary}"
                )
        for field in ("model", "canonical", "vehicleSynchronization", "financial"):
            if any(item[field] != selected[0][field] for item in selected[1:]):
                raise _error(
                    label,
                    f"checkpoint {field} payloads differ at boundary {boundary}",
                )
        completed.append({
            "boundarySeq": boundary,
            "outcome": dict(outcome),
            "payloads": {peer: records[peer] for peer in peer_roster},
        })

    incomplete_acks: dict[str, list[str]] = {}
    divergent_acks: dict[str, dict[str, str]] = {}
    for seq, message in sorted(ordered.items()):
        if message.get("kind") != "commit":
            continue
        peer_digests = acknowledgements.get(seq, {})
        missing = sorted(required_set - set(peer_digests))
        if missing:
            incomplete_acks[str(seq)] = missing
        if len(set(peer_digests.values())) > 1:
            divergent_acks[str(seq)] = dict(sorted(peer_digests.items()))

    return {
        "session": selected_session,
        "audit": str(audit_path),
        "requiredPeers": list(peer_roster),
        "faults": sorted(set(faults)),
        "pending": {
            "proposalPrepares": pending_prepares,
            "proposals": pending_proposals,
            "operations": pending_operations,
            "checkpoints": pending_checkpoints,
            "incompleteCommitAcknowledgements": incomplete_acks,
            "divergentCommitAcknowledgements": divergent_acks,
        },
        "completed": completed,
    }
