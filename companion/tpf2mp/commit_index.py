"""Incremental index over the client's immutable inbound commit queue."""

from __future__ import annotations

import threading
from pathlib import Path

from .protocol import ProtocolError, decode_line


class InboundCommitIndex:
    """Scan history once, then advance from commits written by GameBridge."""

    def __init__(self, directory: Path, session: str) -> None:
        self.directory = directory
        self.session = session
        self._lock = threading.Lock()
        self._sequences: set[int] | None = None
        self._contiguous = 0

    def _scan(self) -> set[int]:
        result: set[int] = set()
        for path in self.directory.glob("*.json"):
            try:
                message = decode_line(path.read_bytes())
                if message.get("session") == self.session \
                        and message.get("kind") in {"commit", "control"}:
                    result.add(int(message["seq"]))
            except (OSError, KeyError, TypeError, ValueError, ProtocolError):
                continue
        return result

    def _ensure(self) -> None:
        if self._sequences is None:
            self._sequences = self._scan()
            self._advance()

    def _advance(self) -> None:
        assert self._sequences is not None
        while self._contiguous + 1 in self._sequences:
            self._contiguous += 1

    def remember(self, sequence: int) -> None:
        with self._lock:
            if self._sequences is None:
                return
            self._sequences.add(sequence)
            self._advance()

    def sequences(self) -> set[int]:
        with self._lock:
            self._ensure()
            return set(self._sequences or ())

    def last_contiguous(self) -> int:
        with self._lock:
            self._ensure()
            return self._contiguous
