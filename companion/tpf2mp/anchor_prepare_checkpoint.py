"""Ordered checkpoint creation for coordinated recovery preparation."""

from __future__ import annotations

from typing import Any

from .protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_action


class AnchorPreparationCheckpoint:
    def __init__(self, host: Any) -> None:
        self.host = host

    def emit(
        self, preparation_seq: int, vehicle_phase_proof: dict[str, Any] | None,
    ) -> dict[str, Any]:
        if not isinstance(vehicle_phase_proof, dict):
            raise ProtocolError("restore checkpoint has no native vehicle phase proof")
        reason = f"recovery-prepare:{preparation_seq}"
        action = validate_action({
            "type": "network.checkpoint_request",
            "preparationSeq": preparation_seq,
            "reason": reason,
            "vehiclePhaseProof": vehicle_phase_proof,
        })
        sequence = self.host.next_seq
        self.host.next_seq += 1
        control = sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.host.bridge.session,
            "seq": sequence,
            "kind": "control",
            "origin_peer": self.host.bridge.peer,
            "tick": 0,
            "payload": {"action": action},
        })
        self.host.audit.append(control)
        self.host.commits[sequence] = control
        self.host.anchor_preparation.observe_ordered(control)
        self.host.bridge.write_inbound(control)
        self.host._broadcast(control)
        print(f"restore point preparation {preparation_seq} requested checkpoint {sequence}")
        return control
