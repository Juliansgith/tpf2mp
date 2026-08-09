from __future__ import annotations

import math
import time
from typing import Any, Callable, Mapping

from .protocol import ProtocolError, validate_vehicle_schedule


# Actions that either need all-peer evidence or immediately open a checkpoint.
CONSENSUS_BOUND_ACTIONS = {
    "match.initialise", "proposal.prepare", "operation.execute", "line.register",
    "town.develop", "recovery.prepare", "recovery.resume", "recovery.save_receipt",
    "content.industry_attest", "freight.industry_bootstrap", "freight.milestone",
    "passenger.milestone",
    "economy.settle", "probe.structural",
}


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
            started_at = self.monotonic()
            tracker = {
                "commitSeq": seq,
                "actionType": str(action.get("type", "clock.set")),
                "requestedSpeed": int(action.get("requestedSpeed", 0)),
                "effectiveSpeed": int(action.get(
                    "effectiveSpeed", action.get("approachSpeed", 0)
                )),
                "releaseSpeed": int(action.get(
                    "releaseSpeed", action.get("effectiveSpeed", 0)
                )),
                "generation": int(action.get("generation", 0)),
                "reason": str(action.get("reason", "host-order")),
                "targetGameTime": action.get("targetGameTime"),
                "requiredPeers": self.required_peers,
                "acks": {},
                "status": "pending",
                "startedAt": started_at,
                "deadline": started_at + min(self.completion_timeout, 10.0),
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


def clock_health_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("clock health payload must be an object")
    required = {
        "schemaVersion", "requestedSpeed", "effectiveSpeed", "generation",
        "engineTick", "lastCommitSeq", "proposalPending",
    }
    schema = payload.get("schemaVersion")
    rendezvous = {
        "rendezvousGeneration", "rendezvousState", "rendezvousTargetTime",
    }
    local_work = {"localWorkPending", "deferredIntentCount"}
    allowed = required | {"observedSpeed", "gameTime"}
    if schema in {2, 3}:
        required |= rendezvous
        allowed |= rendezvous
    if schema == 3:
        required |= local_work
        allowed |= local_work
    if not required <= set(payload) or set(payload) - allowed:
        raise ProtocolError("clock health payload has unknown or missing fields")
    if schema not in {1, 2, 3}:
        raise ProtocolError("unsupported clock health schema")
    for field in (
        "requestedSpeed", "effectiveSpeed", "generation", "engineTick", "lastCommitSeq"
    ):
        if not isinstance(payload.get(field), int) or isinstance(payload.get(field), bool):
            raise ProtocolError(f"clock health {field} must be an integer")
    if not isinstance(payload.get("proposalPending"), bool):
        raise ProtocolError("clock health proposalPending must be boolean")
    if schema == 3:
        if not isinstance(payload.get("localWorkPending"), bool):
            raise ProtocolError("clock health localWorkPending must be boolean")
        deferred = payload.get("deferredIntentCount")
        if not isinstance(deferred, int) or isinstance(deferred, bool) or deferred < 0:
            raise ProtocolError("clock health deferredIntentCount must be non-negative")
    for field in ("observedSpeed", "gameTime"):
        value = payload.get(field)
        if value is not None and (
            not isinstance(value, (int, float)) or isinstance(value, bool)
            or not math.isfinite(float(value))
        ):
            raise ProtocolError(f"clock health {field} must be numeric when present")
    observed_speed = payload.get("observedSpeed")
    if observed_speed is not None and (
        float(observed_speed) < 0 or float(observed_speed) > 4
    ):
        raise ProtocolError("clock health observedSpeed is outside [0,4]")
    game_time = payload.get("gameTime")
    if game_time is not None and float(game_time) < 0:
        raise ProtocolError("clock health gameTime must be non-negative")
    if schema in {2, 3}:
        generation = payload.get("rendezvousGeneration")
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 0:
            raise ProtocolError("clock health rendezvousGeneration must be non-negative")
        if payload.get("rendezvousState") not in {
            "idle", "armed", "approaching", "pausing", "reached", "faulted",
        }:
            raise ProtocolError("clock health rendezvousState is invalid")
        target = payload.get("rendezvousTargetTime")
        if target is not None and (
            not isinstance(target, (int, float)) or isinstance(target, bool)
            or not math.isfinite(float(target))
        ):
            raise ProtocolError("clock health rendezvousTargetTime must be numeric when present")
    return dict(payload)


def clock_rendezvous_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("clock rendezvous payload must be an object")
    required = {
        "schemaVersion", "generation", "targetGameTime", "actualGameTime",
        "engineTick", "success", "error",
    }
    if set(payload) != required or payload.get("schemaVersion") != 1:
        raise ProtocolError("clock rendezvous payload has unknown, missing, or unsupported fields")
    for field in ("generation", "engineTick"):
        if not isinstance(payload.get(field), int) or isinstance(payload.get(field), bool) \
                or payload[field] < 0:
            raise ProtocolError(f"clock rendezvous {field} must be a non-negative integer")
    for field in ("targetGameTime", "actualGameTime"):
        value = payload.get(field)
        if not isinstance(value, (int, float)) or isinstance(value, bool) \
                or not math.isfinite(float(value)):
            raise ProtocolError(f"clock rendezvous {field} must be numeric")
    if not isinstance(payload.get("success"), bool) or not isinstance(payload.get("error"), str):
        raise ProtocolError("clock rendezvous success/error fields are invalid")
    return dict(payload)


def vehicle_sync_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise ProtocolError("vehicle sync payload must be an object")
    required = {
        "schemaVersion", "vehicleCid", "lineCid", "round", "stopIndex",
        "state", "gameTime", "engineTick", "detail",
    }
    schema = payload.get("schemaVersion")
    expected = required if schema == 1 else required | {"schedule"}
    if set(payload) != expected or schema not in {1, 2}:
        raise ProtocolError("vehicle sync payload has unknown, missing, or unsupported fields")
    for field, prefix in (("vehicleCid", "vehicle:"), ("lineCid", "line:")):
        value = payload.get(field)
        if not isinstance(value, str) or not value.startswith(prefix) or len(value) > 320:
            raise ProtocolError(f"vehicle sync {field} is not canonical")
    for field, lower, upper in (
        ("round", 1, 1_000_000_000),
        ("stopIndex", 0, 255),
        ("engineTick", 0, 2_147_483_647),
    ):
        value = payload.get(field)
        if not isinstance(value, int) or isinstance(value, bool) or not lower <= value <= upper:
            raise ProtocolError(f"vehicle sync {field} is outside its supported range")
    if payload.get("state") not in {"held", "released", "fault"}:
        raise ProtocolError("vehicle sync state is invalid")
    game_time = payload.get("gameTime")
    if not isinstance(game_time, (int, float)) or isinstance(game_time, bool) \
            or not math.isfinite(float(game_time)) or game_time < 0:
        raise ProtocolError("vehicle sync gameTime must be non-negative numeric")
    if not isinstance(payload.get("detail"), str) or len(payload["detail"]) > 512:
        raise ProtocolError("vehicle sync detail is invalid")
    result = dict(payload)
    if schema == 2:
        result["schedule"] = validate_vehicle_schedule(payload["schedule"], release=False)
    return result
