"""Incremental recovery-anchor views over the immutable host commit stream."""

from __future__ import annotations

from typing import Any, Mapping


class AnchorHistoryIndex:
    """Index checkpoint outcomes and receipts once as ordered history grows."""

    def __init__(self, host: Any) -> None:
        self.host = host
        self.indexed_through = 0
        self.known_count = 0
        self.checkpoint_outcomes: dict[int, int] = {}
        self.receipts: dict[tuple[int, str], tuple[dict[str, Any], dict[str, Any]]] = {}
        self.local_boundaries: set[int] = set()
        self.last_non_receipt_commit = 0

    def _reset(self) -> None:
        self.indexed_through = self.known_count = 0
        self.checkpoint_outcomes.clear()
        self.receipts.clear()
        self.local_boundaries.clear()
        self.last_non_receipt_commit = 0

    def _index(self, sequence: int, message: Mapping[str, Any]) -> None:
        self.indexed_through = max(self.indexed_through, sequence)
        action = (message.get("payload") or {}).get("action") or {}
        action_type = action.get("type")
        if action_type == "network.checkpoint_outcome" \
                and action.get("success") is True:
            boundary = int(action.get("boundarySeq", 0))
            if boundary > 0:
                self.checkpoint_outcomes[boundary] = max(
                    sequence, self.checkpoint_outcomes.get(boundary, 0)
                )
        if action_type == "recovery.save_receipt":
            boundary = int(action.get("boundarySeq", 0))
            peer = str(message.get("origin_peer") or "")
            if boundary > 0 and peer and isinstance(action.get("saveSha256"), str):
                self.receipts[(boundary, peer)] = (message, dict(action))
                if peer == self.host.bridge.peer:
                    self.local_boundaries.add(boundary)
        elif message.get("kind") == "commit":
            self.last_non_receipt_commit = max(
                self.last_non_receipt_commit, sequence
            )

    def refresh(self) -> None:
        current_count = len(self.host.commits)
        expected_last = max(0, int(self.host.next_seq) - 1)
        added = current_count - self.known_count
        if added < 0 or expected_last < self.indexed_through \
                or expected_last - self.indexed_through != added:
            self._reset()
            for sequence, message in sorted(self.host.commits.items()):
                self._index(int(sequence), message)
        else:
            for sequence in range(self.indexed_through + 1, expected_last + 1):
                message = self.host.commits.get(sequence)
                if message is not None:
                    self._index(sequence, message)
        self.known_count = current_count

    def checkpoint_outcome(self, boundary: int) -> int:
        self.refresh()
        return self.checkpoint_outcomes.get(int(boundary), 0)

    def work_after(self, outcome_sequence: int) -> bool:
        self.refresh()
        return self.last_non_receipt_commit > int(outcome_sequence)

    def receipt(
        self, boundary: int, peer: str
    ) -> tuple[dict[str, Any], dict[str, Any]] | None:
        self.refresh()
        return self.receipts.get((int(boundary), peer))

    def filed_by_local_peer(self) -> set[int]:
        self.refresh()
        return set(self.local_boundaries)

    def restorable(self, required_peers: tuple[str, ...]) -> list[int]:
        self.refresh()
        by_boundary: dict[int, dict[str, bool]] = {}
        for (boundary, peer), (_, action) in self.receipts.items():
            by_boundary.setdefault(boundary, {})[peer] = bool(action.get("metadataSha256"))
        required = set(required_peers)
        return sorted(
            boundary for boundary, receipts in by_boundary.items()
            if required <= set(receipts)
            and len({receipts[peer] for peer in required}) == 1
        )
