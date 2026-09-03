from __future__ import annotations

import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Iterable, Mapping

from .native_mod_table import ActiveContentError, MAX_ACTIVE_MODS, read_active_mods
from .protocol import canonical_json


ACTIVE_CONTENT_SCHEMA_VERSION = 1

# These formats cannot affect construction graphs, vehicle characteristics, or
# authored simulation state.  Excluding them keeps the first compatibility
# scan practical for large Workshop collections while all scripts and resource
# descriptors (including .con/.module/.mdl) remain content-bound.
PRESENTATION_ONLY_SUFFIXES = {
    ".aac", ".avi", ".bmp", ".dds", ".flac", ".gif", ".ico", ".jpeg",
    ".jpg", ".m4a", ".mp3", ".mp4", ".msh", ".ogg", ".png", ".tga",
    ".wav", ".webm", ".webp",
}
IGNORED_DIRECTORY_NAMES = {".git", "__pycache__", ".pytest_cache"}
IGNORED_FILE_SUFFIXES = {".pyc", ".pyo"}


class _ContentHashCache:
    def __init__(self, path: Path | str | None) -> None:
        self.path = Path(path).expanduser().resolve() if path else None
        self.entries: dict[str, dict[str, Any]] = {}
        self.dirty = False
        if self.path and self.path.is_file():
            try:
                value = json.loads(self.path.read_text(encoding="utf-8"))
                if value.get("schemaVersion") == 1 and isinstance(value.get("entries"), dict):
                    self.entries = value["entries"]
            except (OSError, UnicodeError, json.JSONDecodeError, AttributeError):
                self.entries = {}

    @staticmethod
    def _key(path: Path, kind: str) -> str:
        return f"{kind}:{os.path.normcase(str(path.resolve()))}"

    def get(self, path: Path, kind: str) -> dict[str, Any] | None:
        stat = path.stat()
        value = self.entries.get(self._key(path, kind))
        if isinstance(value, dict) \
                and value.get("size") == stat.st_size \
                and value.get("mtimeNs") == stat.st_mtime_ns:
            return value
        return None

    def put(self, path: Path, kind: str, value: Mapping[str, Any]) -> None:
        stat = path.stat()
        self.entries[self._key(path, kind)] = {
            "size": stat.st_size,
            "mtimeNs": stat.st_mtime_ns,
            **dict(value),
        }
        self.dirty = True

    def save(self) -> None:
        if not self.path or not self.dirty:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(
            {"schemaVersion": 1, "entries": self.entries},
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        ) + "\n"
        fd, temporary_name = tempfile.mkstemp(
            prefix=self.path.name + ".", suffix=".tmp", dir=self.path.parent
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, self.path)
        finally:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def _sha256_file(path: Path, cache: _ContentHashCache) -> str:
    cached = cache.get(path, "file")
    if cached and isinstance(cached.get("sha256"), str):
        return cached["sha256"]
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    value = digest.hexdigest()
    cache.put(path, "file", {"sha256": value})
    return value


def _is_load_bearing(relative: Path | str) -> bool:
    path = Path(str(relative).replace("\\", "/"))
    if any(part.lower() in IGNORED_DIRECTORY_NAMES for part in path.parts):
        return False
    suffix = path.suffix.lower()
    return suffix not in PRESENTATION_ONLY_SUFFIXES and suffix not in IGNORED_FILE_SUFFIXES


def _zip_digest(path: Path, cache: _ContentHashCache) -> tuple[str, int]:
    cached = cache.get(path, "zip-logical")
    if cached and isinstance(cached.get("sha256"), str) \
            and isinstance(cached.get("files"), int):
        return cached["sha256"], cached["files"]
    records: list[dict[str, Any]] = []
    try:
        with zipfile.ZipFile(path) as archive:
            entries = sorted(
                (item for item in archive.infolist() if not item.is_dir()),
                key=lambda item: item.filename.casefold(),
            )
            for item in entries:
                if not _is_load_bearing(item.filename):
                    continue
                digest = hashlib.sha256()
                with archive.open(item) as handle:
                    while block := handle.read(1024 * 1024):
                        digest.update(block)
                records.append({
                    "path": item.filename.replace("\\", "/"),
                    "size": item.file_size,
                    "sha256": digest.hexdigest(),
                })
    except (OSError, zipfile.BadZipFile):
        # A file named .zip that is not a ZIP remains bound byte-for-byte.
        return _sha256_file(path, cache), 1
    value = hashlib.sha256(canonical_json(records).encode("utf-8")).hexdigest()
    cache.put(path, "zip-logical", {"sha256": value, "files": len(records)})
    return value, len(records)


def _tree_content_digest(root: Path, cache: _ContentHashCache) -> tuple[str, int]:
    records: list[dict[str, Any]] = []
    paths = sorted(root.rglob("*"), key=lambda value: value.as_posix().casefold())
    for path in paths:
        if not path.is_file():
            continue
        relative = path.relative_to(root)
        if not _is_load_bearing(relative):
            continue
        if path.suffix.lower() == ".zip":
            value, count = _zip_digest(path, cache)
            records.append({
                "path": relative.as_posix(),
                "kind": "zip-tree",
                "files": count,
                "sha256": value,
            })
        else:
            records.append({
                "path": relative.as_posix(),
                "size": path.stat().st_size,
                "sha256": _sha256_file(path, cache),
            })
    value = hashlib.sha256(canonical_json(records).encode("utf-8")).hexdigest()
    return value, len(records)


def _candidate_names(mod_id: str, major_version: int) -> list[str]:
    normalized = mod_id.lstrip("!")
    values = [f"{normalized}_{major_version}", normalized]
    if normalized.endswith(f"_{major_version}"):
        values.reverse()
    return list(dict.fromkeys(values))


def resolve_active_mod_root(
    record: Mapping[str, Any],
    game_executable: Path | str,
    mod_directory: Path | str,
) -> tuple[Path, str]:
    game = Path(game_executable).expanduser().resolve()
    game_root = game.parent
    installed_tpf2mp = Path(mod_directory).expanduser().resolve()
    local_mods = installed_tpf2mp.parent
    mod_id = str(record.get("id", ""))
    if not mod_id or mod_id in {".", ".."} \
            or any(character in mod_id for character in ("\0", "/", "\\", ":")) \
            or any(ord(character) < 32 for character in mod_id):
        raise ActiveContentError("starting save contains an unsafe active mod/DLC id")
    major = int(record.get("majorVersion", 0))
    normalized = mod_id.lstrip("!")
    candidates: list[tuple[Path, str]] = []

    if normalized == "tpf2_mp":
        candidates.append((installed_tpf2mp, "mod"))
    if mod_id.startswith("*") and mod_id[1:].isdigit():
        workshop_root = game_root.parent.parent / "workshop" / "content" / "1066780"
        candidates.append((workshop_root / mod_id[1:], "workshop"))
    elif normalized.startswith("_urbangames_") or mod_id.startswith("_urbangames_"):
        for name in _candidate_names(normalized[1:], major):
            candidates.append((game_root / "dlcs" / name, "dlc"))

    for name in _candidate_names(mod_id, major):
        candidates.extend([
            (local_mods / name, "mod"),
            (game_root / "mods" / name, "mod"),
        ])

    visited: set[str] = set()
    for path, kind in candidates:
        key = os.path.normcase(str(path))
        if key in visited:
            continue
        visited.add(key)
        if path.is_dir():
            return path.resolve(), kind
    version = f"{record.get('majorVersion', '?')}.{record.get('minorVersion', '?')}"
    raise ActiveContentError(
        f"required active mod/DLC {mod_id!r} (version {version}) from the starting "
        "save is not installed; install the same content as the host"
    )


def build_active_content_inventory(
    save_file: Path | str,
    game_executable: Path | str,
    mod_directory: Path | str,
    cache_path: Path | str | None = None,
) -> dict[str, Any]:
    header = read_active_mods(save_file)
    cache = _ContentHashCache(cache_path)
    mods: list[dict[str, Any]] = []
    try:
        for record in header["mods"]:
            root, source_kind = resolve_active_mod_root(record, game_executable, mod_directory)
            content_hash, content_files = _tree_content_digest(root, cache)
            mods.append({
                "id": record["id"],
                "majorVersion": record["majorVersion"],
                "minorVersion": record["minorVersion"],
                "severityAdd": record["severityAdd"],
                "severityRemove": record["severityRemove"],
                "sourceKind": source_kind,
                "contentSha256": content_hash,
                "contentFiles": content_files,
            })
    finally:
        cache.save()
    core = {
        "schemaVersion": ACTIVE_CONTENT_SCHEMA_VERSION,
        "saveVersion": header["saveVersion"],
        "mods": mods,
    }
    return {
        **core,
        "digest": hashlib.sha256(canonical_json(core).encode("utf-8")).hexdigest(),
    }


def compact_content_inventory(inventory: Mapping[str, Any] | None) -> dict[str, Any] | None:
    if inventory is None:
        return None
    mods = inventory.get("mods")
    if inventory.get("schemaVersion") != ACTIVE_CONTENT_SCHEMA_VERSION \
            or not isinstance(inventory.get("digest"), str) \
            or not isinstance(mods, list):
        raise ActiveContentError("active content inventory is malformed")
    return {
        "schemaVersion": ACTIVE_CONTENT_SCHEMA_VERSION,
        "digest": inventory["digest"],
        "mods": [{
            "id": item.get("id"),
            "majorVersion": item.get("majorVersion"),
            "minorVersion": item.get("minorVersion"),
            "contentSha256": item.get("contentSha256"),
        } for item in mods],
    }


def _validated_compact(inventory: Any, label: str) -> dict[str, Any]:
    if not isinstance(inventory, Mapping) \
            or inventory.get("schemaVersion") != ACTIVE_CONTENT_SCHEMA_VERSION \
            or not isinstance(inventory.get("digest"), str) \
            or len(inventory["digest"]) != 64 \
            or not isinstance(inventory.get("mods"), list) \
            or len(inventory["mods"]) > MAX_ACTIVE_MODS:
        raise ActiveContentError(f"{label} active content inventory is malformed")
    result = compact_content_inventory(inventory)
    assert result is not None
    seen: set[str] = set()
    for index, item in enumerate(result["mods"], 1):
        if not isinstance(item.get("id"), str) or not item["id"] or item["id"] in seen:
            raise ActiveContentError(f"{label} active mod {index} has an invalid or duplicate id")
        seen.add(item["id"])
        for key in ("majorVersion", "minorVersion"):
            if not isinstance(item.get(key), int) or isinstance(item.get(key), bool):
                raise ActiveContentError(f"{label} active mod {item['id']!r} has an invalid {key}")
        digest = item.get("contentSha256")
        if not isinstance(digest, str) or len(digest) != 64 \
                or any(character not in "0123456789abcdef" for character in digest):
            raise ActiveContentError(f"{label} active mod {item['id']!r} has an invalid digest")
    return result


def describe_content_mismatch(host_inventory: Any, peer_inventory: Any) -> str:
    """Return a path-free, user-actionable host/peer compatibility diagnosis."""

    host = _validated_compact(host_inventory, "host")
    peer = _validated_compact(peer_inventory, "peer")
    if host["digest"] == peer["digest"]:
        return ""
    host_by_id = {item["id"]: item for item in host["mods"]}
    peer_by_id = {item["id"]: item for item in peer["mods"]}
    missing = [item for item in host["mods"] if item["id"] not in peer_by_id]
    extra = [item for item in peer["mods"] if item["id"] not in host_by_id]

    def names(items: Iterable[Mapping[str, Any]]) -> str:
        values = [
            f"{item['id']} v{item['majorVersion']}.{item['minorVersion']}"
            for item in items
        ]
        return ", ".join(values[:5]) + (f" (+{len(values) - 5} more)" if len(values) > 5 else "")

    if missing:
        return "peer is missing required active content: " + names(missing)
    if extra:
        return "peer has extra active content: " + names(extra)
    for mod_id in host_by_id:
        expected, actual = host_by_id[mod_id], peer_by_id[mod_id]
        expected_version = (expected["majorVersion"], expected["minorVersion"])
        actual_version = (actual["majorVersion"], actual["minorVersion"])
        if expected_version != actual_version:
            return (
                f"active content version differs for {mod_id}: host "
                f"{expected_version[0]}.{expected_version[1]}, peer "
                f"{actual_version[0]}.{actual_version[1]}"
            )
        if expected["contentSha256"] != actual["contentSha256"]:
            return (
                f"installed files differ for active content {mod_id} despite the same "
                "declared version; update or reinstall that mod/DLC on both computers"
            )
    host_order = [item["id"] for item in host["mods"]]
    peer_order = [item["id"] for item in peer["mods"]]
    if host_order != peer_order:
        first = next(
            index for index, values in enumerate(zip(host_order, peer_order), 1)
            if values[0] != values[1]
        )
        return (
            f"active mod load order differs at position {first}: host "
            f"{host_order[first - 1]}, peer {peer_order[first - 1]}"
        )
    return "active content inventory digest differs for an unknown reason"
