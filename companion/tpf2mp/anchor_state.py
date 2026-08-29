"""Transient, authenticated host-to-client recovery readiness state."""

from __future__ import annotations

import time
from typing import Any, Mapping

from .automatic_recovery_state import (
    DEFAULT_AUTOMATIC_RECOVERY,
    validate_automatic_recovery,
)
from .protocol import PROTOCOL_VERSION, ProtocolError, sign


def anchor_state_message(
    session: str, peer: str, readiness: Mapping[str, Any],
    preparation: Mapping[str, Any] | None = None,
    receipt_readiness: Mapping[str, Any] | None = None,
    paused_heartbeat_required: bool = True,
    fault_recovery: Mapping[str, Any] | None = None,
    automatic_recovery: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Build transient host readiness sent to every client companion."""

    preparation = preparation or {}
    receipt_readiness = receipt_readiness or readiness
    recovery = fault_recovery or {}
    automatic = automatic_recovery or DEFAULT_AUTOMATIC_RECOVERY
    return sign({
        "protocol": PROTOCOL_VERSION,
        "session": session,
        "kind": "anchor_state",
        "peer": peer,
        "payload": {
            "schemaVersion": 6,
            "ready": readiness.get("ready") is True,
            "receiptReady": receipt_readiness.get("ready") is True,
            "boundarySeq": max(0, int(readiness.get("boundarySeq", 0))),
            "coreDigest": str(readiness.get("coreDigest") or ""),
            "convergenceKey": str(readiness.get("convergenceKey") or ""),
            "reasons": [str(item)[:512] for item in readiness.get("reasons", [])],
            "preparationStatus": str(preparation.get("anchorPreparationStatus") or "idle"),
            "preparationSeq": preparation.get("anchorPreparationSeq"),
            "preparationCheckpointSeq": preparation.get("anchorPreparationCheckpointSeq"),
            "preparationDetail": preparation.get("anchorPreparationDetail"),
            "pausedHeartbeatRequired": paused_heartbeat_required,
            "faultRecovery": {
                "status": str(recovery.get("status") or "healthy")[:64],
                "eligible": recovery.get("eligible") is True,
                "detail": str(recovery.get("detail") or "")[:512],
                "recoveryId": recovery.get("recoveryId"),
                "boundarySeq": recovery.get("boundarySeq"),
                "faultCode": recovery.get("faultCode"),
            },
            "automaticRecovery": dict(automatic),
            "publishedAtUnixMs": int(time.time() * 1000),
        },
    })


def validate_anchor_state(message: Mapping[str, Any]) -> dict[str, Any]:
    payload = message.get("payload")
    base = {
        "schemaVersion", "ready", "boundarySeq", "coreDigest",
        "convergenceKey", "reasons", "publishedAtUnixMs",
    }
    preparation = {
        "preparationStatus", "preparationSeq", "preparationCheckpointSeq", "preparationDetail",
    }
    receipt = {"receiptReady"}
    heartbeat = {"pausedHeartbeatRequired"}
    recovery = {"faultRecovery"}
    automatic = {"automaticRecovery"}
    schema = payload.get("schemaVersion") if isinstance(payload, dict) else None
    expected = base | preparation | receipt | heartbeat | recovery | automatic if schema == 6 \
        else base | preparation | receipt | heartbeat | recovery if schema == 5 \
        else base | preparation | receipt | heartbeat if schema == 4 \
        else base | preparation | receipt if schema == 3 \
        else base | preparation if schema == 2 else base
    if message.get("kind") != "anchor_state" or not isinstance(payload, dict) \
            or set(payload) != expected or schema not in {1, 2, 3, 4, 5, 6}:
        raise ProtocolError("anchor readiness message is malformed")
    boundary = payload.get("boundarySeq")
    published = payload.get("publishedAtUnixMs")
    if not isinstance(payload.get("ready"), bool) \
            or not isinstance(boundary, int) or isinstance(boundary, bool) or boundary < 0 \
            or not isinstance(published, int) or isinstance(published, bool) or published < 0:
        raise ProtocolError("anchor readiness values are invalid")
    for field in ("coreDigest", "convergenceKey"):
        if not isinstance(payload.get(field), str) or len(payload[field]) > 128:
            raise ProtocolError(f"anchor readiness {field} is invalid")
    reasons = payload.get("reasons")
    if not isinstance(reasons, list) or len(reasons) > 32 \
            or any(not isinstance(item, str) or len(item) > 512 for item in reasons):
        raise ProtocolError("anchor readiness reasons are invalid")
    if schema in {2, 3, 4, 5, 6}:
        if payload.get("preparationStatus") not in {
            "idle", "draining", "pause-requested", "pausing", "checkpointing", "converged",
            "ready", "failed", "superseded",
        }:
            raise ProtocolError("anchor preparation status is invalid")
        for field in ("preparationSeq", "preparationCheckpointSeq"):
            value = payload.get(field)
            if value is not None and (
                not isinstance(value, int) or isinstance(value, bool) or value < 1
            ):
                raise ProtocolError(f"anchor {field} is invalid")
        detail = payload.get("preparationDetail")
        if detail is not None and (not isinstance(detail, str) or len(detail) > 512):
            raise ProtocolError("anchor preparation detail is invalid")
    if schema in {3, 4, 5, 6} and not isinstance(payload.get("receiptReady"), bool):
        raise ProtocolError("anchor receipt readiness is invalid")
    if schema in {4, 5, 6} and not isinstance(payload.get("pausedHeartbeatRequired"), bool):
        raise ProtocolError("anchor paused-heartbeat policy is invalid")
    if schema in {5, 6}:
        fault_recovery = payload.get("faultRecovery")
        expected_recovery = {"status", "eligible", "detail", "recoveryId", "boundarySeq", "faultCode"}
        if not isinstance(fault_recovery, dict) or set(fault_recovery) != expected_recovery \
                or not isinstance(fault_recovery.get("eligible"), bool):
            raise ProtocolError("anchor fault recovery state is invalid")
        if fault_recovery.get("status") not in {
            "healthy", "waiting-evidence", "waiting-quiescence", "ready", "probing",
            "recovered", "rollback-required",
        } or not isinstance(fault_recovery.get("detail"), str) \
                or len(fault_recovery["detail"]) > 512:
            raise ProtocolError("anchor fault recovery status is invalid")
        for field in ("recoveryId", "faultCode"):
            value = fault_recovery.get(field)
            if value is not None and (not isinstance(value, str) or len(value) > 512):
                raise ProtocolError(f"anchor fault recovery {field} is invalid")
        boundary = fault_recovery.get("boundarySeq")
        if boundary is not None and (
            not isinstance(boundary, int) or isinstance(boundary, bool) or boundary < 1
        ):
            raise ProtocolError("anchor fault recovery boundary is invalid")
    if schema == 6:
        validate_automatic_recovery(payload.get("automaticRecovery"))
    return dict(payload)
