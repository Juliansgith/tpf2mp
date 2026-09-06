"""Player-first cancellation of an opportunistic restore-point boundary."""

from __future__ import annotations

from typing import Any, Mapping

from .automatic_recovery_actions import emit_action


def preempt_for_gameplay(scheduler: Any, detail: str) -> str | None:
    """Cancel before the untouched gameplay action is assigned its sequence."""

    now = scheduler.monotonic()
    active = scheduler.host.anchor_preparation.current
    sequence = scheduler.preparation_seq
    if sequence is None and isinstance(active, Mapping):
        sequence = int(active.get("preparationSeq", 0)) or None
    if sequence is None:
        return "automatic restore-point preparation has no durable identity"
    _, cancel_error = emit_action(scheduler.host, {
        "type": "recovery.cancel",
        "preparationSeq": sequence,
        "errorCode": str(detail)[:512],
    })
    if cancel_error:
        scheduler.last_error = (
            "automatic recovery cancellation was rejected: " + cancel_error
        )
        scheduler.state = "retry-wait"
        scheduler.next_cancel_at = now + 5.0
        return scheduler.last_error

    if scheduler.resume_speed > 0 and not scheduler.host.session_fault:
        _, resume_error = emit_action(scheduler.host, {
            "type": "clock.request", "requestedSpeed": scheduler.resume_speed,
        })
    else:
        resume_error = None
    scheduler.next_due_at = now + scheduler.interval_seconds
    scheduler.preparation_seq = None
    scheduler.started_at = None
    scheduler.receipts_observed_at = None
    scheduler.resume_speed = 0
    scheduler.next_cancel_at = None
    scheduler.state = "scheduled" if scheduler.enabled else "disabled"
    scheduler.last_error = (
        "automatic restore point yielded to player activity; shared clock remains paused: "
        + resume_error
    ) if resume_error else None
    return None
