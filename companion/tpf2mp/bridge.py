from __future__ import annotations

import json
import errno
import os
import threading
import time
from pathlib import Path
from typing import Any, Iterator, Mapping

from .protocol import ProtocolError, canonical_json, decode_line, validate_envelope
from .audit_log import AuditLog, AuditUnavailable


_ATOMIC_REPLACE_ATTEMPTS = 50
_ATOMIC_REPLACE_DELAY_SECONDS = 0.02
_RETRYABLE_REPLACE_ERRNOS = {errno.EACCES, errno.EBUSY, errno.EPERM}
_RETRYABLE_REPLACE_WINERRORS = {5, 32, 33}
_EPHEMERAL_OUTBOX_RETENTION = 4096


def _retryable_file_error(exc: OSError) -> bool:
    return (
        exc.errno in _RETRYABLE_REPLACE_ERRNOS
        or getattr(exc, "winerror", None) in _RETRYABLE_REPLACE_WINERRORS
    )


def _sequence(path: Path) -> int:
    try:
        return int(path.stem)
    except ValueError:
        return -1


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # Status can be refreshed by the socket receiver while the owning loop is
    # publishing its cadence sample. A PID-only temporary name lets those two
    # writers delete/replace each other's file on Windows. They may race on
    # the replace (last complete status wins), but never on the temporary.
    temporary = path.with_name(
        f".{path.name}.{os.getpid()}.{threading.get_ident()}.tmp"
    )
    with temporary.open("wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    # Build 35924 polls companion_status.json from Lua. On Windows that reader
    # can briefly open the old file without FILE_SHARE_DELETE, making an
    # otherwise atomic os.replace fail with access denied/sharing violation.
    # Keep the write atomic, but tolerate that bounded transient window instead
    # of terminating the host companion and stranding every connected client.
    for attempt in range(_ATOMIC_REPLACE_ATTEMPTS):
        try:
            os.replace(temporary, path)
            return
        except OSError as exc:
            if not _retryable_file_error(exc) or attempt + 1 >= _ATOMIC_REPLACE_ATTEMPTS:
                raise
            time.sleep(_ATOMIC_REPLACE_DELAY_SECONDS)


class GameBridge:
    """Reliable cursor over the game's immutable numbered file queues."""

    def __init__(self, root: Path | str, session: str, peer: str) -> None:
        self.root = Path(root).expanduser().resolve()
        self.session = session
        self.peer = peer
        self.outbox = self.root / "game_outbox"
        self.inbox = self.root / "game_inbox"
        self.state_dir = self.root / "companion_state"
        self.audit_dir = self.root / "audit"
        self.content_dir = self.root / "content"
        self.industry_content_dir = self.content_dir / "industry"
        for directory in (
            self.outbox, self.inbox, self.state_dir, self.audit_dir,
            self.industry_content_dir,
        ):
            directory.mkdir(parents=True, exist_ok=True)
        self.cursor_path = self.state_dir / f"outbox_cursor_{session}.json"
        self.status_path = self.state_dir / "companion_status.json"
        self.outbox_ephemeral_retention = _EPHEMERAL_OUTBOX_RETENTION
        self.outbox_pruned_through = 0
        self.outbox_cursor = self._load_cursor()

    def _load_cursor(self) -> int:
        try:
            value = json.loads(self.cursor_path.read_text(encoding="utf-8"))
            if value.get("session") == self.session:
                cursor = max(0, int(value.get("last_local_seq", 0)))
                # Schema-1 cursor files predate bounded retention. Treat their
                # old acknowledged prefix as already outside the new retention
                # window instead of issuing thousands of deletes on restart.
                self.outbox_pruned_through = min(
                    cursor,
                    max(0, int(value.get(
                        "pruned_through",
                        max(0, cursor - _EPHEMERAL_OUTBOX_RETENTION),
                    ))),
                )
                return cursor
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            pass
        return 0

    def _save_cursor(self) -> None:
        data = canonical_json({
            "schemaVersion": 2,
            "session": self.session,
            "last_local_seq": self.outbox_cursor,
            "pruned_through": self.outbox_pruned_through,
            "ephemeral_retention_messages": _EPHEMERAL_OUTBOX_RETENTION,
        })
        atomic_write(self.cursor_path, (data + "\n").encode("utf-8"))

    def pending_outbound(self, limit: int = 64) -> Iterator[tuple[int, dict[str, Any]]]:
        # The game queue is immutable and contiguous. Looking up exactly the
        # cursor's successor is O(limit); globbing and sorting the complete
        # session history here made every 10 Hz companion poll O(history).
        # A missing successor is a queue gap, never permission to skip ahead.
        seq = self.outbox_cursor + 1
        for _ in range(max(0, limit)):
            path = self.outbox / f"{seq:012d}.json"
            if not path.exists():
                break
            try:
                message = decode_line(path.read_bytes())
                validate_envelope(message, self.session)
            except (OSError, ProtocolError) as exc:
                raise ProtocolError(f"cannot consume {path}: {exc}") from exc
            local_seq = int(message.get("local_seq", -1))
            if local_seq != seq:
                raise ProtocolError(f"filename/message sequence mismatch at {path}")
            if str(message.get("peer")) != self.peer:
                raise ProtocolError(f"peer mismatch in {path}: {message.get('peer')}")
            yield seq, message
            seq += 1

    def _prune_acknowledged_outbox(self) -> None:
        target = max(0, self.outbox_cursor - _EPHEMERAL_OUTBOX_RETENTION)
        if target <= self.outbox_pruned_through:
            return
        # Keep every durable checkpoint/event/intent/completion/research record
        # in the bridge for offline tools. Clock health and vehicle state are
        # replaceable telemetry is reflected in live authority state (with a
        # sampled clock-health forensic trail); retain a generous local tail
        # while bounding a long session's inode count.
        for seq in range(self.outbox_pruned_through + 1, target + 1):
            path = self.outbox / f"{seq:012d}.json"
            try:
                message = decode_line(path.read_bytes())
                if message.get("kind") in {"clock_health", "vehicle_sync"}:
                    path.unlink(missing_ok=True)
            except (OSError, ProtocolError):
                # Missing files are already pruned. An unexpected unreadable
                # acknowledged record is retained for evidence, never erased.
                pass
        self.outbox_pruned_through = target

    def acknowledge_outbound(self, seq: int) -> None:
        if seq < self.outbox_cursor:
            return
        if seq > self.outbox_cursor + 1 and self.outbox_cursor != 0:
            raise ProtocolError(f"outbox acknowledgement gap: {self.outbox_cursor} -> {seq}")
        self.outbox_cursor = seq
        self._prune_acknowledged_outbox()
        self._save_cursor()

    def write_inbound(self, message: Mapping[str, Any]) -> Path:
        validate_envelope(message, self.session)
        seq = int(message.get("seq", -1))
        if seq < 1:
            raise ProtocolError("inbound commit has no positive global sequence")
        path = self.inbox / f"{seq:012d}.json"
        payload = (canonical_json(message) + "\n").encode("utf-8")
        if path.exists():
            if path.read_bytes() != payload:
                raise ProtocolError(f"conflicting inbound commit at sequence {seq}")
            return path
        atomic_write(path, payload)
        return path

    def existing_commit_sequences(self) -> set[int]:
        result: set[int] = set()
        for path in self.inbox.glob("*.json"):
            try:
                message = decode_line(path.read_bytes())
                if message.get("session") == self.session and message.get("kind") in {"commit", "control"}:
                    result.add(int(message["seq"]))
            except (OSError, KeyError, TypeError, ValueError, ProtocolError):
                continue
        return result

    def write_status(self, values: Mapping[str, Any]) -> Path:
        """Publish replaceable launcher/UI health without entering the commit log."""

        status = dict(values)
        status.setdefault("schemaVersion", 1)
        status.setdefault("session", self.session)
        status.setdefault("peer", self.peer)
        status["pid"] = os.getpid()
        status["updatedAtUnixMs"] = int(time.time() * 1000)
        atomic_write(
            self.status_path,
            (canonical_json(status) + "\n").encode("utf-8"),
        )
        return self.status_path
