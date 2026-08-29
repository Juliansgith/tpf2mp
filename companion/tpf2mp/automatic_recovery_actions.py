"""Protocol-safe emission helpers for automatic recovery maintenance."""

from __future__ import annotations

from typing import Any, Mapping

from .protocol import ProtocolError


def emit_action(
    host: Any, action: Mapping[str, Any],
) -> tuple[dict[str, Any] | None, str | None]:
    """Return a protocol rejection as state; persistence failures still escape."""

    try:
        return host.emit_local_intent(action), None
    except ProtocolError as exc:
        return None, str(exc)
