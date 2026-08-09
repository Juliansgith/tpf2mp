from __future__ import annotations

from typing import Any, Mapping

from .protocol import PROTOCOL_VERSION, sign


class HostIntentMixin:
    """Restart-stable host-companion actions on a disjoint sequence space."""

    def emit_local_intent(self, action: Mapping[str, Any]) -> dict[str, Any] | None:
        local_seq = self._allocate_host_local_seq()
        return self._commit(sign({
            "protocol": PROTOCOL_VERSION,
            "session": self.bridge.session,
            "peer": self.bridge.peer,
            "local_seq": local_seq,
            "tick": 0,
            "kind": "intent",
            "payload": {"action": dict(action)},
        }))

    def _allocate_host_local_seq(self) -> int:
        # Negative host sequences stay disjoint from unbounded positive game
        # sequences and survive companion restarts through the audit scan.
        with self.order_lock:
            while (self.bridge.peer, self._next_local_seq) in self.seen:
                self._next_local_seq -= 1
            local_seq = self._next_local_seq
            self._next_local_seq -= 1
            return local_seq
