from __future__ import annotations

import socket
import threading
from dataclasses import dataclass
from typing import Any, BinaryIO, Mapping

from .protocol import ProtocolError, decode_line, encode_line

MAX_FRAME_BYTES = 4 * 1024 * 1024

def read_frame(reader: BinaryIO) -> dict[str, Any]:
    raw = reader.readline()
    if not raw:
        raise ConnectionError("peer closed the connection")
    if len(raw) > MAX_FRAME_BYTES:
        raise ProtocolError("frame exceeds 4 MiB")
    return decode_line(raw)

def send(
    sock: socket.socket,
    message: Mapping[str, Any],
    lock: threading.Lock | None = None,
) -> None:
    payload = encode_line(message)
    if lock is None:
        sock.sendall(payload)
    else:
        with lock:
            sock.sendall(payload)

@dataclass
class ConnectedPeer:
    peer: str
    sock: socket.socket
    send_lock: threading.Lock

