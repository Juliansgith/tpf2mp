from __future__ import annotations

from typing import Any

from .completion_validation import operation_completion_result_view
from .operation_rejection import proof_error as operation_rejection_proof_error
from .protocol import PROTOCOL_VERSION, ProtocolError, sign


class OperationConsensusCoordinator:
    """Resolve all-peer native operations and journal their ordered outcome."""

    def __init__(self, host: Any) -> None:
        self.host = host

    def emit(
        self, tracker: dict[str, Any], success: bool,
        error_code: str | None = None, *, recoverable: bool = False,
    ) -> dict[str, Any]:
        host = self.host
        if tracker.get("status") != "pending":
            return dict(tracker.get("outcome", {}))
        if success and recoverable:
            raise ProtocolError("successful operation outcome cannot be recoverable")
        completions = tracker["completions"]
        result_digests = {
            item["resultDigest"] for item in completions.values() if item.get("resultDigest")
        }
        core_digests = {
            item["coreDigest"] for item in completions.values() if item.get("coreDigest")
        }
        action: dict[str, Any] = {
            "type": "network.operation_outcome", "operationId": tracker["operationId"],
            "commitSeq": tracker["commitSeq"],
            "operationDigest": tracker["operationDigest"], "success": bool(success),
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
            if recoverable:
                action["recoverable"] = True
        seq, host.next_seq = host.next_seq, host.next_seq + 1
        control = sign({
            "protocol": PROTOCOL_VERSION, "session": host.bridge.session, "seq": seq,
            "kind": "control", "origin_peer": host.bridge.peer, "tick": 0,
            "payload": {"action": action},
        })
        tracker["status"] = "complete" if success else "rejected" if recoverable else "faulted"
        tracker["outcome"], tracker["outcomeSeq"] = dict(action), seq
        if recoverable:
            host._track_checkpoint_boundary(
                seq, f"operation-rejection:{tracker['operationId']}", tracker["operationId"]
            )
        elif success:
            host._track_checkpoint_boundary(
                seq, f"operation-consensus:{tracker['operationId']}", tracker["operationId"]
            )
        else:
            host.session_fault = action["errorCode"]
        host.audit.append(control)
        host.commits[seq] = control
        host.bridge.write_inbound(control)
        host._broadcast(control)
        if success:
            print(f"operation {tracker['operationId']} physically converged at {action['resultDigest']}")
        elif recoverable:
            print(f"operation {tracker['operationId']} was rejected identically and remains healthy")
        else:
            print(f"OPERATION CONSENSUS FAULT {tracker['operationId']}: {action['errorCode']}")
        return control

    def resolve(self, tracker: dict[str, Any]) -> None:
        required = set(tracker["requiredPeers"])
        completions = tracker["completions"]
        if not required <= set(completions):
            return
        selected = [completions[peer] for peer in tracker["requiredPeers"]]
        if any(item.get("operationDigest") != tracker["operationDigest"] for item in selected):
            self.emit(tracker, False, "operation-digest-mismatch")
            return
        success_values = {item.get("success") for item in selected}
        if success_values == {False}:
            if not required <= set(tracker.get("acks") or {}):
                return
            error = operation_rejection_proof_error(tracker, selected)
            self.emit(
                tracker, False, error or "native-operation-rejected",
                recoverable=error is None,
            )
            return
        if success_values != {True}:
            self.emit(tracker, False, "mixed-native-operation-results")
            return
        first_result = operation_completion_result_view(selected[0])
        if any(operation_completion_result_view(item) != first_result for item in selected[1:]):
            self.emit(tracker, False, "operation-physical-result-digest-mismatch")
            return
        if len({item["coreDigest"] for item in selected}) != 1:
            self.emit(tracker, False, "operation-physical-core-digest-mismatch")
            return
        self.emit(tracker, True)
