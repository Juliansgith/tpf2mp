from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .bridge import atomic_write
from .diagnostic_redaction import redact, redact_text
from .relay_api import RelayApiError, RelayCredentials, upload_diagnostics


MAX_LINE_BYTES = 4096
MAX_READ_BYTES = 64 * 1024
MAX_BATCH_EVENTS = 40
MAX_EVENT_TEXT_BYTES = 4096


def _bounded_utf8(value: str, maximum: int = MAX_EVENT_TEXT_BYTES) -> str:
    encoded = value.encode("utf-8")
    if len(encoded) <= maximum:
        return value
    return encoded[:maximum].decode("utf-8", "ignore")


@dataclass
class SourceCursor:
    name: str
    path: Path
    offset: int = 0
    identity: tuple[int, int] | None = None
    last_snapshot_hash: str | None = None


class RelayDiagnosticReporter:
    """Upload bounded text/status evidence; never discovers arbitrary files."""

    def __init__(
        self,
        credentials: RelayCredentials,
        sources: Mapping[str, Path | str],
        *,
        status_path: Path | str | None = None,
        interval_seconds: float = 2.0,
    ) -> None:
        if not 0.5 <= interval_seconds <= 60.0:
            raise RelayApiError("diagnostic interval must be between 0.5 and 60 seconds")
        self.credentials = credentials
        self.sources: list[SourceCursor] = []
        for name, raw_path in sources.items():
            if not name or len(name) > 64 or any(character < " " for character in name):
                raise RelayApiError("diagnostic source name is invalid")
            path = Path(raw_path).expanduser().resolve()
            if path.suffix.lower() not in {".log", ".txt", ".json", ".ndjson"}:
                raise RelayApiError("diagnostic sources must be explicit text or JSON files")
            self.sources.append(SourceCursor(name, path))
        if not self.sources or len(self.sources) > 32:
            raise RelayApiError("diagnostic reporter requires 1-32 explicit sources")
        self.status_path = Path(status_path).expanduser().resolve() if status_path else None
        self.interval_seconds = interval_seconds
        self.stop = threading.Event()
        self.uploaded_events = 0
        self.upload_failures = 0
        self.last_error: str | None = None
        self.started_at = int(time.time())

    def run(self) -> None:
        self._publish("running")
        try:
            while not self.stop.wait(self.interval_seconds):
                events, advances = self._collect()
                if not events:
                    self._publish("running")
                    continue
                try:
                    accepted = upload_diagnostics(self.credentials, events)
                    if accepted != len(events):
                        raise RelayApiError("relay accepted only part of a diagnostic batch")
                    for cursor, offset, identity, snapshot_hash in advances:
                        cursor.offset = offset
                        cursor.identity = identity
                        cursor.last_snapshot_hash = snapshot_hash
                    self.uploaded_events += accepted
                    self.last_error = None
                    self._publish("running")
                except RelayApiError as exc:
                    self.upload_failures += 1
                    self.last_error = str(exc)[:500]
                    self._publish("retrying")
        except KeyboardInterrupt:
            pass
        finally:
            self._publish("stopped")

    def _collect(
        self,
    ) -> tuple[
        list[dict[str, Any]],
        list[tuple[SourceCursor, int, tuple[int, int] | None, str | None]],
    ]:
        events: list[dict[str, Any]] = []
        advances: list[tuple[SourceCursor, int, tuple[int, int] | None, str | None]] = []
        now = int(time.time())
        for cursor in self.sources:
            if len(events) >= MAX_BATCH_EVENTS:
                break
            try:
                stat = cursor.path.stat()
            except OSError:
                continue
            identity = (int(stat.st_dev), int(stat.st_ino))
            # Do not mutate the durable cursor until the relay accepts this
            # batch.  In particular, a rotation followed by an upload outage
            # must not silently discard the beginning of the replacement log.
            start_offset = cursor.offset
            if cursor.identity is not None and cursor.identity != identity:
                start_offset = 0
            if stat.st_size < start_offset:
                start_offset = 0
            if cursor.path.suffix.lower() == ".json":
                if stat.st_size > MAX_READ_BYTES:
                    continue
                try:
                    raw = cursor.path.read_bytes()
                except OSError:
                    continue
                digest = hashlib.sha256(raw).hexdigest()
                if digest == cursor.last_snapshot_hash:
                    continue
                try:
                    payload = json.loads(raw.decode("utf-8-sig"))
                except (UnicodeError, json.JSONDecodeError):
                    payload = {"message": raw[:MAX_LINE_BYTES].decode("utf-8", "replace")}
                sanitized = redact(payload)
                rendered = json.dumps(
                    sanitized, sort_keys=True, separators=(",", ":"), ensure_ascii=False
                )
                rendered_bytes = rendered.encode("utf-8")
                if len(rendered_bytes) > MAX_EVENT_TEXT_BYTES:
                    sanitized = {
                        "contentSha256": digest,
                        "statusText": _bounded_utf8(rendered),
                        "truncated": True,
                    }
                events.append({
                    "type": "client.status",
                    "severity": "info",
                    "occurredAt": now,
                    "payload": {"source": cursor.name, "status": sanitized},
                })
                advances.append((cursor, stat.st_size, identity, digest))
                continue
            try:
                with cursor.path.open("rb") as handle:
                    handle.seek(start_offset)
                    raw = handle.read(MAX_READ_BYTES)
            except OSError:
                continue
            if not raw:
                advances.append((cursor, start_offset, identity, cursor.last_snapshot_hash))
                continue
            complete_end = raw.rfind(b"\n")
            if complete_end < 0 and len(raw) < MAX_READ_BYTES:
                complete_end = len(raw) - 1
            if complete_end < 0:
                # A hostile or corrupt unbounded line is consumed in chunks and
                # represented as one truncated event instead of wedging the tail.
                chunks = [raw]
            else:
                chunks = raw[:complete_end + 1].splitlines(keepends=True)
            consumed = 0
            for chunk in chunks:
                line = chunk.rstrip(b"\r\n")
                if not line:
                    consumed += len(chunk)
                    continue
                # Stop advancing at exactly the last emitted line.  The old
                # implementation advanced over the entire 64-KiB read even
                # when the 128-event batch cap cut it short.
                if len(events) >= MAX_BATCH_EVENTS:
                    break
                message = _bounded_utf8(redact_text(
                    line[:MAX_LINE_BYTES].decode("utf-8", "replace")
                ))
                events.append({
                    "type": "client.log",
                    "severity": "error" if "error" in message.lower() else "info",
                    "occurredAt": now,
                    "payload": {
                        "source": cursor.name,
                        "message": message,
                        "truncated": len(line) > MAX_LINE_BYTES,
                    },
                })
                consumed += len(chunk)
            advances.append((
                cursor,
                start_offset + consumed,
                identity,
                cursor.last_snapshot_hash,
            ))
        return events, advances

    def _publish(self, state: str) -> None:
        if self.status_path is None:
            return
        value = {
            "schemaVersion": 1,
            "pid": os.getpid(),
            "sessionId": self.credentials.session_id,
            "supportId": self.credentials.session_id,
            "role": self.credentials.role,
            "state": state,
            "uploadedEvents": self.uploaded_events,
            "uploadFailures": self.upload_failures,
            "lastError": self.last_error,
            "startedAtUnix": self.started_at,
            "updatedAtUnix": int(time.time()),
            "sources": [cursor.name for cursor in self.sources],
        }
        atomic_write(
            self.status_path,
            (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
            durable=False,
        )
