from __future__ import annotations

import errno
import os
import threading
import time
from pathlib import Path
from typing import Any, Iterator, Mapping

from .protocol import ProtocolError, canonical_json, decode_line


_OPEN_ATTEMPTS = 250
_OPEN_DELAY_SECONDS = 0.02
_RETRYABLE_ERRNOS = {errno.EACCES, errno.EBUSY, errno.EPERM}
_RETRYABLE_WINERRORS = {5, 32, 33}


class AuditUnavailable(OSError):
    """The durable authority journal could not be opened after bounded retries."""


def _retryable(exc: OSError) -> bool:
    return (
        exc.errno in _RETRYABLE_ERRNOS
        or getattr(exc, "winerror", None) in _RETRYABLE_WINERRORS
    )


class AuditLog:
    def __init__(self, path: Path | str) -> None:
        self.path = Path(path).expanduser().resolve()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._append_lock = threading.Lock()
        self.append_retries = 0
        self.read_retries = 0

    def _open_with_retry(self, mode: str):
        retries = 0
        for attempt in range(_OPEN_ATTEMPTS):
            try:
                handle = self.path.open(mode)
                if mode == "ab":
                    self.append_retries += retries
                else:
                    self.read_retries += retries
                return handle
            except OSError as exc:
                if mode == "rb" and isinstance(exc, FileNotFoundError):
                    raise
                if not _retryable(exc) or attempt + 1 >= _OPEN_ATTEMPTS:
                    operation = "append" if mode == "ab" else "read"
                    raise AuditUnavailable(
                        exc.errno or errno.EIO,
                        f"cannot {operation} authority audit after "
                        f"{attempt + 1} attempts: {exc}",
                        str(self.path),
                    ) from exc
                retries += 1
                time.sleep(_OPEN_DELAY_SECONDS)

    def append(self, message: Mapping[str, Any]) -> None:
        line = (canonical_json(message) + "\n").encode("utf-8")
        # One host owns the journal. Serializing append opens also prevents
        # its peer receiver threads from interleaving durable records.
        with self._append_lock:
            try:
                with self._open_with_retry("ab") as handle:
                    handle.write(line)
                    handle.flush()
                    os.fsync(handle.fileno())
            except AuditUnavailable:
                raise
            except OSError as exc:
                # Never retry after an uncertain write: that could duplicate
                # an authority record. Fence the host and recover instead.
                raise AuditUnavailable(
                    exc.errno or errno.EIO,
                    f"cannot durably append authority audit: {exc}",
                    str(self.path),
                ) from exc

    def messages(self) -> Iterator[dict[str, Any]]:
        if not self.path.exists():
            return
        # Close the Windows handle before parsing a potentially long replay.
        # Live appends only overlap the short byte-snapshot operation.
        try:
            with self._open_with_retry("rb") as handle:
                snapshot = handle.read()
        except FileNotFoundError:
            return
        for number, raw in enumerate(snapshot.splitlines(keepends=True), 1):
            if not raw.strip():
                continue
            try:
                yield decode_line(raw)
            except ProtocolError as exc:
                raise ProtocolError(f"invalid audit line {number}: {exc}") from exc
