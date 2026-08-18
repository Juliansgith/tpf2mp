"""Fail-closed host-to-client delivery of a verified coordinated restore plan."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Mapping

from .bridge import GameBridge, atomic_write
from .protocol import (
    PROTOCOL_VERSION, ProtocolError, canonical_json, sign, validate_envelope,
)
from .restore_plan import RESTORE_PLAN_VERSION, verify_restore_plan


class RestorePlanExchange:
    """Publishes one host-watcher plan and durably receives it on each client."""

    def __init__(self, bridge: GameBridge) -> None:
        self.bridge = bridge
        self.published_path = bridge.state_dir / "published_restore_plan.json"
        self.received_path = bridge.state_dir / "received_restore_plan.json"
        self.last_published_checksum: str | None = None
        self._published_signature: tuple[int, int] | None = None
        self.last_received_checksum: str | None = None
        self.last_error: str | None = None

    def _read_verified(self, path: Path) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ProtocolError(f"cannot read restore plan exchange file: {exc}") from exc
        plan = verify_restore_plan(value)
        if plan["version"] != RESTORE_PLAN_VERSION:
            raise ProtocolError(
                "restore plan exchange requires a current native-phase-bound plan"
            )
        if plan["session"] != self.bridge.session:
            raise ProtocolError("restore plan exchange names a different source session")
        return plan

    def published_message(self, force: bool = False) -> dict[str, Any] | None:
        if not self.published_path.is_file():
            self._published_signature = None
            return None
        try:
            info = self.published_path.stat()
            signature = (info.st_size, info.st_mtime_ns)
        except OSError as exc:
            self.last_error = f"cannot inspect restore plan exchange file: {exc}"
            return None
        if not force and signature == self._published_signature:
            return None
        self._published_signature = signature
        try:
            plan = self._read_verified(self.published_path)
        except ProtocolError as exc:
            self.last_error = str(exc)
            return None
        plan_checksum = str(plan["checksum"])
        if not force and plan_checksum == self.last_published_checksum:
            return None
        self.last_published_checksum = plan_checksum
        self.last_error = None
        return sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.bridge.session,
            "kind": "restore_plan",
            "peer": self.bridge.peer,
            "payload": {"schemaVersion": 1, "plan": plan},
        })

    def accept(self, message: Mapping[str, Any]) -> dict[str, Any]:
        validate_envelope(message, self.bridge.session)
        payload = message.get("payload")
        if message.get("kind") != "restore_plan" or message.get("peer") != "player1" \
                or not isinstance(payload, Mapping) \
                or set(payload) != {"schemaVersion", "plan"} \
                or payload.get("schemaVersion") != 1:
            raise ProtocolError("restore plan exchange message is malformed")
        plan = verify_restore_plan(payload.get("plan"))
        if plan["version"] != RESTORE_PLAN_VERSION:
            raise ProtocolError(
                "received restore plan is not native-phase-bound"
            )
        if plan["session"] != self.bridge.session:
            raise ProtocolError("received restore plan names a different source session")
        atomic_write(
            self.received_path,
            (canonical_json(plan) + "\n").encode("utf-8"),
        )
        self.last_received_checksum = str(plan["checksum"])
        self.last_error = None
        return plan

    def status(self) -> dict[str, Any]:
        return {
            "publishedRestorePlanChecksum": self.last_published_checksum,
            "receivedRestorePlanChecksum": self.last_received_checksum,
            "receivedRestorePlanPath": (
                str(self.received_path) if self.received_path.is_file() else None
            ),
            "restorePlanExchangeError": self.last_error,
        }
