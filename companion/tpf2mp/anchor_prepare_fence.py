"""Admission policy while a coordinated native-save boundary is prepared."""

from __future__ import annotations

from typing import Any, Mapping

from .anchor_prepare_cancel import is_internal_cancel
from .automatic_recovery_preempt import preempt_for_gameplay
from .protocol import ProtocolError


def enforce_before_commit(
    coordinator: Any, action: Mapping[str, Any], origin: str, local_seq: int,
) -> None:
    """Fence manual preparation; make automation yield durably to gameplay.

    It orders ``recovery.cancel`` before the untouched gameplay action. Merely
    changing the in-memory status is insufficient: an already-open checkpoint
    tracker would otherwise reject and permanently consume the player's click.
    """

    action_type = str(action.get("type", ""))
    if action_type == "network.checkpoint_request":
        raise ProtocolError("network.checkpoint_request is host-generated")
    active = coordinator.current
    if not active:
        return
    status = str(active.get("status", ""))
    host = coordinator.host
    internal_clock = action_type == "clock.request" \
        and origin == host.bridge.peer and local_seq < 0
    requested_speed = int(action.get("requestedSpeed", -1)) if internal_clock else -1
    synthetic_pause = internal_clock and requested_speed == 0
    synthetic_drain_resume = internal_clock and status == "draining" \
        and requested_speed == int(active.get("resumeSpeed", -1))
    internal_action = synthetic_pause or synthetic_drain_resume \
        or coordinator.phase.internal_probe(active, action_type, origin, local_seq) \
        or is_internal_cancel(host, active, action, origin, local_seq)

    # The receipt attests the boundary already prepared; it is not new work.
    if action_type == "recovery.save_receipt":
        return
    # Automatic recovery is opportunistic. A player action racing its
    # eligibility check wins. Keep the identity until the scheduler orders a
    # durable cancellation; dropping it strands that scheduler until timeout.
    if active.get("automatic") is True and not internal_action \
            and action_type != "recovery.cancel" \
            and status in coordinator.PENDING:
        if status != "superseded":
            active["status"] = "superseded"
            active["detail"] = (
                "new ordered gameplay superseded automatic restore-point preparation"
            )
            coordinator.last = dict(active)
        preempt_error = preempt_for_gameplay(
            host.automatic_recovery, active["detail"]
        )
        if preempt_error:
            raise ProtocolError(
                "could not yield automatic recovery to player action: "
                + preempt_error
            )
        return
    if status in coordinator.PENDING and not internal_action:
        raise ProtocolError(
            f"restore point preparation {active['preparationSeq']} is {status}"
        )
    if status not in coordinator.PENDING and not (synthetic_pause or internal_action):
        active["status"] = "superseded"
        active["detail"] = "new ordered work superseded the prepared boundary"
        coordinator.last = dict(active)
        coordinator.current = None
