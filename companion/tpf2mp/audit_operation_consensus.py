from __future__ import annotations

from typing import Any, Mapping

from .completion_validation import operation_completion_result_view
from .operation_rejection import proof_error as operation_rejection_proof_error
from .protocol import ProtocolError


def verify_operation_consensus(
    commits: Mapping[int, Mapping[str, Any]],
    completions_by_commit: Mapping[int, Mapping[str, Mapping[str, Any]]],
    outcomes: Mapping[int, Mapping[str, Any]],
    acknowledgements: Mapping[int, Mapping[str, str]],
    recoveries: Mapping[int, Mapping[str, Any]],
) -> tuple[int, int, int, int]:
    complete = rejected = faulted = pending = 0
    for commit_seq, operation in commits.items():
        outcome = outcomes.get(commit_seq)
        if not outcome:
            pending += 1
            continue
        if outcome.get("operationId") != operation["operationId"]:
            raise ProtocolError(f"operation outcome identity mismatch at commit {commit_seq}")
        if outcome.get("operationDigest") != operation["operationDigest"]:
            raise ProtocolError(f"operation outcome digest mismatch at commit {commit_seq}")
        recovery = recoveries.get(commit_seq)
        recoverable = (
            outcome.get("recoverable") is True and outcome.get("success") is not True
        ) or bool(recovery and recovery.get("faultType") == "operation-rejection")
        if outcome.get("success") is not True and not recoverable:
            faulted += 1
            continue
        completions = completions_by_commit.get(commit_seq, {})
        required = set(outcome.get("peers", []))
        selected = _required_completions(completions, required, commit_seq, recoverable)
        if any(
            item.get("commitSeq") != commit_seq
            or item.get("operationId") != operation["operationId"]
            or item.get("operationDigest") != operation["operationDigest"]
            for item in selected
        ):
            raise ProtocolError(f"operation completion identity mismatch at commit {commit_seq}")
        if recoverable:
            _verify_rejection(
                commit_seq, operation, outcome, selected, required,
                acknowledgements.get(commit_seq, {}), recovery,
            )
            rejected += 1
            continue
        if any(item.get("success") is not True for item in selected):
            raise ProtocolError(
                f"successful operation outcome contains a failed peer at commit {commit_seq}"
            )
        first_result = operation_completion_result_view(selected[0])
        if any(operation_completion_result_view(item) != first_result for item in selected[1:]):
            raise ProtocolError(f"physical operation result divergence at commit {commit_seq}")
        if outcome.get("resultDigest") != selected[0]["resultDigest"] \
                or outcome.get("coreDigest") != selected[0]["coreDigest"]:
            raise ProtocolError(
                f"operation outcome digests differ from completions at commit {commit_seq}"
            )
        origin = completions.get(str(operation["originPeer"]))
        if origin is None or outcome.get("financeDelta") != origin.get("financeDelta"):
            raise ProtocolError(
                f"operation outcome finance differs from its origin at commit {commit_seq}"
            )
        complete += 1
    return complete, rejected, faulted, pending


def _required_completions(
    completions: Mapping[str, Mapping[str, Any]], required: set[str],
    commit_seq: int, recoverable: bool,
) -> list[Mapping[str, Any]]:
    label = "recoverable operation rejection" if recoverable \
        else "successful operation outcome"
    if not required or not required <= set(completions):
        raise ProtocolError(f"{label} lacks peer completions at commit {commit_seq}")
    return [completions[peer] for peer in sorted(required)]


def _verify_rejection(
    commit_seq: int, operation: Mapping[str, Any], outcome: Mapping[str, Any],
    selected: list[Mapping[str, Any]], required: set[str],
    ack_values: Mapping[str, str], recovery: Mapping[str, Any] | None,
) -> None:
    tracker = {
        **operation, "commitSeq": commit_seq, "requiredPeers": tuple(sorted(required)),
        "acks": {
            peer: {"success": True, "digest": digest}
            for peer, digest in ack_values.items()
        },
    }
    if recovery:
        views = [operation_completion_result_view(item) for item in selected]
        invalid = any(item.get("success") is not False for item in selected) \
            or any(item.get("outputs") or "financeDelta" in item for item in selected) \
            or any(view != views[0] for view in views[1:]) \
            or len({item.get("errorCode") for item in selected}) != 1 \
            or not required <= set(ack_values) \
            or len({ack_values[peer] for peer in required}) != 1 \
            or selected[0]["coreDigest"] not in {ack_values[peer] for peer in required} \
            or recovery.get("operationId") != operation["operationId"] \
            or recovery.get("operationDigest") != operation["operationDigest"] \
            or recovery.get("resultDigest") != selected[0]["resultDigest"] \
            or recovery.get("expectedCoreDigest") != selected[0]["coreDigest"] \
            or recovery.get("nativeErrorCode") != selected[0].get("errorCode") \
            or recovery.get("faultCode") != outcome.get("errorCode")
        if invalid:
            raise ProtocolError(f"recovered operation rejection is invalid at commit {commit_seq}")
    else:
        error = operation_rejection_proof_error(tracker, selected)
        if error:
            raise ProtocolError(
                f"recoverable operation rejection is invalid at commit {commit_seq}: {error}"
            )
    expected_error = recovery.get("faultCode") if recovery else "native-operation-rejected"
    if outcome.get("errorCode") != expected_error \
            or outcome.get("resultDigest") != selected[0]["resultDigest"] \
            or outcome.get("coreDigest") != selected[0]["coreDigest"]:
        raise ProtocolError(
            f"recoverable operation outcome differs from completions at commit {commit_seq}"
        )
