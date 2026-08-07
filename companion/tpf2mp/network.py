from __future__ import annotations

import socket
import re
import threading
import time
from pathlib import Path
from typing import Any, Mapping

from .bridge import AuditLog, GameBridge
from .checkpoint import CHECKPOINT_VERSION, verify_checkpoint
from .consensus import (
    ConsensusTrackers,
    operation_completion_payload,
    proposal_completion_payload,
)
from .anchor import AnchorCoordinator
from .anchor_prepare import AnchorPreparationCoordinator
from .anchor_io import AnchorRequestStore
from .host_status import write_host_status
from .synchronization import SynchronizationCoordinator
from .restore_session import RestoreSessionCoordinator
from .protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    sign,
    validate_action,
    validate_envelope,
)
from .client import CommitClient
from .transport import ConnectedPeer, read_frame as _read_frame, send as _send
HOST_AUTHORITY_ACTIONS = {
    "match.initialise",
    "match.finish",
    "world.freeze",
    "economy.seed_demo",
    "economy.settle",
    "probe.mobility",
    "probe.structural",
    "finance.toggle_neutralizer",
    "town.develop",
    "recovery.resume",
}

# Company-bound actions may originate on either peer; owners carry their service facts.
COMPANY_BOUND_ACTIONS = {"proposal.prepare", "operation.execute", "line.register"}


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
        restore_plan: Mapping[str, Any] | None = None,
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
        self.vehicle_lifecycle_digests: dict[str, dict[str, str]] = {}
        self.vehicle_lifecycle_outcomes: dict[str, str] = {}
        self.vehicle_phase_digests: dict[str, dict[str, str]] = {}
        self.vehicle_phase_outcomes: dict[str, str] = {}
        self.vehicle_phase_divergence_streak = 0
        self.vehicle_phase_state = "unknown"
        self.clock_requested_speed = 0
        self.clock_effective_speed = 0
        self.clock_generation = 0
        self.clock_health: dict[str, dict[str, Any]] = {}
        self.clock_last_adjustment = 0.0
        self.clock_healthy_since: float | None = None
        configured_peers = set(required_peers or ("player1", "player2"))
        configured_peers.add(self.bridge.peer)
        self.required_peers = tuple(sorted(configured_peers))
        self.completion_timeout = max(1.0, float(completion_timeout))
        self.require_connected_peers = bool(require_connected_peers)
        self.consensus = ConsensusTrackers(
            self.bridge.session,
            self.required_peers,
            self.completion_timeout,
        )
        # Compatibility aliases remain for status and recovery readers.
        self.proposal_prepares = self.consensus.proposal_prepares
        self.proposal_consensus = self.consensus.proposals
        self.operation_consensus = self.consensus.operations
        self.checkpoint_consensus = self.consensus.checkpoints
        self.clock_controls = self.consensus.clock_controls
        self.synchronization = SynchronizationCoordinator(self)
        self.restore_session = RestoreSessionCoordinator(self, restore_plan)
        self.anchor = AnchorCoordinator(self)
        self.anchor_preparation = AnchorPreparationCoordinator(self)
        self.anchor_requests = AnchorRequestStore(self.bridge)
        # Negative host sequences stay disjoint from unbounded positive game sequences.
        self._next_local_seq = -1
        self.last_agreed_checkpoint: dict[str, Any] | None = None
        self.session_fault: str | None = None
        self.status = "starting"
        self.last_error: str | None = None
        self.next_seq = 1
        self._load_audit()
        self.synchronization.finalize_restore()
        for tracker in list(self.proposal_prepares.values()):
            if tracker.get("status") == "pending":
                self._resolve_prepare_locked(tracker)

    def _write_status(self, status: str | None = None) -> None:
        write_host_status(self, status)

    def _load_audit(self) -> None:
        for message in self.audit.messages():
            if message.get("session") != self.bridge.session:
                continue
            if message.get("kind") in {"commit", "control"}:
                seq = int(message["seq"])
                self.commits[seq] = message
                self.next_seq = max(self.next_seq, seq + 1)
                if message.get("kind") == "commit":
                    origin_peer = str(message.get("origin_peer"))
                    origin_local_seq = int(message.get("origin_local_seq", -1))
                    self.seen.add((origin_peer, origin_local_seq))
                    if origin_peer == self.bridge.peer and origin_local_seq < 0:
                        self._next_local_seq = min(self._next_local_seq, origin_local_seq - 1)
                    action = message.get("payload", {}).get("action", {})
                    if action.get("type") == "proposal.prepare":
                        self._track_proposal_prepare(message)
                    elif action.get("type") == "proposal.build":
                        proposal = self._track_proposal(message)
                        prepared_from = int(message.get("prepared_from_seq", 0))
                        prepared = self.proposal_prepares.get(prepared_from)
                        if prepared:
                            prepared["status"] = "committed"
                            prepared["buildSeq"] = seq
                            prepared_digests = {
                                item.get("digest")
                                for peer, item in prepared.get("acks", {}).items()
                                if peer in prepared.get("requiredPeers", ())
                                and item.get("success") is True
                            }
                            if len(prepared_digests) == 1 and None not in prepared_digests:
                                prepared["preparedCoreDigest"] = next(iter(prepared_digests))
                                proposal["preparedCoreDigest"] = prepared["preparedCoreDigest"]
                    elif action.get("type") in {"clock.set", "clock.rendezvous"}:
                        self._track_clock(message)
                    elif action.get("type") == "vehicle.sync_release":
                        self.synchronization.track_vehicle_release(message)
                    elif action.get("type") == "network.sync_fault":
                        self.session_fault = str(action.get("errorCode") or "synchronization-fault")
                        self.sync_fault_emitted = True
                    elif action.get("type") == "operation.execute":
                        self._track_operation(message)
                    elif action.get("type") == "match.initialise":
                        self._track_checkpoint_boundary(seq, "match-initialised")
                    elif action.get("type") == "town.develop":
                        self._track_checkpoint_boundary(seq, "town-development")
                    elif action.get("type") == "probe.structural":
                        self._track_checkpoint_boundary(seq, "structural-probe")
                    elif action.get("type") == "recovery.resume":
                        self.restore_session.track_commit(message)
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
                        recoverable = action.get("recoverable") is True \
                            and action.get("success") is not True
                        if tracker:
                            tracker["status"] = (
                                "complete" if action.get("success")
                                else "rejected" if recoverable
                                else "faulted"
                            )
                            tracker["outcome"] = dict(action)
                        if recoverable:
                            self._track_checkpoint_boundary(
                                seq,
                                f"physical-rejection:{action.get('proposalId')}",
                                str(action.get("proposalId", "")),
                            )
                        elif not action.get("success"):
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
                        self.restore_session.observe_checkpoint_outcome(action)
                self.anchor_preparation.observe_ordered(message, restoring=True)
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
                    if payload.get("checkpointVersion") != CHECKPOINT_VERSION:
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
                    if payload.get("success") is not True:
                        clock_tracker["status"] = "faulted"
                    elif set(clock_tracker["requiredPeers"]) <= set(clock_tracker["acks"]):
                        clock_tracker["status"] = (
                            "complete"
                            if all(item["success"] for item in clock_tracker["acks"].values())
                            else "faulted"
                        )
                self.synchronization.resolve_vehicle_ack(
                    prepare_seq, peer, payload.get("success") is True,
                    str(payload.get("error") or ""), restoring=True,
                )
            elif message.get("kind") == "record" and message.get("record_type") == "clock_reached":
                self.synchronization.record_clock_reached({
                    "peer": message.get("peer"), "payload": message.get("payload", {}),
                }, restoring=True)
            elif message.get("kind") == "record" and message.get("record_type") == "vehicle_sync":
                self.synchronization.record_vehicle_sync({
                    "peer": message.get("peer"), "payload": message.get("payload", {}),
                }, restoring=True)

    def _track_proposal_prepare(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        return self.consensus.track_prepare(commit)

    def _track_clock(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        return self.synchronization.track_clock(commit)

    def _pending_clock_seq(self) -> int | None:
        return self.consensus.pending_clock_seq()

    def _track_proposal(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        return self.consensus.track_proposal(commit)

    def _track_operation(self, commit: Mapping[str, Any]) -> dict[str, Any]:
        return self.consensus.track_operation(commit)

    def _track_checkpoint_boundary(
        self,
        boundary_seq: int,
        reason: str,
        proposal_id: str | None = None,
    ) -> dict[str, Any]:
        return self.consensus.track_checkpoint(boundary_seq, reason, proposal_id)

    def _pending_proposal(self) -> dict[str, Any] | None:
        return self.consensus.pending(self.proposal_consensus)

    def _pending_prepare(self) -> dict[str, Any] | None:
        return self.consensus.pending(self.proposal_prepares)

    def _pending_operation(self) -> dict[str, Any] | None:
        return self.consensus.pending(self.operation_consensus)

    def _pending_checkpoint(self) -> dict[str, Any] | None:
        return self.consensus.pending(self.checkpoint_consensus)
    def emit_local_intent(self, action: Mapping[str, Any]) -> dict[str, Any] | None:
        """Order an action the host companion itself originated.

        Used for attestations the companion is uniquely able to make - it
        knows the pause state, the ordered history, and the save on disk -
        rather than round-tripping a question through the game.
        """
        local_seq = self._allocate_host_local_seq()
        return self._commit(sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.bridge.session,
            "peer": self.bridge.peer,
            "local_seq": local_seq,
            "tick": 0,
            "kind": "intent",
            "payload": {"action": dict(action)},
        }))

    def _allocate_host_local_seq(self) -> int:
        """Return a restart-stable identity disjoint from every game intent."""
        with self.order_lock:
            while (self.bridge.peer, self._next_local_seq) in self.seen:
                self._next_local_seq -= 1
            local_seq = self._next_local_seq
            self._next_local_seq -= 1
            return local_seq

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
            self.restore_session.before_commit(action, origin)
            clock_request = action["type"] == "clock.request"
            emergency_pause = clock_request and action["requestedSpeed"] == 0
            self.anchor_preparation.before_commit(action, origin, local_seq)
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
            if action["type"] in {
                "clock.set", "clock.rendezvous", "vehicle.sync_release", "network.sync_fault",
                "network.checkpoint_request",
            }:
                raise ProtocolError(f"{action['type']} is host-generated")
            if clock_request and not emergency_pause and self.require_connected_peers:
                with self.peers_lock:
                    connected = set(self.peers)
                missing = sorted(set(self.required_peers) - {self.bridge.peer} - connected)
                if missing:
                    raise ProtocolError(
                        "cannot resume the shared clock while peers are disconnected: "
                        + ", ".join(missing)
                    )
            if action["type"] in {
                "match.initialise", "proposal.prepare", "operation.execute",
                "line.register", "town.develop", "recovery.prepare", "recovery.resume",
                "recovery.save_receipt",
            }:
                if self.require_connected_peers:
                    with self.peers_lock:
                        connected = set(self.peers)
                    missing = sorted(set(self.required_peers) - {self.bridge.peer} - connected)
                    if missing:
                        raise ProtocolError(
                        "cannot commit a consensus-bound action while peers are disconnected: "
                        + ", ".join(missing)
                    )
            if action["type"] == "recovery.save_receipt":
                existing_receipt = self.anchor.validate_receipt(action, origin)
                if existing_receipt:
                    self.seen.add(key)
                    return existing_receipt
            if action["type"] == "proposal.prepare":
                peer_number = re.fullmatch(r"player([1-9][0-9]*)", origin)
                expected_company = f"company:{peer_number.group(1)}" if peer_number else None
                actual_company = action["transaction"]["companyCid"]
                if expected_company and actual_company != expected_company:
                    raise ProtocolError(
                        f"proposal.prepare from {origin} must act for {expected_company}, not {actual_company}"
                    )
            if action["type"] == "line.register":
                peer_number = re.fullmatch(r"player([1-9][0-9]*)", origin)
                expected_company = f"company:{peer_number.group(1)}" if peer_number else None
                actual_company = action["companyCid"]
                service_company = action["service"].get("companyCid")
                if expected_company and actual_company != expected_company:
                    raise ProtocolError(
                        f"line.register from {origin} must act for {expected_company}, "
                        f"not {actual_company}"
                    )
                if service_company != actual_company:
                    raise ProtocolError("line.register service company must match the acting company")
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
                action = self.synchronization.prepare_clock_request(requested, origin)
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
            elif action["type"] == "town.develop":
                self._track_checkpoint_boundary(seq, "town-development")
            elif action["type"] == "probe.structural":
                self._track_checkpoint_boundary(seq, "structural-probe")
            elif action["type"] == "recovery.resume":
                self.restore_session.track_commit(commit)
            elif action["type"] in {"clock.set", "clock.rendezvous"}:
                self._track_clock(commit)
            self.anchor_preparation.observe_ordered(commit)
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

    _completion_payload = staticmethod(proposal_completion_payload)
    _operation_completion_payload = staticmethod(operation_completion_payload)

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
        proposal = self._track_proposal(commit)
        proposal["preparedCoreDigest"] = tracker.get("preparedCoreDigest")
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
        tracker["preparedCoreDigest"] = next(iter(digests))
        self._commit_prepared_proposal_locked(tracker)

    def _emit_clock_commit_locked(
        self,
        requested_speed: int,
        effective_speed: int,
        reason: str,
    ) -> dict[str, Any]:
        return self.synchronization.emit_clock_set(
            requested_speed, effective_speed, reason
        )

    def _resolve_clock_ack_locked(
        self,
        tracker: dict[str, Any],
        peer: str,
        acknowledgement: dict[str, Any],
    ) -> None:
        self.synchronization.resolve_clock_ack(tracker, peer, acknowledgement)

    def _record_clock_health_locked(self, message: Mapping[str, Any]) -> None:
        self.synchronization.record_clock_health(message)

    def _maybe_adjust_clock_locked(self, now: float | None = None) -> None:
        self.synchronization.maybe_adjust_clock(now)

    def _emit_proposal_outcome_locked(
        self,
        tracker: dict[str, Any],
        success: bool,
        error_code: str | None = None,
        *,
        recoverable: bool = False,
    ) -> dict[str, Any]:
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        if success and recoverable:
            raise ProtocolError("successful proposal outcome cannot be recoverable")
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
            if recoverable:
                action["recoverable"] = True
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
        tracker["status"] = "complete" if success else "rejected" if recoverable else "faulted"
        tracker["outcome"] = dict(action)
        if recoverable:
            self.last_error = action["errorCode"]
            self._track_checkpoint_boundary(
                seq,
                f"physical-rejection:{tracker['proposalId']}",
                tracker["proposalId"],
            )
        elif not success:
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
        elif recoverable:
            print(
                f"proposal {tracker['proposalId']} was identically rejected on all peers "
                "without world mutation; session remains healthy"
            )
        else:
            print(f"PROPOSAL CONSENSUS FAULT {tracker['proposalId']}: {action['errorCode']}")
        return control

    def _resolve_proposal_locked(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        completions = tracker["completions"]
        if not required <= set(completions):
            return
        selected = [completions[peer] for peer in tracker["requiredPeers"]]
        if any(item.get("proposalDigest") != tracker["proposalDigest"] for item in selected):
            self._emit_proposal_outcome_locked(tracker, False, "proposal-digest-mismatch")
            return
        success_values = {item.get("success") for item in selected}
        if success_values == {False}:
            if any(item.get("outputs") for item in selected):
                self._emit_proposal_outcome_locked(
                    tracker, False, "failed-native-proposal-left-canonical-outputs"
                )
                return
            if any("financeDelta" in item for item in selected):
                self._emit_proposal_outcome_locked(
                    tracker, False, "failed-native-proposal-reported-finance-delta"
                )
                return
            if len({item.get("errorCode") for item in selected}) != 1:
                self._emit_proposal_outcome_locked(
                    tracker, False, "native-rejection-error-mismatch"
                )
                return
            if len({item["resultDigest"] for item in selected}) != 1:
                self._emit_proposal_outcome_locked(
                    tracker, False, "physical-result-digest-mismatch"
                )
                return
            if len({item["coreDigest"] for item in selected}) != 1:
                self._emit_proposal_outcome_locked(
                    tracker, False, "physical-core-digest-mismatch"
                )
                return
            failed_core_digest = selected[0]["coreDigest"]
            if not tracker.get("preparedCoreDigest") \
                    or failed_core_digest != tracker.get("preparedCoreDigest"):
                self._emit_proposal_outcome_locked(
                    tracker, False, "native-rejection-mutated-prepared-core"
                )
                return
            self._emit_proposal_outcome_locked(
                tracker,
                False,
                "native-proposal-rejected",
                recoverable=True,
            )
            return
        if success_values != {True}:
            self._emit_proposal_outcome_locked(
                tracker, False, "mixed-native-proposal-results"
            )
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
        self.restore_session.observe_checkpoint_outcome(action)
        self.audit.append(control)
        self.commits[seq] = control
        self.anchor_preparation.observe_ordered(control)
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
        restore_error = self.restore_session.checkpoint_error(tracker, selected)
        if restore_error:
            self._emit_checkpoint_outcome_locked(tracker, False, restore_error)
            return
        if len({item["convergenceKey"] for item in selected}) != 1:
            self._emit_checkpoint_outcome_locked(
                tracker, False, "checkpoint-convergence-key-mismatch"
            )
            return
        self._emit_checkpoint_outcome_locked(tracker, True)

    def _record_checkpoint_locked(self, message: Mapping[str, Any]) -> None:
        payload = verify_checkpoint(message.get("payload", {}))
        if payload.get("checkpointVersion") != CHECKPOINT_VERSION:
            raise ProtocolError(
                f"network checkpoint consensus requires checkpoint format {CHECKPOINT_VERSION}"
            )
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
            tracker = self.anchor_preparation.admit_manual_checkpoint(payload)
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
            self.synchronization.expire(now)
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
                self.synchronization.resolve_vehicle_ack(
                    commit_seq, peer, payload.get("success") is True,
                    str(payload.get("error") or ""),
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
                action_type = str(
                    self.commits.get(commit_seq, {}).get("payload", {})
                    .get("action", {}).get("type", "")
                )
                specially_resolved = action_type in {
                    "proposal.prepare", "proposal.build", "operation.execute",
                    "clock.set", "clock.rendezvous", "vehicle.sync_release",
                    "network.sync_fault",
                }
                if payload.get("success") is not True and not specially_resolved:
                    detail = str(payload.get("error") or "handler returned false")[:240]
                    self.synchronization.fault_session(
                        "authored", f"ordered-action-rejected:{commit_seq}:{peer}:{detail}"
                    )
            elif message.get("kind") == "clock_health":
                self._record_clock_health_locked(message)
            elif message.get("kind") == "clock_reached":
                self.synchronization.record_clock_reached(message)
            elif message.get("kind") == "vehicle_sync":
                self.synchronization.record_vehicle_sync(message)
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
                    digest_groups = (
                        (
                            "vehicle lifecycle",
                            payload.get("vehicleLifecycleDigest"),
                            self.vehicle_lifecycle_digests,
                            self.vehicle_lifecycle_outcomes,
                        ),
                        (
                            "vehicle route phase",
                            payload.get("vehiclePhaseDigest"),
                            self.vehicle_phase_digests,
                            self.vehicle_phase_outcomes,
                        ),
                    )
                    for label, scoped_digest, digest_store, outcome_store in digest_groups:
                        if not isinstance(scoped_digest, str) or not scoped_digest:
                            continue
                        scoped_peer_digests = digest_store.setdefault(sample_key, {})
                        scoped_peer_digests[peer] = scoped_digest
                        if len(scoped_peer_digests) < len(self.required_peers):
                            continue
                        scoped_outcome = (
                            "converged" if len(set(scoped_peer_digests.values())) == 1
                            else "diverged"
                        )
                        if outcome_store.get(sample_key) == scoped_outcome:
                            continue
                        outcome_store[sample_key] = scoped_outcome
                        if label == "vehicle route phase":
                            if scoped_outcome == "diverged":
                                self.vehicle_phase_divergence_streak += 1
                                self.vehicle_phase_state = (
                                    "warning" if self.vehicle_phase_divergence_streak >= 3
                                    else "observing"
                                )
                            else:
                                self.vehicle_phase_divergence_streak = 0
                                self.vehicle_phase_state = "converged"
                        if scoped_outcome == "converged":
                            print(f"{label} sample {sample_key} converged at {scoped_digest}")
                        else:
                            print(
                                f"{label.upper()} DIVERGENCE at {sample_key}: "
                                f"{scoped_peer_digests}"
                            )

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
                    rejection = None
                    if int(message.get("local_seq", 0)) > 0:
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
                if self.anchor_requests.process_host(self.anchor):
                    had_work = True
                self._expire_proposals()
                if self.anchor_preparation.maintain():
                    had_work = True
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
