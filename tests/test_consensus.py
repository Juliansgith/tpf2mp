from __future__ import annotations

import unittest

from tpf2mp.consensus import (
    ConsensusTrackers,
    clock_health_payload,
    operation_completion_payload,
    proposal_completion_payload,
)
from tpf2mp.protocol import ProtocolError


class ConsensusTrackerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.trackers = ConsensusTrackers(
            "consensus-test",
            ("player1", "player2"),
            45.0,
            monotonic=lambda: 100.0,
        )

    @staticmethod
    def commit(seq: int, action: dict[str, object]) -> dict[str, object]:
        return {
            "seq": seq,
            "origin_peer": "player2",
            "origin_local_seq": seq + 10,
            "tick": 7,
            "payload": {"action": action},
        }

    def test_trackers_are_idempotent_and_keep_earliest_pending(self) -> None:
        prepare = self.trackers.track_prepare(
            self.commit(3, {"type": "proposal.prepare", "transaction": {"digest": "1234abcd"}})
        )
        self.assertIs(
            prepare,
            self.trackers.track_prepare(
                self.commit(3, {"type": "proposal.prepare", "transaction": {"digest": "ignored"}})
            ),
        )
        self.assertEqual(prepare["deadline"], 145.0)
        earlier = self.trackers.track_proposal(
            self.commit(1, {"type": "proposal.build", "transaction": {"digest": "11111111"}})
        )
        self.trackers.track_proposal(
            self.commit(2, {"type": "proposal.build", "transaction": {"digest": "22222222"}})
        )
        self.assertIs(self.trackers.pending(self.trackers.proposals), earlier)
        earlier["status"] = "complete"
        self.assertEqual(self.trackers.pending(self.trackers.proposals)["commitSeq"], 2)

    def test_clock_tracker_uses_short_deadline(self) -> None:
        tracker = self.trackers.track_clock(
            self.commit(
                4,
                {
                    "type": "clock.set",
                    "requestedSpeed": 4,
                    "effectiveSpeed": 3,
                    "generation": 2,
                    "reason": "test",
                },
            )
        )
        self.assertEqual(tracker["deadline"], 110.0)
        self.assertEqual(self.trackers.pending_clock_seq(), 4)

    def test_payload_validators_remain_strict(self) -> None:
        proposal = {
            "proposalId": "session:player1:2",
            "commitSeq": 2,
            "proposalDigest": "11111111",
            "success": True,
            "outputs": [],
            "financeDelta": -100,
            "coreDigest": "22222222",
            "resultDigest": "33333333",
        }
        self.assertEqual(proposal_completion_payload(proposal), proposal)
        operation = {
            "operationId": "session:player1:3",
            "commitSeq": 3,
            "operationDigest": "44444444",
            "success": False,
            "outputs": {},
            "postcondition": {},
            "coreDigest": "55555555",
            "resultDigest": "66666666",
            "errorCode": "native-operation-failed",
        }
        self.assertEqual(operation_completion_payload(operation), operation)
        health = {
            "schemaVersion": 1,
            "requestedSpeed": 4,
            "effectiveSpeed": 3,
            "generation": 2,
            "engineTick": 90,
            "lastCommitSeq": 7,
            "proposalPending": False,
        }
        self.assertEqual(clock_health_payload(health), health)
        with self.assertRaises(ProtocolError):
            clock_health_payload({**health, "engineTick": True})


if __name__ == "__main__":
    unittest.main()
