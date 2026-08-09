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
steps = vectors["steps"]
if len(steps) != 256:
    raise SystemExit(f"expected 256 freight stress steps, received {len(steps)}")

action = validate_action(vectors["bootstrap"])
state = new_state()
apply_bootstrap(state, action, {"ready": True, "digest": action["contentDigest"]})
for industry_cid, stocks in vectors["seededOutput"].items():
    for cargo_type, amount in stocks.items():
        state["industries"][industry_cid]["outputStock"][cargo_type] = int(amount)

for step in steps:
    epoch = int(step["epoch"])
    transport = apply_transport(state, step["cargoLines"])
    production = advance(state, epoch, 300)
    if canonical_json(transport) != canonical_json(step["transport"]):
        raise SystemExit(f"freight transport stress summary diverged at epoch {epoch}")
    if canonical_json(production) != canonical_json(step["production"]):
        raise SystemExit(f"freight production stress summary diverged at epoch {epoch}")
    actual_digest = checksum(digest_view(state))
    if actual_digest != step["digest"]:
        raise SystemExit(
            f"freight stress digest diverged at epoch {epoch}: "
            f"{actual_digest} != {step['digest']}"
        )

actual_view = digest_view(state)
if canonical_json(actual_view) != canonical_json(vectors["finalDigestView"]):
    raise SystemExit("freight stress final digest view diverged")
if checksum(actual_view) != vectors["finalDigest"]:
    raise SystemExit("freight stress final digest diverged")
if vectors["idleLineCid"] in state["transportCursors"]:
    raise SystemExit("zero-movement freight line incorrectly acquired a cursor")
for cargo_type in ("GRAIN", "CRUDE", "LOGS"):
    if int(state["totalTransported"].get(cargo_type, 0)) <= 0 \
            or int(state["totalDelivered"].get(cargo_type, 0)) <= 0:
        raise SystemExit(f"freight stress did not move and deliver {cargo_type}")

print(
    f"PASS {len(steps)} cross-language multi-cargo freight stress steps "
    f"at {vectors['finalDigest']}"
)
