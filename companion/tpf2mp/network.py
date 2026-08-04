from __future__ import annotations

import socket
import re
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO, Mapping

from .bridge import AuditLog, GameBridge
from .checkpoint import verify_checkpoint
from .protocol import (
    MAX_PROPOSAL_OUTPUTS,
    PROTOCOL_VERSION,
    ProtocolError,
    decode_line,
    encode_line,
    hello,
    sign,
    validate_action,
    validate_envelope,
)

HOST_AUTHORITY_ACTIONS = {
    "match.initialise",
    "match.finish",
    "world.freeze",
    "line.register",
    "economy.seed_demo",
    "economy.settle",
    "probe.mobility",
    "finance.toggle_neutralizer",
}


def _read_frame(reader: BinaryIO) -> dict[str, Any]:
    raw = reader.readline()
    if not raw:
        raise ConnectionError("peer closed the connection")
    if len(raw) > 4 * 1024 * 1024:
        raise ProtocolError("frame exceeds 4 MiB")
    return decode_line(raw)


def _send(sock: socket.socket, message: Mapping[str, Any], lock: threading.Lock | None = None) -> None:
    payload = encode_line(message)
    if lock is None:
        sock.sendall(payload)
    else:
        with lock:
            sock.sendall(payload)


@dataclass
class ConnectedPeer:
    peer: str
    sock: socket.socket
    send_lock: threading.Lock


class CommitHost:
    def __init__(
        self,
        bridge: GameBridge,
        bind: str,
        port: int,
        audit_path: Path,
        match_fingerprint: str | None = None,
        required_peers: tuple[str, ...] | None = None,
        completion_timeout: float = 45.0,
        require_connected_peers: bool = True,
    ) -> None:
        self.bridge = bridge
        self.bind = bind
        self.port = port
        self.audit = AuditLog(audit_path)
        self.match_fingerprint = match_fingerprint
        self.stop = threading.Event()
        self.order_lock = threading.RLock()
        self.peers_lock = threading.Lock()
        self.peers: dict[str, ConnectedPeer] = {}
        self.seen: set[tuple[str, int]] = set()
        self.commits: dict[int, dict[str, Any]] = {}
        self.ack_digests: dict[int, dict[str, str]] = {}
        self.mobility_digests: dict[str, dict[str, str]] = {}
        self.mobility_outcomes: dict[str, str] = {}
        self.clock_requested_speed = 0
        self.clock_effective_speed = 0
        self.clock_generation = 0
        self.clock_controls: dict[int, dict[str, Any]] = {}
        self.clock_health: dict[str, dict[str, Any]] = {}
        self.clock_last_adjustment = 0.0
        self.clock_healthy_since: float | None = None
        configured_peers = set(required_peers or ("player1", "player2"))
        configured_peers.add(self.bridge.peer)
        self.required_peers = tuple(sorted(configured_peers))
        self.completion_timeout = max(1.0, float(completion_timeout))
        self.require_connected_peers = bool(require_connected_peers)
        self.proposal_prepares: dict[int, dict[str, Any]] = {}
        self.proposal_consensus: dict[int, dict[str, Any]] = {}
        self.operation_consensus: dict[int, dict[str, Any]] = {}
        self.checkpoint_consensus: dict[int, dict[str, Any]] = {}
        self.last_agreed_checkpoint: dict[str, Any] | None = None
        self.session_fault: str | None = None
        self.status = "starting"
        self.last_error: str | None = None
        self.next_seq = 1
        self._load_audit()
        for tracker in list(self.proposal_prepares.values()):
            if tracker.get("status") == "pending":
                self._resolve_prepare_locked(tracker)

    def _write_status(self, status: str | None = None) -> None:
        if status is not None:
            self.status = status
        with self.peers_lock:
            connected = sorted(self.peers)
        pending_proposal = self._pending_proposal()
        pending_prepare = self._pending_prepare()
        pending_operation = self._pending_operation()
        pending_checkpoint = self._pending_checkpoint()
        self.bridge.write_status(
            {
                "role": "host",
                "status": self.status,
                "listening": self.status == "running",
                "connected": all(
                    peer == self.bridge.peer or peer in connected
                    for peer in self.required_peers
                ),
                "bind": self.bind,
                "port": self.port,
                "connectedPeers": connected,
                "requiredPeers": list(self.required_peers),
                "nextCommitSeq": self.next_seq,
                "outboxCursor": self.bridge.outbox_cursor,
                "pendingProposalPrepareSeq": pending_prepare and pending_prepare.get("prepareSeq"),
                "pendingProposalSeq": pending_proposal and pending_proposal.get("commitSeq"),
                "pendingOperationSeq": pending_operation and pending_operation.get("commitSeq"),
                "pendingCheckpointSeq": pending_checkpoint and pending_checkpoint.get("boundarySeq"),
                "lastAgreedCheckpointSeq": self.last_agreed_checkpoint
                and self.last_agreed_checkpoint.get("boundarySeq"),
                "sessionFault": self.session_fault,
                "lastError": self.last_error,
                "matchFingerprint": self.match_fingerprint,
                "mobilityOutcomes": dict(self.mobility_outcomes),
                "clock": {
                    "requestedSpeed": self.clock_requested_speed,
                    "effectiveSpeed": self.clock_effective_speed,
                    "generation": self.clock_generation,
                    "pendingSeq": self._pending_clock_seq(),
                    "healthPeers": sorted(self.clock_health),
                },
            }
        )

    def _load_audit(self) -> None:
        for message in self.audit.messages():
            if message.get("session") != self.bridge.session:
                continue
            if message.get("kind") in {"commit", "control"}:
                seq = int(message["seq"])
                self.commits[seq] = message
                self.next_seq = max(self.next_seq, seq + 1)
                if message.get("kind") == "commit":
                    self.seen.add((str(message.get("origin_peer")), int(message.get("origin_local_seq", -1))))
                    action = message.get("payload", {}).get("action", {})
                    if action.get("type") == "proposal.prepare":
                        self._track_proposal_prepare(message)
                    elif action.get("type") == "proposal.build":
                        self._track_proposal(message)
                        prepared_from = int(message.get("prepared_from_seq", 0))
                        prepared = self.proposal_prepares.get(prepared_from)
                        if prepared:
                            prepared["status"] = "committed"
                            prepared["buildSeq"] = seq
                    elif action.get("type") == "clock.set":
                        self._track_clock(message)
                    elif action.get("type") == "operation.execute":
                        self._track_operation(message)
                    elif action.get("type") == "match.initialise":
                        self._track_checkpoint_boundary(seq, "match-initialised")
                else:
                    action = message.get("payload", {}).get("action", {})
                    if action.get("type") == "network.proposal_prepare_outcome":
                        prepare_seq = int(action.get("prepareSeq", 0))
                        tracker = self.proposal_prepares.get(prepare_seq)
                        if tracker:
                            tracker["status"] = "committed" if action.get("success") else "rejected"
                            tracker["outcome"] = dict(action)
                    elif action.get("type") == "network.proposal_outcome":
                        commit_seq = int(action.get("commitSeq", 0))
                        tracker = self.proposal_consensus.get(commit_seq)
                        if tracker:
                            tracker["status"] = "complete" if action.get("success") else "faulted"
                            tracker["outcome"] = dict(action)
                        if not action.get("success"):
                            self.session_fault = str(action.get("errorCode") or "proposal-consensus-failed")
                        else:
                            self._track_checkpoint_boundary(
                                seq,
                                f"physical-consensus:{action.get('proposalId')}",
                                str(action.get("proposalId", "")),
                            )
                    elif action.get("type") == "network.operation_outcome":
                        commit_seq = int(action.get("commitSeq", 0))
                        tracker = self.operation_consensus.get(commit_seq)
                        if tracker:
                            tracker["status"] = "complete" if action.get("success") else "faulted"
                            tracker["outcome"] = dict(action)
                        if not action.get("success"):
                            self.session_fault = str(
                                action.get("errorCode") or "operation-consensus-failed"
                            )
                        else:
                            self._track_checkpoint_boundary(
                                seq,
                                f"operation-consensus:{action.get('operationId')}",
                                str(action.get("operationId", "")),
                            )
                    elif action.get("type") == "network.checkpoint_outcome":
                        boundary_seq = int(action.get("boundarySeq", 0))
                        tracker = self.checkpoint_consensus.get(boundary_seq)
                        if tracker:
                            tracker["status"] = "complete" if action.get("success") else "faulted"
                            tracker["outcome"] = dict(action)
                        if action.get("success"):
                            self.last_agreed_checkpoint = dict(action)
                        else:
                            self.session_fault = str(action.get("errorCode") or "checkpoint-consensus-failed")
            elif message.get("kind") == "record" and message.get("record_type") == "completion":
                payload = message.get("payload", {})
                commit_seq = int(payload.get("commitSeq", 0))
                tracker = self.proposal_consensus.get(commit_seq)
                if tracker:
                    tracker["completions"][str(message.get("peer", "unknown"))] = dict(payload)
            elif message.get("kind") == "record" and message.get("record_type") == "operation_completion":
                payload = message.get("payload", {})
                commit_seq = int(payload.get("commitSeq", 0))
                tracker = self.operation_consensus.get(commit_seq)
                if tracker:
                    tracker["completions"][str(message.get("peer", "unknown"))] = dict(payload)
            elif message.get("kind") == "record" and message.get("record_type") == "checkpoint":
                payload = verify_checkpoint(message.get("payload", {}))
                boundary_seq = int(payload["eventCursor"]["lastCommitSeq"])
                tracker = self.checkpoint_consensus.get(boundary_seq)
                if tracker:
                    if payload.get("checkpointVersion") != 2:
                        raise ProtocolError("network checkpoint audit uses a legacy checkpoint format")
                    tracker["checkpoints"][str(message.get("peer", "unknown"))] = payload
            elif message.get("kind") == "record" and message.get("record_type") == "ack":
                payload = message.get("payload", {})
                prepare_seq = int(payload.get("commitSeq", 0))
                tracker = self.proposal_prepares.get(prepare_seq)
                peer = str(message.get("peer", "unknown"))
                if tracker and peer in tracker["requiredPeers"]:
                    tracker["acks"][peer] = {
                        "success": payload.get("success") is True,
                        "digest": payload.get("digest"),
                        "error": payload.get("error"),
                    }
                clock_tracker = self.clock_controls.get(prepare_seq)
                if clock_tracker and peer in clock_tracker["requiredPeers"]:
                    clock_tracker["acks"][peer] = {
                        "success": payload.get("success") is True,
                        "digest": payload.get("digest"),
                        "error": payload.get("error"),
                    }
                    if set(clock_tracker["requiredPeers"]) <= set(clock_tracker["acks"]):
                        clock_tracker["status"] = (
                            "complete"
                            if all(item["success"] for item in clock_tracker["acks"].values())
                            else "faulted"
                        )

    def _track_proposal_prepare(self, commit: Mapping[str, Any]) -> dict[str, Any]:
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
                "deadline": time.monotonic() + self.completion_timeout,
            }
            self.proposal_prepares[seq] = tracker
        return tracker

    def _track_clock(self, commit: Mapping[str, Any]) -> dict[str, Any]:
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
                "deadline": time.monotonic() + min(self.completion_timeout, 10.0),
            }
            self.clock_controls[seq] = tracker
            self.clock_last_adjustment = time.monotonic()
        self.clock_requested_speed = tracker["requestedSpeed"]
        self.clock_effective_speed = tracker["effectiveSpeed"]
        self.clock_generation = max(self.clock_generation, tracker["generation"])
        return tracker

    def _pending_clock_seq(self) -> int | None:
        pending = [
            seq for seq, tracker in self.clock_controls.items()
            if tracker.get("status") == "pending"
        ]
        return min(pending) if pending else None

    def _track_proposal(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        transaction = action.get("transaction", {})
        tracker = self.proposal_consensus.get(seq)
        if tracker is None:
            tracker = {
                "commitSeq": seq,
                "proposalId": f"{self.bridge.session}:{commit.get('origin_peer')}:{seq}",
                "originPeer": str(commit.get("origin_peer")),
                "proposalDigest": transaction.get("digest"),
                "requiredPeers": self.required_peers,
                "completions": {},
                "status": "pending",
                "deadline": time.monotonic() + self.completion_timeout,
            }
            self.proposal_consensus[seq] = tracker
        return tracker

    def _track_operation(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        seq = int(commit["seq"])
        action = commit.get("payload", {}).get("action", {})
        transaction = action.get("transaction", {})
        tracker = self.operation_consensus.get(seq)
        if tracker is None:
            tracker = {
                "commitSeq": seq,
                "operationId": f"{self.bridge.session}:{commit.get('origin_peer')}:{seq}",
                "originPeer": str(commit.get("origin_peer")),
                "operationDigest": transaction.get("digest"),
                "operationKind": transaction.get("kind"),
                "requiredPeers": self.required_peers,
                "completions": {},
                "status": "pending",
                "deadline": time.monotonic() + self.completion_timeout,
            }
            self.operation_consensus[seq] = tracker
        return tracker

    def _track_checkpoint_boundary(
        self,
        boundary_seq: int,
        reason: str,
        proposal_id: str | None = None,
    ) -> dict[str, Any]:
        tracker = self.checkpoint_consensus.get(boundary_seq)
        if tracker is None:
            tracker = {
                "boundarySeq": int(boundary_seq),
                "reason": str(reason),
                "proposalId": proposal_id,
                "requiredPeers": self.required_peers,
                "checkpoints": {},
                "status": "pending",
                "deadline": time.monotonic() + self.completion_timeout,
            }
            self.checkpoint_consensus[int(boundary_seq)] = tracker
        return tracker

    def _pending_proposal(self) -> dict[str, Any] | None:
        for seq in sorted(self.proposal_consensus):
            tracker = self.proposal_consensus[seq]
            if tracker.get("status") == "pending":
                return tracker
        return None

    def _pending_prepare(self) -> dict[str, Any] | None:
        for seq in sorted(self.proposal_prepares):
            tracker = self.proposal_prepares[seq]
            if tracker.get("status") == "pending":
                return tracker
        return None

    def _pending_operation(self) -> dict[str, Any] | None:
        for seq in sorted(self.operation_consensus):
            tracker = self.operation_consensus[seq]
            if tracker.get("status") == "pending":
                return tracker
        return None

    def _pending_checkpoint(self) -> dict[str, Any] | None:
        for seq in sorted(self.checkpoint_consensus):
            tracker = self.checkpoint_consensus[seq]
            if tracker.get("status") == "pending":
                return tracker
        return None

    def _commit(self, intent: Mapping[str, Any]) -> dict[str, Any] | None:
        validate_envelope(intent, self.bridge.session)
        if intent.get("kind") != "intent":
            return None
        origin = str(intent.get("peer"))
        local_seq = int(intent.get("local_seq", -1))
        key = (origin, local_seq)
        with self.order_lock:
            if key in self.seen:
                for commit in self.commits.values():
                    if (commit.get("origin_peer"), commit.get("origin_local_seq")) == key:
                        return commit
                return None
            action = validate_action(intent.get("payload", {}).get("action"))
            clock_request = action["type"] == "clock.request"
            emergency_pause = clock_request and action["requestedSpeed"] == 0
            if self.session_fault and not emergency_pause:
                raise ProtocolError(f"session is faulted: {self.session_fault}")
            if not clock_request:
                pending_prepare = self._pending_prepare()
                if pending_prepare:
                    raise ProtocolError(
                        f"proposal prepare {pending_prepare['prepareSeq']} is awaiting all-peer readiness"
                    )
                pending = self._pending_proposal()
                if pending:
                    raise ProtocolError(
                        f"physical proposal {pending['proposalId']} is awaiting completion consensus"
                    )
                pending_operation = self._pending_operation()
                if pending_operation:
                    raise ProtocolError(
                        f"physical operation {pending_operation['operationId']} is awaiting completion consensus"
                    )
                checkpoint_pending = self._pending_checkpoint()
                if checkpoint_pending:
                    raise ProtocolError(
                        f"checkpoint boundary {checkpoint_pending['boundarySeq']} is awaiting peer consensus"
                    )
            if action["type"] in HOST_AUTHORITY_ACTIONS and origin != self.bridge.peer:
                raise ProtocolError(f"{action['type']} may only originate from host peer {self.bridge.peer}")
            if action["type"] == "proposal.build":
                raise ProtocolError("proposal.build is host-generated; submit proposal.prepare first")
            if action["type"] == "clock.set":
                raise ProtocolError("clock.set is host-generated; submit clock.request")
            if clock_request and not emergency_pause and self.require_connected_peers:
                with self.peers_lock:
                    connected = set(self.peers)
                missing = sorted(set(self.required_peers) - {self.bridge.peer} - connected)
                if missing:
                    raise ProtocolError(
                        "cannot resume the shared clock while peers are disconnected: "
                        + ", ".join(missing)
                    )
            if action["type"] in {"match.initialise", "proposal.prepare", "operation.execute"}:
                if self.require_connected_peers:
                    with self.peers_lock:
                        connected = set(self.peers)
                    missing = sorted(set(self.required_peers) - {self.bridge.peer} - connected)
                    if missing:
                        raise ProtocolError(
                            "cannot commit a consensus-bound action while peers are disconnected: "
                            + ", ".join(missing)
                        )
            if action["type"] == "proposal.prepare":
                peer_number = re.fullmatch(r"player([1-9][0-9]*)", origin)
                expected_company = f"company:{peer_number.group(1)}" if peer_number else None
                actual_company = action["transaction"]["companyCid"]
                if expected_company and actual_company != expected_company:
                    raise ProtocolError(
                        f"proposal.prepare from {origin} must act for {expected_company}, not {actual_company}"
                    )
            if action["type"] == "operation.execute":
                peer_number = re.fullmatch(r"player([1-9][0-9]*)", origin)
                expected_company = f"company:{peer_number.group(1)}" if peer_number else None
                actual_company = action["transaction"]["companyCid"]
                if expected_company and actual_company != expected_company:
                    raise ProtocolError(
                        f"operation.execute from {origin} must act for {expected_company}, "
                        f"not {actual_company}"
                    )
                origin_token = action.get("originCaptureToken")
                if origin_token is not None and not (
                    origin_token.startswith(f"{origin}:line-origin:")
                    or origin_token.startswith(f"{origin}:operation-origin:")
                ):
                    raise ProtocolError(
                        "operation.execute optimistic-origin token must belong to its origin peer"
                    )
            if clock_request:
                requested = int(action["requestedSpeed"])
                self.clock_generation += 1
                effective = requested
                action = validate_action(
                    {
                        "type": "clock.set",
                        "requestedSpeed": requested,
                        "effectiveSpeed": effective,
                        "generation": self.clock_generation,
                        "reason": f"player-request:{origin}",
                    }
                )
            seq = self.next_seq
            self.next_seq += 1
            commit = sign(
                {
                    "protocol": PROTOCOL_VERSION,
                    "session": self.bridge.session,
                    "seq": seq,
                    "kind": "commit",
                    "origin_peer": origin,
                    "origin_local_seq": local_seq,
                    "tick": int(intent.get("tick", 0)),
                    "payload": {"action": action},
                }
            )
            self.audit.append(commit)
            self.seen.add(key)
            self.commits[seq] = commit
            if action["type"] == "proposal.prepare":
                self._track_proposal_prepare(commit)
            elif action["type"] == "proposal.build":
                self._track_proposal(commit)
            elif action["type"] == "operation.execute":
                self._track_operation(commit)
            elif action["type"] == "match.initialise":
                self._track_checkpoint_boundary(seq, "match-initialised")
            elif action["type"] == "clock.set":
                self._track_clock(commit)
            self.bridge.write_inbound(commit)
        self._broadcast(commit)
        return commit

    def _reject_intent(
        self, intent: Mapping[str, Any], reason: str
    ) -> dict[str, Any] | None:
        """Order a non-mutating rejection so the origin can release its barrier.

        A receipt only acknowledges the companion's disk/network transport.  The
        game process cannot see it, so without this ordered control it keeps its
        ``networkIntentAwaitingOrder`` latch forever after a protocol rejection.
        Rejections use the shared sequence stream and are replayable from audit,
        just like the existing consensus outcome controls.
        """
        validate_envelope(intent, self.bridge.session)
        if intent.get("kind") != "intent":
            return None
        origin = str(intent.get("peer", ""))
        local_seq = int(intent.get("local_seq", -1))
        if not origin or local_seq < 1:
            raise ProtocolError("rejected intent has invalid origin identity")
        source_action = intent.get("payload", {}).get("action", {})
        action_type = str(source_action.get("type", "unknown"))[:128]
        error_code = str(reason or "intent-rejected")[:512]
        with self.order_lock:
            for ordered in self.commits.values():
                action = ordered.get("payload", {}).get("action", {})
                if (
                    ordered.get("kind") == "control"
                    and action.get("type") == "network.intent_rejected"
                    and action.get("originPeer") == origin
                    and int(action.get("originLocalSeq", -1)) == local_seq
                ):
                    return ordered
            seq = self.next_seq
            self.next_seq += 1
            action = {
                "type": "network.intent_rejected",
                "originPeer": origin,
                "originLocalSeq": local_seq,
                "actionType": action_type,
                "errorCode": error_code,
            }
            control = sign(
                {
                    "protocol": PROTOCOL_VERSION,
                    "session": self.bridge.session,
                    "seq": seq,
                    "kind": "control",
                    "origin_peer": self.bridge.peer,
                    "tick": int(intent.get("tick", 0)),
                    "payload": {"action": action},
                }
            )
            self.last_error = error_code
            self.audit.append(control)
            self.commits[seq] = control
            self.bridge.write_inbound(control)
            self._broadcast(control)
            return control

    @staticmethod
    def _completion_payload(payload: Any) -> dict[str, Any]:
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
        # Failed Lua completions have no output slots, so the deterministic
        # game encoder spells the empty table as `{}`. Preserve that spelling
        # for the peer result digest but treat it as an empty sequence during
        # validation. A non-empty object is never a valid output collection.
        lua_empty_outputs = isinstance(outputs, dict) and not outputs
        if (not isinstance(outputs, list) and not lua_empty_outputs) or len(outputs) > MAX_PROPOSAL_OUTPUTS:
            raise ProtocolError("proposal completion outputs are invalid")
        for output in [] if lua_empty_outputs else outputs:
            if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
                raise ProtocolError("proposal completion output is malformed")
            if output["kind"] not in {
                "node", "edge", "edge_object", "construction", "station", "station_group", "depot", "asset",
            }:
                raise ProtocolError("proposal completion output kind is unsupported")
            if not isinstance(output["cid"], str) or not output["cid"].startswith(output["kind"] + ":"):
                raise ProtocolError("proposal completion output has a non-canonical id")
            if not isinstance(output["slot"], str) or not output["slot"].startswith(output["kind"] + ":"):
                raise ProtocolError("proposal completion output has an invalid slot")
        if "errorCode" in payload and not isinstance(payload["errorCode"], str):
            raise ProtocolError("proposal completion errorCode must be a string")
        if payload["success"]:
            finance_delta = payload.get("financeDelta")
            if not isinstance(finance_delta, int) or isinstance(finance_delta, bool):
                raise ProtocolError("successful proposal completion requires integer financeDelta")
        return dict(payload)

    @staticmethod
    def _operation_completion_payload(payload: Any) -> dict[str, Any]:
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
        # Delete/update operations and failures can legitimately produce no
        # canonical output object; Lua encodes that empty table as `{}`.
        lua_empty_outputs = isinstance(outputs, dict) and not outputs
        if (not isinstance(outputs, list) and not lua_empty_outputs) or len(outputs) > 1:
            raise ProtocolError("operation completion outputs are invalid")
        for output in [] if lua_empty_outputs else outputs:
            if not isinstance(output, dict) or set(output) != {"kind", "cid", "slot"}:
                raise ProtocolError("operation completion output is malformed")
            if output["kind"] not in {"line", "vehicle"}:
                raise ProtocolError("operation completion output kind is unsupported")
            if not isinstance(output["cid"], str) or not output["cid"].startswith(output["kind"] + ":"):
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

    def _record_message(self, message: Mapping[str, Any]) -> dict[str, Any]:
        return sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "kind": "record",
                "peer": str(message.get("peer", "unknown")),
                "local_seq": int(message.get("local_seq", 0)),
                "record_type": str(message.get("kind", "unknown")),
                "payload": message.get("payload", {}),
            }
        )

    def _emit_prepare_rejection_locked(
        self,
        tracker: dict[str, Any],
        error_code: str,
    ) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        action = {
            "type": "network.proposal_prepare_outcome",
            "prepareSeq": tracker["prepareSeq"],
            "proposalDigest": tracker["proposalDigest"],
            "success": False,
            "errorCode": str(error_code)[:512],
            "peers": list(tracker["requiredPeers"]),
        }
        seq = self.next_seq
        self.next_seq += 1
        control = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "control",
                "origin_peer": self.bridge.peer,
                "tick": 0,
                "payload": {"action": action},
            }
        )
        tracker["status"] = "rejected"
        tracker["outcome"] = dict(action)
        self.last_error = action["errorCode"]
        self.audit.append(control)
        self.commits[seq] = control
        self.bridge.write_inbound(control)
        self._broadcast(control)
        print(
            f"proposal prepare {tracker['prepareSeq']} rejected without world mutation: "
            f"{action['errorCode']}"
        )
        return control

    def _commit_prepared_proposal_locked(self, tracker: dict[str, Any]) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            build_seq = tracker.get("buildSeq")
            return dict(self.commits.get(build_seq, {})) if build_seq else {}
        action = validate_action(
            {"type": "proposal.build", "transaction": tracker["transaction"]}
        )
        seq = self.next_seq
        self.next_seq += 1
        commit = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "commit",
                "origin_peer": tracker["originPeer"],
                "origin_local_seq": tracker["originLocalSeq"],
                "prepared_from_seq": tracker["prepareSeq"],
                "tick": tracker["originTick"],
                "payload": {"action": action},
            }
        )
        tracker["status"] = "committed"
        tracker["buildSeq"] = seq
        self.audit.append(commit)
        self.commits[seq] = commit
        self._track_proposal(commit)
        self.bridge.write_inbound(commit)
        self._broadcast(commit)
        print(
            f"proposal prepare {tracker['prepareSeq']} passed on all peers; "
            f"committed build {seq}"
        )
        return commit

    def _resolve_prepare_locked(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        acknowledgements = tracker["acks"]
        if not required <= set(acknowledgements):
            return
        selected = [acknowledgements[peer] for peer in tracker["requiredPeers"]]
        failed = [
            (peer, acknowledgements[peer])
            for peer in tracker["requiredPeers"]
            if acknowledgements[peer].get("success") is not True
        ]
        if failed:
            peer, acknowledgement = failed[0]
            detail = acknowledgement.get("error") or "local readiness check failed"
            self._emit_prepare_rejection_locked(
                tracker, f"proposal-prepare-rejected:{peer}:{detail}"
            )
            return
        digests = {item.get("digest") for item in selected}
        if None in digests or len(digests) != 1:
            self._emit_prepare_rejection_locked(
                tracker, "proposal-prepare-core-digest-mismatch"
            )
            return
        self._commit_prepared_proposal_locked(tracker)

    def _emit_clock_commit_locked(
        self,
        requested_speed: int,
        effective_speed: int,
        reason: str,
    ) -> dict[str, Any]:
        requested_speed = max(0, min(4, int(requested_speed)))
        effective_speed = max(0, min(requested_speed, int(effective_speed)))
        self.clock_generation += 1
        action = validate_action(
            {
                "type": "clock.set",
                "requestedSpeed": requested_speed,
                "effectiveSpeed": effective_speed,
                "generation": self.clock_generation,
                "reason": str(reason)[:160] or "host-adjustment",
            }
        )
        seq = self.next_seq
        self.next_seq += 1
        commit = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "commit",
                "origin_peer": self.bridge.peer,
                "origin_local_seq": -self.clock_generation,
                "clock_control": True,
                "tick": 0,
                "payload": {"action": action},
            }
        )
        self.audit.append(commit)
        self.commits[seq] = commit
        self._track_clock(commit)
        self.clock_last_adjustment = time.monotonic()
        self.bridge.write_inbound(commit)
        self._broadcast(commit)
        print(
            f"shared clock requested={requested_speed} effective={effective_speed}: {reason}"
        )
        return commit

    def _resolve_clock_ack_locked(
        self,
        tracker: dict[str, Any],
        peer: str,
        acknowledgement: dict[str, Any],
    ) -> None:
        previous = tracker["acks"].get(peer)
        if previous and previous != acknowledgement:
            raise ProtocolError(f"peer {peer} sent conflicting clock acknowledgements")
        tracker["acks"][peer] = acknowledgement
        if set(tracker["requiredPeers"]) - set(tracker["acks"]):
            return
        failed = [
            name for name in tracker["requiredPeers"]
            if tracker["acks"][name].get("success") is not True
        ]
        if not failed:
            tracker["status"] = "complete"
            return
        tracker["status"] = "faulted"
        self.last_error = "clock-command-rejected:" + ",".join(failed)
        if (
            tracker["generation"] == self.clock_generation
            and tracker["effectiveSpeed"] != 0
        ):
            self._emit_clock_commit_locked(
                tracker["requestedSpeed"], 0, self.last_error + ":resync-pause"
            )

    @staticmethod
    def _clock_health_payload(payload: Any) -> dict[str, Any]:
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

    def _record_clock_health_locked(self, message: Mapping[str, Any]) -> None:
        peer = str(message.get("peer", "unknown"))
        if peer not in self.required_peers:
            raise ProtocolError(f"clock health came from unexpected peer {peer}")
        payload = self._clock_health_payload(message.get("payload"))
        now = time.monotonic()
        prior = self.clock_health.get(peer)
        sample: dict[str, Any] = dict(payload)
        sample["receivedAt"] = now
        if prior:
            elapsed = now - float(prior["receivedAt"])
            if elapsed > 0:
                sample["tickRate"] = max(
                    0.0, (payload["engineTick"] - prior["engineTick"]) / elapsed
                )
                if payload.get("gameTime") is not None and prior.get("gameTime") is not None:
                    sample["gameRate"] = (
                        float(payload["gameTime"]) - float(prior["gameTime"])
                    ) / elapsed
        self.clock_health[peer] = sample
        self._maybe_adjust_clock_locked(now)

    def _maybe_adjust_clock_locked(self, now: float | None = None) -> None:
        now = time.monotonic() if now is None else now
        if self.clock_requested_speed == 0 or self._pending_clock_seq() is not None:
            return
        samples = [self.clock_health.get(peer) for peer in self.required_peers]
        missing = any(sample is None for sample in samples)
        stale = [
            now - float(sample["receivedAt"])
            for sample in samples if sample is not None
        ]
        max_stale = max(stale, default=0.0)
        latest_seq = max(0, self.next_seq - 1)
        backlogs = [
            max(0, latest_seq - int(sample.get("lastCommitSeq", 0)))
            for sample in samples if sample is not None
        ]
        max_backlog = max(backlogs, default=0)
        rates = [
            float(sample["tickRate"])
            for sample in samples if sample is not None and sample.get("tickRate") is not None
        ]
        rate_ratio = min(rates) / max(rates) if len(rates) >= 2 and max(rates) > 0 else 1.0
        observed_mismatch = any(
            sample is not None
            and sample.get("observedSpeed") is not None
            and abs(float(sample["observedSpeed"]) - self.clock_effective_speed) > 0.1
            for sample in samples
        )
        low_rate = any(rate < 2.0 for rate in rates)
        unhealthy = (
            missing and now - self.clock_last_adjustment > 9.0
        ) or max_stale > 6.0 or max_backlog > 2 or rate_ratio < 0.65 or low_rate or observed_mismatch
        severe = max_stale > 12.0 or max_backlog > 6
        if unhealthy:
            self.clock_healthy_since = None
            if now - self.clock_last_adjustment < 3.0:
                return
            target = 0 if severe else max(1, self.clock_effective_speed - 1)
            if target != self.clock_effective_speed:
                reason = "adaptive-resync-pause" if severe else "adaptive-slowest-peer-cap"
                self._emit_clock_commit_locked(self.clock_requested_speed, target, reason)
            return
        if self.clock_healthy_since is None:
            self.clock_healthy_since = now
            return
        if (
            self.clock_effective_speed < self.clock_requested_speed
            and now - self.clock_healthy_since >= 12.0
            and now - self.clock_last_adjustment >= 4.0
        ):
            self._emit_clock_commit_locked(
                self.clock_requested_speed,
                self.clock_effective_speed + 1,
                "adaptive-recovery-step",
            )
            self.clock_healthy_since = now

    def _emit_proposal_outcome_locked(
        self,
        tracker: dict[str, Any],
        success: bool,
        error_code: str | None = None,
    ) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        completions = tracker["completions"]
        result_digests = {item["resultDigest"] for item in completions.values() if item.get("resultDigest")}
        core_digests = {item["coreDigest"] for item in completions.values() if item.get("coreDigest")}
        result_digest = next(iter(result_digests)) if len(result_digests) == 1 else ""
        core_digest = next(iter(core_digests)) if len(core_digests) == 1 else ""
        action = {
            "type": "network.proposal_outcome",
            "proposalId": tracker["proposalId"],
            "commitSeq": tracker["commitSeq"],
            "proposalDigest": tracker["proposalDigest"],
            "success": bool(success),
            "resultDigest": result_digest,
            "coreDigest": core_digest,
            "peers": list(tracker["requiredPeers"]),
        }
        if success:
            # Build 35924 can charge a proposal only on the machine where its
            # canonical company is also the native command issuer.  Physical
            # results must agree, but native wallet deltas need not.  The
            # proposal origin is authoritative and every peer normalizes to
            # that delta while applying this ordered control.
            origin_completion = completions.get(tracker.get("originPeer"))
            if origin_completion is None:
                raise ProtocolError("proposal origin has no physical completion")
            action["financeDelta"] = origin_completion["financeDelta"]
        if not success:
            action["errorCode"] = str(error_code or "proposal-consensus-failed")
        seq = self.next_seq
        self.next_seq += 1
        control = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "control",
                "origin_peer": self.bridge.peer,
                "tick": 0,
                "payload": {"action": action},
            }
        )
        tracker["status"] = "complete" if success else "faulted"
        tracker["outcome"] = dict(action)
        if not success:
            self.session_fault = action["errorCode"]
        else:
            self._track_checkpoint_boundary(
                seq,
                f"physical-consensus:{tracker['proposalId']}",
                tracker["proposalId"],
            )
        self.audit.append(control)
        self.commits[seq] = control
        self.bridge.write_inbound(control)
        self._broadcast(control)
        if success:
            print(f"proposal {tracker['proposalId']} physically converged at {result_digest}")
        else:
            print(f"PROPOSAL CONSENSUS FAULT {tracker['proposalId']}: {action['errorCode']}")
        return control

    def _resolve_proposal_locked(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        completions = tracker["completions"]
        if not required <= set(completions):
            return
        selected = [completions[peer] for peer in tracker["requiredPeers"]]
        if any(item.get("success") is not True for item in selected):
            self._emit_proposal_outcome_locked(tracker, False, "peer-native-proposal-failed")
            return
        if any(item.get("proposalDigest") != tracker["proposalDigest"] for item in selected):
            self._emit_proposal_outcome_locked(tracker, False, "proposal-digest-mismatch")
            return
        if len({item["resultDigest"] for item in selected}) != 1:
            self._emit_proposal_outcome_locked(tracker, False, "physical-result-digest-mismatch")
            return
        if len({item["coreDigest"] for item in selected}) != 1:
            self._emit_proposal_outcome_locked(tracker, False, "physical-core-digest-mismatch")
            return
        self._emit_proposal_outcome_locked(tracker, True)

    def _emit_operation_outcome_locked(
        self,
        tracker: dict[str, Any],
        success: bool,
        error_code: str | None = None,
    ) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        completions = tracker["completions"]
        result_digests = {
            item["resultDigest"] for item in completions.values() if item.get("resultDigest")
        }
        core_digests = {
            item["coreDigest"] for item in completions.values() if item.get("coreDigest")
        }
        action: dict[str, Any] = {
            "type": "network.operation_outcome",
            "operationId": tracker["operationId"],
            "commitSeq": tracker["commitSeq"],
            "operationDigest": tracker["operationDigest"],
            "success": bool(success),
            "resultDigest": next(iter(result_digests)) if len(result_digests) == 1 else "",
            "coreDigest": next(iter(core_digests)) if len(core_digests) == 1 else "",
            "peers": list(tracker["requiredPeers"]),
        }
        if success:
            origin_completion = completions.get(tracker.get("originPeer"))
            if origin_completion is None:
                raise ProtocolError("operation origin has no physical completion")
            action["financeDelta"] = origin_completion["financeDelta"]
        else:
            action["errorCode"] = str(error_code or "operation-consensus-failed")
        seq = self.next_seq
        self.next_seq += 1
        control = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "control",
                "origin_peer": self.bridge.peer,
                "tick": 0,
                "payload": {"action": action},
            }
        )
        tracker["status"] = "complete" if success else "faulted"
        tracker["outcome"] = dict(action)
        if not success:
            self.session_fault = action["errorCode"]
        else:
            self._track_checkpoint_boundary(
                seq,
                f"operation-consensus:{tracker['operationId']}",
                tracker["operationId"],
            )
        self.audit.append(control)
        self.commits[seq] = control
        self.bridge.write_inbound(control)
        self._broadcast(control)
        if success:
            print(
                f"operation {tracker['operationId']} physically converged at "
                f"{action['resultDigest']}"
            )
        else:
            print(
                f"OPERATION CONSENSUS FAULT {tracker['operationId']}: "
                f"{action['errorCode']}"
            )
        return control

    def _resolve_operation_locked(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        completions = tracker["completions"]
        if not required <= set(completions):
            return
        selected = [completions[peer] for peer in tracker["requiredPeers"]]
        if any(item.get("success") is not True for item in selected):
            self._emit_operation_outcome_locked(tracker, False, "peer-native-operation-failed")
            return
        if any(item.get("operationDigest") != tracker["operationDigest"] for item in selected):
            self._emit_operation_outcome_locked(tracker, False, "operation-digest-mismatch")
            return
        if len({item["resultDigest"] for item in selected}) != 1:
            self._emit_operation_outcome_locked(
                tracker, False, "operation-physical-result-digest-mismatch"
            )
            return
        if len({item["coreDigest"] for item in selected}) != 1:
            self._emit_operation_outcome_locked(
                tracker, False, "operation-physical-core-digest-mismatch"
            )
            return
        self._emit_operation_outcome_locked(tracker, True)

    def _emit_checkpoint_outcome_locked(
        self,
        tracker: dict[str, Any],
        success: bool,
        error_code: str | None = None,
    ) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        checkpoints = tracker["checkpoints"]
        convergence_keys = {
            item["convergenceKey"] for item in checkpoints.values() if item.get("convergenceKey")
        }
        core_digests = {item["coreDigest"] for item in checkpoints.values() if item.get("coreDigest")}
        model_digests = {item["modelDigest"] for item in checkpoints.values() if item.get("modelDigest")}
        canonical_digests = {
            item["canonicalDigest"] for item in checkpoints.values() if item.get("canonicalDigest")
        }
        financial_digests = {
            item["financialDigest"] for item in checkpoints.values() if item.get("financialDigest")
        }
        structural_digests = {
            item["structuralDigest"] for item in checkpoints.values() if item.get("structuralDigest")
        }
        world_manifest_digests = {
            item["worldManifestDigest"]
            for item in checkpoints.values()
            if item.get("worldManifestDigest")
        }
        action: dict[str, Any] = {
            "type": "network.checkpoint_outcome",
            "boundarySeq": tracker["boundarySeq"],
            "reason": tracker["reason"],
            "success": bool(success),
            "convergenceKey": next(iter(convergence_keys)) if len(convergence_keys) == 1 else "",
            "coreDigest": next(iter(core_digests)) if len(core_digests) == 1 else "",
            "modelDigest": next(iter(model_digests)) if len(model_digests) == 1 else "",
            "canonicalDigest": next(iter(canonical_digests)) if len(canonical_digests) == 1 else "",
            "financialDigest": next(iter(financial_digests)) if len(financial_digests) == 1 else "",
            "peers": list(tracker["requiredPeers"]),
        }
        if tracker.get("proposalId"):
            action["proposalId"] = tracker["proposalId"]
        if len(structural_digests) == 1:
            action["structuralDigest"] = next(iter(structural_digests))
        if len(world_manifest_digests) == 1:
            action["worldManifestDigest"] = next(iter(world_manifest_digests))
        if not success:
            action["errorCode"] = str(error_code or "checkpoint-consensus-failed")
        seq = self.next_seq
        self.next_seq += 1
        control = sign(
            {
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "seq": seq,
                "kind": "control",
                "origin_peer": self.bridge.peer,
                "tick": 0,
                "payload": {"action": action},
            }
        )
        tracker["status"] = "complete" if success else "faulted"
        tracker["outcome"] = dict(action)
        if success:
            self.last_agreed_checkpoint = dict(action)
        else:
            self.session_fault = action["errorCode"]
        self.audit.append(control)
        self.commits[seq] = control
        self.bridge.write_inbound(control)
        self._broadcast(control)
        if success:
            print(
                f"checkpoint boundary {tracker['boundarySeq']} converged at "
                f"{action['convergenceKey']}"
            )
        else:
            print(
                f"CHECKPOINT CONSENSUS FAULT at boundary {tracker['boundarySeq']}: "
                f"{action['errorCode']}"
            )
        return control

    def _resolve_checkpoint_locked(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        checkpoints = tracker["checkpoints"]
        if not required <= set(checkpoints):
            return
        selected = [checkpoints[peer] for peer in tracker["requiredPeers"]]
        if len({item["convergenceKey"] for item in selected}) != 1:
            self._emit_checkpoint_outcome_locked(
                tracker, False, "checkpoint-convergence-key-mismatch"
            )
            return
        self._emit_checkpoint_outcome_locked(tracker, True)

    def _record_checkpoint_locked(self, message: Mapping[str, Any]) -> None:
        payload = verify_checkpoint(message.get("payload", {}))
        if payload.get("checkpointVersion") != 2:
            raise ProtocolError("network checkpoint consensus requires checkpoint format 2")
        peer = str(message.get("peer", "unknown"))
        if payload.get("sessionId") != self.bridge.session:
            raise ProtocolError("checkpoint payload session does not match the network session")
        if payload.get("peerId") != peer:
            raise ProtocolError("checkpoint payload peer does not match its envelope")
        if payload.get("networkMode") != "network":
            raise ProtocolError("checkpoint consensus requires network-mode checkpoints")
        boundary_seq = int(payload["eventCursor"]["lastCommitSeq"])
        tracker = self.checkpoint_consensus.get(boundary_seq)
        if not tracker:
            self.audit.append(self._record_message(message))
            return
        if peer not in tracker["requiredPeers"]:
            raise ProtocolError(f"checkpoint came from unexpected peer {peer}")
        if payload.get("reason") != tracker["reason"]:
            raise ProtocolError(
                f"checkpoint reason differs at boundary {boundary_seq}: {payload.get('reason')}"
            )
        previous = tracker["checkpoints"].get(peer)
        if previous:
            if previous != payload:
                raise ProtocolError(f"peer {peer} sent conflicting checkpoints for boundary {boundary_seq}")
            return
        self.audit.append(self._record_message(message))
        tracker["checkpoints"][peer] = payload
        self._resolve_checkpoint_locked(tracker)

    def _record_completion_locked(self, message: Mapping[str, Any]) -> None:
        payload = self._completion_payload(message.get("payload"))
        peer = str(message.get("peer", "unknown"))
        tracker = self.proposal_consensus.get(payload["commitSeq"])
        if not tracker:
            raise ProtocolError("proposal completion references an unknown commit")
        if peer not in tracker["requiredPeers"]:
            raise ProtocolError(f"proposal completion came from unexpected peer {peer}")
        if payload["proposalId"] != tracker["proposalId"]:
            raise ProtocolError("proposal completion proposalId does not match its commit")
        if payload["proposalDigest"] != tracker["proposalDigest"]:
            raise ProtocolError("proposal completion digest does not match its commit")
        previous = tracker["completions"].get(peer)
        if previous:
            if previous != payload:
                raise ProtocolError(f"peer {peer} sent conflicting proposal completions")
            return
        self.audit.append(self._record_message(message))
        tracker["completions"][peer] = payload
        self._resolve_proposal_locked(tracker)

    def _record_operation_completion_locked(self, message: Mapping[str, Any]) -> None:
        payload = self._operation_completion_payload(message.get("payload"))
        peer = str(message.get("peer", "unknown"))
        tracker = self.operation_consensus.get(payload["commitSeq"])
        if not tracker:
            raise ProtocolError("operation completion references an unknown commit")
        if peer not in tracker["requiredPeers"]:
            raise ProtocolError(f"operation completion came from unexpected peer {peer}")
        if payload["operationId"] != tracker["operationId"]:
            raise ProtocolError("operation completion operationId does not match its commit")
        if payload["operationDigest"] != tracker["operationDigest"]:
            raise ProtocolError("operation completion digest does not match its commit")
        previous = tracker["completions"].get(peer)
        if previous:
            if previous != payload:
                raise ProtocolError(f"peer {peer} sent conflicting operation completions")
            return
        self.audit.append(self._record_message(message))
        tracker["completions"][peer] = payload
        self._resolve_operation_locked(tracker)

    def _expire_proposals(self) -> None:
        now = time.monotonic()
        with self.order_lock:
            for tracker in list(self.clock_controls.values()):
                if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                    tracker["status"] = "faulted"
                    missing = sorted(set(tracker["requiredPeers"]) - set(tracker["acks"]))
                    self.last_error = "clock-ack-timeout:" + ",".join(missing)
                    if (
                        tracker["generation"] == self.clock_generation
                        and tracker["effectiveSpeed"] != 0
                    ):
                        self._emit_clock_commit_locked(
                            tracker["requestedSpeed"], 0,
                            self.last_error + ":resync-pause",
                        )
            for tracker in self.proposal_prepares.values():
                if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                    missing = sorted(set(tracker["requiredPeers"]) - set(tracker["acks"]))
                    code = "proposal-prepare-timeout:" + ",".join(missing)
                    self._emit_prepare_rejection_locked(tracker, code)
            for tracker in self.proposal_consensus.values():
                if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                    missing = sorted(set(tracker["requiredPeers"]) - set(tracker["completions"]))
                    code = "proposal-completion-timeout:" + ",".join(missing)
                    self._emit_proposal_outcome_locked(tracker, False, code)
            for tracker in self.operation_consensus.values():
                if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                    missing = sorted(set(tracker["requiredPeers"]) - set(tracker["completions"]))
                    code = "operation-completion-timeout:" + ",".join(missing)
                    self._emit_operation_outcome_locked(tracker, False, code)
            for tracker in self.checkpoint_consensus.values():
                if tracker.get("status") == "pending" and now >= float(tracker["deadline"]):
                    missing = sorted(set(tracker["requiredPeers"]) - set(tracker["checkpoints"]))
                    code = "checkpoint-consensus-timeout:" + ",".join(missing)
                    self._emit_checkpoint_outcome_locked(tracker, False, code)

    def _record_non_intent(self, message: Mapping[str, Any]) -> None:
        with self.order_lock:
            if message.get("kind") == "completion":
                self._record_completion_locked(message)
                return
            if message.get("kind") == "operation_completion":
                self._record_operation_completion_locked(message)
                return
            if message.get("kind") == "checkpoint":
                self._record_checkpoint_locked(message)
                return
            record = self._record_message(message)
            self.audit.append(record)
            if message.get("kind") == "ack":
                payload = message.get("payload", {})
                commit_seq = int(payload.get("commitSeq", 0))
                digest = payload.get("digest")
                peer = str(message.get("peer", "unknown"))
                if commit_seq > 0 and isinstance(digest, str):
                    peer_digests = self.ack_digests.setdefault(commit_seq, {})
                    peer_digests[peer] = digest
                    unique = set(peer_digests.values())
                    if len(peer_digests) >= len(self.required_peers) and len(unique) == 1:
                        print(f"commit {commit_seq} queue state converged at {digest}")
                    elif len(unique) > 1:
                        print(f"DIVERGENCE at commit {commit_seq}: {peer_digests}")
                prepare_tracker = self.proposal_prepares.get(commit_seq)
                if prepare_tracker and prepare_tracker.get("status") == "pending":
                    if peer not in prepare_tracker["requiredPeers"]:
                        raise ProtocolError(f"proposal prepare acknowledgement came from {peer}")
                    acknowledgement = {
                        "success": payload.get("success") is True,
                        "digest": payload.get("digest"),
                        "error": payload.get("error"),
                    }
                    previous = prepare_tracker["acks"].get(peer)
                    if previous and previous != acknowledgement:
                        raise ProtocolError(
                            f"peer {peer} sent conflicting proposal prepare acknowledgements"
                        )
                    prepare_tracker["acks"][peer] = acknowledgement
                    self._resolve_prepare_locked(prepare_tracker)
                clock_tracker = self.clock_controls.get(commit_seq)
                if clock_tracker and clock_tracker.get("status") == "pending":
                    if peer not in clock_tracker["requiredPeers"]:
                        raise ProtocolError(f"clock acknowledgement came from {peer}")
                    self._resolve_clock_ack_locked(
                        clock_tracker,
                        peer,
                        {
                            "success": payload.get("success") is True,
                            "digest": payload.get("digest"),
                            "error": payload.get("error"),
                        },
                    )
                tracker = self.proposal_consensus.get(commit_seq)
                if tracker and tracker.get("status") == "pending" and payload.get("success") is not True:
                    self._emit_proposal_outcome_locked(tracker, False, f"proposal-queue-rejected:{peer}")
                operation_tracker = self.operation_consensus.get(commit_seq)
                if operation_tracker and operation_tracker.get("status") == "pending" \
                        and payload.get("success") is not True:
                    self._emit_operation_outcome_locked(
                        operation_tracker, False, f"operation-queue-rejected:{peer}"
                    )
            elif message.get("kind") == "clock_health":
                self._record_clock_health_locked(message)
            elif message.get("kind") == "mobility":
                payload = message.get("payload", {})
                sample_key = payload.get("sampleKey")
                digest = payload.get("digest")
                peer = str(message.get("peer", "unknown"))
                if isinstance(sample_key, str) and sample_key and isinstance(digest, str) and digest:
                    peer_digests = self.mobility_digests.setdefault(sample_key, {})
                    peer_digests[peer] = digest
                    unique = set(peer_digests.values())
                    if len(peer_digests) >= len(self.required_peers):
                        outcome = "converged" if len(unique) == 1 else "diverged"
                        if self.mobility_outcomes.get(sample_key) != outcome:
                            self.mobility_outcomes[sample_key] = outcome
                            if outcome == "converged":
                                print(f"mobility sample {sample_key} converged at {digest}")
                            else:
                                print(f"MOBILITY DIVERGENCE at {sample_key}: {peer_digests}")

    def _broadcast(self, message: Mapping[str, Any]) -> None:
        failed: list[str] = []
        with self.peers_lock:
            peers = list(self.peers.values())
        for peer in peers:
            try:
                _send(peer.sock, message, peer.send_lock)
            except OSError:
                failed.append(peer.peer)
        if failed:
            with self.peers_lock:
                for peer_name in failed:
                    item = self.peers.pop(peer_name, None)
                    if item:
                        try:
                            item.sock.close()
                        except OSError:
                            pass

    def _serve_peer(self, conn: socket.socket, address: tuple[str, int]) -> None:
        peer_name: str | None = None
        reader = conn.makefile("rb")
        try:
            greeting = _read_frame(reader)
            validate_envelope(greeting, self.bridge.session)
            if greeting.get("kind") != "hello":
                raise ProtocolError("first client frame must be hello")
            peer_name = str(greeting.get("peer", ""))
            if not peer_name or peer_name == self.bridge.peer:
                raise ProtocolError("client peer id is empty or conflicts with host")
            if peer_name not in self.required_peers:
                raise ProtocolError(f"peer {peer_name} is not in the pinned match roster")
            if self.match_fingerprint and greeting.get("match_fingerprint") != self.match_fingerprint:
                raise ProtocolError("match fingerprint differs from the host")
            connected = ConnectedPeer(peer_name, conn, threading.Lock())
            with self.peers_lock:
                old = self.peers.pop(peer_name, None)
                if old:
                    old.sock.close()
                self.peers[peer_name] = connected
            acknowledgement = sign(
                {
                    "protocol": PROTOCOL_VERSION,
                    "session": self.bridge.session,
                    "kind": "hello_ack",
                    "peer": self.bridge.peer,
                    "next_seq": self.next_seq,
                    "match_fingerprint": self.match_fingerprint,
                }
            )
            _send(conn, acknowledgement, connected.send_lock)
            last_commit = int(greeting.get("last_commit_seq", 0))
            for seq in sorted(self.commits):
                if seq > last_commit:
                    _send(conn, self.commits[seq], connected.send_lock)
            print(f"client {peer_name} connected from {address[0]}:{address[1]}")
            while not self.stop.is_set():
                message = _read_frame(reader)
                validate_envelope(message, self.bridge.session)
                if str(message.get("peer")) != peer_name:
                    raise ProtocolError("connected peer changed identity")
                accepted, reason, commit_seq = True, None, None
                try:
                    if message.get("kind") == "intent":
                        commit = self._commit(message)
                        commit_seq = commit and commit.get("seq")
                    else:
                        self._record_non_intent(message)
                except ProtocolError as exc:
                    accepted, reason = False, str(exc)
                    rejection = self._reject_intent(message, reason)
                    commit_seq = rejection and rejection.get("seq")
                    print(f"rejected {peer_name} local sequence {message.get('local_seq')}: {reason}")
                receipt = sign(
                    {
                        "protocol": PROTOCOL_VERSION,
                        "session": self.bridge.session,
                        "kind": "receipt",
                        "peer": self.bridge.peer,
                        "recipient": peer_name,
                        "local_seq": int(message.get("local_seq", 0)),
                        "accepted": accepted,
                        "reason": reason,
                        "commit_seq": commit_seq,
                    }
                )
                _send(conn, receipt, connected.send_lock)
        except (ConnectionError, OSError, ProtocolError) as exc:
            if not self.stop.is_set():
                print(f"client {peer_name or address} disconnected: {exc}")
        finally:
            with self.peers_lock:
                if peer_name and self.peers.get(peer_name) and self.peers[peer_name].sock is conn:
                    self.peers.pop(peer_name, None)
            try:
                reader.close()
                conn.close()
            except OSError:
                pass

    def _accept_loop(self, listener: socket.socket) -> None:
        while not self.stop.is_set():
            try:
                conn, address = listener.accept()
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                threading.Thread(target=self._serve_peer, args=(conn, address), daemon=True).start()
            except socket.timeout:
                continue
            except OSError:
                if not self.stop.is_set():
                    raise

    def run(self, poll_seconds: float = 0.1) -> None:
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((self.bind, self.port))
        listener.listen(8)
        listener.settimeout(0.5)
        threading.Thread(target=self._accept_loop, args=(listener,), daemon=True).start()
        print(f"TPF2MP host listening on {self.bind}:{self.port}")
        print(f"session={self.bridge.session} peer={self.bridge.peer} bridge={self.bridge.root}")
        print(f"match fingerprint={self.match_fingerprint or 'UNVERIFIED'}")
        self._write_status("running")
        next_status = time.monotonic()
        try:
            while not self.stop.is_set():
                had_work = False
                for local_seq, message in self.bridge.pending_outbound():
                    try:
                        if message.get("kind") == "intent":
                            self._commit(message)
                        else:
                            self._record_non_intent(message)
                    except ProtocolError as exc:
                        self.last_error = str(exc)
                        self._reject_intent(message, str(exc))
                        print(f"rejected local game sequence {local_seq}: {exc}")
                    self.bridge.acknowledge_outbound(local_seq)
                    had_work = True
                self._expire_proposals()
                if time.monotonic() >= next_status:
                    self._write_status()
                    next_status = time.monotonic() + 0.5
                if not had_work:
                    time.sleep(poll_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            listener.close()
            with self.peers_lock:
                for peer in self.peers.values():
                    peer.sock.close()
            self._write_status("stopped")


class CommitClient:
    def __init__(
        self,
        bridge: GameBridge,
        host: str,
        port: int,
        match_fingerprint: str | None = None,
    ) -> None:
        self.bridge = bridge
        self.host = host
        self.port = port
        self.match_fingerprint = match_fingerprint
        self.stop = threading.Event()
        self.status = "starting"
        self.connected = False
        self.last_error: str | None = None
        self.next_host_seq: int | None = None

    def _write_status(self, status: str | None = None) -> None:
        if status is not None:
            self.status = status
        self.bridge.write_status(
            {
                "role": "client",
                "status": self.status,
                "connected": self.connected,
                "host": self.host,
                "port": self.port,
                "nextHostSeq": self.next_host_seq,
                "outboxCursor": self.bridge.outbox_cursor,
                "lastCommitSeq": self._last_commit(),
                "lastError": self.last_error,
                "matchFingerprint": self.match_fingerprint,
            }
        )

    def _last_commit(self) -> int:
        sequences = self.bridge.existing_commit_sequences()
        current = 0
        while current + 1 in sequences:
            current += 1
        return current

    def _session(self, poll_seconds: float) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=5)
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        reader = sock.makefile("rb")
        send_lock = threading.Lock()
        _send(
            sock,
            hello(self.bridge.session, self.bridge.peer, self._last_commit(), self.match_fingerprint),
            send_lock,
        )
        acknowledgement = _read_frame(reader)
        validate_envelope(acknowledgement, self.bridge.session)
        if acknowledgement.get("kind") != "hello_ack":
            raise ProtocolError("host did not acknowledge handshake")
        if self.match_fingerprint and acknowledgement.get("match_fingerprint") != self.match_fingerprint:
            raise ProtocolError("host acknowledged a different match fingerprint")
        self.connected = True
        self.status = "connected"
        self.last_error = None
        self.next_host_seq = int(acknowledgement.get("next_seq", 0))
        self._write_status()
        print(f"connected to {self.host}:{self.port}; next host sequence {acknowledgement.get('next_seq')}")
        receiver_error: list[BaseException] = []
        sent_pending: set[int] = set()

        def receive() -> None:
            try:
                while not self.stop.is_set():
                    message = _read_frame(reader)
                    validate_envelope(message, self.bridge.session)
                    if message.get("kind") in {"commit", "control"}:
                        self.bridge.write_inbound(message)
                    elif message.get("kind") == "receipt":
                        if str(message.get("recipient")) != self.bridge.peer:
                            raise ProtocolError("receipt was addressed to another peer")
                        local_seq = int(message.get("local_seq", 0))
                        self.bridge.acknowledge_outbound(local_seq)
                        if not message.get("accepted"):
                            print(f"host rejected local sequence {local_seq}: {message.get('reason')}")
            except BaseException as exc:  # surfaced in the owning reconnect loop
                receiver_error.append(exc)

        thread = threading.Thread(target=receive, daemon=True)
        thread.start()
        try:
            next_status = time.monotonic()
            while not self.stop.is_set() and not receiver_error:
                had_work = False
                for local_seq, message in self.bridge.pending_outbound():
                    if local_seq not in sent_pending:
                        _send(sock, message, send_lock)
                        sent_pending.add(local_seq)
                        had_work = True
                if not had_work:
                    time.sleep(poll_seconds)
                if time.monotonic() >= next_status:
                    self._write_status()
                    next_status = time.monotonic() + 0.5
            if receiver_error:
                raise ConnectionError(str(receiver_error[0]))
        finally:
            self.connected = False
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            reader.close()
            sock.close()

    def run(self, poll_seconds: float = 0.1, retry_seconds: float = 2.0) -> None:
        print(f"TPF2MP client peer={self.bridge.peer} session={self.bridge.session} bridge={self.bridge.root}")
        print(f"match fingerprint={self.match_fingerprint or 'UNVERIFIED'}")
        self._write_status("connecting")
        try:
            while not self.stop.is_set():
                try:
                    self._session(poll_seconds)
                except (ConnectionError, OSError, ProtocolError) as exc:
                    if self.stop.is_set():
                        break
                    self.connected = False
                    self.last_error = str(exc)
                    self._write_status("retrying")
                    print(f"connection unavailable: {exc}; retrying in {retry_seconds:.1f}s")
                    self.stop.wait(retry_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.connected = False
            self._write_status("stopped")
