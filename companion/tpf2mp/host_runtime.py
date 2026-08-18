from __future__ import annotations

import errno
import socket
import threading
import time
from typing import Any

from .bridge import AuditUnavailable
from .protocol import ProtocolError


def run_host(host: Any, poll_seconds: float = 0.1) -> None:
    """Own the host listener/poll lifecycle while CommitHost owns policy."""

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((host.bind, host.port))
    listener.listen(8)
    listener.settimeout(0.5)
    threading.Thread(
        target=host._accept_loop, args=(listener,), daemon=True
    ).start()
    print(f"TPF2MP host listening on {host.bind}:{host.port}")
    print(
        f"session={host.bridge.session} peer={host.bridge.peer} "
        f"bridge={host.bridge.root}"
    )
    print(f"match fingerprint={host.match_fingerprint or 'UNVERIFIED'}")
    host._write_status("running")
    next_status = next_anchor_poll = next_content_poll = time.monotonic()
    try:
        while not host.stop.is_set():
            if host.audit_failure.is_set():
                raise host.audit_failure_error or AuditUnavailable(
                    errno.EIO,
                    "authority audit is unavailable",
                    str(host.audit.path),
                )
            had_work = False
            for local_seq, message in host.bridge.pending_outbound():
                try:
                    if message.get("kind") == "intent":
                        host._commit(message)
                    else:
                        host._record_non_intent(message)
                except ProtocolError as exc:
                    host.last_error = str(exc)
                    host._reject_intent(message, str(exc))
                    print(f"rejected local game sequence {local_seq}: {exc}")
                host.bridge.acknowledge_outbound(local_seq)
                had_work = True
            now = time.monotonic()
            if now >= next_anchor_poll:
                if host.anchor_requests.process_host(host.anchor):
                    had_work = True
                next_anchor_poll = now + 0.5
            host._expire_proposals()
            if host.anchor_preparation.maintain():
                had_work = True
            if now >= next_content_poll:
                if host.industry_content.refresh():
                    had_work = True
                next_content_poll = now + 1.0
            if now >= next_status:
                host._write_status()
                next_status = now + 1.0
            if not had_work:
                time.sleep(poll_seconds)
    except AuditUnavailable as exc:
        host._enter_audit_fault(exc)
        _fence_failed_authority(host, listener, exc)
    except KeyboardInterrupt:
        pass
    finally:
        host.stop.set()
        listener.close()
        with host.peers_lock:
            for peer in host.peers.values():
                peer.sock.close()
        host._write_status("stopped")


def _fence_failed_authority(
    host: Any, listener: socket.socket, exc: AuditUnavailable
) -> None:
    """Remain observable but accept no traffic after journal durability fails."""

    try:
        listener.close()
    except OSError:
        pass
    with host.peers_lock:
        connected = list(host.peers.values())
        host.peers.clear()
    for peer in connected:
        try:
            peer.sock.close()
        except OSError:
            pass
    host._write_status("faulted")
    print(f"AUTHORITY AUDIT FAULT: {exc}; host remains fail-closed")
    while not host.stop.wait(0.5):
        try:
            host._write_status("faulted")
        except OSError:
            pass
