from __future__ import annotations

from typing import Any, Mapping

from .audit_operation_consensus import verify_operation_consensus
from .completion_validation import proposal_completion_result_view
from .protocol import ProtocolError


def verify_physical_consensus(
    proposal_commits: Mapping[int, Mapping[str, Any]],
    proposal_completions: Mapping[int, Mapping[str, Mapping[str, Any]]],
    proposal_outcomes: Mapping[int, Mapping[str, Any]],
    operation_commits: Mapping[int, Mapping[str, Any]],
    operation_completions: Mapping[int, Mapping[str, Mapping[str, Any]]],
    operation_outcomes: Mapping[int, Mapping[str, Any]],
    acknowledgements: Mapping[int, Mapping[str, str]],
    proposal_recoveries: Mapping[int, Mapping[str, Any]] | None = None,
) -> dict[str, tuple[int, ...]]:
    proposal_recoveries = proposal_recoveries or {}
    proposal_complete = proposal_rejected = proposal_faulted = proposal_pending = 0
    for commit_seq, proposal in proposal_commits.items():
        outcome = proposal_outcomes.get(commit_seq)
        if not outcome:
            proposal_pending += 1
            continue
        completions = proposal_completions.get(commit_seq, {})
        required = set(outcome.get("peers", []))
        if outcome.get("proposalId") != proposal["proposalId"]:
            raise ProtocolError(f"proposal outcome identity mismatch at commit {commit_seq}")
        if outcome.get("proposalDigest") != proposal["proposalDigest"]:
            raise ProtocolError(f"proposal outcome digest mismatch at commit {commit_seq}")
        if outcome.get("success") and outcome.get("recoverable") is True:
            raise ProtocolError(f"successful proposal is marked recoverable at commit {commit_seq}")
        if outcome.get("success"):
            selected = _required_completions(
                completions, required, commit_seq, "successful proposal outcome"
            )
            _verify_proposal_completions(commit_seq, proposal, selected, True)
            if outcome.get("resultDigest") != selected[0]["resultDigest"] \
                    or outcome.get("coreDigest") != selected[0]["coreDigest"]:
                raise ProtocolError(
                    f"proposal outcome digests differ from completions at commit {commit_seq}"
                )
            origin = completions.get(str(proposal["originPeer"]))
            if origin is None or outcome.get("financeDelta") != origin.get("financeDelta"):
                raise ProtocolError(
                    f"proposal outcome finance differs from its origin at commit {commit_seq}"
                )
            proposal_complete += 1
        elif outcome.get("recoverable") is True or commit_seq in proposal_recoveries:
            recovery = proposal_recoveries.get(commit_seq)
            selected = _required_completions(
                completions, required, commit_seq, "recoverable proposal rejection"
            )
            _verify_proposal_completions(commit_seq, proposal, selected, False)
            if any(item.get("outputs") or "financeDelta" in item for item in selected):
                raise ProtocolError(
                    f"recoverable proposal rejection contains mutation residue at commit {commit_seq}"
                )
            if len({item.get("errorCode") for item in selected}) != 1:
                raise ProtocolError(
                    f"recoverable proposal rejection has different native errors at commit {commit_seq}"
                )
            evidence = recovery or outcome
            if evidence.get("resultDigest") != selected[0]["resultDigest"] \
                    or evidence.get("expectedCoreDigest", evidence.get("coreDigest")) \
                    != selected[0]["coreDigest"]:
                raise ProtocolError(
                    f"recoverable proposal outcome digests differ from completions at commit {commit_seq}"
                )
            if recovery and (
                recovery.get("proposalId") != proposal["proposalId"]
                or recovery.get("proposalDigest") != proposal["proposalDigest"]
                or recovery.get("nativeErrorCode") != selected[0].get("errorCode")
                or outcome.get("errorCode") != recovery.get("faultCode")
            ):
                raise ProtocolError(
                    f"fault recovery evidence differs from its proposal at commit {commit_seq}"
                )
            prepared = acknowledgements.get(int(proposal.get("preparedFromSeq", 0)), {})
            if not required <= set(prepared) \
                    or len({prepared[peer] for peer in required}) != 1 \
                    or selected[0]["coreDigest"] != next(
                        iter({prepared[peer] for peer in required})
                    ):
                raise ProtocolError(
                    f"recoverable proposal rejection does not preserve its prepare core at commit {commit_seq}"
                )
            proposal_rejected += 1
        else:
            proposal_faulted += 1

    operations = verify_operation_consensus(
        operation_commits, operation_completions, operation_outcomes,
        acknowledgements, proposal_recoveries,
    )

    return {
        "proposals": (
            proposal_complete, proposal_rejected, proposal_faulted, proposal_pending,
        ),
        "operations": operations,
    }


def _required_completions(
    completions: Mapping[str, Mapping[str, Any]],
    required: set[str],
    commit_seq: int,
    label: str,
) -> list[Mapping[str, Any]]:
    if not required or not required <= set(completions):
        raise ProtocolError(f"{label} lacks peer completions at commit {commit_seq}")
    return [completions[peer] for peer in sorted(required)]


def _verify_proposal_completions(
    commit_seq: int,
    proposal: Mapping[str, Any],
    selected: list[Mapping[str, Any]],
    expected_success: bool,
) -> None:
    if any(
        item.get("commitSeq") != commit_seq
        or item.get("proposalId") != proposal["proposalId"]
        or item.get("proposalDigest") != proposal["proposalDigest"]
        for item in selected
    ):
        raise ProtocolError(f"proposal completion identity mismatch at commit {commit_seq}")
    if any(item.get("success") is not expected_success for item in selected):
        state = "successful" if expected_success else "recoverable"
        raise ProtocolError(
            f"{state} proposal outcome contains a mismatched peer at commit {commit_seq}"
        )
    first_result = proposal_completion_result_view(selected[0])
    if any(proposal_completion_result_view(item) != first_result for item in selected[1:]):
        raise ProtocolError(f"physical result divergence at commit {commit_seq}")
