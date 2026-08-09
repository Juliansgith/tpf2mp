"""Discovery of the newest complete, receipt-bound local restore archive."""

from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any

from .native_save import sha256_file
from .protocol import ProtocolError
from .recovery import verify_recovery_archive
from .restore import confirm_restore_readiness
from .restore_plan import verify_restore_plan


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ProtocolError(f"local restore metadata is not an object: {path}")
    return value


def _candidate(session_root: Path, peer: str) -> dict[str, Any]:
    pointer_path = session_root / peer / "latest-recovery-archive.json"
    pointer = _read_json(pointer_path)
    if pointer.get("schemaVersion") not in {1, 2} \
            or pointer.get("session") != session_root.name \
            or pointer.get("peer") != peer:
        raise ProtocolError("local restore pointer identity is invalid")

    peer_root = (session_root / peer).resolve()
    recovery_root = (peer_root / "recovery").resolve()
    archive_root = Path(str(pointer.get("archiveDirectory", ""))).resolve()
    manifest_path = Path(str(pointer.get("manifestPath", ""))).resolve()
    plan_path = Path(str(pointer.get("recoveryPlanPath", ""))).resolve()
    if not _inside(archive_root, recovery_root) or not _inside(plan_path, recovery_root):
        raise ProtocolError("local restore pointer escapes its peer recovery directory")
    if manifest_path != archive_root / "archive-manifest.json":
        raise ProtocolError("local restore pointer names a foreign archive manifest")
    if not manifest_path.is_file() or not plan_path.is_file():
        raise ProtocolError("local restore pointer names missing plan or archive files")
    if sha256_file(manifest_path) != pointer.get("manifestSha256"):
        raise ProtocolError("local restore pointer manifest hash changed")

    plan = verify_restore_plan(_read_json(plan_path))
    manifest = verify_recovery_archive(_read_json(manifest_path), archive_root)
    if plan.get("session") != session_root.name or peer not in plan["requiredPeers"]:
        raise ProtocolError("local restore plan identity differs from its session directory")
    if manifest.get("association") != "coordinated-receipt-bound-restore-save" \
            or manifest.get("session") != session_root.name \
            or manifest.get("peer") != peer \
            or manifest.get("recoveryPlanChecksum") != plan.get("checksum"):
        raise ProtocolError("local restore archive is not bound to its selected plan")

    save_entries = [
        item for item in manifest["save"]["files"] if item.get("role") == "save"
    ]
    if len(save_entries) != 1:
        raise ProtocolError("local restore archive does not contain exactly one save")
    save_path = (archive_root / str(save_entries[0]["path"])).resolve()
    readiness = confirm_restore_readiness(plan, {peer: save_path})
    if readiness["peers"].get(peer, {}).get("ok") is not True:
        raise ProtocolError("local restore save differs from its plan attestation")
    archived_at = str(manifest.get("createdAtUtc", ""))
    sort_time = datetime.fromisoformat(archived_at.replace("Z", "+00:00")).timestamp()
    return {
        "schemaVersion": 1,
        "session": session_root.name,
        "resumeSession": plan["resumeSession"],
        "peer": peer,
        "boundarySeq": plan["boundarySeq"],
        "planChecksum": plan["checksum"],
        "planPath": str(plan_path),
        "savePath": str(save_path),
        "archiveDirectory": str(archive_root),
        "archivedAtUtc": archived_at,
        "_sortTime": sort_time,
    }


def latest_local_restore(sessions_root: Path | str, peer: str) -> dict[str, Any]:
    """Return the newest fully verified archive for one local peer."""

    if peer not in {"player1", "player2"}:
        raise ProtocolError("local restore peer must be player1 or player2")
    root = Path(sessions_root).expanduser().resolve()
    if not root.is_dir():
        raise ProtocolError(f"local session directory is missing: {root}")
    candidates: list[dict[str, Any]] = []
    for session_root in sorted(path for path in root.iterdir() if path.is_dir()):
        pointer = session_root / peer / "latest-recovery-archive.json"
        if not pointer.is_file():
            continue
        try:
            candidates.append(_candidate(session_root, peer))
        except (OSError, ValueError, json.JSONDecodeError, ProtocolError):
            continue
    if not candidates:
        raise ProtocolError(f"no verified receipt-bound local restore exists for {peer}")
    latest = max(candidates, key=lambda item: (item["_sortTime"], item["session"]))
    latest.pop("_sortTime")
    return latest
