"""Local save-watcher handoff and peer-to-peer anchor readiness transport.

The PowerShell watcher proves which native process and save directory it is
observing.  The already-authenticated companion must still create the ordered
receipt: letting a second process write directly into the game's positive
``local_seq`` namespace would reintroduce sequence collisions and FIFO gaps.
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Any, Iterator, Mapping

from .anchor_state import anchor_state_message, validate_anchor_state
from .bridge import GameBridge, atomic_write
from .native_save import hash_load_bearing_save
from .protocol import (
    PROTOCOL_VERSION,
    ProtocolError,
    canonical_json,
    sign,
    validate_action,
)


class AnchorRequestStore:
    """Durable local queue from the native-save watcher to its companion."""

    def __init__(self, bridge: GameBridge) -> None:
        self.bridge = bridge
        self.requests = bridge.state_dir / "anchor_requests"
        self.results = bridge.state_dir / "anchor_results"
        self.requests.mkdir(parents=True, exist_ok=True)
        self.results.mkdir(parents=True, exist_ok=True)
        self._status_cache: dict[str, Any] | None = None

    def _read(self, path: Path) -> dict[str, Any]:
        try:
            value = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ProtocolError(f"cannot read anchor request {path.name}: {exc}") from exc
        expected = {
            "schemaVersion", "session", "peer", "requestId", "boundarySeq",
            "coreDigest", "convergenceKey", "savePath", "savedAtUnix",
        }
        if not isinstance(value, dict) or set(value) != expected \
                or value.get("schemaVersion") != 1 \
                or value.get("session") != self.bridge.session \
                or value.get("peer") != self.bridge.peer:
            raise ProtocolError(f"anchor request {path.name} has an invalid identity or schema")
        request_id = value.get("requestId")
        boundary = value.get("boundarySeq")
        saved_at = value.get("savedAtUnix")
        if not isinstance(request_id, str) or len(request_id) != 32 \
                or any(character not in "0123456789abcdef" for character in request_id) \
                or not isinstance(boundary, int) or isinstance(boundary, bool) or boundary < 1 \
                or not isinstance(saved_at, int) or isinstance(saved_at, bool) or saved_at < 0:
            raise ProtocolError(f"anchor request {path.name} has invalid values")
        for field in ("coreDigest", "convergenceKey"):
            item = value.get(field)
            if not isinstance(item, str) or not item or len(item) > 128:
                raise ProtocolError(f"anchor request {path.name} has invalid {field}")
        save = Path(str(value.get("savePath", ""))).expanduser().resolve()
        if save.suffix.lower() != ".sav" or not save.is_file():
            raise ProtocolError(f"anchor request save is missing or is not a .sav: {save}")
        value["savePath"] = str(save)
        return value

    def _result_path(self, request_id: str) -> Path:
        return self.results / f"{request_id}.json"

    def _result(self, request_id: str) -> dict[str, Any] | None:
        path = self._result_path(request_id)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
            return value if isinstance(value, dict) else None
        except (OSError, json.JSONDecodeError):
            return None

    def _write_result(self, request_id: str, value: Mapping[str, Any]) -> None:
        result = {
            "schemaVersion": 1,
            "session": self.bridge.session,
            "peer": self.bridge.peer,
            "requestId": request_id,
            **dict(value),
            "updatedAtUnixMs": int(time.time() * 1000),
        }
        atomic_write(
            self._result_path(request_id),
            (canonical_json(result) + "\n").encode("utf-8"),
        )
        self._status_cache = None

    def pending(self) -> Iterator[dict[str, Any]]:
        for path in sorted(self.requests.glob("*.json")):
            request_id = path.stem
            valid_id = len(request_id) == 32 and all(
                character in "0123456789abcdef" for character in request_id
            )
            result = self._result(request_id) if valid_id else None
            if result and result.get("status") in {"accepted", "rejected"}:
                continue
            try:
                request = self._read(path)
            except ProtocolError as exc:
                # A watcher may move, replace, or lose a just-written save
                # before the companion's next poll. Reject that durable queue
                # item in isolation; never terminate the authenticated host or
                # client process and strand the whole session.
                if valid_id:
                    self._write_result(request_id, {
                        "status": "rejected",
                        "boundarySeq": None,
                        "saveSha256": None,
                        "metadataSha256": None,
                        "localSeq": None,
                        "error": str(exc)[:1024],
                    })
                continue
            result = self._result(request["requestId"])
            if not result or result.get("status") not in {"accepted", "rejected"}:
                yield request

    @staticmethod
    def _matches_state(request: Mapping[str, Any], state: Mapping[str, Any]) -> bool:
        return state.get("receiptReady", state.get("ready")) is True \
            and int(state.get("boundarySeq", 0)) == int(request["boundarySeq"]) \
            and state.get("coreDigest") == request["coreDigest"] \
            and state.get("convergenceKey") == request["convergenceKey"]

    def process_host(self, anchor: Any) -> bool:
        changed = False
        for request in self.pending():
            try:
                readiness = anchor.readiness(receipt=True)
                if not self._matches_state(request, readiness):
                    raise ProtocolError("anchor request no longer matches a READY boundary")
                result = anchor.anchor_save(request["savePath"], request["savedAtUnix"])
                self._write_result(request["requestId"], {
                    "status": "accepted",
                    "boundarySeq": request["boundarySeq"],
                    "saveSha256": result["saveSha256"],
                    "metadataSha256": result.get("metadataSha256"),
                    "localSeq": None,
                    "error": None,
                })
            except (OSError, ProtocolError, ValueError) as exc:
                self._write_result(request["requestId"], {
                    "status": "rejected",
                    "boundarySeq": request["boundarySeq"],
                    "saveSha256": None,
                    "metadataSha256": None,
                    "localSeq": None,
                    "error": str(exc)[:1024],
                })
            changed = True
        return changed

    def _allocate_client_seq(self) -> int:
        used = []
        for path in self.results.glob("*.json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
                sequence = value.get("localSeq")
                if isinstance(sequence, int) and not isinstance(sequence, bool) and sequence < 0:
                    used.append(sequence)
            except (OSError, json.JSONDecodeError):
                continue
        return min(used, default=0) - 1

    def client_intents(self, anchor_state: Mapping[str, Any] | None) -> Iterator[dict[str, Any]]:
        if not isinstance(anchor_state, Mapping):
            return
        for request in self.pending():
            result = self._result(request["requestId"])
            if result and result.get("status") == "pending" \
                    and isinstance(result.get("intent"), dict):
                yield dict(result["intent"])
                continue
            if not self._matches_state(request, anchor_state):
                continue
            try:
                save_hashes = hash_load_bearing_save(request["savePath"])
                receipt = validate_action({
                    "type": "recovery.save_receipt",
                    "boundarySeq": request["boundarySeq"],
                    "savedAtUnix": request["savedAtUnix"],
                    "saveSha256": save_hashes["saveSha256"],
                    "metadataSha256": save_hashes["metadataSha256"],
                    "coreDigest": request["coreDigest"],
                    "convergenceKey": request["convergenceKey"],
                    "paused": True,
                })
            except (OSError, ProtocolError, ValueError) as exc:
                self._write_result(request["requestId"], {
                    "status": "rejected",
                    "boundarySeq": request["boundarySeq"],
                    "saveSha256": None,
                    "metadataSha256": None,
                    "localSeq": None,
                    "error": str(exc)[:1024],
                })
                continue
            local_seq = self._allocate_client_seq()
            intent = sign({
                "protocol": PROTOCOL_VERSION,
                "session": self.bridge.session,
                "peer": self.bridge.peer,
                "local_seq": local_seq,
                "tick": 0,
                "kind": "intent",
                "payload": {"action": receipt},
            })
            self._write_result(request["requestId"], {
                "status": "pending",
                "boundarySeq": request["boundarySeq"],
                "saveSha256": receipt["saveSha256"],
                "metadataSha256": receipt["metadataSha256"],
                "localSeq": local_seq,
                "intent": intent,
                "error": None,
            })
            yield intent

    def record_receipt(self, local_seq: int, accepted: bool, reason: str | None) -> bool:
        for path in self.results.glob("*.json"):
            try:
                result = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if result.get("status") != "pending" or result.get("localSeq") != local_seq:
                continue
            self._write_result(str(result["requestId"]), {
                "status": "accepted" if accepted else "rejected",
                "boundarySeq": result.get("boundarySeq"),
                "saveSha256": result.get("saveSha256"),
                "metadataSha256": result.get("metadataSha256"),
                "localSeq": local_seq,
                "error": None if accepted else str(reason or "host rejected receipt")[:1024],
            })
            return True
        return False

    def status(self) -> dict[str, Any]:
        if self._status_cache is not None:
            return dict(self._status_cache)
        accepted: set[int] = set()
        pending = 0
        last_error: str | None = None
        for path in self.results.glob("*.json"):
            try:
                result = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if result.get("status") == "accepted":
                accepted.add(int(result.get("boundarySeq", 0)))
            elif result.get("status") == "pending":
                pending += 1
            elif result.get("error"):
                last_error = str(result["error"])
        self._status_cache = {
            "localAnchorsFiled": sorted(value for value in accepted if value > 0),
            "pendingAnchorRequests": pending,
            "lastAnchorRequestError": last_error,
        }
        return dict(self._status_cache)
