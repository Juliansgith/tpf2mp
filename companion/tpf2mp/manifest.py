from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any, Iterable

from .active_content import build_active_content_inventory
from .protocol import PROTOCOL_VERSION, canonical_json

IGNORED_PARTS = {"__pycache__", ".git", ".pytest_cache"}
IGNORED_SUFFIXES = {".pyc", ".pyo"}


def hash_file(path: Path | str) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        while block := handle.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def tree_records(root: Path | str) -> list[dict[str, Any]]:
    root = Path(root).expanduser().resolve()
    records: list[dict[str, Any]] = []
    for path in sorted(root.rglob("*"), key=lambda item: item.as_posix().lower()):
        relative = path.relative_to(root)
        if not path.is_file() or any(part in IGNORED_PARTS for part in relative.parts):
            continue
        if path.suffix.lower() in IGNORED_SUFFIXES:
            continue
        records.append(
            {
                "path": relative.as_posix(),
                "size": path.stat().st_size,
                "sha256": hash_file(path),
            }
        )
    return records


def tree_hash(root: Path | str) -> tuple[str, int]:
    records = tree_records(root)
    digest = hashlib.sha256(canonical_json(records).encode("utf-8")).hexdigest()
    return digest, len(records)


def build_manifest(
    game_executable: Path | str,
    mod_directory: Path | str,
    companion_directory: Path | str,
    save_file: Path | str | None = None,
    extras: Iterable[Path | str] = (),
    active_mod_save: Path | str | None = None,
    content_cache: Path | str | None = None,
) -> dict[str, Any]:
    game_executable = Path(game_executable).expanduser().resolve()
    mod_directory = Path(mod_directory).expanduser().resolve()
    companion_directory = Path(companion_directory).expanduser().resolve()
    if not game_executable.is_file():
        raise FileNotFoundError(game_executable)
    if not mod_directory.is_dir():
        raise FileNotFoundError(mod_directory)
    if not companion_directory.is_dir():
        raise FileNotFoundError(companion_directory)

    mod_hash, mod_files = tree_hash(mod_directory)
    companion_hash, companion_files = tree_hash(companion_directory)
    components: dict[str, Any] = {
        "game_executable": {"sha256": hash_file(game_executable), "size": game_executable.stat().st_size},
        "mod": {"sha256": mod_hash, "files": mod_files},
        "companion": {"sha256": companion_hash, "files": companion_files},
    }
    if save_file:
        save = Path(save_file).expanduser().resolve()
        save_component = {"sha256": hash_file(save), "size": save.stat().st_size}
        sidecar = save.with_name(save.name + ".lua")
        if sidecar.is_file():
            save_component["script_state_sha256"] = hash_file(sidecar)
            save_component["script_state_size"] = sidecar.stat().st_size
        components["starting_save"] = save_component
    inventory_save = active_mod_save or save_file
    if inventory_save:
        components["active_content"] = build_active_content_inventory(
            inventory_save,
            game_executable,
            mod_directory,
            cache_path=content_cache,
        )
    extra_values = []
    for index, item in enumerate(extras, 1):
        path = Path(item).expanduser().resolve()
        if path.is_dir():
            value, count = tree_hash(path)
            extra_values.append({"slot": index, "kind": "tree", "sha256": value, "files": count})
        else:
            extra_values.append({"slot": index, "kind": "file", "sha256": hash_file(path), "size": path.stat().st_size})
    if extra_values:
        components["extras"] = extra_values

    core = {
        "format": 2,
        "protocol": PROTOCOL_VERSION,
        "components": components,
    }
    result = dict(core)
    result["fingerprint"] = hashlib.sha256(canonical_json(core).encode("utf-8")).hexdigest()
    return result


def write_manifest(path: Path | str, manifest: dict[str, Any]) -> None:
    path = Path(path).expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(canonical_json(manifest) + "\n", encoding="utf-8")


def load_manifest(path: Path | str) -> dict[str, Any]:
    path = Path(path).expanduser().resolve()
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or not isinstance(value.get("fingerprint"), str):
        raise ValueError("invalid match manifest")
    core = dict(value)
    expected = core.pop("fingerprint")
    actual = hashlib.sha256(canonical_json(core).encode("utf-8")).hexdigest()
    if actual != expected:
        raise ValueError(f"manifest fingerprint mismatch: expected {expected}, calculated {actual}")
    if int(value.get("protocol", -1)) != PROTOCOL_VERSION:
        raise ValueError("manifest protocol mismatch")
    return value
