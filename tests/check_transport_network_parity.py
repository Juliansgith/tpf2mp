from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(project / "companion"))

from tpf2mp.protocol import checksum  # noqa: E402
from tpf2mp.transport_network import pin_cargo_line, rebuild  # noqa: E402

payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1 or not isinstance(payload.get("vectors"), list):
    raise SystemExit("invalid transport-network parity payload")
for vector in payload["vectors"]:
    state = copy.deepcopy(vector["input"])
    summary = rebuild(state)
    if vector.get("pinLineCid"):
        pin_cargo_line(state, vector["pinLineCid"])
    if checksum(state) != vector["expectedDigest"]:
        raise SystemExit(f'{vector["name"]}: authored network state diverged')
    if checksum(summary) != vector["expectedSummaryDigest"]:
        raise SystemExit(f'{vector["name"]}: route summary diverged')
print(f'PASS {len(payload["vectors"])} cross-language transport-network parity vectors')
