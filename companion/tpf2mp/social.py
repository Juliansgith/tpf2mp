"""Advisory chat/ping/preview side channel outside the ordered commit path.

Specified by `docs/SOCIAL_CHANNEL.md`. Nothing here enters an intent, a commit,
an event record, a checkpoint digest or the audit replay, so every failure is
counted and ignored instead of faulting the session.
"""

from __future__ import annotations

import json
import math
import re
import threading
import zlib
from typing import Any, Callable, Mapping

from .bridge import GameBridge, atomic_write
from .protocol import (
    PROTOCOL_VERSION, ProtocolError, canonical_json, sign, validate_envelope,
)

SOCIAL_SCHEMA_VERSION = 1
SOCIAL_PEERS = ("player1", "player2")
PING_KINDS = ("wait", "ready", "look", "pause")
MAX_TEXT_CHARACTERS = 240
MAX_CURVES = 24
CURVE_LENGTH = 8
DETAIL_LENGTH = 10
DETAIL_HEIGHTS = 4
TRANSF_LENGTH = 16
MAX_FILE_CHARACTERS = 128
MAX_PARAMS_CHARACTERS = 4096
NAME_PATTERN = re.compile(r"^[A-Za-z0-9_./-]+$")
FILE_PATTERN = re.compile(r"^[A-Za-z0-9_./-]+\.con$")
TERRAIN_ALIGNMENTS = (0, 1, 2)
BUS_STOPS = (0, 1)
TRAM_TRACKS = (0, 1, 2)
CATENARY_STATES = (0, 1)
MAX_FRAME_ITEMS = 32
MAX_FRAME_BYTES = 32 * 1024
MAX_OUTGOING_ITEMS = 32
MAX_OUTGOING_BYTES = 64 * 1024
MAX_INCOMING_ITEMS = 64
_ITEM_KEYS = {"id", "peer", "channel", "at", "body"}
_DOCUMENT_KEYS = {"schemaVersion", "session", "peer", "seq", "items"}
_FRAME_KEYS = {"checksum", "items", "kind", "peer", "protocol", "session"}
_ATTACH_LOCK = threading.Lock()


def _count(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ProtocolError(f"social {label} must be a non-negative integer")
    return value


def _number(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProtocolError(f"social {label} must be a number")
    number = float(value)
    if not math.isfinite(number):
        raise ProtocolError(f"social {label} must be finite")
    return number


def _numbers(value: Any, length: int, label: str) -> list[float]:
    if not isinstance(value, list) or len(value) != length:
        raise ProtocolError(f"social {label} must hold exactly {length} numbers")
    return [_number(item, label) for item in value]


def _flag(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        raise ProtocolError(f"social {label} must be a boolean")
    return value


def _choice(value: Any, allowed: tuple[int, ...], label: str) -> int:
    # `bool` is an `int` subclass, so an unguarded membership test would accept
    # `True` wherever 1 is legal and change the meaning of a replayed detail.
    if not isinstance(value, int) or isinstance(value, bool) or value not in allowed:
        raise ProtocolError(f"social {label} must be one of {allowed}")
    return value


def _name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_FILE_CHARACTERS \
            or NAME_PATTERN.fullmatch(value) is None:
        raise ProtocolError(f"social {label} is empty, oversized or off-charset")
    return value


def _chat_body(body: Mapping[str, Any]) -> dict[str, Any]:
    if set(body) != {"text"}:
        raise ProtocolError("social chat body has an unexpected key set")
    text = body["text"]
    # Printable means "no control or unassigned code points"; the length bound
    # counts characters so a Lua byte check and this check agree on ASCII.
    if not isinstance(text, str) or not 1 <= len(text) <= MAX_TEXT_CHARACTERS \
            or not text.isprintable():
        raise ProtocolError("social chat text is empty, oversized or unprintable")
    return {"text": text}


def _ping_body(body: Mapping[str, Any]) -> dict[str, Any]:
    kind = body.get("kind")
    if kind not in PING_KINDS:
        raise ProtocolError("social ping kind is unknown")
    # A "look" ping carries both coordinates or neither (no ground position
    # was resolvable on the sender); other kinds carry only the kind.
    keys = set(body)
    if kind != "look" or keys == {"kind"}:
        if keys != {"kind"}:
            raise ProtocolError("social ping body has an unexpected key set")
        return {"kind": kind}
    if keys != {"kind", "x", "y"}:
        raise ProtocolError("social ping body has an unexpected key set")
    x, y = _number(body["x"], "ping x"), _number(body["y"], "ping y")
    return {"kind": kind, "x": x, "y": y}


def _detail(value: Any) -> list[Any]:
    """One optional per-curve segment detail, in the documented slot order.

    `[z0, z1, tz0, tz1, terrain, file, bus, tram, catenary, structure]` is what
    the game's builder proposal carries beside the XY curve, so a receiver with
    the native preview renderer can rebuild the proposal instead of drawing a
    flat ribbon. `structure` names the bridge or tunnel type and is empty
    exactly when the segment sits on the ground (`terrain == 0`).
    """
    if not isinstance(value, list) or len(value) != DETAIL_LENGTH:
        raise ProtocolError(
            f"social preview detail must hold exactly {DETAIL_LENGTH} values"
        )
    heights = [
        _number(item, "preview detail height") for item in value[:DETAIL_HEIGHTS]
    ]
    terrain = _choice(value[4], TERRAIN_ALIGNMENTS, "preview detail terrain")
    structure = value[9]
    if terrain == 0:
        if structure != "":
            raise ProtocolError("social preview ground detail names a structure")
        structure = ""
    else:
        structure = _name(structure, "preview detail structure")
    return heights + [
        terrain,
        _name(value[5], "preview detail file"),
        _choice(value[6], BUS_STOPS, "preview detail bus stop"),
        _choice(value[7], TRAM_TRACKS, "preview detail tram track"),
        _choice(value[8], CATENARY_STATES, "preview detail catenary"),
        structure,
    ]


def _params(value: Any) -> str:
    # Construction parameters are an opaque ordered blob to the companion; only
    # printable ASCII crosses the wire so a Lua byte scan agrees with this one.
    if not isinstance(value, str) or not 1 <= len(value) <= MAX_PARAMS_CHARACTERS \
            or any(not 0x20 <= ord(char) <= 0x7E for char in value):
        raise ProtocolError("social preview construction params are invalid")
    return value


def _path_body(kind: str, body: Mapping[str, Any]) -> dict[str, Any]:
    keys = set(body)
    if keys not in ({"kind", "invalid", "curves"},
                    {"kind", "invalid", "curves", "details"}):
        raise ProtocolError("social preview body has an unexpected key set")
    curves = body["curves"]
    if not isinstance(curves, list) or not 1 <= len(curves) <= MAX_CURVES:
        raise ProtocolError("social preview curve count is out of range")
    validated = {
        "kind": kind,
        "invalid": _flag(body["invalid"], "preview validity"),
        "curves": [
            _numbers(curve, CURVE_LENGTH, "preview curve") for curve in curves
        ],
    }
    if "details" in keys:
        details = body["details"]
        if not isinstance(details, list) or len(details) != len(curves):
            raise ProtocolError("social preview details do not match their curves")
        validated["details"] = [_detail(detail) for detail in details]
    return validated


def _construction_body(kind: str, body: Mapping[str, Any]) -> dict[str, Any]:
    keys = set(body)
    exact = {"kind", "invalid", "file", "x", "y", "z", "transf"}
    if keys != exact and keys != exact | {"params"}:
        raise ProtocolError("social preview body has an unexpected key set")
    name = body["file"]
    if not isinstance(name, str) or len(name) > MAX_FILE_CHARACTERS \
            or FILE_PATTERN.fullmatch(name) is None:
        raise ProtocolError("social preview construction file is invalid")
    validated = {
        "kind": kind,
        "invalid": _flag(body["invalid"], "preview validity"),
        "file": name,
        "x": _number(body["x"], "preview x"),
        "y": _number(body["y"], "preview y"),
        "z": _number(body["z"], "preview z"),
        "transf": _numbers(body["transf"], TRANSF_LENGTH, "preview transf"),
    }
    if "params" in keys:
        validated["params"] = _params(body["params"])
    return validated


def _preview_body(body: Mapping[str, Any]) -> dict[str, Any]:
    kind = body.get("kind")
    if kind == "off":
        if set(body) != {"kind"}:
            raise ProtocolError("social preview body has an unexpected key set")
        return {"kind": kind}
    if kind in {"road", "rail"}:
        return _path_body(kind, body)
    if kind == "construction":
        return _construction_body(kind, body)
    raise ProtocolError("social preview kind is unknown")


def validate_social_item(value: Any, origin: str | None = None) -> dict[str, Any]:
    """Return one strictly bounded chat/ping/preview item, or raise."""

    if not isinstance(value, Mapping) or set(value) != _ITEM_KEYS:
        raise ProtocolError("social item has an unexpected key set")
    peer = value["peer"]
    if peer not in SOCIAL_PEERS or (origin is not None and peer != origin):
        raise ProtocolError("social item names an unusable origin peer")
    body, channel = value["body"], value["channel"]
    if not isinstance(body, Mapping):
        raise ProtocolError("social item body must be an object")
    if channel == "chat":
        validated = _chat_body(body)
    elif channel == "ping":
        validated = _ping_body(body)
    elif channel == "preview":
        validated = _preview_body(body)
    else:
        raise ProtocolError("social item channel is unknown")
    return {
        "id": _count(value["id"], "item id"),
        "peer": peer,
        "channel": channel,
        "at": _count(value["at"], "item timestamp"),
        "body": validated,
    }


def validate_social_items(values: Any, origin: str, limit: int) -> list[dict]:
    """Validate an ascending, deduplicated run of one origin peer's items."""

    if not isinstance(values, list) or len(values) > limit:
        raise ProtocolError("social item list is oversized")
    items = [validate_social_item(item, origin) for item in values]
    for earlier, later in zip(items, items[1:]):
        if later["id"] <= earlier["id"]:
            raise ProtocolError("social items are not ordered by ascending id")
    return items


def validate_social_document(value: Any, session: str, peer: str, limit: int) -> dict:
    """Validate one `social_out.json`/`social_in.json` ring for `peer`."""

    if not isinstance(value, Mapping) or set(value) != _DOCUMENT_KEYS \
            or value.get("schemaVersion") != SOCIAL_SCHEMA_VERSION:
        raise ProtocolError("social document header is invalid")
    if value["session"] != session:
        raise ProtocolError("social document names a different session")
    if value["peer"] != peer:
        raise ProtocolError("social document names a different peer")
    return {
        "schemaVersion": SOCIAL_SCHEMA_VERSION,
        "session": session,
        "peer": peer,
        "seq": _count(value["seq"], "document seq"),
        "items": validate_social_items(value["items"], peer, limit),
    }


def social_frame(session: str, peer: str, items: list[Mapping[str, Any]]) -> dict:
    """Build the signed advisory wire frame; it never enters the commit log."""

    return sign({
        "protocol": PROTOCOL_VERSION,
        "session": session,
        "kind": "social",
        "peer": peer,
        "items": [dict(item) for item in items],
    })


def validate_social_frame(message: Any, session: str, local_peer: str) -> dict:
    """Validate a received `social` frame from the other peer of `session`."""

    if not isinstance(message, Mapping) or set(message) != _FRAME_KEYS \
            or message.get("kind") != "social":
        raise ProtocolError("social frame has an unexpected key set")
    validate_envelope(message, session)
    peer = message["peer"]
    if peer not in SOCIAL_PEERS or peer == local_peer:
        raise ProtocolError("social frame names an unusable origin peer")
    items = validate_social_items(message["items"], peer, MAX_FRAME_ITEMS)
    if not items:
        raise ProtocolError("social frame carries no items")
    if len(canonical_json(message).encode("utf-8")) > MAX_FRAME_BYTES:
        raise ProtocolError("social frame exceeds 32 KiB")
    return {"peer": peer, "items": items}


class SocialRelay:
    """One peer's advisory relay between its game bridge files and the socket."""

    def __init__(self, bridge: GameBridge) -> None:
        self.bridge = bridge
        self.outgoing_path = bridge.state_dir / "social_out.json"
        self.incoming_path = bridge.state_dir / "social_in.json"
        self.forwarded_through: dict[str, int] = {}
        self.seen_through: dict[str, int] = {}
        self.forwarded = 0
        self.received = 0
        self.dropped = 0
        self.drop_reasons: dict[str, int] = {}
        self.last_error: str | None = None
        self._items: list[dict[str, Any]] = []
        self._seq = 0
        self._signature: tuple[int, int] | None = None
        self._lock = threading.Lock()

    def status(self) -> dict[str, int]:
        # Small, Lua-readable health for `companion_status.json`.
        return {
            "forwarded": self.forwarded,
            "received": self.received,
            "dropped": self.dropped,
        }

    def _drop(self, reason: str, count: int = 1) -> None:
        with self._lock:
            self.dropped += count
            self.drop_reasons[reason] = self.drop_reasons.get(reason, 0) + count

    def _read_outgoing(self, raw: bytes) -> dict[str, Any] | None:
        try:
            value = json.loads(raw.decode("utf-8-sig"))
        except ValueError as exc:
            self._drop("unreadable-outgoing")
            self.last_error = f"social outbox is not JSON: {exc}"
            return None
        try:
            return validate_social_document(
                value, self.bridge.session, self.bridge.peer, MAX_OUTGOING_ITEMS
            )
        except ProtocolError as exc:
            self._drop("invalid-outgoing")
            self.last_error = str(exc)
            return None

    def pump_outgoing(self, send: Callable[[Mapping[str, Any]], Any]) -> int:
        """Forward this peer's unsent ring as one frame. Never raises on files."""

        # Content, not mtime: a Windows timer tick is coarser than the game's
        # five-hertz publication, and an unchanged ring must not re-forward.
        try:
            size = self.outgoing_path.stat().st_size
            raw = b"" if size > MAX_OUTGOING_BYTES else self.outgoing_path.read_bytes()
        except OSError as exc:
            self.last_error = f"cannot read social outbox: {exc}"
            return 0
        signature = (size, zlib.crc32(raw))
        if signature == self._signature:
            return 0
        if size > MAX_OUTGOING_BYTES:
            self._signature = signature
            self._drop("oversized-outgoing")
            return 0
        document = self._read_outgoing(raw)
        if document is None:
            self._signature = signature
            return 0
        batch = [
            item for item in document["items"]
            if item["id"] > self.forwarded_through.get(item["peer"], 0)
        ][-MAX_FRAME_ITEMS:]
        frame: dict[str, Any] | None = None
        while batch:
            frame = social_frame(self.bridge.session, self.bridge.peer, batch)
            if len(canonical_json(frame).encode("utf-8")) <= MAX_FRAME_BYTES:
                break
            self._drop("outgoing-frame-too-large")
            batch, frame = batch[1:], None
        if frame is None:
            self._signature = signature
            return 0
        send(frame)
        for item in batch:
            self.forwarded_through[item["peer"]] = item["id"]
        self.forwarded += len(batch)
        self.last_error = None
        self._signature = signature
        return len(batch)

    def accept_frame(self, message: Mapping[str, Any]) -> int:
        """Validate one received frame and publish the fresh items. Never raises."""

        try:
            frame = validate_social_frame(
                message, self.bridge.session, self.bridge.peer
            )
        except ProtocolError as exc:
            self._drop("invalid-frame")
            self.last_error = str(exc)
            return 0
        peer = frame["peer"]
        seen = self.seen_through.get(peer, 0)
        fresh = [item for item in frame["items"] if item["id"] > seen]
        if len(fresh) != len(frame["items"]):
            self._drop("duplicate-item", len(frame["items"]) - len(fresh))
        if not fresh:
            return 0
        self.seen_through[peer] = fresh[-1]["id"]
        self._items = (self._items + fresh)[-MAX_INCOMING_ITEMS:]
        self._seq += 1
        document = {
            "schemaVersion": SOCIAL_SCHEMA_VERSION,
            "session": self.bridge.session,
            "peer": peer,
            "seq": self._seq,
            "items": self._items,
        }
        try:
            atomic_write(
                self.incoming_path,
                (canonical_json(document) + "\n").encode("utf-8"),
                durable=False,
            )
        except OSError as exc:
            self._drop("unwritable-incoming", len(fresh))
            self.last_error = f"cannot publish social inbox: {exc}"
            return 0
        self.received += len(fresh)
        self.last_error = None
        return len(fresh)


def social_relay(owner: Any) -> SocialRelay:
    """Lazily attach one relay to a commit host or client.

    The channel is advisory, so it binds here instead of widening the authority
    modules that own ordered commits.
    """
    relay = getattr(owner, "social", None)
    if isinstance(relay, SocialRelay):
        return relay
    with _ATTACH_LOCK:
        relay = getattr(owner, "social", None)
        if not isinstance(relay, SocialRelay):
            relay = SocialRelay(owner.bridge)
            owner.social = relay
        return relay
