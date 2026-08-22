"""Small metadata-keyed index for immutable-ish companion queue directories."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


class JsonFileIndex:
    def __init__(self, directory: Path) -> None:
        self.directory = directory
        self._directory_stamp: int | None = None
        self._paths: tuple[Path, ...] = ()
        self._values: dict[Path, tuple[tuple[int, int], Any]] = {}
        self.path_scans = 0
        self.file_reads = 0

    def paths(self) -> tuple[Path, ...]:
        try:
            stamp = self.directory.stat().st_mtime_ns
        except OSError:
            stamp = None
        if stamp != self._directory_stamp:
            self._paths = tuple(sorted(self.directory.glob("*.json")))
            self._directory_stamp = stamp
            self.path_scans += 1
            live = set(self._paths)
            self._values = {path: value for path, value in self._values.items() if path in live}
        return self._paths

    def read(self, path: Path, *, encoding: str = "utf-8") -> Any:
        stat = path.stat()
        signature = (stat.st_mtime_ns, stat.st_size)
        cached = self._values.get(path)
        if cached is not None and cached[0] == signature:
            return cached[1]
        value = json.loads(path.read_text(encoding=encoding))
        self._values[path] = (signature, value)
        self.file_reads += 1
        return value

    def invalidate(self, path: Path | None = None) -> None:
        self._directory_stamp = None
        if path is None:
            self._values.clear()
        else:
            self._values.pop(path, None)
