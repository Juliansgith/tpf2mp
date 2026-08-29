"""Semantic sampling policy for relay diagnostics."""

from __future__ import annotations

import hashlib
import json
from typing import Any, Mapping


STATUS_STEADY_SECONDS = 20.0
LOG_DEDUP_SECONDS = 60.0
_CRITICAL_KEYS = {
    "state", "status", "error", "lastError", "sessionFault", "connected",
    "socketConnected", "synchronized", "anchorReady", "anchorReceiptReady",
    "anchorPreparationStatus", "restorePoints", "faultRecovery",
    "automaticRecovery", "uiSaveFallbackStatus", "receiptStatus", "channels",
}
_GAME_IMPORTANT = (
    "error", "exception", "assert", "crash", "fault", "failure", "rejected",
    '"success":false', "internal", "rollback", "timeout",
)


def critical_status_hash(value: Any) -> str:
    def project(item: Any) -> Any:
        if isinstance(item, Mapping):
            projected = {}
            for key, child in item.items():
                name = str(key)
                if name in _CRITICAL_KEYS:
                    projected[name] = child
                    continue
                nested = project(child)
                if nested not in ({}, []):
                    projected[name] = nested
            return projected
        if isinstance(item, list):
            return [child for child in (project(value) for value in item[:32]) if child]
        return None

    encoded = json.dumps(
        project(value), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def emit_status_now(
    *, last_emitted_at: float, last_critical_hash: str | None,
    critical_hash: str, now: float,
) -> bool:
    return last_emitted_at <= 0 \
        or critical_hash != last_critical_hash \
        or now - last_emitted_at >= STATUS_STEADY_SECONDS


def emit_log_line(source: str, message: str) -> bool:
    if source != "game.stdout":
        return True
    lowered = message.lower()
    return any(marker in lowered for marker in _GAME_IMPORTANT)


def log_digest(message: str) -> str:
    return hashlib.sha256(message.encode("utf-8")).hexdigest()
