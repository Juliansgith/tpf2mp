"""Durable-in-memory cursor updates after relay diagnostic acceptance."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping

from .diagnostic_sampling import LOG_DEDUP_SECONDS, log_digest


@dataclass
class SourceCursor:
    name: str
    path: Path
    offset: int = 0
    identity: tuple[int, int] | None = None
    last_snapshot_hash: str | None = None
    last_snapshot_emitted_at: float = 0.0
    last_critical_hash: str | None = None
    recent_log_hashes: dict[str, float] | None = None


CursorAdvance = tuple[
    SourceCursor, int, tuple[int, int] | None, str | None, str | None,
]


def apply_advances(
    advances: Iterable[CursorAdvance], *, emitted_at: float | None = None,
) -> None:
    for cursor, offset, identity, snapshot_hash, critical_hash in advances:
        cursor.offset = offset
        cursor.identity = identity
        cursor.last_snapshot_hash = snapshot_hash
        cursor.last_critical_hash = critical_hash
        if emitted_at is not None and snapshot_hash is not None:
            cursor.last_snapshot_emitted_at = emitted_at
        if emitted_at is not None and cursor.recent_log_hashes:
            cursor.recent_log_hashes = {
                digest: prior
                for digest, prior in cursor.recent_log_hashes.items()
                if emitted_at - prior < LOG_DEDUP_SECONDS
            }


def remember_uploaded_logs(
    sources: Iterable[SourceCursor], events: Iterable[Mapping[str, Any]], emitted_at: float,
) -> None:
    by_name = {cursor.name: cursor for cursor in sources}
    for event in events:
        if event.get("type") != "client.log":
            continue
        payload = event.get("payload", {})
        cursor = by_name.get(str(payload.get("source", "")))
        if cursor is None:
            continue
        cursor.recent_log_hashes = cursor.recent_log_hashes or {}
        cursor.recent_log_hashes[log_digest(str(payload.get("message", "")))] = emitted_at
