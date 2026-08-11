"""Transient, authenticated host-to-client recovery readiness state."""

from __future__ import annotations

import time
from typing import Any, Mapping

from .protocol import PROTOCOL_VERSION, ProtocolError, sign


def anchor_state_message(
    session: str, peer: str, readiness: Mapping[str, Any],
    preparation: Mapping[str, Any] | None = None,
    receipt_readiness: Mapping[str, Any] | None = None,
    paused_heartbeat_required: bool = True,
) -> dict[str, Any]:
    """Build transient host readiness sent to every client companion."""

    preparation = preparation or {}
    receipt_readiness = receipt_readiness or readiness
    return sign({
        "protocol": PROTOCOL_VERSION,
        "session": session,
        "kind": "anchor_state",
        "peer": peer,
        "payload": {
            "schemaVersion": 4,
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
    schema = payload.get("schemaVersion") if isinstance(payload, dict) else None
    expected = base | preparation | receipt | heartbeat if schema == 4 \
        else base | preparation | receipt if schema == 3 \
        else base | preparation if schema == 2 else base
    if message.get("kind") != "anchor_state" or not isinstance(payload, dict) \
            or set(payload) != expected or schema not in {1, 2, 3, 4}:
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
    if schema in {2, 3, 4}:
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
    if schema in {3, 4} and not isinstance(payload.get("receiptReady"), bool):
        raise ProtocolError("anchor receipt readiness is invalid")
    if schema == 4 and not isinstance(payload.get("pausedHeartbeatRequired"), bool):
        raise ProtocolError("anchor paused-heartbeat policy is invalid")
    return dict(payload)
