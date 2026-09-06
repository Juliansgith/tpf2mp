"""Bounded physical-UI recipe discovery; never accepted as release proof."""
import json
from pathlib import Path
import time
from .schema import validate_suite


def next_case(suite, output, desktop, clock=time.monotonic, sleep=time.sleep):
    seconds = suite.get("calibrationIdleSeconds")
    if not seconds:
        return None
    inbox = Path(output) / "followups"
    inbox.mkdir(exist_ok=True)
    path = inbox / f"{len(suite['cases']) + 1:04d}.json"
    print(f"Calibration waiting up to {seconds}s for {path}; STOP ends cleanly.", flush=True)
    deadline = clock() + seconds
    while clock() < deadline:
        desktop.check("player1"); desktop.check("player2")
        if (inbox / "STOP").exists():
            return None
        if path.exists():
            if path.stat().st_size > 256_000:
                raise ValueError("calibration request exceeds 256 KB")
            # Atomic rename or apply_patch writes are preferred. Incomplete
            # files fail this run, never cause a partial or retried action.
            case = json.loads(path.read_text(encoding="utf-8-sig"))
            candidate = {**suite, "cases": [*suite["cases"], case]}
            validate_suite(candidate)
            if case.get("coverage"):
                raise ValueError("calibration cannot claim coverage labels")
            return case
        sleep(.2)
    return None
