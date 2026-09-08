"""Validate the native serializer's data-only Lua without executing a save."""
from __future__ import annotations

import re
from pathlib import Path

from .protocol import ProtocolError

MAX_METADATA_BYTES = 32 * 1024 * 1024
MAX_DEPTH = 128
_TOKEN = re.compile(
    r'''(?P<space>\s+)|(?P<comment>--[^\r\n]*)|'''
    r'''(?P<string>"(?:[^"\\\r\n]|\\(?:\r\n|[\s\S]))*"|'(?:[^'\\\r\n]|\\(?:\r\n|[\s\S]))*')|'''
    r'''(?P<number>-?(?:(?:inf|nan)\b|0[xX][0-9a-fA-F]+|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?))|'''
    r'''(?P<name>[A-Za-z_][A-Za-z_0-9]*)|(?P<punct>[{}\[\](),;=])'''
)
_KEYWORDS = set("and break do else elseif end false for function if in local nil not or repeat return then true until while goto".split())


class MetadataError(ProtocolError):
    """A native save's sidecar is not complete serialized Lua data."""


class _Parser:
    def __init__(self, text: str) -> None:
        self.text, self.position = text, 0
        self.kind, self.value, self.start = "", "", 0
        self.advance()

    def error(self, message: str) -> None:
        line = self.text.count("\n", 0, self.start) + 1
        raise MetadataError(f"line {line}: {message}")

    def advance(self) -> None:
        while self.position < len(self.text):
            self.start = self.position
            token = _TOKEN.match(self.text, self.position)
            if token is None:
                self.error("invalid or incomplete native Lua data")
            self.position = token.end()
            if token.lastgroup in {"space", "comment"}:
                continue
            self.kind, self.value = token.lastgroup, token.group()
            return
        self.kind, self.value, self.start = "eof", "", self.position

    def expect(self, value: str) -> None:
        if self.value != value:
            self.error(f"expected {value!r}")
        self.advance()

    def literal(self, depth: int) -> None:
        if self.value == "{":
            self.table(depth + 1)
        elif self.kind in {"string", "number"} or self.value in {"true", "false", "nil"}:
            self.advance()
        else:
            self.error("expected a serialized value (expressions are not accepted)")

    def table(self, depth: int) -> None:
        if depth > MAX_DEPTH:
            self.error("native Lua data exceeds the nesting limit")
        self.expect("{")
        while self.value != "}":
            if self.value == "[":
                self.advance()
                if self.kind not in {"string", "number"} and self.value not in {"true", "false"}:
                    self.error("expected a literal table key")
                self.advance()
                self.expect("]")
                self.expect("=")
                self.literal(depth)
            elif self.kind == "name" and self.value not in _KEYWORDS:
                self.advance()
                self.expect("=")
                self.literal(depth)
            else:
                self.literal(depth)
            if self.value in {",", ";"}:
                self.advance()
            elif self.value != "}":
                self.error("expected a table separator or closing brace")
        self.expect("}")

    def parse(self) -> None:
        for token in ("function", "data", "(", ")", "return"):
            self.expect(token)
        self.table(0)
        self.expect("end")
        if self.value == ";":
            self.advance()
        if self.kind != "eof":
            self.error("unexpected content after the saved data function")


def validate_metadata(save_path: Path | str) -> Path:
    save = Path(save_path).expanduser().resolve()
    metadata = Path(str(save) + ".lua")
    try:
        with metadata.open("rb") as handle:
            raw = handle.read(MAX_METADATA_BYTES + 1)
        if len(raw) > MAX_METADATA_BYTES:
            raise MetadataError("native Lua data exceeds 32 MiB")
        _Parser(raw.decode("utf-8-sig")).parse()
    except (MetadataError, UnicodeError, OSError) as exc:
        raise MetadataError(
            f"Cannot safely load {save.name}: save metadata {metadata.name} "
            f"is incomplete, damaged, or unsupported ({exc}). "
            "Use a verified restore point or another save; the original files were not changed."
        ) from exc
    return metadata
