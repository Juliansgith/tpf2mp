from __future__ import annotations

from typing import Any, Mapping

from .protocol import ProtocolError


OPTIMISTIC_OPERATION_KINDS = frozenset({
    "line.create", "line.update", "line.delete", "entity.name", "entity.color",
})


def can_supersede(
    host: Any, tracker: Mapping[str, Any], action: Mapping[str, Any], origin: str,
) -> bool:
    """Whether an already-applied optimistic edit may replace this boundary."""
    if tracker.get("status") != "pending" or action.get("type") != "operation.execute":
        return False
    transaction = action.get("transaction")
    token = action.get("originCaptureToken")
    if not isinstance(transaction, Mapping) \
            or transaction.get("kind") not in OPTIMISTIC_OPERATION_KINDS \
            or not isinstance(token, str) \
            or not (token.startswith(f"{origin}:line-origin:")
                    or token.startswith(f"{origin}:operation-origin:")):
        return False
    operation_id = str(tracker.get("proposalId") or "")
    if not operation_id or tracker.get("reason") != f"operation-consensus:{operation_id}":
        return False
    previous = next((item for item in host.operation_consensus.values()
                     if item.get("operationId") == operation_id), None)
    return bool(previous and previous.get("status") == "complete"
                and previous.get("originPeer") == origin)


def reject_client_marker(action: Any) -> None:
    if isinstance(action, Mapping) and action.get("type") == "operation.execute" \
            and "supersedesCheckpointBoundarySeq" in action:
        raise ProtocolError("operation checkpoint supersession is host-derived")


def admit(
    host: Any, tracker: dict[str, Any] | None,
    action: Mapping[str, Any], origin: str,
) -> dict[str, Any] | None:
    if tracker is None or can_supersede(host, tracker, action, origin):
        return tracker
    raise ProtocolError(
        f"checkpoint boundary {tracker['boundarySeq']} is awaiting peer consensus"
    )


def mark(tracker: dict[str, Any], origin: str, sequence: int) -> None:
    tracker["status"] = "superseded"
    tracker["supersededByOrigin"] = origin
    tracker["supersededBySeq"] = int(sequence)


def annotate(
    tracker: dict[str, Any] | None, action: Mapping[str, Any],
    origin: str, sequence: int,
) -> Mapping[str, Any]:
    if tracker is None:
        return action
    result = dict(action)
    result["supersedesCheckpointBoundarySeq"] = int(tracker["boundarySeq"])
    mark(tracker, origin, sequence)
    return result


def restore(host: Any, action: Mapping[str, Any], origin: str, sequence: int) -> None:
    boundary = action.get("supersedesCheckpointBoundarySeq")
    if isinstance(boundary, bool) or not isinstance(boundary, int):
        return
    tracker = host.checkpoint_consensus.get(boundary)
    if tracker and tracker.get("status") == "pending":
        mark(tracker, origin, sequence)
