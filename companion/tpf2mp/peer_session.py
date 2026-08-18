from __future__ import annotations

import socket
import threading
from typing import Any

from .bridge import AuditUnavailable
from .protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_envelope
from .transport import ConnectedPeer, read_frame, send


def serve_peer(host: Any, conn: socket.socket, address: tuple[str, int]) -> None:
    """Handshake, ordered catch-up, and serve one replaceable client socket."""

    peer_name: str | None = None
    ready_connection = False
    reader = conn.makefile("rb")
    try:
        greeting = read_frame(reader)
        validate_envelope(greeting, host.bridge.session)
        if greeting.get("kind") != "hello":
            raise ProtocolError("first client frame must be hello")
        peer_name = str(greeting.get("peer", ""))
        if not peer_name or peer_name == host.bridge.peer:
            raise ProtocolError("client peer id is empty or conflicts with host")
        if peer_name not in host.required_peers:
            raise ProtocolError(f"peer {peer_name} is not in the pinned match roster")
        if host.match_fingerprint \
                and greeting.get("match_fingerprint") != host.match_fingerprint:
            raise ProtocolError("match fingerprint differs from the host")
        connected = ConnectedPeer(peer_name, conn, threading.Lock())
        with host.peers_lock:
            old = host.peers.pop(peer_name, None)
            if old:
                old.sock.close()
        if old:
            with host.order_lock:
                host.reconnect.disconnected(peer_name, "connection-replaced")
        last_commit = int(greeting.get("last_commit_seq", 0))
        with host.order_lock:
            latest_commit = host.next_seq - 1
        if last_commit < 0 or last_commit > latest_commit:
            raise ProtocolError("client last commit sequence is outside host history")
        if last_commit > 0 and last_commit not in host.commits:
            raise ProtocolError("client last commit sequence is absent from host history")
        host.reconnect.synchronizing(peer_name, last_commit)
        send(conn, sign({
            "protocol": PROTOCOL_VERSION,
            "session": host.bridge.session,
            "kind": "hello_ack",
            "peer": host.bridge.peer,
            "next_seq": host.next_seq,
            "replay_from_seq": last_commit + 1,
            "match_fingerprint": host.match_fingerprint,
        }), connected.send_lock)

        replayed_through = last_commit
        while True:
            with host.order_lock:
                replay_target = host.next_seq - 1
                missing = [
                    seq for seq in range(replayed_through + 1, replay_target + 1)
                    if seq not in host.commits
                ]
                if missing:
                    raise ProtocolError(
                        f"host ordered history is missing sequence {missing[0]}"
                    )
                replay_batch = [host.commits[seq] for seq in range(
                    replayed_through + 1, replay_target + 1
                )]
            for message in replay_batch:
                send(conn, message, connected.send_lock)
            replayed_through = replay_target
            with host.order_lock:
                if replayed_through != host.next_seq - 1:
                    continue
                restore_plan = host.restore_plan_exchange.published_message(force=True)
                if restore_plan:
                    send(conn, restore_plan, connected.send_lock)
                with host.peers_lock:
                    host.peers[peer_name] = connected
                host.reconnect.ready(peer_name, replayed_through)
                ready_connection = True
                send(conn, sign({
                    "protocol": PROTOCOL_VERSION,
                    "session": host.bridge.session,
                    "kind": "sync_ready",
                    "peer": host.bridge.peer,
                    "through_seq": replayed_through,
                }), connected.send_lock)
                break
        print(
            f"client {peer_name} connected from {address[0]}:{address[1]}; "
            f"replayed through {replayed_through}"
        )

        while not host.stop.is_set():
            message = read_frame(reader)
            validate_envelope(message, host.bridge.session)
            if str(message.get("peer")) != peer_name:
                raise ProtocolError("connected peer changed identity")
            accepted, reason, commit_seq = True, None, None
            try:
                if message.get("kind") == "intent":
                    commit = host._commit(message)
                    commit_seq = commit and commit.get("seq")
                else:
                    host._record_non_intent(message)
            except ProtocolError as exc:
                accepted, reason = False, str(exc)
                rejection = None
                if int(message.get("local_seq", 0)) > 0:
                    rejection = host._reject_intent(message, reason)
                commit_seq = rejection and rejection.get("seq")
                print(
                    f"rejected {peer_name} local sequence "
                    f"{message.get('local_seq')}: {reason}"
                )
            send(conn, sign({
                "protocol": PROTOCOL_VERSION,
                "session": host.bridge.session,
                "kind": "receipt",
                "peer": host.bridge.peer,
                "recipient": peer_name,
                "local_seq": int(message.get("local_seq", 0)),
                "accepted": accepted,
                "reason": reason,
                "commit_seq": commit_seq,
            }), connected.send_lock)
    except AuditUnavailable as exc:
        host._enter_audit_fault(exc)
        if not host.stop.is_set():
            print(f"AUTHORITY AUDIT FAULT while serving {peer_name or address}: {exc}")
    except (ConnectionError, OSError, ProtocolError) as exc:
        if not host.stop.is_set():
            print(f"client {peer_name or address} disconnected: {exc}")
    finally:
        removed_ready_peer = False
        with host.order_lock:
            with host.peers_lock:
                if peer_name and host.peers.get(peer_name) \
                        and host.peers[peer_name].sock is conn:
                    host.peers.pop(peer_name, None)
                    removed_ready_peer = ready_connection
            if removed_ready_peer and peer_name:
                host.reconnect.disconnected(peer_name, "connection-lost")
        try:
            reader.close()
            conn.close()
        except OSError:
            pass
