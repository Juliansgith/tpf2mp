from __future__ import annotations

import json
import os
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect

from . import __version__
from .bridge import atomic_write
from .relay_api import RelayApiError, RelayCredentials, websocket_url


MAX_GAMEPLAY_FRAME_BYTES = 4 * 1024 * 1024
TUNNEL_CHUNK_BYTES = 64 * 1024


@dataclass(frozen=True)
class LocalEndpoint:
    mode: str
    host: str
    port: int

    def validate(self) -> "LocalEndpoint":
        if self.mode not in {"connect", "listen"}:
            raise RelayApiError("local relay endpoint mode is invalid")
        if self.host not in {"127.0.0.1", "::1", "localhost"}:
            raise RelayApiError("relay tunnels may target or expose loopback only")
        if not isinstance(self.port, int) or isinstance(self.port, bool) \
                or not 1 <= self.port <= 65535:
            raise RelayApiError("local relay endpoint port is invalid")
        return self


class TunnelStatus:
    def __init__(
        self,
        path: Path | str | None,
        credentials: RelayCredentials,
        endpoints: dict[str, LocalEndpoint],
    ) -> None:
        self.path = Path(path).expanduser().resolve() if path else None
        self.credentials = credentials
        self.endpoints = endpoints
        self.lock = threading.Lock()
        self.channels: dict[str, dict[str, Any]] = {
            channel: {
                "state": "starting",
                "paired": False,
                "connections": 0,
                "bytesSent": 0,
                "bytesReceived": 0,
                "lastError": None,
            } for channel in endpoints
        }
        self.started_at = int(time.time())

    def update(self, channel: str, **fields: Any) -> None:
        with self.lock:
            self.channels[channel].update(fields)
            self._write()

    def add_bytes(self, channel: str, sent: int = 0, received: int = 0) -> None:
        with self.lock:
            value = self.channels[channel]
            value["bytesSent"] += sent
            value["bytesReceived"] += received

    def publish(self) -> None:
        with self.lock:
            self._write()

    def _write(self) -> None:
        if self.path is None:
            return
        value = {
            "schemaVersion": 1,
            "pid": os.getpid(),
            "relayUrl": self.credentials.relay_url,
            "sessionId": self.credentials.session_id,
            "supportId": self.credentials.session_id,
            "role": self.credentials.role,
            "startedAtUnix": self.started_at,
            "updatedAtUnix": int(time.time()),
            "channels": self.channels,
        }
        atomic_write(
            self.path,
            (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
            durable=False,
        )


class RelayTunnel:
    def __init__(
        self,
        credentials: RelayCredentials,
        endpoints: dict[str, LocalEndpoint],
        *,
        match_fingerprint: str = "",
        match_manifest_path: Path | str | None = None,
        status_path: Path | str | None = None,
    ) -> None:
        if set(endpoints) - {"gameplay", "save"} or not endpoints:
            raise RelayApiError("relay tunnel channel set is invalid")
        expected_mode = "connect" if credentials.role == "host" else "listen"
        for endpoint in endpoints.values():
            endpoint.validate()
            if endpoint.mode != expected_mode:
                raise RelayApiError(
                    f"{credentials.role} relay channels must use {expected_mode} endpoints"
                )
        if match_fingerprint and not (
            len(match_fingerprint) == 64
            and all(character in "0123456789abcdef" for character in match_fingerprint)
        ):
            raise RelayApiError("relay match fingerprint is malformed")
        self.credentials = credentials
        self.endpoints = endpoints
        self.match_fingerprint = match_fingerprint
        self.match_manifest_path = (
            Path(match_manifest_path).expanduser().resolve()
            if match_manifest_path else None
        )
        self.stop = threading.Event()
        self.status = TunnelStatus(status_path, credentials, endpoints)
        self.listeners: dict[str, socket.socket] = {}
        self.threads: list[threading.Thread] = []

    def run(self) -> None:
        self.status.publish()
        try:
            for channel, endpoint in self.endpoints.items():
                if endpoint.mode == "listen":
                    self.listeners[channel] = self._listener(endpoint)
                    self.status.update(
                        channel,
                        state="listening-local",
                        localAddress=f"{endpoint.host}:{endpoint.port}",
                    )
                thread = threading.Thread(
                    target=self._channel_loop,
                    args=(channel, endpoint),
                    name=f"tpf2mp-relay-{channel}",
                    daemon=True,
                )
                self.threads.append(thread)
                thread.start()
            while not self.stop.wait(0.5):
                if not any(thread.is_alive() for thread in self.threads):
                    raise RelayApiError("every relay tunnel channel stopped")
                self.status.publish()
        except KeyboardInterrupt:
            pass
        finally:
            self.close()

    def close(self) -> None:
        self.stop.set()
        for listener in self.listeners.values():
            try:
                listener.close()
            except OSError:
                pass
        for thread in self.threads:
            if thread is not threading.current_thread():
                thread.join(timeout=2.0)
        for channel in self.endpoints:
            self.status.update(channel, state="stopped", paired=False)

    def _listener(self, endpoint: LocalEndpoint) -> socket.socket:
        listener = socket.socket(socket.AF_INET6 if endpoint.host == "::1" else socket.AF_INET)
        if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        else:
            listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((endpoint.host, endpoint.port))
        listener.listen(4)
        listener.settimeout(0.5)
        return listener

    def _channel_loop(self, channel: str, endpoint: LocalEndpoint) -> None:
        attempts = 0
        while not self.stop.is_set():
            local: socket.socket | None = None
            websocket: Any = None
            try:
                if endpoint.mode == "listen":
                    self.status.update(channel, state="listening-local", paired=False)
                    local = self._accept(channel)
                    if local is None:
                        continue
                self.status.update(channel, state="connecting-relay", paired=False)
                websocket = self._connect_websocket(channel)
                self.status.update(channel, state="waiting-peer", paired=False, lastError=None)
                self._expect_paired(websocket, channel)
                if endpoint.mode == "connect":
                    local = self._connect_local(endpoint, channel)
                assert local is not None
                local.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                local.settimeout(None)
                attempts = 0
                current = self.status.channels[channel]["connections"] + 1
                self.status.update(
                    channel,
                    state="paired",
                    paired=True,
                    connections=current,
                    lastError=None,
                )
                self._bridge(channel, local, websocket)
            except (OSError, ConnectionError, ConnectionClosed, RelayApiError, TimeoutError) as exc:
                attempts += 1
                self.status.update(
                    channel,
                    state="retrying",
                    paired=False,
                    lastError=str(exc)[:500],
                    retryAttempt=attempts,
                )
            finally:
                if local is not None:
                    try:
                        local.close()
                    except OSError:
                        pass
                if websocket is not None:
                    try:
                        websocket.close()
                    except Exception:
                        pass
            self.stop.wait(min(10.0, 0.5 * (2 ** min(attempts, 5))))

    def _accept(self, channel: str) -> socket.socket | None:
        listener = self.listeners[channel]
        while not self.stop.is_set():
            try:
                connection, _ = listener.accept()
                return connection
            except socket.timeout:
                continue
            except OSError:
                if self.stop.is_set():
                    return None
                raise
        return None

    def _connect_local(
        self, endpoint: LocalEndpoint, channel: str
    ) -> socket.socket:
        deadline = time.monotonic() + 30.0
        last_error: OSError | None = None
        while not self.stop.is_set() and time.monotonic() < deadline:
            try:
                return socket.create_connection((endpoint.host, endpoint.port), timeout=2.0)
            except OSError as exc:
                last_error = exc
                self.status.update(channel, state="waiting-local-service", paired=True)
                self.stop.wait(0.25)
        raise ConnectionError(f"local {channel} service was unavailable: {last_error}")

    def _connect_websocket(self, channel: str) -> Any:
        headers = {
            "Authorization": "Bearer " + self.credentials.token,
            "X-TPF2MP-Role": self.credentials.role,
            "X-TPF2MP-Client-Version": __version__,
        }
        fingerprint = self._current_fingerprint()
        if fingerprint:
            headers["X-TPF2MP-Match-Fingerprint"] = fingerprint
        return connect(
            websocket_url(
                self.credentials.relay_url, self.credentials.session_id, channel
            ),
            additional_headers=headers,
            compression=None,
            user_agent_header=f"TPF2MP/{__version__}",
            open_timeout=15.0,
            ping_interval=20.0,
            ping_timeout=20.0,
            close_timeout=3.0,
            max_size=MAX_GAMEPLAY_FRAME_BYTES,
            max_queue=8,
        )

    def _current_fingerprint(self) -> str:
        fingerprint = self.match_fingerprint
        if self.match_manifest_path and self.match_manifest_path.is_file():
            try:
                value = json.loads(
                    self.match_manifest_path.read_text(encoding="utf-8-sig")
                )
                candidate = value.get("fingerprint") if isinstance(value, dict) else None
                if isinstance(candidate, str):
                    fingerprint = candidate
            except (OSError, UnicodeError, json.JSONDecodeError):
                pass
        if fingerprint and not (
            len(fingerprint) == 64
            and all(character in "0123456789abcdef" for character in fingerprint)
        ):
            raise RelayApiError("relay match fingerprint is malformed")
        return fingerprint

    def _expect_paired(self, websocket: Any, channel: str) -> None:
        value = websocket.recv(timeout=200.0)
        if not isinstance(value, str):
            raise RelayApiError("relay sent binary data before pairing")
        try:
            message = json.loads(value)
        except json.JSONDecodeError as exc:
            raise RelayApiError("relay pairing message is invalid") from exc
        if message != {
            "channel": channel,
            "schemaVersion": 1,
            "sessionId": self.credentials.session_id,
            "type": "paired",
        }:
            raise RelayApiError("relay paired this tunnel with unexpected metadata")

    def _bridge(self, channel: str, local: socket.socket, websocket: Any) -> None:
        finished = threading.Event()
        errors: list[BaseException] = []

        def local_to_relay() -> None:
            try:
                if channel == "gameplay":
                    reader = local.makefile("rb")
                    try:
                        while not finished.is_set():
                            frame = reader.readline(MAX_GAMEPLAY_FRAME_BYTES + 1)
                            if not frame:
                                return
                            if len(frame) > MAX_GAMEPLAY_FRAME_BYTES or not frame.endswith(b"\n"):
                                raise RelayApiError("local gameplay frame exceeds 4 MiB")
                            websocket.send(frame)
                            self.status.add_bytes(channel, sent=len(frame))
                    finally:
                        reader.close()
                else:
                    while not finished.is_set():
                        chunk = local.recv(TUNNEL_CHUNK_BYTES)
                        if not chunk:
                            return
                        websocket.send(chunk)
                        self.status.add_bytes(channel, sent=len(chunk))
            except BaseException as exc:
                if not finished.is_set():
                    errors.append(exc)
            finally:
                finished.set()

        def relay_to_local() -> None:
            try:
                while not finished.is_set():
                    data = websocket.recv()
                    if not isinstance(data, bytes):
                        raise RelayApiError("relay sent an unexpected text message")
                    local.sendall(data)
                    self.status.add_bytes(channel, received=len(data))
            except BaseException as exc:
                if not finished.is_set():
                    errors.append(exc)
            finally:
                finished.set()

        threads = [
            threading.Thread(target=local_to_relay, name=f"relay-{channel}-upload", daemon=True),
            threading.Thread(target=relay_to_local, name=f"relay-{channel}-download", daemon=True),
        ]
        for thread in threads:
            thread.start()
        finished.wait()
        try:
            local.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            websocket.close()
        except Exception:
            pass
        for thread in threads:
            thread.join(timeout=2.0)
        self.status.update(channel, state="disconnected", paired=False)
        if errors:
            first = errors[0]
            if isinstance(first, (OSError, ConnectionError, ConnectionClosed, RelayApiError)):
                raise first
            raise ConnectionError(str(first)) from first
