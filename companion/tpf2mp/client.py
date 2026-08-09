from __future__ import annotations

import socket
import threading
import time

from .bridge import GameBridge
from .anchor_io import AnchorRequestStore, validate_anchor_state
from .industry_content import IndustryContentCoordinator
from .protocol import ProtocolError, hello, validate_envelope
from .restore_plan_exchange import RestorePlanExchange
from .transport import read_frame as _read_frame, send as _send

class CommitClient:
    def __init__(
        self,
        bridge: GameBridge,
        host: str,
        port: int,
        match_fingerprint: str | None = None,
    ) -> None:
        self.bridge = bridge
        self.host = host
        self.port = port
        self.match_fingerprint = match_fingerprint
        self.stop = threading.Event()
        self.status = "starting"
        self.connected = False
        self.last_error: str | None = None
        self.next_host_seq: int | None = None
        self.anchor_state: dict[str, object] | None = None
        self.anchor_requests = AnchorRequestStore(self.bridge)
        self.restore_plan_exchange = RestorePlanExchange(self.bridge)
        self.industry_content = IndustryContentCoordinator(self.bridge)

    def _write_status(self, status: str | None = None) -> None:
        if status is not None:
            self.status = status
        anchor = self.anchor_state or {}
        self.bridge.write_status(
            {
                "role": "client",
                "status": self.status,
                "connected": self.connected,
                "host": self.host,
                "port": self.port,
                "nextHostSeq": self.next_host_seq,
                "outboxCursor": self.bridge.outbox_cursor,
                "outboxPrunedThrough": self.bridge.outbox_pruned_through,
                "outboxEphemeralRetention": self.bridge.outbox_ephemeral_retention,
                "lastCommitSeq": self._last_commit(),
                "lastError": self.last_error,
                "matchFingerprint": self.match_fingerprint,
                "anchorReady": anchor.get("ready") is True,
                "anchorBoundarySeq": anchor.get("boundarySeq"),
                "anchorReasons": anchor.get("reasons", ["host readiness has not arrived"]),
                "anchorCoreDigest": anchor.get("coreDigest"),
                "anchorConvergenceKey": anchor.get("convergenceKey"),
                "anchorPreparationStatus": anchor.get("preparationStatus", "idle"),
                "anchorPreparationSeq": anchor.get("preparationSeq"),
                "anchorPreparationCheckpointSeq": anchor.get("preparationCheckpointSeq"),
                "anchorPreparationDetail": anchor.get("preparationDetail"),
                **self.anchor_requests.status(),
                **self.restore_plan_exchange.status(),
                **self.industry_content.status(),
            }
        )

    def _last_commit(self) -> int:
        sequences = self.bridge.existing_commit_sequences()
        current = 0
        while current + 1 in sequences:
            current += 1
        return current

    def _session(self, poll_seconds: float) -> None:
        sock = socket.create_connection((self.host, self.port), timeout=5)
        sock.settimeout(None)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        reader = sock.makefile("rb")
        send_lock = threading.Lock()
        _send(
            sock,
            hello(self.bridge.session, self.bridge.peer, self._last_commit(), self.match_fingerprint),
            send_lock,
        )
        acknowledgement = _read_frame(reader)
        validate_envelope(acknowledgement, self.bridge.session)
        if acknowledgement.get("kind") != "hello_ack":
            raise ProtocolError("host did not acknowledge handshake")
        if self.match_fingerprint and acknowledgement.get("match_fingerprint") != self.match_fingerprint:
            raise ProtocolError("host acknowledged a different match fingerprint")
        self.connected = True
        self.status = "connected"
        self.last_error = None
        self.next_host_seq = int(acknowledgement.get("next_seq", 0))
        self._write_status()
        print(f"connected to {self.host}:{self.port}; next host sequence {acknowledgement.get('next_seq')}")
        receiver_error: list[BaseException] = []
        sent_pending: set[int] = set()

        def receive() -> None:
            try:
                while not self.stop.is_set():
                    message = _read_frame(reader)
                    validate_envelope(message, self.bridge.session)
                    if message.get("kind") in {"commit", "control"}:
                        self.bridge.write_inbound(message)
                    elif message.get("kind") == "anchor_state":
                        self.anchor_state = validate_anchor_state(message)
                    elif message.get("kind") == "restore_plan":
                        self.restore_plan_exchange.accept(message)
                    elif message.get("kind") == "receipt":
                        if str(message.get("recipient")) != self.bridge.peer:
                            raise ProtocolError("receipt was addressed to another peer")
                        local_seq = int(message.get("local_seq", 0))
                        if local_seq < 0:
                            self.anchor_requests.record_receipt(
                                local_seq, message.get("accepted") is True,
                                str(message.get("reason") or "") or None,
                            )
                        else:
                            self.bridge.acknowledge_outbound(local_seq)
                        if not message.get("accepted"):
                            print(f"host rejected local sequence {local_seq}: {message.get('reason')}")
            except BaseException as exc:  # surfaced in the owning reconnect loop
                receiver_error.append(exc)

        thread = threading.Thread(target=receive, daemon=True)
        thread.start()
        try:
            next_status = time.monotonic()
            while not self.stop.is_set() and not receiver_error:
                had_work = False
                for local_seq, message in self.bridge.pending_outbound():
                    if local_seq not in sent_pending:
                        _send(sock, message, send_lock)
                        sent_pending.add(local_seq)
                        had_work = True
                for message in self.anchor_requests.client_intents(self.anchor_state):
                    local_seq = int(message["local_seq"])
                    if local_seq not in sent_pending:
                        _send(sock, message, send_lock)
                        sent_pending.add(local_seq)
                        had_work = True
                if self.industry_content.refresh():
                    had_work = True
                if not had_work:
                    time.sleep(poll_seconds)
                if time.monotonic() >= next_status:
                    self._write_status()
                    next_status = time.monotonic() + 0.5
            if receiver_error:
                raise ConnectionError(str(receiver_error[0]))
        finally:
            self.connected = False
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            reader.close()
            sock.close()

    def run(self, poll_seconds: float = 0.1, retry_seconds: float = 2.0) -> None:
        print(f"TPF2MP client peer={self.bridge.peer} session={self.bridge.session} bridge={self.bridge.root}")
        print(f"match fingerprint={self.match_fingerprint or 'UNVERIFIED'}")
        self._write_status("connecting")
        try:
            while not self.stop.is_set():
                try:
                    self._session(poll_seconds)
                except (ConnectionError, OSError, ProtocolError) as exc:
                    if self.stop.is_set():
                        break
                    self.connected = False
                    self.last_error = str(exc)
                    self._write_status("retrying")
                    print(f"connection unavailable: {exc}; retrying in {retry_seconds:.1f}s")
                    self.stop.wait(retry_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.connected = False
            self._write_status("stopped")
