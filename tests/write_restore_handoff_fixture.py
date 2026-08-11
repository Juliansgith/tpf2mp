from __future__ import annotations

import argparse
import json
from pathlib import Path

from tpf2mp.bridge import atomic_write
from tpf2mp.native_save import hash_load_bearing_save
from tpf2mp.protocol import canonical_json, sign
from tpf2mp.session_identity import derive_resume_session


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--session", required=True)
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=True)
    save = root / "player2.sav"
    save.write_bytes(b"synthetic-player2-receipt-bound-world")
    Path(str(save) + ".lua").write_text(
        "return { syntheticBoundary = 9 }", encoding="utf-8"
    )
    hashes = hash_load_bearing_save(save)
    boundary = 9
    attestation = {
        "saveSha256": hashes["saveSha256"],
        "metadataSha256": hashes["metadataSha256"],
        "savedAtUnix": 1_786_294_800,
        "receiptCommitSeq": 11,
        "boundarySeq": boundary,
        "coreDigest": "synthetic-core-9",
        "convergenceKey": "synthetic-key-9",
    }
    plan = sign({
        "format": "tpf2mp-restore-plan",
        "version": 6,
        "protocol": 1,
        "session": args.session,
        "resumeSession": derive_resume_session(args.session, boundary),
        "generatedAtUtc": "2026-08-09T18:00:00+00:00",
        "boundarySeq": boundary,
        "convergenceKey": "synthetic-key-9",
        "coreDigest": "synthetic-core-9",
        "requiredPeers": ["player1", "player2"],
        "peerSaves": {
            "player1": {
                **attestation,
                "saveSha256": "a" * 64,
                "metadataSha256": "b" * 64,
                "receiptCommitSeq": 10,
            },
            "player2": attestation,
        },
        "matchContentProfile": {
            "schemaVersion": 1,
            "agentMode": "skeleton",
            "townDevelopment": False,
        },
        "vehiclePhaseProof": {
            "schemaVersion": 1,
            "sampleKeys": [
                f"{args.session}:player1:7", f"{args.session}:player1:8",
            ],
            "vehiclePhaseDigest": "4567def0",
            "vehicleRounds": [],
        },
        "steps": ["restore both peer-local saves"],
    })
    plan_path = root / "host-restore-plan.json"
    atomic_write(plan_path, (canonical_json(plan) + "\n").encode("utf-8"))
    print(json.dumps({"planPath": str(plan_path), "savePath": str(save)}))


if __name__ == "__main__":
    main()
