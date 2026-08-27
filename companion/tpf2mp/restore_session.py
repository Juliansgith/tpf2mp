from __future__ import annotations

from typing import Any, Mapping

from .protocol import ProtocolError
from .restore import verify_restore_plan
from .restore_plan import RESTORE_PLAN_VERSION


class RestoreSessionCoordinator:
    """Bind a fresh sequencer session to one receipt-verified save boundary."""

    def __init__(
        self,
        host: Any,
        plan: Mapping[str, Any] | None,
        *,
        saved_match_auto: bool = False,
    ) -> None:
        self.host = host
        self.plan = verify_restore_plan(plan) if plan is not None else None
        self.saved_match_auto = bool(saved_match_auto and self.plan is None)
        self.state = (
            "awaiting-start"
            if self.saved_match_auto
            else "disabled" if self.plan is None else "awaiting-resume"
        )
        self.commit_seq: int | None = None
        self.start_action_type: str | None = None
        self.error: str | None = None
        if self.plan is None:
            return
        if self.plan["version"] != RESTORE_PLAN_VERSION:
            raise ProtocolError(
                "network resume requires a current native-phase-bound restore plan"
            )
        if self.plan["resumeSession"] != host.bridge.session:
            raise ProtocolError("restore plan resume session differs from the sequencer session")
        if tuple(sorted(self.plan["requiredPeers"])) != tuple(sorted(host.required_peers)):
            raise ProtocolError("restore plan peer roster differs from the sequencer roster")
        host.synchronization.vehicle.restore_round_cursors(
            self.plan["vehiclePhaseProof"]["vehicleRounds"]
        )

    def expected_action(self) -> dict[str, Any] | None:
        if self.plan is None:
            return None
        return {
            "type": "recovery.resume",
            "fromSession": self.plan["session"],
            "boundarySeq": self.plan["boundarySeq"],
            "coreDigest": self.plan["coreDigest"],
            "convergenceKey": self.plan["convergenceKey"],
            "planChecksum": self.plan["checksum"],
            "vehiclePhaseDigest": self.plan["vehiclePhaseProof"][
                "vehiclePhaseDigest"
            ],
        }

    def before_commit(self, action: Mapping[str, Any], origin: str) -> None:
        if self.plan is None:
            if action.get("type") == "recovery.resume":
                raise ProtocolError("recovery.resume requires a sequencer restore plan")
            if not self.saved_match_auto:
                if action.get("type") == "recovery.continue":
                    raise ProtocolError(
                        "recovery.continue requires launcher saved-match fencing"
                    )
                return
            action_type = action.get("type")
            emergency_pause = (
                action_type == "clock.request"
                and action.get("requestedSpeed") == 0
            )
            if self.state == "complete":
                if action_type == "recovery.continue":
                    raise ProtocolError("saved-match continuation has already completed")
                return
            if action_type == "content.industry_attest" or emergency_pause:
                return
            if action_type not in {"match.initialise", "recovery.continue"}:
                raise ProtocolError(
                    "the first saved-world boundary must initialise a fresh match "
                    "or continue the exact saved match"
                )
            if origin != self.host.bridge.peer:
                raise ProtocolError(
                    f"{action_type} may only originate from the host peer"
                )
            if self.commit_seq is not None:
                raise ProtocolError("saved-world startup boundary is already ordered")
            return
        action_type = action.get("type")
        emergency_pause = action_type == "clock.request" and action.get("requestedSpeed") == 0
        if self.state != "complete" and action_type != "recovery.resume" and not emergency_pause:
            raise ProtocolError("restore handshake must converge before gameplay resumes")
        if action_type != "recovery.resume":
            return
        if origin != self.host.bridge.peer:
            raise ProtocolError("recovery.resume may only originate from the host peer")
        if action != self.expected_action():
            raise ProtocolError("recovery.resume does not match the sequencer restore plan")
        if self.commit_seq is not None:
            raise ProtocolError("restore resume has already been ordered")

    def track_commit(self, commit: Mapping[str, Any]) -> dict[str, Any] | None:
        action = commit.get("payload", {}).get("action", {})
        if self.plan is None and self.saved_match_auto:
            action_type = action.get("type")
            if action_type not in {"match.initialise", "recovery.continue"}:
                return None
            if self.commit_seq is not None:
                if self.commit_seq == int(commit["seq"]):
                    return None
                raise ProtocolError("audit contains multiple saved-world startup boundaries")
            self.commit_seq = int(commit["seq"])
            self.start_action_type = str(action_type)
            self.state = "awaiting-checkpoint"
            reason = (
                "match-initialised"
                if action_type == "match.initialise"
                else "saved-match-continuation:"
                + str(action.get("saveFingerprint", ""))[:12]
            )
            return self.host._track_checkpoint_boundary(self.commit_seq, reason)
        if action.get("type") != "recovery.resume":
            return None
        if action != self.expected_action():
            raise ProtocolError("audit recovery.resume does not match the restore plan")
        self.commit_seq = int(commit["seq"])
        self.state = "awaiting-checkpoint"
        return self.host._track_checkpoint_boundary(
            self.commit_seq, f"restore-resume:{self.plan['checksum']}"
        )

    def observe_checkpoint_outcome(self, action: Mapping[str, Any]) -> None:
        if self.commit_seq is None:
            return
        boundary = action.get("boundarySeq")
        if not isinstance(boundary, int) or isinstance(boundary, bool):
            raise ProtocolError("restore checkpoint outcome boundary is invalid")
        if boundary != self.commit_seq:
            return
        if action.get("success") is True:
            self.state, self.error = "complete", None
        else:
            self.state = "faulted"
            self.error = str(action.get("errorCode") or "restore-checkpoint-failed")

    def status(self) -> dict[str, Any]:
        return {
            "restoreStatus": self.state,
            "restoreBoundarySeq": self.plan and self.plan["boundarySeq"],
            "restoreSourceSession": self.plan and self.plan["session"],
            "restoreCommitSeq": self.commit_seq,
            "restoreError": self.error,
            "savedMatchAuto": self.saved_match_auto,
            "savedMatchStartAction": self.start_action_type,
        }
