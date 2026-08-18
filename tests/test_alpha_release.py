from __future__ import annotations

import socket
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tpf2mp.alpha_acceptance import evaluate_alpha_evidence
from tpf2mp.bridge import GameBridge, atomic_write
from tpf2mp.client import CommitClient
from tpf2mp.network import CommitHost
from tpf2mp.protocol import sign
from tpf2mp.session_identity import derive_resume_session


def available_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])
    finally:
        sock.close()


def wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return bool(predicate())


class AlphaReconnectTests(unittest.TestCase):
    def test_disconnect_pauses_and_recovery_resets_consensus_deadlines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "alpha-grace", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
            )
            host.clock_requested_speed = 3
            host.clock_effective_speed = 3
            tracker = host.consensus.track_checkpoint(7, "alpha-reconnect")
            tracker["deadline"] = 11.0

            host.reconnect.disconnected("player2", "test-link-loss", now=10.0)

            self.assertEqual(host.clock_requested_speed, 3)
            self.assertEqual(host.clock_effective_speed, 0)
            self.assertTrue(host.reconnect.active())
            self.assertTrue(host.synchronization.pause_deadlines_protected())
            self.assertEqual(host.reconnect.status()["reconnect"]["events"], 1)

            host.reconnect.synchronizing("player2", 0, now=20.0)
            host.reconnect.ready("player2", host.next_seq - 1, now=30.0)

            self.assertFalse(host.reconnect.active())
            self.assertGreater(float(tracker["deadline"]), 30.0)
            status = host.reconnect.status()["reconnect"]
            self.assertEqual(status["recoveries"], 1)
            self.assertTrue(status["resumeRequired"])
            self.assertEqual(status["last"]["player2"]["status"], "recovered")

    def test_reconnect_replays_every_commit_before_becoming_ready(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            port = available_port()
            host_bridge = GameBridge(root / "host", "alpha-replay", "player1")
            client_bridge = GameBridge(root / "client", "alpha-replay", "player2")
            host = CommitHost(
                host_bridge, "127.0.0.1", port, root / "audit.ndjson", "same"
            )
            first_client = CommitClient(client_bridge, "127.0.0.1", port, "same")
            host_thread = threading.Thread(
                target=host.run, kwargs={"poll_seconds": 0.01}, daemon=True
            )
            first_thread = threading.Thread(
                target=first_client.run,
                kwargs={"poll_seconds": 0.01, "retry_seconds": 0.02},
                daemon=True,
            )
            host_thread.start()
            first_thread.start()
            self.assertTrue(wait_for(lambda: first_client.connected))

            first_client.stop.set()
            first_thread.join(timeout=2.0)
            self.assertTrue(wait_for(lambda: "player2" not in host.peers))
            self.assertTrue(host.reconnect.active())

            with host.order_lock:
                offline = host._emit_clock_commit_locked(3, 0, "alpha-offline-marker")
            offline_seq = int(offline["seq"])
            self.assertNotIn(offline_seq, client_bridge.existing_commit_sequences())

            second_client = CommitClient(client_bridge, "127.0.0.1", port, "same")
            second_thread = threading.Thread(
                target=second_client.run,
                kwargs={"poll_seconds": 0.01, "retry_seconds": 0.02},
                daemon=True,
            )
            second_thread.start()
            self.assertTrue(wait_for(lambda: second_client.connected))

            self.assertIn(offline_seq, client_bridge.existing_commit_sequences())
            self.assertEqual(second_client.last_synchronized_host_seq, host.next_seq - 1)
            self.assertFalse(host.reconnect.active())
            self.assertEqual(host.reconnect.status()["reconnect"]["recoveries"], 1)

            second_client.stop.set()
            host.stop.set()
            second_thread.join(timeout=2.0)
            host_thread.join(timeout=2.0)

    def test_reconnect_grace_expires_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "alpha-timeout", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
            )
            host.reconnect.grace_seconds = 10.0
            host.reconnect.disconnected("player2", "gone", now=100.0)
            self.assertTrue(host.reconnect.expire(now=109.9))
            self.assertTrue(host.reconnect.active())
            self.assertFalse(host.reconnect.expire(now=110.0))
            self.assertEqual(host.session_fault, "peer-reconnect-timeout:player2")
            self.assertEqual(host.reconnect.status()["reconnect"]["timeouts"], 1)


def alpha_restore_plan(session: str, boundary: int) -> dict:
    first = {
        "saveSha256": "a" * 64, "metadataSha256": "b" * 64,
        "savedAtUnix": 1000, "receiptCommitSeq": boundary + 1,
        "boundarySeq": boundary, "coreDigest": f"core-{boundary}",
        "convergenceKey": f"key-{boundary}",
    }
    return sign({
        "format": "tpf2mp-restore-plan", "version": 6, "protocol": 1,
        "session": session, "resumeSession": derive_resume_session(session, boundary),
        "generatedAtUtc": "2026-08-18T00:00:00+00:00",
        "boundarySeq": boundary, "convergenceKey": f"key-{boundary}",
        "coreDigest": f"core-{boundary}", "requiredPeers": ["player1", "player2"],
        "peerSaves": {
            "player1": first,
            "player2": {**first, "saveSha256": "c" * 64,
                        "metadataSha256": "d" * 64,
                        "receiptCommitSeq": boundary + 2},
        },
        "matchContentProfile": {
            "schemaVersion": 1, "agentMode": "skeleton", "townDevelopment": True,
        },
        "vehiclePhaseProof": {
            "schemaVersion": 1,
            "sampleKeys": [f"{session}:player1:{boundary - 2}",
                           f"{session}:player1:{boundary - 1}"],
            "vehiclePhaseDigest": "4567def0", "vehicleRounds": [],
        },
        "steps": ["restore both peers"],
    })


def alpha_shared(session: str = "alpha-full") -> dict:
    services = {
        "line:passenger-a": {
            "enabled": True,
            "metadata": {"networkMaxTransfers": 1, "networkOriginRoutes": [{
                "digest": "1234abcd", "lines": ["line:passenger-a", "line:passenger-b"],
            }]},
        },
        "line:passenger-b": {"enabled": True, "metadata": {}},
        "line:cargo-a": {"enabled": True, "metadata": {
            "freightContractSchema": 2, "freightPathDigest": "abcd1234",
            "freightLegIndex": 0, "freightLegCount": 2,
        }},
        "line:cargo-b": {"enabled": True, "metadata": {
            "freightContractSchema": 2, "freightPathDigest": "abcd1234",
            "freightLegIndex": 1, "freightLegCount": 2,
        }},
    }
    def payload(boundary: int) -> dict:
        return {
            "eventCursor": {"lastCommitSeq": boundary},
            "coreDigest": f"core-{boundary}", "convergenceKey": f"key-{boundary}",
            "model": {"economy": {"epoch": 4, "services": services}},
            "vehicleSynchronization": {
                "vehicles": [{"vehicleCid": "vehicle:1"}, {"vehicleCid": "vehicle:2"}],
                "passengerPresentation": {"vehicles": [{"vehicleCid": "vehicle:1"}]},
                "cargoPresentation": {
                    "vehicles": [{"vehicleCid": "vehicle:2"}],
                    "stationStock": {"station_group:x": {"OIL": 3}},
                    "lines": [
                        {"transportSchema": 2, "destinationKind": "station",
                         "sourceKind": "industry", "deliveredTotal": 12,
                         "boardedTotal": 12},
                        {"transportSchema": 2, "destinationKind": "industry",
                         "sourceKind": "station", "deliveredTotal": 9,
                         "boardedTotal": 9},
                    ],
                },
            },
        }
    return {
        "session": session, "requiredPeers": ["player1", "player2"],
        "faults": [],
        "pending": {
            "proposalPrepares": [], "proposals": [], "operations": [],
            "checkpoints": [], "incompleteCommitAcknowledgements": {},
            "divergentCommitAcknowledgements": {},
        },
        "actionCounts": {"town.develop": 2, "recovery.save_receipt": 2},
        "physicalOutcomes": {"proposalsSuccessful": 3, "operationsSuccessful": 5},
        "completed": [
            {"boundarySeq": boundary,
             "payloads": {"player1": payload(boundary), "player2": payload(boundary)}}
            for boundary in (5, 6, 7)
        ],
    }


class AlphaEvidenceTests(unittest.TestCase):
    def test_concurrent_status_publication_uses_distinct_atomic_temporaries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "companion_status.json"
            barrier = threading.Barrier(8)
            errors: list[BaseException] = []

            def publish(index: int) -> None:
                try:
                    barrier.wait()
                    atomic_write(path, (json.dumps({"writer": index}) + "\n").encode())
                except BaseException as exc:
                    errors.append(exc)

            workers = [threading.Thread(target=publish, args=(index,)) for index in range(8)]
            for worker in workers:
                worker.start()
            for worker in workers:
                worker.join()
            self.assertEqual(errors, [])
            self.assertIn(json.loads(path.read_text())["writer"], range(8))
            self.assertEqual(list(path.parent.glob(".*.tmp")), [])

    def test_full_alpha_profile_proves_every_release_gate(self) -> None:
        shared = alpha_shared()
        statuses = {
            "player1": {"connected": True, "reconnect": {
                "active": False, "synchronizingPeers": {}, "events": 1,
                "recoveries": 1, "timeouts": 0,
            }},
            "player2": {"connected": True, "synchronized": True},
        }
        report = evaluate_alpha_evidence(
            shared, profile="alpha", statuses=statuses,
            restore_plan=alpha_restore_plan("alpha-full", 7),
        )
        self.assertTrue(report["passed"], report["problems"])
        self.assertEqual(report["maxima"]["cargoTransferRoutes"], 1)
        self.assertEqual(report["maxima"]["passengerTransferRoutes"], 1)

    def test_missing_ack_and_status_fail_closed(self) -> None:
        shared = alpha_shared()
        shared["pending"]["incompleteCommitAcknowledgements"] = {"7": ["player2"]}
        report = evaluate_alpha_evidence(shared, profile="playable")
        self.assertFalse(report["passed"])
        self.assertTrue(any(problem.startswith("quiescent:") for problem in report["problems"]))
        self.assertTrue(any(problem.startswith("peer-synchronized:")
                            for problem in report["problems"]))

    def test_core_profile_reports_optional_gaps_without_failing(self) -> None:
        shared = alpha_shared()
        shared["completed"] = shared["completed"][:1]
        report = evaluate_alpha_evidence(shared, profile="core")
        self.assertTrue(report["passed"], report["problems"])
        reconnect = next(item for item in report["checks"]
                         if item["code"] == "reconnect-recovery")
        self.assertFalse(reconnect["required"])
        self.assertFalse(reconnect["passed"])


if __name__ == "__main__":
    unittest.main()
