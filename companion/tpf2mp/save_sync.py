"""Bounded pre-session transfer of a complete Transport Fever 2 save set.

The normal multiplayer handshake includes the starting-save hashes.  A peer
that does not have those bytes cannot reach that handshake, so save transfer
uses a deliberately separate listener (the gameplay port plus one).  The
listener exposes only the host's already-pinned save, and the receiver makes
the native ``.sav`` visible only after its metadata and optional preview have
been received and verified.

This is a transport-neutral pre-session protocol, not an Internet file server.
Direct LAN/VPN mode supplies its private transport; secure-relay mode carries
the same listener byte-for-byte through an authenticated WSS channel. Content
integrity is independently pinned by SHA-256 here and again by the ordinary
match fingerprint.
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import socket
import tempfile
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, BinaryIO, Mapping

from .bridge import atomic_write
from .native_save import sha256_file
from .protocol import ProtocolError, canonical_json, decode_line, encode_line, sign
from .session_identity import validate_session_id


SAVE_SYNC_VERSION = 1
SAVE_SYNC_FORMAT = "tpf2mp-save-sync"
MAX_CONTROL_FRAME_BYTES = 64 * 1024
MAX_SAVE_FILES = 3
MAX_FILE_BYTES = 8 * 1024 * 1024 * 1024
MAX_TOTAL_BYTES = 12 * 1024 * 1024 * 1024
TRANSFER_CHUNK_BYTES = 1024 * 1024
DEFAULT_CONNECT_TIMEOUT_SECONDS = 30.0
DEFAULT_TRANSFER_TIMEOUT_SECONDS = 600.0
_ROLES = ("save", "metadata", "preview")


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_control(reader: BinaryIO) -> dict[str, Any]:
    raw = reader.readline(MAX_CONTROL_FRAME_BYTES + 1)
    if not raw:
        raise ConnectionError("save-sync peer closed the connection")
    if len(raw) > MAX_CONTROL_FRAME_BYTES or not raw.endswith(b"\n"):
        raise ProtocolError("save-sync control frame exceeds 64 KiB")
    return decode_line(raw)


def _send_control(sock: socket.socket, value: Mapping[str, Any]) -> None:
    sock.sendall(encode_line(sign(value)))


def _bundle_id(manifest_without_id: Mapping[str, Any]) -> str:
    payload = canonical_json(manifest_without_id).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _source_files(save_path: Path | str) -> tuple[Path, list[tuple[str, Path]]]:
    save = Path(save_path).expanduser().resolve()
    if save.suffix.lower() != ".sav" or not save.is_file():
        raise ProtocolError(f"save-sync source is missing or is not .sav: {save}")
    metadata = Path(str(save) + ".lua")
    if not metadata.is_file():
        raise ProtocolError(f"save-sync metadata is missing: {metadata}")
    files: list[tuple[str, Path]] = [("save", save), ("metadata", metadata)]
    preview = save.with_suffix(".jpg")
    if preview.is_file():
        files.append(("preview", preview))
    return save, files


def build_save_sync_manifest(
    save_path: Path | str,
    session: str,
) -> tuple[dict[str, Any], list[tuple[str, Path]]]:
    """Hash one stable native save set and return its wire manifest/sources."""

    safe_session = validate_session_id(session, "save-sync session")
    save, sources = _source_files(save_path)
    before = [(path.stat().st_size, path.stat().st_mtime_ns) for _, path in sources]
    files: list[dict[str, Any]] = []
    total = 0
    for role, path in sources:
        size = path.stat().st_size
        if size < 0 or size > MAX_FILE_BYTES:
            raise ProtocolError(f"save-sync {role} file exceeds the 8 GiB limit")
        total += size
        if total > MAX_TOTAL_BYTES:
            raise ProtocolError("save-sync bundle exceeds the 12 GiB limit")
        files.append({"role": role, "bytes": size, "sha256": sha256_file(path)})
    after = [(path.stat().st_size, path.stat().st_mtime_ns) for _, path in sources]
    if before != after:
        raise ProtocolError("native save changed while its save-sync manifest was built")
    core: dict[str, Any] = {
        "format": SAVE_SYNC_FORMAT,
        "version": SAVE_SYNC_VERSION,
        "session": safe_session,
        "sourceBaseName": save.stem[:128],
        "files": files,
        "totalBytes": total,
    }
    return {**core, "bundleId": _bundle_id(core)}, sources


def validate_save_sync_manifest(
    value: Mapping[str, Any],
    expected_session: str,
) -> dict[str, Any]:
    safe_session = validate_session_id(expected_session, "save-sync session")
    if not isinstance(value, Mapping):
        raise ProtocolError("save-sync manifest is not an object")
    manifest = dict(value)
    if manifest.get("format") != SAVE_SYNC_FORMAT or manifest.get("version") != SAVE_SYNC_VERSION:
        raise ProtocolError("unsupported save-sync manifest")
    if manifest.get("session") != safe_session:
        raise ProtocolError("save-sync manifest names a different session")
    bundle_id = manifest.get("bundleId")
    if not isinstance(bundle_id, str) or not re.fullmatch(r"[0-9a-f]{64}", bundle_id):
        raise ProtocolError("save-sync manifest has an invalid bundle id")
    core = dict(manifest)
    core.pop("bundleId", None)
    if _bundle_id(core) != bundle_id:
        raise ProtocolError("save-sync manifest bundle id does not match its content")
    source_name = manifest.get("sourceBaseName")
    if not isinstance(source_name, str) or not source_name or len(source_name) > 128 \
            or any(character in source_name for character in "\r\n\0"):
        raise ProtocolError("save-sync manifest has an invalid source name")
    files = manifest.get("files")
    if not isinstance(files, list) or not 2 <= len(files) <= MAX_SAVE_FILES:
        raise ProtocolError("save-sync manifest has an invalid file list")
    roles: list[str] = []
    total = 0
    for item in files:
        if not isinstance(item, Mapping):
            raise ProtocolError("save-sync file entry is not an object")
        role = item.get("role")
        size = item.get("bytes")
        digest = item.get("sha256")
        if role not in _ROLES or role in roles:
            raise ProtocolError("save-sync file roles are invalid or duplicated")
        if not isinstance(size, int) or isinstance(size, bool) or not 0 <= size <= MAX_FILE_BYTES:
            raise ProtocolError("save-sync file size is invalid")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ProtocolError("save-sync file hash is invalid")
        roles.append(str(role))
        total += size
    if roles[:2] != ["save", "metadata"] or roles[2:] not in ([], ["preview"]):
        raise ProtocolError("save-sync file order must be save, metadata, optional preview")
    if total > MAX_TOTAL_BYTES or manifest.get("totalBytes") != total:
        raise ProtocolError("save-sync total byte count is invalid")
    return manifest


def _write_status(path: Path | None, value: Mapping[str, Any]) -> None:
    if path is None:
        return
    atomic_write(path, (canonical_json(value) + "\n").encode("utf-8"), durable=False)


class SaveSyncServer:
    """Small bounded listener that serves only one precomputed save manifest."""

    def __init__(
        self,
        save_path: Path | str,
        session: str,
        bind: str = "127.0.0.1",
        port: int = 29743,
        *,
        status_path: Path | str | None = None,
        max_downloads: int = 8,
        transfer_timeout: float = DEFAULT_TRANSFER_TIMEOUT_SECONDS,
    ) -> None:
        if not isinstance(port, int) or isinstance(port, bool) or not 0 <= port <= 65535:
            raise ProtocolError("save-sync port must be between 0 and 65535")
        if not isinstance(max_downloads, int) or not 1 <= max_downloads <= 64:
            raise ProtocolError("save-sync max downloads must be between 1 and 64")
        self.session = validate_session_id(session, "save-sync session")
        self.bind = bind
        self.requested_port = port
        self.port = port
        self.status_path = Path(status_path).expanduser().resolve() if status_path else None
        self.max_downloads = max_downloads
        self.transfer_timeout = max(1.0, float(transfer_timeout))
        self.manifest, self.sources = build_save_sync_manifest(save_path, self.session)
        self.listener: socket.socket | None = None
        self.thread: threading.Thread | None = None
        self.stop_event = threading.Event()
        self.state_lock = threading.Lock()
        self.active_lock = threading.BoundedSemaphore(2)
        self.successful_downloads = 0
        self.started_downloads = 0
        self.rejected_requests = 0
        self.last_client: str | None = None
        self.last_error: str | None = None
        self.listening = False

    def _status(self) -> dict[str, Any]:
        return {
            "schemaVersion": 1,
            "pid": os.getpid(),
            "session": self.session,
            "listening": self.listening,
            "bind": self.bind,
            "port": self.port,
            "bundleId": self.manifest["bundleId"],
            "totalBytes": self.manifest["totalBytes"],
            "successfulDownloads": self.successful_downloads,
            "startedDownloads": self.started_downloads,
            "rejectedRequests": self.rejected_requests,
            "lastClient": self.last_client,
            "lastError": self.last_error,
            "updatedAtUtc": _utc_now(),
        }

    def _publish_status(self) -> None:
        with self.state_lock:
            value = self._status()
        _write_status(self.status_path, value)

    def start(self) -> "SaveSyncServer":
        if self.listener is not None:
            raise RuntimeError("save-sync server is already started")
        candidates = socket.getaddrinfo(
            self.bind, self.requested_port, type=socket.SOCK_STREAM,
            flags=socket.AI_PASSIVE,
        )
        last_error: OSError | None = None
        for family, socktype, proto, _, address in candidates:
            listener = socket.socket(family, socktype, proto)
            try:
                if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                else:
                    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                listener.bind(address)
                listener.listen(4)
                listener.settimeout(0.5)
                self.listener = listener
                self.port = int(listener.getsockname()[1])
                break
            except OSError as exc:
                last_error = exc
                listener.close()
        if self.listener is None:
            raise ProtocolError(f"save-sync listener could not bind: {last_error}")
        with self.state_lock:
            self.listening = True
        self._publish_status()
        self.thread = threading.Thread(
            target=self._accept_loop,
            name=f"tpf2mp-save-sync-{self.session}",
            daemon=True,
        )
        self.thread.start()
        return self

    def _record_failure(self, address: object, error: Exception) -> None:
        with self.state_lock:
            self.rejected_requests += 1
            self.last_client = str(address)
            self.last_error = str(error)[:500]
        self._publish_status()

    def _handle(self, conn: socket.socket, address: object) -> None:
        acquired = self.active_lock.acquire(blocking=False)
        if not acquired:
            try:
                _send_control(conn, {
                    "kind": "save_sync_error", "version": SAVE_SYNC_VERSION,
                    "session": self.session, "error": "save-sync server is busy",
                })
            finally:
                conn.close()
            return
        try:
            conn.settimeout(self.transfer_timeout)
            reader = conn.makefile("rb")
            try:
                request = _read_control(reader)
                if request.get("kind") != "save_sync_request" \
                        or request.get("version") != SAVE_SYNC_VERSION:
                    raise ProtocolError("invalid save-sync request")
                if request.get("session") != self.session or request.get("peer") != "player2":
                    raise ProtocolError("save-sync request identity does not match this host")
                with self.state_lock:
                    if self.started_downloads >= self.max_downloads:
                        raise ProtocolError("save-sync download limit has been reached")
                    # Reserve before streaming so concurrent clients cannot
                    # both pass the cap. Failed attempts remain counted,
                    # bounding abuse as well as successful re-downloads.
                    self.started_downloads += 1
                    self.last_client = str(address)
                    self.last_error = None
                _send_control(conn, {
                    "kind": "save_sync_manifest", "version": SAVE_SYNC_VERSION,
                    "session": self.session, "manifest": self.manifest,
                })
                for entry, (_, source) in zip(self.manifest["files"], self.sources):
                    sent_hash = hashlib.sha256()
                    sent_bytes = 0
                    with source.open("rb") as handle:
                        while True:
                            chunk = handle.read(TRANSFER_CHUNK_BYTES)
                            if not chunk:
                                break
                            conn.sendall(chunk)
                            sent_hash.update(chunk)
                            sent_bytes += len(chunk)
                    if sent_bytes != entry["bytes"] or sent_hash.hexdigest() != entry["sha256"]:
                        raise ProtocolError("host save changed during transfer")
                _send_control(conn, {
                    "kind": "save_sync_end", "version": SAVE_SYNC_VERSION,
                    "session": self.session, "bundleId": self.manifest["bundleId"],
                })
                receipt = _read_control(reader)
                if receipt.get("kind") != "save_sync_receipt" \
                        or receipt.get("session") != self.session \
                        or receipt.get("bundleId") != self.manifest["bundleId"] \
                        or receipt.get("success") is not True:
                    raise ProtocolError("peer did not acknowledge the verified save")
                with self.state_lock:
                    self.successful_downloads += 1
                    self.last_client = str(address)
                    self.last_error = None
                self._publish_status()
            finally:
                reader.close()
        except (ConnectionError, OSError, ProtocolError) as exc:
            try:
                _send_control(conn, {
                    "kind": "save_sync_error", "version": SAVE_SYNC_VERSION,
                    "session": self.session, "error": str(exc)[:500],
                })
            except OSError:
                pass
            self._record_failure(address, exc)
        finally:
            conn.close()
            self.active_lock.release()

    def _accept_loop(self) -> None:
        assert self.listener is not None
        while not self.stop_event.is_set():
            try:
                conn, address = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if not self.stop_event.is_set():
                    with self.state_lock:
                        self.last_error = "save-sync listener stopped unexpectedly"
                break
            threading.Thread(
                target=self._handle,
                args=(conn, address),
                name=f"tpf2mp-save-sync-peer-{self.session}",
                daemon=True,
            ).start()
        with self.state_lock:
            self.listening = False
        self._publish_status()

    def close(self) -> None:
        self.stop_event.set()
        with self.state_lock:
            self.listening = False
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        if self.thread is not None and self.thread is not threading.current_thread():
            self.thread.join(timeout=2.0)
        self._publish_status()

    def __enter__(self) -> "SaveSyncServer":
        return self.start()

    def __exit__(self, *_: object) -> None:
        self.close()


def _receive_exact(reader: BinaryIO, destination: Path, size: int, expected_hash: str) -> None:
    remaining = size
    digest = hashlib.sha256()
    with destination.open("xb") as handle:
        while remaining:
            chunk = reader.read(min(TRANSFER_CHUNK_BYTES, remaining))
            if not chunk:
                raise ConnectionError("save-sync transfer ended before all bytes arrived")
            handle.write(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
        handle.flush()
        os.fsync(handle.fileno())
    if digest.hexdigest() != expected_hash:
        raise ProtocolError("save-sync received file hash mismatch")


def _safe_destination_base(session: str, bundle_id: str, suffix: int = 1) -> str:
    compact_session = re.sub(r"[^A-Za-z0-9._-]+", "-", session).strip(".-_")[:20]
    base = f"tpf2mp_{compact_session}_{bundle_id[:10]}"
    return base if suffix == 1 else f"{base}-{suffix}"


def _destination_paths(root: Path, base: str, has_preview: bool) -> dict[str, Path]:
    save = root / f"{base}.sav"
    result = {"save": save, "metadata": Path(str(save) + ".lua")}
    if has_preview:
        result["preview"] = root / f"{base}.jpg"
    return result


def _matches_existing(paths: Mapping[str, Path], files: list[Mapping[str, Any]]) -> bool:
    expected = {str(item["role"]): item for item in files}
    if set(paths) != set(expected):
        return False
    return all(
        path.is_file()
        and path.stat().st_size == int(expected[role]["bytes"])
        and sha256_file(path) == expected[role]["sha256"]
        for role, path in paths.items()
    )


def _install_received(
    stage_files: Mapping[str, Path],
    destination: Path,
    manifest: Mapping[str, Any],
) -> tuple[dict[str, Path], bool]:
    files = list(manifest["files"])
    has_preview = any(item["role"] == "preview" for item in files)
    selected: dict[str, Path] | None = None
    for suffix in range(1, 101):
        candidate = _destination_paths(
            destination,
            _safe_destination_base(str(manifest["session"]), str(manifest["bundleId"]), suffix),
            has_preview,
        )
        if _matches_existing(candidate, files):
            return candidate, True
        if all(not path.exists() for path in candidate.values()):
            selected = candidate
            break
    if selected is None:
        raise ProtocolError("could not allocate a collision-free synchronized save name")

    # Metadata and preview become visible first.  The game only recognizes the
    # bundle after the .sav is renamed last, preventing a partial loadable save.
    created: list[Path] = []
    try:
        for role in ("metadata", "preview", "save"):
            if role not in stage_files:
                continue
            source = stage_files[role]
            target = selected[role]
            if target.exists():
                raise ProtocolError(f"synchronized save destination appeared concurrently: {target}")
            source.rename(target)
            created.append(target)
        if not _matches_existing(selected, files):
            raise ProtocolError("installed synchronized save failed final verification")
        return selected, False
    except Exception:
        for path in reversed(created):
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
        raise


def receive_save(
    host: str,
    port: int,
    session: str,
    destination_directory: Path | str,
    *,
    connect_timeout: float = DEFAULT_CONNECT_TIMEOUT_SECONDS,
    transfer_timeout: float = DEFAULT_TRANSFER_TIMEOUT_SECONDS,
    receipt_path: Path | str | None = None,
) -> dict[str, Any]:
    """Receive, verify, and transactionally install the host's pinned save."""

    safe_session = validate_session_id(session, "save-sync session")
    if not host or len(host) > 253 or any(character in host for character in "\r\n\0"):
        raise ProtocolError("save-sync host address is invalid")
    if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
        raise ProtocolError("save-sync port must be between 1 and 65535")
    destination = Path(destination_directory).expanduser().resolve()
    if not destination.is_dir():
        raise ProtocolError(f"save-sync destination directory is missing: {destination}")

    deadline = time.monotonic() + max(0.1, float(connect_timeout))
    sock: socket.socket | None = None
    last_error: OSError | None = None
    while time.monotonic() < deadline:
        try:
            sock = socket.create_connection(
                (host, port), timeout=min(2.0, max(0.1, deadline - time.monotonic())),
            )
            break
        except OSError as exc:
            last_error = exc
            time.sleep(min(0.25, max(0.0, deadline - time.monotonic())))
    if sock is None:
        raise ProtocolError(f"could not connect to host save sync at {host}:{port}: {last_error}")

    stage = Path(tempfile.mkdtemp(prefix=".tpf2mp-save-sync-", dir=destination))
    installed: dict[str, Path] | None = None
    manifest: dict[str, Any] | None = None
    reused = False
    try:
        sock.settimeout(max(1.0, float(transfer_timeout)))
        _send_control(sock, {
            "kind": "save_sync_request", "version": SAVE_SYNC_VERSION,
            "session": safe_session, "peer": "player2",
        })
        reader = sock.makefile("rb")
        try:
            response = _read_control(reader)
            if response.get("kind") == "save_sync_error":
                raise ProtocolError(str(response.get("error") or "host rejected save sync"))
            if response.get("kind") != "save_sync_manifest" \
                    or response.get("version") != SAVE_SYNC_VERSION \
                    or response.get("session") != safe_session:
                raise ProtocolError("host returned an invalid save-sync response")
            payload = response.get("manifest")
            if not isinstance(payload, Mapping):
                raise ProtocolError("host save-sync response omitted its manifest")
            manifest = validate_save_sync_manifest(payload, safe_session)
            stage_files: dict[str, Path] = {}
            for item in manifest["files"]:
                role = str(item["role"])
                target = stage / f"{role}.part"
                _receive_exact(reader, target, int(item["bytes"]), str(item["sha256"]))
                stage_files[role] = target
            ending = _read_control(reader)
            if ending.get("kind") != "save_sync_end" \
                    or ending.get("session") != safe_session \
                    or ending.get("bundleId") != manifest["bundleId"]:
                raise ProtocolError("host did not complete the advertised save-sync bundle")
            installed, reused = _install_received(stage_files, destination, manifest)
            _send_control(sock, {
                "kind": "save_sync_receipt", "version": SAVE_SYNC_VERSION,
                "session": safe_session, "bundleId": manifest["bundleId"],
                "success": True,
            })
        finally:
            reader.close()

        assert installed is not None and manifest is not None
        receipt: dict[str, Any] = {
            "schemaVersion": 1,
            "session": safe_session,
            "host": host,
            "port": port,
            "bundleId": manifest["bundleId"],
            "savePath": str(installed["save"]),
            "metadataPath": str(installed["metadata"]),
            "previewPath": str(installed["preview"]) if "preview" in installed else None,
            "totalBytes": manifest["totalBytes"],
            "files": manifest["files"],
            "reused": reused,
            "receivedAtUtc": _utc_now(),
        }
        if receipt_path is not None:
            resolved_receipt = Path(receipt_path).expanduser().resolve()
            atomic_write(
                resolved_receipt,
                (canonical_json(receipt) + "\n").encode("utf-8"),
            )
        return receipt
    finally:
        try:
            sock.close()
        except OSError:
            pass
        shutil.rmtree(stage, ignore_errors=True)
