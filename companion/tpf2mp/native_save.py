"""Stable hashes for the two files Transport Fever 2 actually reloads."""

from __future__ import annotations

import hashlib
from pathlib import Path
from .protocol import ProtocolError


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_bearing_paths(save_path: Path | str) -> tuple[Path, Path]:
    save = Path(save_path).expanduser().resolve()
    metadata = Path(str(save) + ".lua")
    if save.suffix.lower() != ".sav" or not save.is_file():
        raise ProtocolError(f"native save is missing or is not a .sav: {save}")
    if not metadata.is_file():
        raise ProtocolError(f"native save metadata is missing: {metadata}")
    return save, metadata


def _snapshot(paths: tuple[Path, ...]) -> tuple[tuple[int, int], ...]:
    result = []
    for path in paths:
        stat = path.stat()
        result.append((stat.st_size, stat.st_mtime_ns))
    return tuple(result)


def hash_load_bearing_save(save_path: Path | str) -> dict[str, str]:
    """Hash `.sav` plus `.sav.lua`, refusing a pair that changes mid-read."""

    save, metadata = load_bearing_paths(save_path)
    paths = (save, metadata)
    before = _snapshot(paths)
    hashes = tuple(sha256_file(path) for path in paths)
    after = _snapshot(paths)
    if before != after:
        raise ProtocolError("native save changed while its load-bearing files were hashed")
    return {
        "savePath": str(save),
        "metadataPath": str(metadata),
        "saveSha256": hashes[0],
        "metadataSha256": hashes[1],
    }
