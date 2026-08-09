from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from .audit_replay import replay
from .bridge import GameBridge
from .checkpoint import write_report as write_checkpoint_report
from .freight_live_report import configure_cli as configure_freight_live_cli
from .freight_live_report import run_cli as run_freight_live_cli
from .manifest import build_manifest, load_manifest, write_manifest
from .network import CommitClient, CommitHost
from .passenger_feeder_live_report import (
    configure_cli as configure_passenger_feeder_live_cli,
)
from .passenger_feeder_live_report import run_cli as run_passenger_feeder_live_cli
from .protocol import ProtocolError
from .recovery import verify_recovery_archive, write_recovery_archive, write_recovery_plan
from .research import write_report
from .restore import confirm_restore_readiness, verify_restore_plan, write_restore_plan


def default_bridge(peer: str) -> Path:
    return Path(os.environ.get("TEMP", ".")) / "tpf2mp_bridge" / peer


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="TPF2MP deterministic commit-ordering companion")
    commands = result.add_subparsers(dest="command", required=True)

    host = commands.add_parser("host", help="run the authoritative commit sequencer")
    host.add_argument("--bind", default="127.0.0.1")
    host.add_argument("--port", type=int, default=29742)
    host.add_argument("--peer", default="player1")
    host.add_argument("--session", default="local-dev")
    host.add_argument("--bridge", type=Path)
    host.add_argument("--audit", type=Path)
    host.add_argument("--manifest", type=Path)
    host.add_argument("--restore-plan", type=Path)
    host.add_argument("--required-peer", action="append", default=None,
                      help="pin a required physical-consensus peer (repeatable; defaults to player1/player2)")
    host.add_argument(
        "--completion-timeout",
        type=float,
        default=45.0,
        help="seconds allowed for physical completion or checkpoint consensus",
    )

    client = commands.add_parser("client", help="connect a game instance to a host")
    client.add_argument("host")
    client.add_argument("--port", type=int, default=29742)
    client.add_argument("--peer", default="player2")
    client.add_argument("--session", default="local-dev")
    client.add_argument("--bridge", type=Path)
    client.add_argument("--manifest", type=Path)

    replay = commands.add_parser("replay", help="verify and summarize an audit log")
    replay.add_argument("audit", type=Path)
    replay.add_argument("--session")

    configure_freight_live_cli(commands)
    configure_passenger_feeder_live_cli(commands)

    inspect = commands.add_parser("inspect", help="show bridge cursor and queue state")
    inspect.add_argument("--peer", default="player1")
    inspect.add_argument("--session", default="local-dev")
    inspect.add_argument("--bridge", type=Path)

    fingerprint = commands.add_parser("fingerprint", help="build a pinned match-content manifest")
    fingerprint.add_argument("--game-exe", type=Path, required=True)
    fingerprint.add_argument("--mod-dir", type=Path, required=True)
    fingerprint.add_argument("--companion-dir", type=Path, required=True)
    fingerprint.add_argument("--save", type=Path)
    fingerprint.add_argument("--extra", type=Path, action="append", default=[])
    fingerprint.add_argument("--output", type=Path, required=True)

    research = commands.add_parser("research-report", help="render the latest in-game research export as Markdown")
    research.add_argument("--peer", default="player1")
    research.add_argument("--session", default="local-dev")
    research.add_argument("--bridge", type=Path)
    research.add_argument("--output", type=Path, required=True)

    checkpoint = commands.add_parser(
        "checkpoint-report", help="verify a checkpoint, its event hash chain, and deterministic model replay"
    )
    checkpoint.add_argument("--peer", default="player1")
    checkpoint.add_argument("--session", default="local-dev")
    checkpoint.add_argument("--bridge", type=Path)
    checkpoint.add_argument("--anchor", choices=("first", "latest"), default="latest")
    checkpoint.add_argument("--output", type=Path, required=True)

    recovery = commands.add_parser(
        "recovery-plan", help="create a checksummed restart plan from the latest agreed peer checkpoint"
    )
    recovery.add_argument("audit", type=Path)
    recovery.add_argument("--session")
    recovery.add_argument("--output", type=Path, required=True)

    restore = commands.add_parser(
        "restore-plan", help="create a receipt-bound plan for a fully saved all-peer boundary"
    )
    restore.add_argument("audit", type=Path)
    restore.add_argument("--session")
    restore.add_argument("--boundary", type=int)
    restore_policy = restore.add_mutually_exclusive_group(required=True)
    restore_policy.add_argument(
        "--match-profile", type=Path,
        help="bind the exact match-content profile used by the source session",
    )
    restore_policy.add_argument(
        "--allow-legacy-unbound", action="store_true",
        help="explicitly generate a policy-unbound v2 plan for an old session",
    )
    restore.add_argument("--output", type=Path, required=True)

    verify_restore = commands.add_parser(
        "verify-restore-plan", help="verify a receipt-bound plan and re-hash every peer save"
    )
    verify_restore.add_argument("plan", type=Path)
    verify_restore.add_argument(
        "--save", action="append", default=[], metavar="PEER=PATH",
        help="peer save to verify; repeat once for every required peer",
    )
    verify_restore.add_argument(
        "--metadata-only", action="store_true",
        help="verify the checksummed plan without claiming its save files are present",
    )
    verify_restore_save = commands.add_parser(
        "verify-restore-save", help="verify this peer's save against a receipt-bound plan"
    )
    verify_restore_save.add_argument("plan", type=Path)
    verify_restore_save.add_argument("--peer", required=True)
    verify_restore_save.add_argument("--save", type=Path, required=True)

    archive = commands.add_parser(
        "archive-save", help="copy and attest a complete native save triplet for recovery"
    )
    archive.add_argument("save", type=Path)
    archive.add_argument("--session", required=True)
    archive.add_argument("--peer", choices=("player1", "player2"), required=True)
    archive.add_argument("--output-dir", type=Path, required=True)
    archive.add_argument("--recovery-plan", type=Path)

    verify_archive = commands.add_parser(
        "verify-recovery-archive", help="verify a signed recovery archive and every native file"
    )
    verify_archive.add_argument("manifest", type=Path)
    verify_archive.add_argument("--archive-dir", type=Path)
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "host":
            bridge_path = args.bridge or default_bridge(args.peer)
            game_bridge = GameBridge(bridge_path, args.session, args.peer)
            audit = args.audit or (game_bridge.audit_dir / f"{args.session}.ndjson")
            fingerprint = load_manifest(args.manifest)["fingerprint"] if args.manifest else None
            restore_plan = verify_restore_plan(json.loads(
                args.restore_plan.read_text(encoding="utf-8-sig")
            )) if args.restore_plan else None
            CommitHost(
                game_bridge,
                args.bind,
                args.port,
                audit,
                fingerprint,
                required_peers=tuple(args.required_peer) if args.required_peer else None,
                completion_timeout=args.completion_timeout,
                restore_plan=restore_plan,
            ).run()
        elif args.command == "client":
            bridge_path = args.bridge or default_bridge(args.peer)
            fingerprint = load_manifest(args.manifest)["fingerprint"] if args.manifest else None
            CommitClient(GameBridge(bridge_path, args.session, args.peer), args.host, args.port, fingerprint).run()
        elif args.command == "replay":
            return replay(args.audit, args.session)
        elif args.command == "freight-live-report":
            return run_freight_live_cli(args, replay)
        elif args.command == "passenger-feeder-live-report":
            return run_passenger_feeder_live_cli(args, replay)
        elif args.command == "inspect":
            bridge_path = args.bridge or default_bridge(args.peer)
            game_bridge = GameBridge(bridge_path, args.session, args.peer)
            pending = list(game_bridge.pending_outbound())
            commits = game_bridge.existing_commit_sequences()
            print(f"bridge={game_bridge.root}")
            print(f"outbox_cursor={game_bridge.outbox_cursor} pending_outbox={len(pending)}")
            print(f"inbox_commits={len(commits)} highest={max(commits) if commits else 0}")
        elif args.command == "fingerprint":
            manifest = build_manifest(
                args.game_exe,
                args.mod_dir,
                args.companion_dir,
                save_file=args.save,
                extras=args.extra,
            )
            write_manifest(args.output, manifest)
            print(f"manifest={args.output.resolve()}")
            print(f"fingerprint={manifest['fingerprint']}")
        elif args.command == "research-report":
            bridge_path = args.bridge or default_bridge(args.peer)
            report = write_report(bridge_path, args.session, args.output)
            print(f"research_report={args.output.resolve()}")
            print(f"structural_digest={report.get('structural', {}).get('digest', 'unknown')}")
        elif args.command == "checkpoint-report":
            bridge_path = args.bridge or default_bridge(args.peer)
            report = write_checkpoint_report(
                bridge_path, args.session, args.output, peer=args.peer, anchor=args.anchor
            )
            print(f"checkpoint_report={args.output.resolve()}")
            print(f"model_replay={report['modelReplay']['status']}")
            print(f"events_verified={report['eventsVerified']}")
            print(f"final_model_digest={report['finalModelDigest']}")
        elif args.command == "recovery-plan":
            plan = write_recovery_plan(args.audit, args.output, args.session)
            print(f"recovery_plan={args.output.resolve()}")
            print(f"resume_session={plan['resumeSession']}")
            print(f"checkpoint_boundary={plan['anchor']['boundarySeq']}")
            print(f"convergence_key={plan['anchor']['convergenceKey']}")
        elif args.command == "restore-plan":
            match_profile = json.loads(
                args.match_profile.read_text(encoding="utf-8-sig")
            ) if args.match_profile else None
            plan = write_restore_plan(
                args.audit, args.output, args.session, args.boundary, match_profile,
            )
            print(f"restore_plan={args.output.resolve()}")
            print(f"restore_plan_version={plan['version']}")
            print(f"resume_session={plan['resumeSession']}")
            print(f"checkpoint_boundary={plan['boundarySeq']}")
            print(f"convergence_key={plan['convergenceKey']}")
        elif args.command == "verify-restore-plan":
            plan = verify_restore_plan(json.loads(args.plan.read_text(encoding="utf-8-sig")))
            if args.metadata_only:
                if args.save:
                    raise ProtocolError("--metadata-only cannot be combined with --save")
                print(f"restore_plan_valid={args.plan.resolve()}")
                print(f"restore_plan_version={plan['version']}")
                print(f"resume_session={plan['resumeSession']}")
                print(f"checkpoint_boundary={plan['boundarySeq']}")
                return 0
            peer_saves: dict[str, Path] = {}
            for item in args.save:
                peer, separator, value = item.partition("=")
                if not separator or not peer or not value or peer in peer_saves:
                    raise ProtocolError("--save must be a unique PEER=PATH mapping")
                peer_saves[peer] = Path(value)
            readiness = confirm_restore_readiness(plan, peer_saves)
            if not readiness["ready"]:
                raise ProtocolError("restore is not ready: " + "; ".join(readiness["problems"]))
            print(f"restore_plan_valid={args.plan.resolve()}")
            print(f"resume_session={readiness['resumeSession']}")
            print(f"checkpoint_boundary={readiness['boundarySeq']}")
        elif args.command == "verify-restore-save":
            plan = verify_restore_plan(json.loads(args.plan.read_text(encoding="utf-8-sig")))
            if args.peer not in plan["requiredPeers"]:
                raise ProtocolError("restore peer is not in the plan roster")
            readiness = confirm_restore_readiness(plan, {args.peer: args.save})
            peer = readiness["peers"][args.peer]
            if peer.get("ok") is not True:
                raise ProtocolError(f"{args.peer} restore save does not match its attestation")
            print(f"restore_save_valid={Path(peer['path']).resolve()}")
            print(f"peer={args.peer}")
            print(f"resume_session={readiness['resumeSession']}")
        elif args.command == "archive-save":
            recovery_plan = None
            if args.recovery_plan:
                recovery_plan = json.loads(args.recovery_plan.read_text(encoding="utf-8-sig"))
            manifest = write_recovery_archive(
                args.save, args.output_dir, args.session, args.peer, recovery_plan
            )
            print(f"recovery_archive={args.output_dir.resolve()}")
            print(f"archive_manifest={(args.output_dir / 'archive-manifest.json').resolve()}")
            print(f"association={manifest['association']}")
        elif args.command == "verify-recovery-archive":
            manifest = json.loads(args.manifest.read_text(encoding="utf-8-sig"))
            archive_directory = args.archive_dir or args.manifest.parent
            verified = verify_recovery_archive(manifest, archive_directory)
            print(f"recovery_archive_valid={Path(archive_directory).resolve()}")
            print(f"association={verified['association']}")
        return 0
    except (OSError, ProtocolError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
