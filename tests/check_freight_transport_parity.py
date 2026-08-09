from __future__ import annotations

import json
import sys
from pathlib import Path

project = Path(sys.argv[1]).resolve()
vector_path = Path(sys.argv[2]).resolve()
sys.path.insert(0, str(project / "companion"))

from tpf2mp.freight import (  # noqa: E402
    advance, apply_bootstrap, apply_transport, digest_view, new_state,
)
from tpf2mp.protocol import canonical_json, checksum, validate_action  # noqa: E402

vectors = json.loads(vector_path.read_text(encoding="utf-8"))
action = validate_action(vectors["bootstrap"])
state = new_state()
apply_bootstrap(state, action, {"ready": True, "digest": action["contentDigest"]})
state["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"] = int(
    vectors["seededOutput"]
)
for step in vectors["steps"]:
    transport = apply_transport(state, step["cargoLines"])
    production = advance(state, int(step["epoch"]), 300)
    actual_view = digest_view(state)
    if canonical_json(transport) != canonical_json(step["transport"]):
        raise SystemExit(f"freight transport summary diverged at epoch {step['epoch']}")
    if canonical_json(production) != canonical_json(step["production"]):
        raise SystemExit(f"freight production summary diverged at epoch {step['epoch']}")
    if canonical_json(actual_view) != canonical_json(step["digestView"]):
        raise SystemExit(f"freight digest view diverged at epoch {step['epoch']}")
    if checksum(actual_view) != step["digest"]:
        raise SystemExit(f"freight digest diverged at epoch {step['epoch']}")
print(f"PASS {len(vectors['steps'])} cross-language freight transport parity steps")
