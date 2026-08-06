"""Creating restore points from live sessions.

`restore.py` decides whether a boundary *is* a restore point. This decides
when one can be made, and makes it.

The companion is the right place for both halves because it already knows
everything the attestation needs: it coordinates the shared clock, so it
knows whether the pause is acknowledged; it owns the ordered history, so it
knows whether anything has happened since the last converged checkpoint; and
the recovery watcher already sees new native saves appear.

A player therefore never has to understand the invariant. They pause, save
normally, and the companion either files a receipt or explains why it will
not.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any, Mapping

from .protocol import ProtocolError


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class AnchorCoordinator:
    """Watches for an anchorable save and files the ordered receipt."""

    def __init__(self, host: Any) -> None:
        self.host = host
        self.filed: dict[int, str] = {}
        self.last_reason: str | None = None
        self.last_receipt: dict[str, Any] | None = None

    # -- readiness -----------------------------------------------------

    def readiness(self) -> dict[str, Any]:
        """Whether a save taken right now would be a valid restore anchor.

        Reported as reasons rather than a bare boolean so the overlay can
        tell a player exactly what to do: unpause nothing, build nothing,
        just save.
        """

        reasons: list[str] = []
        checkpoint = self.host.last_agreed_checkpoint
        boundary = int(checkpoint.get("boundarySeq", 0)) if checkpoint else 0
        if boundary <= 0:
            reasons.append("no checkpoint boundary has converged yet")
        if not self.host.synchronization.shared_pause_acknowledged():
            reasons.append("the shared clock is not paused on every peer")
        if self.host.session_fault:
            reasons.append("the session has already faulted; restore instead of anchoring")
        pending = self._pending_work()
        if pending:
            reasons.append(f"{pending} ordered action(s) are still settling")
        if boundary > 0 and self._commits_since(boundary):
            reasons.append("work has been ordered since the last converged checkpoint")
        return {
            "ready": not reasons,
            "boundarySeq": boundary,
            "convergenceKey": checkpoint.get("convergenceKey") if checkpoint else None,
            "coreDigest": checkpoint.get("coreDigest") if checkpoint else None,
            "alreadyFiled": boundary in self.filed,
            "reasons": reasons,
        }

    def _pending_work(self) -> int:
        pending = 0
        for tracker in (
            self.host.proposal_prepares, self.host.proposal_consensus,
            self.host.operation_consensus, self.host.checkpoint_consensus,
        ):
            pending += sum(
                1 for item in tracker.values()
                if isinstance(item, Mapping) and item.get("status") == "pending"
            )
        return pending

    def _commits_since(self, boundary_seq: int) -> bool:
        """True when world-changing work was ordered after the boundary.

        The checkpoint outcome that closes a boundary is itself ordered, so
        the comparison starts from that outcome's sequence. Save receipts are
        excluded: they attest, they do not change a world.
        """

        outcome_seq = 0
        for seq, message in self.host.commits.items():
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") == "network.checkpoint_outcome" \
                    and int(action.get("boundarySeq", 0)) == boundary_seq \
                    and action.get("success") is True:
                outcome_seq = max(outcome_seq, int(seq))
        if outcome_seq == 0:
            return False
        for seq, message in self.host.commits.items():
            if int(seq) <= outcome_seq or message.get("kind") != "commit":
                continue
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") != "recovery.save_receipt":
                return True
        return False

    # -- filing --------------------------------------------------------

    def anchor_save(self, save_path: Path | str, saved_at_unix: int) -> dict[str, Any]:
        """Attest one native save as the current boundary's restore point.

        Refuses rather than files whenever the world is not provably at the
        boundary; a receipt that is not true is worse than no receipt,
        because a later restore would trust it.
        """

        state = self.readiness()
        if not state["ready"]:
            self.last_reason = "; ".join(state["reasons"])
            raise ProtocolError(f"save cannot be anchored: {self.last_reason}")
        path = Path(save_path).expanduser().resolve()
        if path.suffix.lower() != ".sav" or not path.is_file():
            raise ProtocolError(f"anchor save is missing or is not a .sav: {path}")
        boundary = int(state["boundarySeq"])
        if boundary in self.filed:
            self.last_reason = "boundary already anchored by this peer"
            return {
                "filed": False, "boundarySeq": boundary,
                "saveSha256": self.filed[boundary], "reason": self.last_reason,
            }
        receipt = {
            "type": "recovery.save_receipt",
            "boundarySeq": boundary,
            "savedAtUnix": max(0, int(saved_at_unix)),
            "saveSha256": _sha256_file(path),
            "coreDigest": str(state["coreDigest"] or ""),
            "convergenceKey": str(state["convergenceKey"] or ""),
            "paused": True,
        }
        self.host.emit_local_intent(receipt)
        self.filed[boundary] = receipt["saveSha256"]
        self.last_receipt = dict(receipt)
        self.last_reason = None
        return {"filed": True, **receipt}

    # -- status --------------------------------------------------------

    def status(self) -> dict[str, Any]:
        state = self.readiness()
        return {
            "anchorReady": state["ready"],
            "anchorBoundarySeq": state["boundarySeq"],
            "anchorReasons": state["reasons"],
            "anchorsFiled": sorted(self.filed),
            "lastAnchorReason": self.last_reason,
            "restorePoints": self.restorable(),
        }

    def restorable(self) -> list[int]:
        """Boundaries every required peer has attested, newest last."""

        by_boundary: dict[int, set[str]] = {}
        for message in self.host.commits.values():
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") != "recovery.save_receipt":
                continue
            boundary = int(action.get("boundarySeq", 0))
            peer = str(message.get("origin_peer") or "")
            if boundary > 0 and peer:
                by_boundary.setdefault(boundary, set()).add(peer)
        required = set(self.host.required_peers)
        return sorted(
            boundary for boundary, peers in by_boundary.items() if required <= peers
        )
