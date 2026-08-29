from __future__ import annotations

import threading
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from tpf2mp.anchor_prepare import AnchorPreparationCoordinator
from tpf2mp.anchor_state import anchor_state_message, validate_anchor_state
from tpf2mp.automatic_recovery import AutomaticRecoveryScheduler
from tpf2mp.bridge import GameBridge
from tpf2mp.network import CommitHost
from tpf2mp.protocol import PROTOCOL_VERSION, ProtocolError, sign, validate_action


class MutableClock:
    def __init__(self, value: float) -> None:
        self.value = value

    def __call__(self) -> float:
        return self.value


class FakeHistory:
    def __init__(self) -> None:
        self.receipts: dict[tuple[int, str], tuple[dict, dict]] = {}

    def receipt(self, boundary: int, peer: str):
        return self.receipts.get((boundary, peer))


class FakeAnchor:
    def __init__(self) -> None:
        self.points: list[int] = []
        self.pending = 0
        self.history = FakeHistory()

    def restorable(self) -> list[int]:
        return list(self.points)

    def _pending_work(self) -> int:
        return self.pending


class FakeHost:
    def __init__(self) -> None:
        self.anchor = FakeAnchor()
        self.anchor_preparation = SimpleNamespace(current=None)
        self.restore_session = SimpleNamespace(status=lambda: {})
        self.bridge = SimpleNamespace(peer="player1")
        self.required_peers = ("player1", "player2")
        self.require_connected_peers = False
        self.peers_lock = threading.Lock()
        self.peers = {}
        self.session_fault = None
        self.last_agreed_checkpoint = {"boundarySeq": 4}
        self.clock_requested_speed = 3
        self.clock_effective_speed = 3
        self.actions: list[dict] = []
        self.next_sequence = 7
        self.reject_resume = False

    def emit_local_intent(self, action: dict):
        self.actions.append(dict(action))
        if action["type"] == "clock.request" and self.reject_resume:
            raise ProtocolError("cannot resume while player2 is disconnected")
        if action["type"] == "recovery.prepare":
            sequence = self.next_sequence
            self.next_sequence += 1
            self.anchor_preparation.current = {
                "preparationSeq": sequence,
                "status": "draining",
            }
            return {"seq": sequence}
        if action["type"] == "recovery.cancel" and self.anchor_preparation.current:
            self.anchor_preparation.current["status"] = "failed"
        return {"seq": self.next_sequence}


class AutomaticRecoveryTests(unittest.TestCase):
    def _scheduler(self, host: FakeHost, mono: MutableClock, wall: MutableClock):
        return AutomaticRecoveryScheduler(
            host,
            interval_seconds=10,
            timeout_seconds=30,
            monotonic=mono,
            wall_time=wall,
        )

    def test_periodic_preparation_waits_for_both_receipts_then_resumes(self) -> None:
        host = FakeHost()
        mono, wall = MutableClock(0), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        mono.value = 10
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions, [{
            "type": "recovery.prepare", "automatic": True,
        }])
        self.assertEqual(scheduler.status()["automaticRecovery"]["preparationSeq"], 7)

        host.anchor.points = [12]
        for peer, saved_at in (("player1", 1010), ("player2", 1011)):
            host.anchor.history.receipts[(12, peer)] = (
                {}, {"savedAtUnix": saved_at},
            )
        mono.value = 11
        self.assertTrue(scheduler.maintain())
        self.assertEqual(scheduler.status()["automaticRecovery"]["status"], "finalizing")
        mono.value = 16
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions[-1], {"type": "clock.request", "requestedSpeed": 3})
        status = scheduler.status()["automaticRecovery"]
        self.assertEqual(status["status"], "scheduled")
        self.assertEqual(status["lastBoundarySeq"], 12)
        self.assertEqual(status["lastCompletedAtUnix"], 1011)

    def test_timeout_is_ordered_and_releases_the_preparation_fence(self) -> None:
        host = FakeHost()
        mono, wall = MutableClock(0), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        mono.value = 10
        scheduler.maintain()
        mono.value = 40
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions[-2], {
            "type": "recovery.cancel", "preparationSeq": 7,
            "errorCode": "automatic restore-point preparation timed out",
        })
        self.assertEqual(host.actions[-1], {"type": "clock.request", "requestedSpeed": 3})
        self.assertEqual(scheduler.status()["automaticRecovery"]["status"], "retry-wait")

    def test_faulted_preparation_cancels_without_resuming_gameplay(self) -> None:
        host = FakeHost()
        mono, wall = MutableClock(0), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        mono.value = 10
        scheduler.maintain()
        host.session_fault = "checkpoint-consensus-failed"
        host.anchor_preparation.current.update({
            "status": "failed", "detail": "checkpoint consensus failed",
        })
        mono.value = 11
        scheduler.maintain()
        self.assertEqual(host.actions[-1]["type"], "recovery.cancel")
        self.assertFalse(any(
            action["type"] == "clock.request" for action in host.actions
        ))

    def test_restart_refreshes_an_already_stale_restore_point_immediately(self) -> None:
        host = FakeHost()
        host.anchor.points = [5]
        for peer in host.required_peers:
            host.anchor.history.receipts[(5, peer)] = (
                {}, {"savedAtUnix": 1000},
            )
        mono, wall = MutableClock(50), MutableClock(2000)
        scheduler = AutomaticRecoveryScheduler(
            host, interval_seconds=900, timeout_seconds=180,
            monotonic=mono, wall_time=wall,
        )
        self.assertEqual(scheduler.status()["automaticRecovery"]["nextDueInSeconds"], 0)
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions[-1]["type"], "recovery.prepare")

    def test_scheduler_waits_for_a_converged_checkpoint(self) -> None:
        host = FakeHost()
        host.last_agreed_checkpoint = None
        mono, wall = MutableClock(0), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        mono.value = 10
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions, [])
        self.assertEqual(
            scheduler.status()["automaticRecovery"]["lastError"],
            "waiting for the first converged checkpoint",
        )

    def test_restart_adopts_an_interrupted_automatic_preparation(self) -> None:
        host = FakeHost()
        host.anchor_preparation.current = {
            "preparationSeq": 7, "automatic": True, "status": "checkpointing",
            "checkpointBoundarySeq": 9, "resumeSpeed": 3,
        }
        mono, wall = MutableClock(50), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        status = scheduler.status()["automaticRecovery"]
        self.assertEqual(status["preparationSeq"], 7)
        self.assertEqual(status["status"], "preparing")
        host.anchor.points = [9]
        for peer in host.required_peers:
            host.anchor.history.receipts[(9, peer)] = ({}, {"savedAtUnix": 1001})
        mono.value = 51
        self.assertTrue(scheduler.maintain())
        mono.value = 56
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions[-1], {"type": "clock.request", "requestedSpeed": 3})

    def test_restart_finalizes_receipts_written_before_scheduler_restart(self) -> None:
        host = FakeHost()
        host.anchor.points = [9]
        for peer in host.required_peers:
            host.anchor.history.receipts[(9, peer)] = ({}, {"savedAtUnix": 1001})
        host.anchor_preparation.current = {
            "preparationSeq": 7, "automatic": True, "status": "ready",
            "checkpointBoundarySeq": 9, "resumeSpeed": 2,
        }
        mono, wall = MutableClock(50), MutableClock(1002)
        scheduler = self._scheduler(host, mono, wall)
        self.assertEqual(
            scheduler.status()["automaticRecovery"]["status"], "finalizing"
        )
        mono.value = 55
        self.assertTrue(scheduler.maintain())
        self.assertEqual(host.actions[-1], {"type": "clock.request", "requestedSpeed": 2})

    def test_completed_restore_survives_a_disconnected_speed_resume(self) -> None:
        host = FakeHost()
        mono, wall = MutableClock(0), MutableClock(1000)
        scheduler = self._scheduler(host, mono, wall)
        mono.value = 10
        scheduler.maintain()
        host.anchor.points = [12]
        for peer in host.required_peers:
            host.anchor.history.receipts[(12, peer)] = ({}, {"savedAtUnix": 1010})
        mono.value = 11
        scheduler.maintain()
        host.reject_resume = True
        mono.value = 16
        self.assertTrue(scheduler.maintain())
        status = scheduler.status()["automaticRecovery"]
        self.assertEqual(status["lastBoundarySeq"], 12)
        self.assertIn("remains paused", status["lastError"])

    def test_audit_replay_retires_a_preparation_after_host_resume(self) -> None:
        host = FakeHost()
        coordinator = AnchorPreparationCoordinator(host)
        coordinator.current = {
            "preparationSeq": 7, "automatic": True, "status": "ready",
        }
        coordinator.observe_ordered({
            "seq": 12, "origin_peer": "player1", "origin_local_seq": -3,
            "payload": {"action": {"type": "clock.set", "requestedSpeed": 3}},
        }, restoring=True)
        self.assertIsNone(coordinator.current)
        self.assertEqual(coordinator.last["status"], "superseded")

    def test_wire_state_and_cancel_action_are_strict(self) -> None:
        message = anchor_state_message(
            "anchor-state", "player1",
            {"ready": False, "boundarySeq": 4, "coreDigest": "core",
             "convergenceKey": "key", "reasons": []},
            automatic_recovery={
                "enabled": True, "intervalSeconds": 900, "timeoutSeconds": 180,
                "status": "scheduled", "preparationSeq": None,
                "lastBoundarySeq": 4, "lastCompletedAtUnix": 1000,
                "lastCompletedAgeSeconds": 5, "nextDueInSeconds": 895,
                "attempts": 1, "lastError": None,
            },
        )
        self.assertEqual(validate_anchor_state(message)["schemaVersion"], 6)
        action = {"type": "recovery.cancel", "preparationSeq": 7, "errorCode": "timeout"}
        self.assertEqual(validate_action(action), action)
        self.assertEqual(validate_action({
            "type": "recovery.prepare", "automatic": True,
        })["automatic"], True)
        with self.assertRaisesRegex(ProtocolError, "automatic marker"):
            validate_action({"type": "recovery.prepare", "automatic": False})
        with self.assertRaisesRegex(ProtocolError, "preparationSeq"):
            validate_action({**action, "preparationSeq": True})
        malformed = dict(message["payload"]["automaticRecovery"])
        malformed["attempts"] = True
        message["payload"]["automaticRecovery"] = malformed
        with self.assertRaisesRegex(ProtocolError, "attempts"):
            validate_anchor_state(message)

    def test_ordered_cancel_remains_available_after_a_session_fault(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "bridge", "cancel-test", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
                automatic_recovery_interval=0,
            )
            host.anchor_preparation.current = {
                "preparationSeq": 7, "status": "ready",
                "checkpointBoundarySeq": None, "detail": "waiting for saves",
            }
            host.session_fault = "checkpoint-consensus-failed"
            commit = host.emit_local_intent({
                "type": "recovery.cancel", "preparationSeq": 7,
                "errorCode": "automatic save failed",
            })
            self.assertIsNotNone(commit)
            self.assertEqual(host.anchor_preparation.current["status"], "failed")
            self.assertEqual(
                host.anchor_preparation.current["detail"], "automatic save failed"
            )
            marker_host = CommitHost(
                GameBridge(root / "marker-bridge", "marker-test", "player1"),
                "127.0.0.1", 0, root / "marker-audit.ndjson",
                require_connected_peers=False, automatic_recovery_interval=0,
            )
            marker_host.anchor_preparation.current = {
                "preparationSeq": 8, "status": "ready",
            }
            with self.assertRaisesRegex(ProtocolError, "host-generated"):
                marker_host._commit(sign({
                    "protocol": PROTOCOL_VERSION, "session": "marker-test",
                    "kind": "intent", "peer": "player2", "local_seq": 1,
                    "tick": 0, "payload": {"action": {
                        "type": "recovery.prepare", "automatic": True,
                    }},
                }))
            self.assertEqual(marker_host.anchor_preparation.current["status"], "ready")


if __name__ == "__main__":
    unittest.main()
