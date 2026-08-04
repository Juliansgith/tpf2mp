from __future__ import annotations

import re
import time
from typing import Any, Callable, Mapping

from .protocol import MAX_PROPOSAL_OUTPUTS, ProtocolError


class ConsensusTrackers:
    """Owns bounded host-side consensus registries and tracker construction."""

    def __init__(
        self,
        session: str,
        required_peers: tuple[str, ...],
        completion_timeout: float,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.session = str(session)
        self.required_peers = tuple(required_peers)
        self.completion_timeout = max(1.0, float(completion_timeout))
        self.monotonic = monotonic
        self.proposal_prepares: dict[int, dict[str, Any]] = {}
        self.proposals: dict[int, dict[str, Any]] = {}
        self.operations: dict[int, dict[str, Any]] = {}
        self.checkpoints: dict[int, dict[str, Any]] = {}
        self.clock_controls: dict[int, dict[str, Any]] = {}

    def track_prepare(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        transaction = action.get("transaction", {})
        tracker = self.proposal_prepares.get(seq)
        if tracker is None:
            tracker = {
                "prepareSeq": seq,
                "originPeer": str(commit.get("origin_peer")),
                "originLocalSeq": int(commit.get("origin_local_seq", -1)),
                "originTick": int(commit.get("tick", 0)),
                "proposalDigest": transaction.get("digest"),
                "transaction": dict(transaction),
                "requiredPeers": self.required_peers,
                "acks": {},
                "status": "pending",
                "deadline": self.monotonic() + self.completion_timeout,
            }
            self.proposal_prepares[seq] = tracker
        return tracker

    def track_clock(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        tracker = self.clock_controls.get(seq)
        if tracker is None:
            tracker = {
                "commitSeq": seq,
                "requestedSpeed": int(action.get("requestedSpeed", 0)),
                "effectiveSpeed": int(action.get("effectiveSpeed", 0)),
                "generation": int(action.get("generation", 0)),
                "reason": str(action.get("reason", "host-order")),
                "requiredPeers": self.required_peers,
                "acks": {},
                "status": "pending",
                "deadline": self.monotonic() + min(self.completion_timeout, 10.0),
            }
            self.clock_controls[seq] = tracker
        return tracker

    def track_proposal(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        transaction = action.get("transaction", {})
        tracker = self.proposals.get(seq)
        if tracker is None:
            tracker = {
                "commitSeq": seq,
                "proposalId": f"{self.session}:{commit.get('origin_peer')}:{seq}",
                "originPeer": str(commit.get("origin_peer")),
                "proposalDigest": transaction.get("digest"),
                "requiredPeers": self.required_peers,
                "completions": {},
                "status": "pending",
                "deadline": self.monotonic() + self.completion_timeout,
            }
            self.proposals[seq] = tracker
        return tracker

    def track_operation(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        transaction = action.get("transaction", {})
        tracker = self.operations.get(seq)
        if tracker is None:
            tracker = {
                "commitSeq": seq,
                "operationId": f"{self.session}:{commit.get('origin_peer')}:{seq}",
                "originPeer": str(commit.get("origin_peer")),
                "operationDigest": transaction.get("digest"),
                "operationKind": transaction.get("kind"),
                "requiredPeers": self.required_peers,
                "completions": {},
                "status": "pending",
                "deadline": self.monotonic() + self.completion_timeout,
            }
            self.operations[seq] = tracker
        return tracker

    def track_checkpoint(
        self,
        boundary_seq: int,
        reason: str,
        proposal_id: str | None = None,
    ) -> dict[str, Any]:
        key = int(boundary_seq)
        tracker = self.checkpoints.get(key)
        if tracker is None:
            tracker = {
                "boundarySeq": key,
                "reason": str(reason),
                "proposalId": proposal_id,
                "requiredPeers": self.required_peers,
                "checkpoints": {},
                "status": "pending",
                "deadline": self.monotonic() + self.completion_timeout,
            }
            self.checkpoints[key] = tracker
        return tracker

    @staticmethod
    def pending(registry: Mapping[int, dict[str, Any]]) -> dict[str, Any] | None:
        for seq in sorted(registry):
            tracker = registry[seq]
            if tracker.get("status") == "pending":
                return tracker
        return None

    def pending_clock_seq(self) -> int | None:
        pending = [
            seq
            for seq, tracker in self.clock_controls.items()
            if tracker.get("status") == "pending"
        ]
        return min(pending) if pending else None


def proposal_completion_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("proposal completion payload must be an object")
    allowed = {
        "proposalId", "commitSeq", "proposalDigest", "success", "outputs",
        "financeDelta", "coreDigest", "resultDigest", "errorCode",
    }
    if set(payload) - allowed:
        raise ProtocolError("proposal completion has unknown fields")
    required = allowed - {"errorCode", "financeDelta"}
    if not required <= set(payload):
        raise ProtocolError("proposal completion has missing fields")
    commit_seq = payload.get("commitSeq")
    if not isinstance(commit_seq, int) or isinstance(commit_seq, bool) or commit_seq < 1:
        raise ProtocolError("proposal completion commitSeq must be positive")
    if not isinstance(payload.get("proposalId"), str) or not payload["proposalId"]:
        raise ProtocolError("proposal completion has no proposalId")
    if not isinstance(payload.get("success"), bool):
        raise ProtocolError("proposal completion success must be boolean")
    for field in ("proposalDigest", "coreDigest", "resultDigest"):
        value = payload.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{8}", value) is None:
            raise ProtocolError(f"proposal completion {field} is not a canonical digest")
    outputs = payload.get("outputs")
    lua_empty_outputs = isinstance(outputs, dict) and not outputs
    if (
        (not isinstance(outputs, list) and not lua_empty_outputs)
        or len(outputs) > MAX_PROPOSAL_OUTPUTS
    ):
        raise ProtocolError("proposal completion outputs are invalid")
    for output in [] if lua_empty_outputs else outputs:
        if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
            raise ProtocolError("proposal completion output is malformed")
        if output["kind"] not in {
            "node", "edge", "edge_object", "construction", "station",
            "station_group", "depot", "asset",
        }:
            raise ProtocolError("proposal completion output kind is unsupported")
        if not isinstance(output["cid"], str) or not output["cid"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("proposal completion output has a non-canonical id")
        if not isinstance(output["slot"], str) or not output["slot"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("proposal completion output has an invalid slot")
    if "errorCode" in payload and not isinstance(payload["errorCode"], str):
        raise ProtocolError("proposal completion errorCode must be a string")
    if payload["success"]:
        finance_delta = payload.get("financeDelta")
        if not isinstance(finance_delta, int) or isinstance(finance_delta, bool):
            raise ProtocolError("successful proposal completion requires integer financeDelta")
    return dict(payload)


def operation_completion_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("operation completion payload must be an object")
    allowed = {
        "operationId", "commitSeq", "operationDigest", "success", "outputs",
        "postcondition", "financeDelta", "coreDigest", "resultDigest", "errorCode",
    }
    if set(payload) - allowed:
        raise ProtocolError("operation completion has unknown fields")
    required = allowed - {"errorCode", "financeDelta"}
    if not required <= set(payload):
        raise ProtocolError("operation completion has missing fields")
    commit_seq = payload.get("commitSeq")
    if not isinstance(commit_seq, int) or isinstance(commit_seq, bool) or commit_seq < 1:
        raise ProtocolError("operation completion commitSeq must be positive")
    if not isinstance(payload.get("operationId"), str) or not payload["operationId"]:
        raise ProtocolError("operation completion has no operationId")
    if not isinstance(payload.get("success"), bool):
        raise ProtocolError("operation completion success must be boolean")
    for field in ("operationDigest", "coreDigest", "resultDigest"):
        value = payload.get(field)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{8}", value) is None:
            raise ProtocolError(f"operation completion {field} is not a canonical digest")
    outputs = payload.get("outputs")
    lua_empty_outputs = isinstance(outputs, dict) and not outputs
    if (not isinstance(outputs, list) and not lua_empty_outputs) or len(outputs) > 1:
        raise ProtocolError("operation completion outputs are invalid")
    for output in [] if lua_empty_outputs else outputs:
        if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
            raise ProtocolError("operation completion output is malformed")
        if output["kind"] not in {"line", "vehicle"}:
            raise ProtocolError("operation completion output kind is unsupported")
        if not isinstance(output["cid"], str) or not output["cid"].startswith(
            output["kind"] + ":"
        ):
            raise ProtocolError("operation completion output has a non-canonical id")
        if output["slot"] != output["kind"] + ":1":
            raise ProtocolError("operation completion output has an invalid slot")
    if not isinstance(payload.get("postcondition"), dict):
        raise ProtocolError("operation completion postcondition must be an object")
    if "errorCode" in payload and not isinstance(payload["errorCode"], str):
        raise ProtocolError("operation completion errorCode must be a string")
    if payload["success"]:
        finance_delta = payload.get("financeDelta")
        if not isinstance(finance_delta, int) or isinstance(finance_delta, bool):
            raise ProtocolError("successful operation completion requires integer financeDelta")
    return dict(payload)


def clock_health_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("clock health payload must be an object")
    required = {
        "schemaVersion", "requestedSpeed", "effectiveSpeed", "generation",
        "engineTick", "lastCommitSeq", "proposalPending",
    }
    allowed = required | {"observedSpeed", "gameTime"}
    if not required <= set(payload) or set(payload) - allowed:
        raise ProtocolError("clock health payload has unknown or missing fields")
    if payload.get("schemaVersion") != 1:
        raise ProtocolError("unsupported clock health schema")
    for field in (
        "requestedSpeed", "effectiveSpeed", "generation", "engineTick", "lastCommitSeq"
    ):
        if not isinstance(payload.get(field), int) or isinstance(payload.get(field), bool):
            raise ProtocolError(f"clock health {field} must be an integer")
    if not isinstance(payload.get("proposalPending"), bool):
        raise ProtocolError("clock health proposalPending must be boolean")
    for field in ("observedSpeed", "gameTime"):
        value = payload.get(field)
        if value is not None and (
            not isinstance(value, (int, float)) or isinstance(value, bool)
        ):
            raise ProtocolError(f"clock health {field} must be numeric when present")
    return dict(payload)
