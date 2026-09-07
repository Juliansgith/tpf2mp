from __future__ import annotations

import select
import socket
import threading
import time
from dataclasses import dataclass
from typing import Any, BinaryIO, Mapping

from .protocol import ProtocolError, decode_line, encode_line

MAX_FRAME_BYTES = 4 * 1024 * 1024
SEND_TIMEOUT_SECONDS = 5.0


class SocketReader:
    """Bounded line buffering on a socket shared with a deadline-aware writer."""

    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        self.sock.setblocking(False)
        self.buffer = bytearray()

    def readline(self, limit: int) -> bytes:
        while True:
            newline = self.buffer.find(b"\n", 0, limit)
            if newline >= 0 or len(self.buffer) >= limit:
                end = newline + 1 if newline >= 0 else limit
                result = bytes(self.buffer[:end])
                del self.buffer[:end]
                return result
            try:
                chunk = self.sock.recv(min(65536, limit - len(self.buffer)))
            except BlockingIOError:
                try:
                    # Winsock may not wake select immediately on a concurrent
                    # shutdown. Poll so recv observes the closed read side.
                    select.select([self.sock], [], [], 0.1)
                except ValueError as exc:
                    raise ConnectionError("peer socket closed during read") from exc
                continue
            if not chunk:
                result = bytes(self.buffer)
                self.buffer.clear()
                return result
            self.buffer.extend(chunk)

    def close(self) -> None:
        shutdown_connection(self.sock)
        self.sock.close()


def read_frame(reader: BinaryIO | SocketReader) -> dict[str, Any]:
    raw = reader.readline(MAX_FRAME_BYTES + 1)
    if not raw:
        raise ConnectionError("peer closed the connection")
    if len(raw) > MAX_FRAME_BYTES:
        raise ProtocolError("frame exceeds 4 MiB")
    return decode_line(raw)


def shutdown_connection(sock: socket.socket) -> None:
    # Wake a receiver waiting for readability when a sender abandons a stream.
    try:
        sock.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass


def send(
    sock: socket.socket,
    message: Mapping[str, Any],
    lock: threading.Lock | None = None,
) -> None:
    payload = encode_line(message)
    deadline = time.monotonic() + SEND_TIMEOUT_SECONDS
    if lock is not None and not lock.acquire(timeout=SEND_TIMEOUT_SECONDS):
        shutdown_connection(sock)
        raise TimeoutError("peer send lock deadline exceeded")

    try:
        # Both session readers use SocketReader, never socket.makefile():
        # nonblocking writes must not poison or truncate a buffered read.
        sock.setblocking(False)
        remaining = memoryview(payload)
        while remaining:
            seconds = deadline - time.monotonic()
            if seconds <= 0:
                raise TimeoutError("peer send deadline exceeded")
            try:
                written = sock.send(remaining)
            except BlockingIOError:
                try:
                    select.select([], [sock], [], seconds)
                except ValueError as exc:
                    raise ConnectionError("peer socket closed during send") from exc
                continue
            if written == 0:
                raise ConnectionError("peer closed the connection during send")
            remaining = remaining[written:]
    except OSError:
        # A partial frame is never retried on the same stream. Reconnect will
        # replay durable messages using the existing sequence/receipt protocol.
        shutdown_connection(sock)
        raise
    finally:
        if lock is not None:
            lock.release()


@dataclass
class ConnectedPeer:
    peer: str
    sock: socket.socket
    send_lock: threading.Lock
