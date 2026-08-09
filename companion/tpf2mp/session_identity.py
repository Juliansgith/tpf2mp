"""Portable match and restore-session identities shared with the Lua runtime."""

from __future__ import annotations

import re
import zlib
from typing import Any

from .protocol import MAX_EXACT_INTEGER, ProtocolError

MAX_SESSION_LENGTH = 64
_SESSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")


def validate_session_id(value: Any, label: str = "session") -> str:
    if not isinstance(value, str) or _SESSION.fullmatch(value) is None:
        raise ProtocolError(
            f"{label} must be 1-64 ASCII letters, digits, dots, underscores, or hyphens"
        )
    return value


def _adler_text(value: str) -> str:
    return f"{zlib.adler32(value.encode('ascii')) & 0xFFFFFFFF:08x}"


def derive_resume_session(source_session: Any, boundary_seq: Any) -> str:
    """Return the legacy readable id when it fits, otherwise a bounded tagged id."""

    source = validate_session_id(source_session, "restore source session")
    if not isinstance(boundary_seq, int) or isinstance(boundary_seq, bool) \
            or not 1 <= boundary_seq <= MAX_EXACT_INTEGER:
        raise ProtocolError("restore boundary is invalid")
    boundary = str(boundary_seq)
    readable = f"{source}-r{boundary}"
    if len(readable) <= MAX_SESSION_LENGTH:
        return readable
    token = _adler_text(f"resume:{source}:{boundary}") \
        + _adler_text(f"source:{source}")
    suffix = f"-h{token}-r{boundary}"
    prefix_length = MAX_SESSION_LENGTH - len(suffix)
    if prefix_length < 1:
        raise ProtocolError("restore boundary cannot fit a bounded session identity")
    return source[:prefix_length] + suffix
