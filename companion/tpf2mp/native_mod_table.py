from __future__ import annotations

import struct
from pathlib import Path
from typing import Any, BinaryIO

import zstandard

from .protocol import ProtocolError


MAX_ACTIVE_MODS = 2048
MAX_HEADER_BYTES = 64 * 1024 * 1024
MAX_STRING_BYTES = 16 * 1024 * 1024
MAX_NESTED_ITEMS = 65536


class ActiveContentError(ProtocolError):
    """The starting save's active content cannot be proven locally."""


class _SaveHeaderReader:
    def __init__(self, stream: BinaryIO) -> None:
        self.stream = stream
        self.consumed = 0

    def read_exact(self, size: int) -> bytes:
        if size < 0 or self.consumed + size > MAX_HEADER_BYTES:
            raise ActiveContentError("Transport Fever 2 save header exceeds the safety limit")
        chunks: list[bytes] = []
        remaining = size
        while remaining:
            block = self.stream.read(remaining)
            if not block:
                raise ActiveContentError("Transport Fever 2 save header is truncated")
            chunks.append(block)
            remaining -= len(block)
        self.consumed += size
        return b"".join(chunks)

    def u32(self, label: str) -> int:
        del label  # retained at call sites to make the binary contract readable
        return struct.unpack("<I", self.read_exact(4))[0]

    def count(self, label: str, maximum: int = MAX_NESTED_ITEMS) -> int:
        value = self.u32(label)
        if value > maximum:
            raise ActiveContentError(f"Transport Fever 2 save has an invalid {label}: {value}")
        return value

    def string(self, label: str) -> str:
        length = self.u32(f"{label} length")
        if length > MAX_STRING_BYTES:
            raise ActiveContentError(
                f"Transport Fever 2 save has an oversized {label}: {length} bytes"
            )
        try:
            return self.read_exact(length).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ActiveContentError(
                f"Transport Fever 2 save has invalid UTF-8 in {label}"
            ) from exc


def read_active_mods(save_file: Path | str) -> dict[str, Any]:
    """Read the ordered active-mod table from a compressed native .sav header.

    The table is ahead of world/entity data, so this does not deserialize or
    trust the rest of the save. The layout is the Build 35924 save contract
    (native save version 340) and is deliberately bounded/fail-closed.
    """

    save = Path(save_file).expanduser().resolve()
    if not save.is_file():
        raise FileNotFoundError(save)
    try:
        with save.open("rb") as compressed:
            if compressed.read(4) != b"\x28\xb5\x2f\xfd":
                raise ActiveContentError(
                    f"starting save is not a supported Zstandard Transport Fever 2 save: {save.name}"
                )
            compressed.seek(0)
            with zstandard.ZstdDecompressor().stream_reader(compressed) as stream:
                reader = _SaveHeaderReader(stream)
                if reader.read_exact(4) != b"tf**":
                    raise ActiveContentError("decompressed starting save has an invalid native magic")
                save_version = reader.u32("save version")
                # Seven native header words precede the active-mod vector in
                # version 340. Their meanings are irrelevant to compatibility.
                header_words = [reader.u32(f"header word {index}") for index in range(7)]
                mod_count = reader.count("active mod count", MAX_ACTIVE_MODS)
                mods: list[dict[str, Any]] = []
                seen: set[str] = set()
                for index in range(mod_count):
                    mod_id = reader.string(f"active mod {index + 1} id")
                    if not mod_id or len(mod_id) > 512:
                        raise ActiveContentError(
                            f"Transport Fever 2 save has an invalid active mod id at position {index + 1}"
                        )
                    if mod_id in seen:
                        raise ActiveContentError(f"starting save lists active mod {mod_id!r} more than once")
                    seen.add(mod_id)
                    record: dict[str, Any] = {
                        "id": mod_id,
                        "majorVersion": reader.u32("mod major version"),
                        "minorVersion": reader.u32("mod minor version"),
                        "severityAdd": reader.u32("mod add severity"),
                        "severityRemove": reader.u32("mod remove severity"),
                    }
                    # Human-facing metadata and parameter declarations still
                    # need to be consumed, but are not trusted as identity.
                    reader.string("mod name")
                    reader.string("mod description")
                    for _ in range(reader.count("mod tag count")):
                        reader.string("mod tag")
                    for _ in range(reader.count("mod author count")):
                        reader.string("mod author name")
                        reader.string("mod author role")
                    for _ in range(reader.count("mod parameter count")):
                        reader.string("mod parameter key")
                        reader.string("mod parameter label")
                        for _ in range(reader.count("mod parameter choice count")):
                            reader.string("mod parameter choice")
                        reader.u32("mod parameter default index")
                        reader.u32("mod parameter ui type")
                        reader.u32("mod parameter reserved word 1")
                        reader.u32("mod parameter reserved word 2")
                        reader.string("mod parameter tooltip")
                    reader.u32("mod reserved word 1")
                    reader.u32("mod reserved word 2")
                    mods.append(record)
    except zstandard.ZstdError as exc:
        raise ActiveContentError(f"starting save Zstandard stream is invalid: {exc}") from exc
    return {
        "saveVersion": save_version,
        "nativeHeaderWords": header_words,
        "mods": mods,
    }
