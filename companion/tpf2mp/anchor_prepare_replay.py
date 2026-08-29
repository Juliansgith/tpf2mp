"""Audit-only reconstruction helpers for recovery preparation."""

from __future__ import annotations

from typing import Any, Mapping


def retire_after_host_resume(
    host: Any,
    current: dict[str, Any] | None,
    message: Mapping[str, Any],
    action: Mapping[str, Any],
    restoring: bool,
    pending_statuses: set[str],
) -> dict[str, Any] | None:
    """Mirror live before_commit() after a transformed host clock request."""

    if not restoring or not current \
            or str(current.get("status", "")) in pending_statuses \
            or action.get("type") not in {"clock.set", "clock.rendezvous"} \
            or str(message.get("origin_peer")) != host.bridge.peer \
            or int(message.get("origin_local_seq", 0)) >= 0:
        return None
    retired = dict(current)
    retired["status"] = "superseded"
    retired["detail"] = "host resumed after the prepared boundary"
    return retired
