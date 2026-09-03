from __future__ import annotations

import socket
import threading
import time
from typing import Any

from .anchor_io import validate_anchor_state
from .active_content import describe_content_mismatch
from .protocol import ProtocolError, hello, validate_envelope
from .transport import read_frame, send


def run_client_session(client: Any, poll_seconds: float) -> None:
    """Connect, catch up, and pump one client socket until it is replaced."""

    sock = socket.create_connection((client.host, client.port), timeout=5)
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    reader = sock.makefile("rb")
    send_lock = threading.Lock()
    try:
        send(sock, hello(
            client.bridge.session, client.bridge.peer, client._last_commit(),
            client.match_fingerprint,
            client.match_content_inventory,
        ), send_lock)
        acknowledgement = read_frame(reader)
        validate_envelope(acknowledgement, client.bridge.session)
        if acknowledgement.get("kind") == "hello_reject":
            reason = acknowledgement.get("reason")
            raise ProtocolError(
                str(reason) if isinstance(reason, str) and reason
                else "host rejected the multiplayer compatibility check"
            )
        if acknowledgement.get("kind") != "hello_ack":
            raise ProtocolError("host did not acknowledge handshake")
        host_content = acknowledgement.get("active_content")
        if client.match_content_inventory is not None:
            if host_content is None:
                raise ProtocolError(
                    "host did not provide its active mod/DLC inventory"
                )
            detail = describe_content_mismatch(
                host_content, client.match_content_inventory
            )
            if detail:
                raise ProtocolError("active mod/DLC compatibility check failed: " + detail)
        if client.match_fingerprint \
                and acknowledgement.get("match_fingerprint") != client.match_fingerprint:
            raise ProtocolError("host acknowledged a different match fingerprint")
    except BaseException:
        reader.close()
        sock.close()
        raise
    client.socket_connected = True
    client.connected = False
    client.synchronized = False
    client.status = "synchronizing"
    client.last_error = None
    client.next_host_seq = int(acknowledgement.get("next_seq", 0))
    client._write_status()
    print(
        f"connected socket to {client.host}:{client.port}; synchronizing from host "
        f"sequence {acknowledgement.get('replay_from_seq', acknowledgement.get('next_seq'))}"
    )
    receiver_error: list[BaseException] = []
    sent_pending: set[int] = set()

    def receive() -> None:
        try:
            while not client.stop.is_set():
                message = read_frame(reader)
                validate_envelope(message, client.bridge.session)
                kind = message.get("kind")
                if kind in {"commit", "control"}:
                    client.bridge.write_inbound(message)
                elif kind == "anchor_state":
                    client.anchor_state = validate_anchor_state(message)
                elif kind == "restore_plan":
                    client.restore_plan_exchange.accept(message)
                elif kind == "sync_ready":
                    _accept_sync_ready(client, message)
                elif kind == "receipt":
                    _accept_receipt(client, message)
        except BaseException as exc:  # surfaced in the owning reconnect loop
            receiver_error.append(exc)

    receiver = threading.Thread(target=receive, daemon=True)
    receiver.start()
    try:
        next_status = next_anchor_poll = next_content_poll = time.monotonic()
        synchronize_deadline = time.monotonic() + 120.0
        while not client.stop.is_set() and not receiver_error:
            had_work = False
            if client.synchronized:
                for local_seq, message in client.bridge.pending_outbound():
                    if local_seq not in sent_pending:
                        send(sock, message, send_lock)
                        sent_pending.add(local_seq)
                        had_work = True
                now = time.monotonic()
                if now >= next_anchor_poll:
                    for message in client.anchor_requests.client_intents(client.anchor_state):
                        local_seq = int(message["local_seq"])
                        if local_seq not in sent_pending:
                            send(sock, message, send_lock)
                            sent_pending.add(local_seq)
                            had_work = True
                    next_anchor_poll = now + 0.5
                if now >= next_content_poll:
                    if client.industry_content.refresh():
                        had_work = True
                    next_content_poll = now + 1.0
            elif time.monotonic() >= synchronize_deadline:
                raise ConnectionError("host backlog synchronization timed out")
            if not had_work:
                time.sleep(poll_seconds)
            if time.monotonic() >= next_status:
                client._write_status()
                next_status = time.monotonic() + 1.0
        if receiver_error:
            raise ConnectionError(str(receiver_error[0]))
    finally:
        client.connected = False
        client.socket_connected = False
        client.synchronized = False
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        reader.close()
        sock.close()


def _accept_sync_ready(client: Any, message: dict[str, Any]) -> None:
    through_seq = message.get("through_seq")
    if not isinstance(through_seq, int) or isinstance(through_seq, bool) \
            or through_seq < 0:
        raise ProtocolError("host sync_ready sequence is invalid")
    if str(message.get("peer", "")) == client.bridge.peer:
        raise ProtocolError("host sync_ready used the client peer identity")
    if client.ever_synchronized:
        client.reconnects += 1
    client.ever_synchronized = True
    client.synchronized = True
    client.connected = True
    client.status = "connected"
    client.last_synchronized_host_seq = through_seq
    client.next_host_seq = through_seq + 1
    client.retry_attempts = 0
    client.retry_delay_seconds = 0.0
    client._write_status()
    print(f"host backlog synchronized through sequence {through_seq}")


def _accept_receipt(client: Any, message: dict[str, Any]) -> None:
    if str(message.get("recipient")) != client.bridge.peer:
        raise ProtocolError("receipt was addressed to another peer")
    local_seq = int(message.get("local_seq", 0))
    if local_seq < 0:
        client.anchor_requests.record_receipt(
            local_seq, message.get("accepted") is True,
            str(message.get("reason") or "") or None,
        )
    else:
        client.bridge.acknowledge_outbound(local_seq)
    if not message.get("accepted"):
        print(f"host rejected local sequence {local_seq}: {message.get('reason')}")
