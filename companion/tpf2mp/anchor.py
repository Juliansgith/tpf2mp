"""Creating restore points from live sessions.

`restore.py` decides whether a boundary *is* a restore point. This decides
when one can be made, and makes it.

The companion is the right place for both halves because it already knows
everything the attestation needs: it coordinates the shared clock, so it
knows whether the pause is acknowledged; it owns the ordered history, so it
knows whether anything has happened since the last converged checkpoint; and
the recovery watcher already sees new native saves appear.

A player therefore never has to understand the invariant. One preparation
request makes the companion pause and checkpoint both worlds; after READY,
each game automatically requests its peer-specific native save. The watcher
attests that stable file. A correctly prefixed manual save remains a fallback.
"""

from __future__ import annotations

import hashlib
import time
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

    HEALTH_MAX_AGE = 3.0

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
        reasons.extend(self._health_reasons(boundary))
        if self.host.session_fault:
            reasons.append("the session has already faulted; restore instead of anchoring")
        pending = self._pending_work()
        if pending:
            reasons.append(f"{pending} ordered action(s) are still settling")
        if boundary > 0 and self._commits_since(boundary):
            reasons.append("work has been ordered since the last converged checkpoint")
        preparation = getattr(self.host, "anchor_preparation", None)
        if preparation is not None:
            reasons = preparation.readiness_reasons() + reasons
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
            self.host.clock_controls,
        ):
            pending += sum(
                1 for item in tracker.values()
                if isinstance(item, Mapping) and item.get("status") == "pending"
            )
        rendezvous = self.host.clock_rendezvous
        if isinstance(rendezvous, Mapping) and rendezvous.get("status") not in {
            "complete", "faulted", "superseded",
        }:
            pending += 1
        pause_fence = self.host.synchronization.clock_pause_fence
        if isinstance(pause_fence, Mapping) and pause_fence.get("status") not in {
            "complete", "faulted", "superseded",
        }:
            pending += 1
        pending += sum(
            1 for item in self.host.vehicle_sync_rounds.values()
            if isinstance(item, Mapping) and item.get("status") not in {"complete", "faulted"}
        )
        return pending

    def _checkpoint_outcome_seq(self, boundary_seq: int) -> int:
        outcome_seq = 0
        for seq, message in self.host.commits.items():
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") == "network.checkpoint_outcome" \
                    and int(action.get("boundarySeq", 0)) == int(boundary_seq) \
                    and action.get("success") is True:
                outcome_seq = max(outcome_seq, int(seq))
        return outcome_seq

    def _health_reasons(self, boundary_seq: int) -> list[str]:
        """Prove every game process is paused and locally quiescent now.

        Server-side consensus tables cannot see an intent which is still in a
        game's deferred FIFO or awaiting its host order. Schema-3 heartbeats
        close that gap and make a false READY receipt impossible.
        """

        reasons: list[str] = []
        now = time.monotonic()
        outcome_seq = self._checkpoint_outcome_seq(boundary_seq) if boundary_seq > 0 else 0
        generation = int(self.host.clock_pause_acknowledged_generation)
        for peer in self.host.required_peers:
            sample = self.host.clock_health.get(peer)
            if not isinstance(sample, Mapping):
                reasons.append(f"{peer} has not reported anchor-readiness health")
                continue
            if now - float(sample.get("receivedAt", 0.0)) > self.HEALTH_MAX_AGE:
                reasons.append(f"{peer} anchor-readiness health is stale")
                continue
            if int(sample.get("schemaVersion", 0)) < 3:
                reasons.append(f"{peer} health cannot prove its local intent queue is empty")
                continue
            if sample.get("localWorkPending") is not False:
                reasons.append(f"{peer} still has local ordered work pending")
            observed = sample.get("observedSpeed")
            if observed is None or float(observed) != 0.0:
                reasons.append(f"{peer} has not observed the native game paused")
            if int(sample.get("generation", -1)) < generation:
                reasons.append(f"{peer} has not observed the acknowledged pause generation")
            if outcome_seq > 0 and int(sample.get("lastCommitSeq", -1)) < outcome_seq:
                reasons.append(f"{peer} has not consumed the converged checkpoint outcome")
        return reasons

    def _commits_since(self, boundary_seq: int) -> bool:
        """True when world-changing work was ordered after the boundary.

        The checkpoint outcome that closes a boundary is itself ordered, so
        the comparison starts from that outcome's sequence. Save receipts are
        excluded: they attest, they do not change a world.
        """

        outcome_seq = self._checkpoint_outcome_seq(boundary_seq)
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
        existing_hash = self._filed_hash(boundary, self.host.bridge.peer)
        if existing_hash:
            self.filed[boundary] = existing_hash
            self.last_reason = "boundary already anchored by this peer"
            return {
                "filed": False, "boundarySeq": boundary,
                "saveSha256": existing_hash, "reason": self.last_reason,
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

    def _filed_hash(self, boundary: int, peer: str) -> str | None:
        for message in self.host.commits.values():
            action = (message.get("payload") or {}).get("action") or {}
            if action.get("type") == "recovery.save_receipt" \
                    and message.get("origin_peer") == peer \
                    and int(action.get("boundarySeq", 0)) == int(boundary):
                value = action.get("saveSha256")
                if isinstance(value, str):
                    return value
        return None

    def validate_receipt(
        self, action: Mapping[str, Any], origin_peer: str
    ) -> dict[str, Any] | None:
        """Validate a companion-authored receipt against live host truth.

        The protocol validates shape; this validates the claim.  A client may
        only name the boundary the host says is READY *now*, and duplicate
        receipts may be replayed only when they are byte-for-byte equivalent.
        """

        if origin_peer not in self.host.required_peers:
            raise ProtocolError("save receipt came from a peer outside the match roster")
        readiness = self.readiness()
        if not readiness["ready"]:
            raise ProtocolError(
                "save receipt arrived while the boundary was not READY: "
                + "; ".join(readiness["reasons"])
            )
        comparisons = {
            "boundarySeq": readiness["boundarySeq"],
            "coreDigest": readiness["coreDigest"],
            "convergenceKey": readiness["convergenceKey"],
        }
        for field, expected in comparisons.items():
            if action.get(field) != expected:
                raise ProtocolError(f"save receipt {field} does not match the READY boundary")
        for message in self.host.commits.values():
            existing = (message.get("payload") or {}).get("action") or {}
            if existing.get("type") != "recovery.save_receipt" \
                    or message.get("origin_peer") != origin_peer \
                    or int(existing.get("boundarySeq", 0)) != int(action["boundarySeq"]):
                continue
            if existing != dict(action):
                raise ProtocolError("peer filed conflicting receipts for one boundary")
            return message
        return None

    # -- status --------------------------------------------------------

    def status(self) -> dict[str, Any]:
        state = self.readiness()
        locally_filed = {
            int(action.get("boundarySeq", 0))
            for message in self.host.commits.values()
            for action in [(message.get("payload") or {}).get("action") or {}]
            if action.get("type") == "recovery.save_receipt"
            and message.get("origin_peer") == self.host.bridge.peer
        }
        return {
            "anchorReady": state["ready"],
            "anchorBoundarySeq": state["boundarySeq"],
            "anchorCoreDigest": state["coreDigest"],
            "anchorConvergenceKey": state["convergenceKey"],
            "anchorReasons": state["reasons"],
            "anchorsFiled": sorted(value for value in locally_filed if value > 0),
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
