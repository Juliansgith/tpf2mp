from __future__ import annotations

import threading
import time
from typing import Any, Mapping

from .bridge import GameBridge
from .anchor_io import AnchorRequestStore
from .industry_content import IndustryContentCoordinator
from .protocol import ProtocolError
from .client_session import run_client_session
from .restore_plan_exchange import RestorePlanExchange
from .active_content import compact_content_inventory

class CommitClient:
    def __init__(
        self,
        bridge: GameBridge,
        host: str,
        port: int,
        match_fingerprint: str | None = None,
        match_content_inventory: Mapping[str, Any] | None = None,
    ) -> None:
        self.bridge = bridge
        self.host = host
        self.port = port
        self.match_fingerprint = match_fingerprint
        self.match_content_inventory = compact_content_inventory(match_content_inventory)
        self.stop = threading.Event()
        self.status = "starting"
        self.connected = False
        self.socket_connected = False
        self.synchronized = False
        self.ever_synchronized = False
        self.reconnects = 0
        self.last_synchronized_host_seq: int | None = None
        self.last_error: str | None = None
        self.retry_attempts, self.retry_delay_seconds = 0, 0.0
        self._next_connection_error_log_at = 0.0
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
                "socketConnected": self.socket_connected,
                "synchronized": self.synchronized,
                "reconnects": self.reconnects,
                "lastSynchronizedHostSeq": self.last_synchronized_host_seq,
                "host": self.host,
                "port": self.port,
                "nextHostSeq": self.next_host_seq,
                "outboxCursor": self.bridge.outbox_cursor,
                "outboxPrunedThrough": self.bridge.outbox_pruned_through,
                "outboxEphemeralRetention": self.bridge.outbox_ephemeral_retention,
                "lastCommitSeq": self._last_commit(),
                "lastError": self.last_error,
                "retryAttempts": self.retry_attempts,
                "retryDelaySeconds": self.retry_delay_seconds,
                "matchFingerprint": self.match_fingerprint,
                "activeContentDigest": self.match_content_inventory and self.match_content_inventory["digest"],
                "activeContentCount": len(self.match_content_inventory["mods"])
                if self.match_content_inventory else None,
                "pausedHeartbeatRequired": anchor.get("pausedHeartbeatRequired", True) is True,
                "anchorReady": anchor.get("ready") is True,
                "anchorReceiptReady": anchor.get("receiptReady", anchor.get("ready")) is True,
                "anchorBoundarySeq": anchor.get("boundarySeq"),
                "anchorReasons": anchor.get("reasons", ["host readiness has not arrived"]),
                "anchorCoreDigest": anchor.get("coreDigest"),
                "anchorConvergenceKey": anchor.get("convergenceKey"),
                "anchorPreparationStatus": anchor.get("preparationStatus", "idle"),
                "anchorPreparationSeq": anchor.get("preparationSeq"),
                "anchorPreparationCheckpointSeq": anchor.get("preparationCheckpointSeq"),
                "anchorPreparationDetail": anchor.get("preparationDetail"),
                "automaticRecovery": anchor.get("automaticRecovery", {
                    "enabled": False, "status": "unavailable",
                }),
                "faultRecovery": anchor.get("faultRecovery", {
                    "status": "healthy", "eligible": False,
                    "detail": "host recovery state has not arrived",
                }),
                **self.anchor_requests.status(),
                **self.restore_plan_exchange.status(),
                **self.industry_content.status(),
            }
        )

    def _last_commit(self) -> int:
        return self.bridge.last_contiguous_commit_sequence()

    def _session(self, poll_seconds: float) -> None:
        run_client_session(self, poll_seconds)

    def run(self, poll_seconds: float = 0.1, retry_seconds: float = 2.0) -> None:
        print(f"TPF2MP client peer={self.bridge.peer} session={self.bridge.session} bridge={self.bridge.root}")
        print(f"match fingerprint={self.match_fingerprint or 'UNVERIFIED'}")
        if self.match_content_inventory:
            print(
                f"active content verified={len(self.match_content_inventory['mods'])} "
                f"digest={self.match_content_inventory['digest']}"
            )
        self._write_status("connecting")
        try:
            while not self.stop.is_set():
                try:
                    self._session(poll_seconds)
                except (ConnectionError, OSError, ProtocolError) as exc:
                    if self.stop.is_set():
                        break
                    self.connected = False
                    self.socket_connected = False
                    self.synchronized = False
                    previous_error = self.last_error
                    self.last_error = str(exc)
                    self.retry_attempts += 1
                    self.retry_delay_seconds = min(
                        10.0,
                        max(0.01, float(retry_seconds))
                        * (2 ** min(self.retry_attempts - 1, 4)),
                    )
                    self._write_status("retrying")
                    now = time.monotonic()
                    error_text = str(exc)
                    if self.retry_attempts == 1 \
                            or error_text != previous_error \
                            or now >= self._next_connection_error_log_at:
                        print(
                            f"connection unavailable: {exc}; retrying in "
                            f"{self.retry_delay_seconds:.1f}s "
                            f"(attempt {self.retry_attempts})"
                        )
                        self._next_connection_error_log_at = now + 30.0
                    self.stop.wait(self.retry_delay_seconds)
        except KeyboardInterrupt:
            pass
        finally:
            self.stop.set()
            self.connected = False
            self.socket_connected = False
            self.synchronized = False
            self._write_status("stopped")
