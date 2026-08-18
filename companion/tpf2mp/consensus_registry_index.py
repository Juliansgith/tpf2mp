"""Incremental views over append-only consensus tracker registries."""

from __future__ import annotations

import threading
from typing import Any, Mapping


class TrackerRegistryIndex:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._pending: dict[int, dict[str, Any]] = {}
        self._counts: dict[int, dict[str, Any]] = {}

    def pending(
        self, registry: Mapping[int, dict[str, Any]]
    ) -> dict[str, Any] | None:
        items = self.pending_items(registry)
        return items[0] if items else None

    def pending_items(
        self, registry: Mapping[int, dict[str, Any]]
    ) -> list[dict[str, Any]]:
        identity, length = id(registry), len(registry)
        with self._lock:
            cached = self._pending.get(identity)
            if cached and cached["length"] == length:
                keys = [
                    key for key in cached["keys"]
                    if registry.get(key, {}).get("status") == "pending"
                ]
            else:
                keys = [
                    key for key in sorted(registry)
                    if registry[key].get("status") == "pending"
                ]
            self._pending[identity] = {"length": length, "keys": keys}
            return [registry[key] for key in keys]

    def counts(
        self,
        registry: Mapping[int, dict[str, Any]],
        statuses: tuple[str, ...],
    ) -> dict[str, int]:
        identity, length = id(registry), len(registry)
        with self._lock:
            cached = self._counts.get(identity)
            if cached and cached["length"] == length and all(
                registry.get(key, {}).get("status") == "pending"
                for key in cached["pendingKeys"]
            ):
                return dict(cached["values"])
            values = {status: 0 for status in statuses}
            pending_keys: list[int] = []
            for key, tracker in registry.items():
                status = str(tracker.get("status", "pending"))
                if status in values:
                    values[status] += 1
                if status == "pending":
                    pending_keys.append(key)
            self._counts[identity] = {
                "length": length, "pendingKeys": pending_keys, "values": values,
            }
            return dict(values)
