"""Coordinated rollback to an agreed boundary.

Every consensus failure in this system faults closed, which is correct but
leaves the session dead. Without a way back, a fault and a desync kick feel
identical to a player. This module turns an agreed checkpoint boundary into a
restore point both peers can actually return to.

The design rests on one property of Transport Fever 2: a native save contains
the mod's own script state. A save written while a peer is paused at an agreed
boundary therefore *is* the canonical state of that boundary - restoring needs
no state patching, only proof that both peers restore the same boundary.

A restore point is ready only when:

1. the boundary converged (every required peer acknowledged the checkpoint);
2. every required peer filed an ordered `recovery.save_receipt` for it,
   attesting a paused world and naming the save's sha-256;
3. no ordered commit exists between the boundary and any peer's receipt, so
   nothing happened after the checkpoint that the save would also contain;
4. every peer's receipt agrees on the boundary's core digest and convergence
   key, so they saved the same world rather than two similar ones.

Failing any of these is reported as a reason, never silently downgraded. A
restore point that cannot be proven is worse than none, because it invites a
resume from divergent geometry.
"""

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .bridge import atomic_write
from .protocol import (
    PROTOCOL_VERSION, ProtocolError, canonical_json, sign, validate_action, verify,
)

RESTORE_PLAN_VERSION = 3
LEGACY_RESTORE_PLAN_VERSION = 2
MATCH_PROFILE_AGENT_MODES = {"skeleton", "vanilla", "empty"}


def _validate_match_profile(value: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(value, Mapping) or set(value) != {
        "schemaVersion", "agentMode", "townDevelopment",
    }:
        raise ProtocolError("restore plan match-content profile is malformed")
    profile_version = value.get("schemaVersion")
    if not isinstance(profile_version, int) or isinstance(profile_version, bool) \
            or profile_version != 1:
        raise ProtocolError("restore plan match-content profile version is invalid")
    agent_mode = value.get("agentMode")
    if agent_mode not in MATCH_PROFILE_AGENT_MODES:
        raise ProtocolError("restore plan match-content agent mode is invalid")
    if not isinstance(value.get("townDevelopment"), bool):
        raise ProtocolError("restore plan match-content town-development flag is invalid")
    return {
        "schemaVersion": 1,
        "agentMode": agent_mode,
        "townDevelopment": value["townDevelopment"],
    }


def _messages(audit_path: Path, session: str | None) -> list[dict[str, Any]]:
    path = Path(audit_path).expanduser().resolve()
    if not path.is_file():
        raise ProtocolError(f"audit log is missing: {path}")
    records: list[dict[str, Any]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                record = verify(json.loads(line))
            except Exception:
                continue
            if session and record.get("session") != session:
                continue
            records.append(record)
    sessions = {str(record.get("session") or "") for record in records}
    sessions.discard("")
    if session is None and len(sessions) > 1:
        raise ProtocolError(
            "audit log contains multiple sessions; select one explicitly before restoring"
        )
    return records


def _action(record: Mapping[str, Any]) -> dict[str, Any]:
    payload = record.get("payload")
    if not isinstance(payload, Mapping):
        return {}
    action = payload.get("action")
    return dict(action) if isinstance(action, Mapping) else {}


def analyse_restore_points(
    audit_path: Path | str,
    session: str | None = None,
    required_peers: tuple[str, ...] | None = None,
) -> dict[str, Any]:
    """Every candidate boundary with a ready/not-ready verdict and reasons."""

    records = _messages(Path(audit_path), session)
    if not records:
        raise ProtocolError("audit log contains no verifiable records for this session")
    resolved_session = session or str(records[0].get("session"))

    converged: dict[int, dict[str, Any]] = {}
    receipts: dict[int, dict[str, list[dict[str, Any]]]] = {}
    convergence_conflicts: dict[int, list[str]] = {}
    commit_seqs: list[int] = []
    peers: set[str] = set()

    for record in records:
        kind = record.get("kind")
        action = _action(record)
        peer = str(record.get("origin_peer") or record.get("peer") or "")
        if peer:
            peers.add(peer)
        # A save receipt is itself ordered, but it changes no world, so it
        # must not count as work that happened after the boundary.
        if kind == "commit" and action.get("type") != "recovery.save_receipt":
            commit_seqs.append(int(record.get("seq", 0)))
        if action.get("type") == "network.checkpoint_outcome" and action.get("success") is True:
            boundary = int(action.get("boundarySeq", 0))
            if boundary > 0:
                candidate = {
                    "boundarySeq": boundary,
                    "outcomeSeq": int(record.get("seq", 0)),
                    "convergenceKey": action.get("convergenceKey"),
                    "coreDigest": action.get("coreDigest"),
                }
                previous = converged.get(boundary)
                if previous and any(
                    previous.get(field) != candidate.get(field)
                    for field in ("convergenceKey", "coreDigest")
                ):
                    convergence_conflicts.setdefault(boundary, []).append(
                        "conflicting checkpoint outcomes name the same boundary"
                    )
                elif previous is None or candidate["outcomeSeq"] > previous["outcomeSeq"]:
                    converged[boundary] = candidate
        if action.get("type") == "recovery.save_receipt":
            if kind != "commit":
                continue
            if not record.get("origin_peer"):
                raise ProtocolError("save receipt is not an origin-attributed ordered commit")
            validate_action(action)
            boundary = int(action.get("boundarySeq", 0))
            if boundary > 0 and peer:
                receipts.setdefault(boundary, {}).setdefault(peer, []).append({
                    "peer": peer,
                    "commitSeq": int(record.get("seq", 0)),
                    "savedAtUnix": int(action.get("savedAtUnix", 0)),
                    "saveSha256": action.get("saveSha256"),
                    "coreDigest": action.get("coreDigest"),
                    "convergenceKey": action.get("convergenceKey"),
                })

    if required_peers and len(set(required_peers)) != len(required_peers):
        raise ProtocolError("required peer roster contains duplicates")
    expected = tuple(sorted(set(required_peers or peers or ("player1", "player2"))))
    if not expected or any(not peer for peer in expected):
        raise ProtocolError("required peer roster is empty or invalid")
    points: list[dict[str, Any]] = []
    for boundary in sorted(converged):
        anchor = converged[boundary]
        receipt_lists = receipts.get(boundary, {})
        filed = {peer: values[0] for peer, values in receipt_lists.items() if values}
        reasons: list[str] = list(convergence_conflicts.get(boundary, ()))

        missing = [peer for peer in expected if peer not in filed]
        if missing:
            reasons.append("missing save receipts: " + ", ".join(missing))
        unexpected = sorted(set(filed) - set(expected))
        if unexpected:
            reasons.append("save receipts came from peers outside the roster: " + ", ".join(unexpected))

        for peer, values in sorted(receipt_lists.items()):
            semantic = {
                (
                    item["savedAtUnix"], item["saveSha256"], item["coreDigest"],
                    item["convergenceKey"],
                )
                for item in values
            }
            if len(semantic) > 1:
                reasons.append(f"{peer} filed conflicting duplicate save receipts")

        # Quiescence: nothing may have been ordered between the checkpoint
        # outcome and a peer's save, or that peer's save contains more than
        # this boundary and the two worlds would resume out of step.
        for peer in sorted(filed):
            receipt = filed[peer]
            if receipt["commitSeq"] <= anchor["outcomeSeq"]:
                reasons.append(f"{peer} save receipt precedes its checkpoint outcome")
            intervening = [
                seq for seq in commit_seqs
                if anchor["outcomeSeq"] < seq < receipt["commitSeq"]
            ]
            if intervening:
                reasons.append(
                    f"{peer} saved after {len(intervening)} ordered commit(s) past the boundary"
                )

        roster_filed = {peer: filed[peer] for peer in expected if peer in filed}
        digests = {receipt.get("coreDigest") for receipt in roster_filed.values()}
        keys = {receipt.get("convergenceKey") for receipt in roster_filed.values()}
        if filed and (len(digests) > 1 or len(keys) > 1):
            reasons.append("peers attested different world state for this boundary")
        if filed and anchor.get("coreDigest") and digests and anchor["coreDigest"] not in digests:
            reasons.append("save receipts do not match the agreed checkpoint core digest")
        if filed and anchor.get("convergenceKey") and keys \
                and anchor["convergenceKey"] not in keys:
            reasons.append("save receipts do not match the agreed checkpoint convergence key")

        points.append({
            **anchor,
            "receipts": {peer: filed[peer] for peer in sorted(filed)},
            "requiredPeers": list(expected),
            "ready": not reasons,
            "reasons": reasons,
        })

    ready = [point for point in points if point["ready"]]
    return {
        "session": resolved_session,
        "requiredPeers": list(expected),
        "points": points,
        "latestReady": ready[-1] if ready else None,
    }


def build_restore_plan(
    audit_path: Path | str,
    session: str | None = None,
    boundary_seq: int | None = None,
    required_peers: tuple[str, ...] | None = None,
    match_profile: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Signed instruction for returning both peers to one agreed boundary."""

    analysis = analyse_restore_points(audit_path, session, required_peers)
    if boundary_seq is None:
        point = analysis["latestReady"]
        if point is None:
            raise ProtocolError(
                "no restore point is ready; the session has no boundary both peers saved while paused"
            )
    else:
        matches = [item for item in analysis["points"] if item["boundarySeq"] == int(boundary_seq)]
        if not matches:
            raise ProtocolError(f"boundary {boundary_seq} is not an agreed checkpoint")
        point = matches[0]
        if not point["ready"]:
            raise ProtocolError(
                f"boundary {boundary_seq} is not restorable: " + "; ".join(point["reasons"])
            )

    boundary = int(point["boundarySeq"])
    plan_version = RESTORE_PLAN_VERSION if match_profile is not None \
        else LEGACY_RESTORE_PLAN_VERSION
    plan = {
        "format": "tpf2mp-restore-plan",
        "version": plan_version,
        "protocol": PROTOCOL_VERSION,
        "session": analysis["session"],
        "resumeSession": f"{analysis['session']}-r{boundary}",
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "boundarySeq": boundary,
        "convergenceKey": point["convergenceKey"],
        "coreDigest": point["coreDigest"],
        "requiredPeers": list(analysis["requiredPeers"]),
        "peerSaves": {
            peer: {
                "saveSha256": receipt["saveSha256"],
                "savedAtUnix": receipt["savedAtUnix"],
                "receiptCommitSeq": receipt["commitSeq"],
                "boundarySeq": boundary,
                "coreDigest": point["coreDigest"],
                "convergenceKey": point["convergenceKey"],
            }
            for peer, receipt in point["receipts"].items()
        },
        "steps": [
            "Stop every game and companion for the faulted session.",
            "Each peer loads its own attested save; the plan names its sha-256.",
            "Start the companions with resumeSession as the session id.",
            "Refuse to continue if any save hash or the first checkpoint digest differs.",
        ],
    }
    if match_profile is not None:
        plan["matchContentProfile"] = _validate_match_profile(match_profile)
    return sign(plan)


def verify_restore_plan(value: Mapping[str, Any]) -> dict[str, Any]:
    plan = verify(value)
    version = plan.get("version")
    if not isinstance(version, int) or isinstance(version, bool) \
            or plan.get("format") != "tpf2mp-restore-plan" \
            or version not in {LEGACY_RESTORE_PLAN_VERSION, RESTORE_PLAN_VERSION}:
        raise ProtocolError("unsupported restore plan format")
    if int(plan.get("protocol", -1)) != PROTOCOL_VERSION:
        raise ProtocolError("restore plan protocol mismatch")
    allowed = {
        "format", "version", "protocol", "session", "resumeSession",
        "generatedAtUtc", "boundarySeq", "convergenceKey", "coreDigest",
        "requiredPeers", "peerSaves", "steps", "checksum",
    }
    if version == RESTORE_PLAN_VERSION:
        allowed.add("matchContentProfile")
    if set(plan) != allowed:
        raise ProtocolError("restore plan has unknown or missing fields")
    if version == RESTORE_PLAN_VERSION:
        plan["matchContentProfile"] = _validate_match_profile(
            plan.get("matchContentProfile")
        )
    session = plan.get("session")
    boundary = plan.get("boundarySeq")
    if not isinstance(session, str) or not session or len(session) > 160:
        raise ProtocolError("restore plan session is invalid")
    if not isinstance(boundary, int) or isinstance(boundary, bool) \
            or not 1 <= boundary <= 9_007_199_254_740_991:
        raise ProtocolError("restore plan boundary is invalid")
    if plan.get("resumeSession") != f"{session}-r{boundary}":
        raise ProtocolError("restore plan resume session does not match its boundary")
    for field in ("convergenceKey", "coreDigest"):
        value = plan.get(field)
        if not isinstance(value, str) or not value or len(value) > 128:
            raise ProtocolError(f"restore plan {field} is invalid")
    if not isinstance(plan.get("generatedAtUtc"), str) or not plan["generatedAtUtc"]:
        raise ProtocolError("restore plan generation timestamp is invalid")
    if not isinstance(plan.get("steps"), list) or not plan["steps"] \
            or any(not isinstance(step, str) or not step for step in plan["steps"]):
        raise ProtocolError("restore plan steps are invalid")

    peers = plan.get("requiredPeers")
    saves = plan.get("peerSaves")
    if not isinstance(peers, list) or not peers \
            or any(not isinstance(peer, str) or not peer for peer in peers):
        raise ProtocolError("restore plan has no required peers")
    if len(set(peers)) != len(peers):
        raise ProtocolError("restore plan required peer roster contains duplicates")
    if not isinstance(saves, Mapping) or set(saves) != set(peers):
        raise ProtocolError("restore plan is missing a peer save attestation")
    expected_save_fields = {
        "saveSha256", "savedAtUnix", "receiptCommitSeq", "boundarySeq",
        "coreDigest", "convergenceKey",
    }
    for peer in peers:
        save = saves[peer]
        if not isinstance(save, Mapping) or set(save) != expected_save_fields:
            raise ProtocolError(f"restore plan {peer} save attestation is malformed")
        sha = save.get("saveSha256")
        if not isinstance(sha, str) or len(sha) != 64 \
                or any(character not in "0123456789abcdef" for character in sha):
            raise ProtocolError(f"restore plan {peer} save hash is invalid")
        for field, minimum in (("savedAtUnix", 0), ("receiptCommitSeq", 1)):
            item = save.get(field)
            if not isinstance(item, int) or isinstance(item, bool) \
                    or not minimum <= item <= 9_007_199_254_740_991:
                raise ProtocolError(f"restore plan {peer} {field} is invalid")
        if save.get("boundarySeq") != boundary \
                or save.get("coreDigest") != plan["coreDigest"] \
                or save.get("convergenceKey") != plan["convergenceKey"]:
            raise ProtocolError(f"restore plan {peer} save names a different boundary")
    return plan


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def confirm_restore_readiness(
    plan: Mapping[str, Any],
    peer_saves: Mapping[str, Path | str],
) -> dict[str, Any]:
    """Re-hash each peer's save on disk and refuse on any drift.

    The receipts prove what a peer saved at the time. This proves the file is
    still that save now - a replaced or edited save must never be resumed into
    a session that believes it holds the agreed boundary.
    """

    verified = verify_restore_plan(plan)
    results: dict[str, Any] = {}
    problems: list[str] = []
    for peer in verified["requiredPeers"]:
        expected = verified["peerSaves"][peer]["saveSha256"]
        supplied = peer_saves.get(peer)
        if supplied is None:
            problems.append(f"{peer} save was not supplied")
            results[peer] = {"ok": False, "reason": "not supplied"}
            continue
        path = Path(supplied).expanduser().resolve()
        if not path.is_file() or path.suffix.lower() != ".sav":
            problems.append(f"{peer} save is missing or is not a .sav: {path}")
            results[peer] = {"ok": False, "reason": "missing"}
            continue
        actual = _sha256_file(path)
        ok = actual == expected
        if not ok:
            problems.append(f"{peer} save no longer matches its attested hash")
        results[peer] = {
            "ok": ok, "path": str(path), "expected": expected, "actual": actual,
        }
    return {
        "ready": not problems,
        "boundarySeq": verified["boundarySeq"],
        "resumeSession": verified["resumeSession"],
        "peers": results,
        "problems": problems,
    }


def write_restore_plan(
    audit_path: Path | str,
    output_path: Path | str,
    session: str | None = None,
    boundary_seq: int | None = None,
    match_profile: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    plan = build_restore_plan(
        audit_path, session, boundary_seq, match_profile=match_profile,
    )
    output = Path(output_path).expanduser().resolve()
    atomic_write(output, (canonical_json(plan) + "\n").encode("utf-8"))
    return plan
