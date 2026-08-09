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
   attesting a paused world and naming the load-bearing save hashes;
3. no ordered commit exists between the boundary and any peer's receipt, so
   nothing happened after the checkpoint that the save would also contain;
4. every peer's receipt agrees on the boundary's core digest and convergence
   key, so they saved the same world rather than two similar ones.

Failing any of these is reported as a reason, never silently downgraded. A
restore point that cannot be proven is worse than none, because it invites a
resume from divergent geometry.
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .bridge import atomic_write
from .native_save import hash_load_bearing_save, sha256_file
from .protocol import (
    PROTOCOL_VERSION, ProtocolError, canonical_json, sign, validate_action, verify,
)
from .restore_plan import (
    LEGACY_RESTORE_PLAN_VERSION,
    PROFILE_RESTORE_PLAN_VERSION,
    RESTORE_PLAN_VERSION,
    validate_match_profile,
    verify_restore_plan,
)


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
                    "metadataSha256": action.get("metadataSha256"),
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
                    item["savedAtUnix"], item["saveSha256"],
                    item.get("metadataSha256"), item["coreDigest"],
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
        metadata_kinds = {
            bool(receipt.get("metadataSha256")) for receipt in roster_filed.values()
        }
        if len(metadata_kinds) > 1:
            reasons.append("restore boundary mixes legacy and load-bearing save receipts")
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
            detail = ""
            if analysis["points"]:
                detail = ": " + "; ".join(analysis["points"][-1]["reasons"])
            raise ProtocolError(
                "no restore point is ready; the session has no boundary both peers saved while paused"
                + detail
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
    metadata_receipts = [
        bool(receipt.get("metadataSha256")) for receipt in point["receipts"].values()
    ]
    if any(metadata_receipts) and not all(metadata_receipts):
        raise ProtocolError("restore boundary mixes legacy and load-bearing save receipts")
    plan_version = (
        RESTORE_PLAN_VERSION if match_profile is not None and all(metadata_receipts)
        else PROFILE_RESTORE_PLAN_VERSION if match_profile is not None
        else LEGACY_RESTORE_PLAN_VERSION
    )
    peer_saves: dict[str, dict[str, Any]] = {}
    for peer, receipt in point["receipts"].items():
        peer_saves[peer] = {
            "saveSha256": receipt["saveSha256"],
            "savedAtUnix": receipt["savedAtUnix"],
            "receiptCommitSeq": receipt["commitSeq"],
            "boundarySeq": boundary,
            "coreDigest": point["coreDigest"],
            "convergenceKey": point["convergenceKey"],
        }
        if plan_version == RESTORE_PLAN_VERSION:
            peer_saves[peer]["metadataSha256"] = receipt["metadataSha256"]
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
        "peerSaves": peer_saves,
        "steps": [
            "Stop every game and companion for the faulted session.",
            "Each peer loads its own attested save; current plans hash its load-bearing pair.",
            "Start the companions with resumeSession as the session id.",
            "Refuse to continue if any save hash or the first checkpoint digest differs.",
        ],
    }
    if match_profile is not None:
        plan["matchContentProfile"] = validate_match_profile(match_profile)
    return sign(plan)


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
        expected_metadata = verified["peerSaves"][peer].get("metadataSha256")
        try:
            if expected_metadata:
                hashes = hash_load_bearing_save(path)
                actual = hashes["saveSha256"]
                actual_metadata = hashes["metadataSha256"]
            else:
                actual = sha256_file(path)
                actual_metadata = None
        except (OSError, ProtocolError) as exc:
            problems.append(f"{peer} save set could not be verified: {exc}")
            results[peer] = {"ok": False, "reason": str(exc)}
            continue
        ok = actual == expected and (
            expected_metadata is None or actual_metadata == expected_metadata
        )
        if not ok:
            problems.append(f"{peer} save no longer matches its attested hash")
        results[peer] = {
            "ok": ok, "path": str(path), "expected": expected, "actual": actual,
            "metadataExpected": expected_metadata, "metadataActual": actual_metadata,
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
