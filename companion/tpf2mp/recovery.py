from __future__ import annotations

import hashlib
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

from .bridge import AuditLog, atomic_write
from .checkpoint import CHECKPOINT_VERSION, verify_checkpoint
from .native_save import hash_load_bearing_save, sha256_file
from .protocol import PROTOCOL_VERSION, ProtocolError, canonical_json, sign, validate_envelope, verify
from .restore import verify_restore_plan

RECOVERY_PLAN_VERSION = 1
RECOVERY_ARCHIVE_VERSION = 1


def analyse_recovery_anchor(audit_path: Path | str, session: str | None = None) -> dict[str, Any]:
    """Find and prove the newest all-peer checkpoint outcome in an authority audit.

    This deliberately does not claim that a checkpoint can repair native geometry.
    It identifies the exact boundary to which every player must reload an identical
    save before starting the derived recovery session.
    """

    path = Path(audit_path).expanduser().resolve()
    selected_session = session
    expected_seq = 1
    checkpoint_records: dict[int, dict[str, dict[str, Any]]] = {}
    agreed: list[tuple[int, dict[str, Any]]] = []
    faults: list[dict[str, Any]] = []

    for message in AuditLog(path).messages():
        message_session = str(message.get("session", ""))
        if selected_session is None:
            selected_session = message_session
        if message_session != selected_session:
            continue
        validate_envelope(message, selected_session)
        if message.get("kind") in {"commit", "control"}:
            seq = int(message.get("seq", 0))
            if seq != expected_seq:
                raise ProtocolError(
                    f"ordered message sequence gap: expected {expected_seq}, found {seq}"
                )
            expected_seq += 1
            action = message.get("payload", {}).get("action", {})
            if action.get("type") == "network.checkpoint_outcome":
                if action.get("success") is True:
                    agreed.append((seq, dict(action)))
                else:
                    faults.append({"seq": seq, "type": action.get("type"), **dict(action)})
            elif action.get("type") == "network.proposal_outcome" \
                    and action.get("success") is not True \
                    and action.get("recoverable") is not True:
                faults.append({"seq": seq, "type": action.get("type"), **dict(action)})
        elif message.get("kind") == "record" and message.get("record_type") == "checkpoint":
            payload = verify_checkpoint(message.get("payload", {}))
            if payload.get("checkpointVersion") not in {2, 3, CHECKPOINT_VERSION}:
                continue
            peer = str(message.get("peer", "unknown"))
            if payload.get("sessionId") != selected_session or payload.get("peerId") != peer:
                raise ProtocolError("checkpoint record identity differs from its audit envelope")
            boundary_seq = int(payload["eventCursor"]["lastCommitSeq"])
            peers = checkpoint_records.setdefault(boundary_seq, {})
            previous = peers.get(peer)
            if previous and previous != payload:
                raise ProtocolError(
                    f"peer {peer} has conflicting checkpoint records at boundary {boundary_seq}"
                )
            peers[peer] = payload

    if not selected_session:
        raise ProtocolError("audit has no session")
    if not agreed:
        raise ProtocolError("audit has no successful all-peer checkpoint outcome")

    outcome_seq, outcome = agreed[-1]
    boundary_seq = int(outcome.get("boundarySeq", 0))
    required = tuple(sorted(str(peer) for peer in outcome.get("peers", [])))
    records = checkpoint_records.get(boundary_seq, {})
    if not required or not set(required) <= set(records):
        missing = sorted(set(required) - set(records))
        raise ProtocolError("agreed checkpoint is missing peer records: " + ", ".join(missing))
    selected = [records[peer] for peer in required]
    convergence_key = str(outcome.get("convergenceKey", ""))
    if not convergence_key or any(item.get("convergenceKey") != convergence_key for item in selected):
        raise ProtocolError("checkpoint outcome does not match its peer convergence records")
    for field in ("coreDigest", "modelDigest", "canonicalDigest", "financialDigest"):
        if any(item.get(field) != outcome.get(field) for item in selected):
            raise ProtocolError(f"checkpoint outcome {field} differs from its peer records")
    if "structuralDigest" in outcome and any(
        item.get("structuralDigest") != outcome.get("structuralDigest") for item in selected
    ):
        raise ProtocolError("checkpoint outcome structuralDigest differs from its peer records")

    later_fault = next((fault for fault in faults if int(fault["seq"]) > outcome_seq), None)
    return {
        "session": selected_session,
        "outcomeSeq": outcome_seq,
        "boundarySeq": boundary_seq,
        "outcome": outcome,
        "requiredPeers": list(required),
        "records": {peer: records[peer] for peer in required},
        "laterFault": later_fault,
    }


def build_recovery_plan(audit_path: Path | str, session: str | None = None) -> dict[str, Any]:
    path = Path(audit_path).expanduser().resolve()
    analysis = analyse_recovery_anchor(path, session)
    outcome = analysis["outcome"]
    boundary_seq = int(analysis["boundarySeq"])
    peer_checkpoints = {
        peer: {
            "checkpointDigest": payload["checkpointDigest"],
            "tick": payload.get("tick"),
            "lastEventSeq": payload["eventCursor"]["lastEventSeq"],
        }
        for peer, payload in analysis["records"].items()
    }
    plan = {
        "format": "tpf2mp-recovery-plan",
        "version": RECOVERY_PLAN_VERSION,
        "protocol": PROTOCOL_VERSION,
        "session": analysis["session"],
        "resumeSession": f"{analysis['session']}-r{boundary_seq}",
        "generatedAtUtc": datetime.now(timezone.utc).isoformat(),
        "auditSha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "anchor": {
            "boundarySeq": boundary_seq,
            "outcomeSeq": analysis["outcomeSeq"],
            "reason": outcome.get("reason"),
            "proposalId": outcome.get("proposalId"),
            "convergenceKey": outcome["convergenceKey"],
            "coreDigest": outcome["coreDigest"],
            "modelDigest": outcome["modelDigest"],
            "canonicalDigest": outcome["canonicalDigest"],
            "financialDigest": outcome["financialDigest"],
            "structuralDigest": outcome.get("structuralDigest"),
        },
        "requiredPeers": analysis["requiredPeers"],
        "peerCheckpoints": peer_checkpoints,
        "laterFault": analysis["laterFault"],
        "recoveryMode": "coordinated-identical-save-reload",
        "requirements": [
            "Stop every companion and game instance for the faulted session.",
            "Each peer must load an identical native save captured at this agreed boundary.",
            "Regenerate matching content/save manifests and use resumeSession as a new session id.",
            "Do not import this checkpoint into divergent live geometry; it is an authority anchor, not a geometry patch.",
        ],
    }
    return sign(plan)


def verify_recovery_plan(value: Mapping[str, Any]) -> dict[str, Any]:
    plan = verify(value)
    if plan.get("format") != "tpf2mp-recovery-plan" or plan.get("version") != RECOVERY_PLAN_VERSION:
        raise ProtocolError("unsupported recovery plan format")
    if int(plan.get("protocol", -1)) != PROTOCOL_VERSION:
        raise ProtocolError("recovery plan protocol mismatch")
    if not isinstance(plan.get("requiredPeers"), list) or not plan["requiredPeers"]:
        raise ProtocolError("recovery plan has no required peers")
    if not isinstance(plan.get("anchor"), dict) or not plan["anchor"].get("convergenceKey"):
        raise ProtocolError("recovery plan has no agreed checkpoint anchor")
    return plan


def write_recovery_plan(
    audit_path: Path | str,
    output_path: Path | str,
    session: str | None = None,
) -> dict[str, Any]:
    plan = build_recovery_plan(audit_path, session)
    output = Path(output_path).expanduser().resolve()
    atomic_write(output, (canonical_json(plan) + "\n").encode("utf-8"))
    return plan


def write_recovery_archive(
    save_path: Path | str,
    output_directory: Path | str,
    session: str,
    peer: str,
    recovery_plan: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Copy and attest one complete native save triplet.

    A linked recovery plan proves the authority checkpoint.  It does not prove
    that Transport Fever 2 wrote the native save at that exact simulation tick,
    so the manifest keeps the association explicit instead of overclaiming it.
    """

    source_save = Path(save_path).expanduser().resolve()
    if source_save.suffix.lower() != ".sav" or not source_save.is_file():
        raise ProtocolError(f"native recovery save is missing or is not .sav: {source_save}")
    source_metadata = Path(str(source_save) + ".lua")
    if not source_metadata.is_file():
        raise ProtocolError(f"native recovery metadata is missing: {source_metadata}")
    source_image = source_save.with_suffix(".jpg")
    sources: list[tuple[str, Path]] = [
        ("save", source_save),
        ("metadata", source_metadata),
    ]
    if source_image.is_file():
        sources.append(("preview", source_image))

    if not session or peer not in {"player1", "player2"}:
        raise ProtocolError("recovery archive requires a session and numbered peer")
    verified_plan: dict[str, Any] | None = None
    plan_kind: str | None = None
    if recovery_plan is not None:
        try:
            verified_plan = verify_restore_plan(recovery_plan)
            plan_kind = "restore"
        except ProtocolError:
            verified_plan = verify_recovery_plan(recovery_plan)
            plan_kind = "recovery"
        if verified_plan.get("session") != session:
            raise ProtocolError("recovery plan session differs from archive session")
        if peer not in verified_plan.get("requiredPeers", []):
            raise ProtocolError("recovery plan does not contain the archive peer")
        if plan_kind == "restore":
            expected = verified_plan["peerSaves"][peer]
            hashes = hash_load_bearing_save(source_save)
            if (
                hashes["saveSha256"] != expected["saveSha256"]
                or (
                    expected.get("metadataSha256") is not None
                    and hashes["metadataSha256"] != expected["metadataSha256"]
                )
            ):
                raise ProtocolError(
                    f"native recovery save set does not match {peer}'s receipt-bound restore plan"
                )

    restore_attestation = None
    checkpoint_anchor = verified_plan.get("anchor") if verified_plan else None
    if verified_plan and plan_kind == "restore":
        restore_attestation = {
            "peer": peer,
            "requiredPeers": list(verified_plan["requiredPeers"]),
            **dict(verified_plan["peerSaves"][peer]),
        }
        checkpoint_anchor = {
            "boundarySeq": verified_plan["boundarySeq"],
            "convergenceKey": verified_plan["convergenceKey"],
            "coreDigest": verified_plan["coreDigest"],
        }

    output = Path(output_directory).expanduser().resolve()
    if output.exists():
        raise ProtocolError(f"recovery archive output already exists: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.mkdir()
    try:
        files: list[dict[str, Any]] = []
        for role, source in sources:
            before = sha256_file(source)
            destination = output / source.name
            shutil.copy2(source, destination)
            after = sha256_file(source)
            copied = sha256_file(destination)
            if before != after or copied != before:
                raise ProtocolError(f"native save changed while being archived: {source}")
            files.append(
                {
                    "role": role,
                    "path": destination.name,
                    "bytes": destination.stat().st_size,
                    "sha256": copied,
                }
            )

        manifest: dict[str, Any] = {
            "format": "tpf2mp-recovery-archive",
            "version": RECOVERY_ARCHIVE_VERSION,
            "protocol": PROTOCOL_VERSION,
            "session": session,
            "peer": peer,
            "createdAtUtc": datetime.now(timezone.utc).isoformat(),
            "association": (
                "coordinated-receipt-bound-restore-save"
                if plan_kind == "restore"
                else "agreed-checkpoint-native-save-candidate"
                if plan_kind == "recovery"
                else "unanchored-native-save"
            ),
            "save": {
                "baseName": source_save.stem,
                "files": files,
            },
            "checkpointAnchor": checkpoint_anchor,
            "recoveryPlanChecksum": verified_plan.get("checksum") if verified_plan else None,
            "restoreAttestation": restore_attestation,
            "limitations": [
                "The archive proves the copied native bytes and, when linked, the authority checkpoint.",
                "The game exposes no supported save-at-checkpoint command, so temporal association is not exact native-tick proof.",
                "Every peer must reload byte-identical archive files before using the recovery session.",
            ],
        }
        signed = sign(manifest)
        atomic_write(output / "archive-manifest.json", (canonical_json(signed) + "\n").encode("utf-8"))
        verify_recovery_archive(signed, output)
        return signed
    except Exception:
        shutil.rmtree(output, ignore_errors=True)
        raise


def verify_recovery_archive(
    value: Mapping[str, Any], archive_directory: Path | str
) -> dict[str, Any]:
    manifest = verify(value)
    if (
        manifest.get("format") != "tpf2mp-recovery-archive"
        or manifest.get("version") != RECOVERY_ARCHIVE_VERSION
    ):
        raise ProtocolError("unsupported recovery archive format")
    if int(manifest.get("protocol", -1)) != PROTOCOL_VERSION:
        raise ProtocolError("recovery archive protocol mismatch")
    if manifest.get("peer") not in {"player1", "player2"} or not manifest.get("session"):
        raise ProtocolError("recovery archive identity is invalid")
    association = manifest.get("association")
    if association not in {
        "unanchored-native-save", "agreed-checkpoint-native-save-candidate",
        "coordinated-receipt-bound-restore-save",
    }:
        raise ProtocolError("recovery archive association is invalid")
    save = manifest.get("save")
    if not isinstance(save, dict) or not isinstance(save.get("files"), list):
        raise ProtocolError("recovery archive has no native save files")
    roles = {str(item.get("role")) for item in save["files"] if isinstance(item, dict)}
    if not {"save", "metadata"} <= roles:
        raise ProtocolError("recovery archive lacks its save or metadata file")

    root = Path(archive_directory).expanduser().resolve()
    for item in save["files"]:
        if not isinstance(item, dict):
            raise ProtocolError("recovery archive file entry is invalid")
        relative = Path(str(item.get("path", "")))
        if relative.is_absolute() or ".." in relative.parts or len(relative.parts) != 1:
            raise ProtocolError("recovery archive file path escapes its archive")
        path = (root / relative).resolve()
        if path.parent != root or not path.is_file():
            raise ProtocolError(f"recovery archive file is missing: {relative}")
        if path.stat().st_size != int(item.get("bytes", -1)):
            raise ProtocolError(f"recovery archive file size mismatch: {relative}")
        if sha256_file(path) != item.get("sha256"):
            raise ProtocolError(f"recovery archive file hash mismatch: {relative}")
    attestation = manifest.get("restoreAttestation")
    if association == "coordinated-receipt-bound-restore-save":
        if not isinstance(attestation, Mapping) or attestation.get("peer") != manifest["peer"]:
            raise ProtocolError("receipt-bound recovery archive has no matching peer attestation")
        required = attestation.get("requiredPeers")
        if not isinstance(required, list) or manifest["peer"] not in required:
            raise ProtocolError("receipt-bound recovery archive has an invalid peer roster")
        save_entries = [item for item in save["files"] if item.get("role") == "save"]
        if len(save_entries) != 1 or save_entries[0].get("sha256") != attestation.get("saveSha256"):
            raise ProtocolError("receipt-bound recovery archive save differs from its attestation")
        metadata_entries = [
            item for item in save["files"] if item.get("role") == "metadata"
        ]
        expected_metadata = attestation.get("metadataSha256")
        if expected_metadata is not None and (
            len(metadata_entries) != 1
            or metadata_entries[0].get("sha256") != expected_metadata
        ):
            raise ProtocolError(
                "receipt-bound recovery archive metadata differs from its attestation"
            )
        anchor = manifest.get("checkpointAnchor")
        if not isinstance(anchor, Mapping) or any(
            anchor.get(field) != attestation.get(field)
            for field in ("boundarySeq", "coreDigest", "convergenceKey")
        ):
            raise ProtocolError("receipt-bound recovery archive names a different checkpoint")
        if not isinstance(manifest.get("recoveryPlanChecksum"), str) \
                or not manifest["recoveryPlanChecksum"]:
            raise ProtocolError("receipt-bound recovery archive has no restore-plan checksum")
    elif attestation is not None:
        raise ProtocolError("non-receipted recovery archive contains a restore attestation")
    return manifest
