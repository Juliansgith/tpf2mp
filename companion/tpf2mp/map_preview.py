"""A bounded native map overview. Network peers never supply image codecs/URLs."""
from __future__ import annotations

import base64
import hashlib
import struct
from pathlib import Path

from .bridge import atomic_write
from .relay_api import RelayApiError

WIDTH, HEIGHT = 512, 288
PIXEL_BYTES = WIDTH * HEIGHT * 3


def from_file(path: Path) -> dict:
    with path.open('rb') as source:
        raw = source.read(PIXEL_BYTES + 1)
    if len(raw) != PIXEL_BYTES:
        raise RelayApiError('native map overview has invalid dimensions')
    return {'format': 'bgr24-512x288', 'sha256': hashlib.sha256(raw).hexdigest(),
            'pixels': base64.b64encode(raw).decode('ascii')}


def pixels(value: dict) -> bytes:
    if not isinstance(value, dict) or set(value) != {'format', 'sha256', 'pixels'} \
            or value['format'] != 'bgr24-512x288' or not isinstance(value['pixels'], str) \
            or len(value['pixels']) != PIXEL_BYTES * 4 // 3:
        raise RelayApiError('invalid map preview format or dimensions')
    try:
        raw = base64.b64decode(value['pixels'], validate=True)
    except ValueError:
        raise RelayApiError('invalid map preview pixels') from None
    if len(raw) != PIXEL_BYTES or hashlib.sha256(raw).hexdigest() != value['sha256']:
        raise RelayApiError('map preview checksum mismatch')
    return raw


def write_bitmap(value: dict, output: Path) -> None:
    raw = pixels(value)
    # Fixed uncompressed top-down BGR bitmap; no remote dimensions, palettes,
    # compression, embedded profiles, links, or metadata reach Windows GDI+.
    header = struct.pack('<2sIHHI', b'BM', 54 + len(raw), 0, 0, 54)
    header += struct.pack('<IiiHHIIiiII', 40, WIDTH, -HEIGHT, 1, 24, 0, len(raw), 0, 0, 0, 0)
    atomic_write(output, header + raw, durable=True)
