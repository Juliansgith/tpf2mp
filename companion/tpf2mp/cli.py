from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from .bridge import AuditLog, GameBridge
from .checkpoint import verify_checkpoint, verify_event_record, write_report as write_checkpoint_report
from .manifest import build_manifest, load_manifest, write_manifest
from .network import CommitClient, CommitHost
from .protocol import ProtocolError, validate_envelope
from .recovery import verify_recovery_archive, write_recovery_archive, write_recovery_plan
from .research import write_report


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


def replay(path: Path, session: str | None) -> int:
    commits = 0
    controls = 0
    records = 0
    expected = 1
    commit_sequences: list[int] = []
    peers: set[str] = set()
    acknowledgements: dict[int, dict[str, str]] = {}
    proposal_commits: dict[int, dict[str, Any]] = {}
    proposal_completions: dict[int, dict[str, dict[str, Any]]] = {}
    proposal_outcomes: dict[int, dict[str, Any]] = {}
    checkpoint_records: dict[int, dict[str, dict[str, Any]]] = {}
    checkpoint_outcomes: dict[int, dict[str, Any]] = {}
    checkpoint_expected_boundaries: set[int] = set()
    checkpoint_chains: dict[str, dict[str, Any]] = {}
    checkpoints = event_records = replayed_events = 0
    for message in AuditLog(path).messages():
        selected_session = session or str(message.get("session", ""))
        validate_envelope(message, selected_session)
        if session and message.get("session") != session:
            continue
        if message.get("kind") in {"commit", "control"}:
            seq = int(message["seq"])
            if seq != expected:
                raise ProtocolError(f"ordered message sequence gap: expected {expected}, found {seq}")
            expected += 1
            action = message.get("payload", {}).get("action", {})
            if message.get("kind") == "commit":
                commits += 1
                commit_sequences.append(seq)
                peers.add(str(message.get("origin_peer")))
                if action.get("type") == "proposal.build":
                    proposal_commits[seq] = {
                        "proposalId": f"{message.get('session')}:{message.get('origin_peer')}:{seq}",
                        "proposalDigest": action.get("transaction", {}).get("digest"),
                    }
                elif action.get("type") == "match.initialise":
                    checkpoint_expected_boundaries.add(seq)
            else:
                controls += 1
                if action.get("type") == "network.proposal_outcome":
                    commit_seq = int(action.get("commitSeq", 0))
                    if commit_seq not in proposal_commits:
                        raise ProtocolError("proposal outcome references an unknown proposal commit")
                    proposal_outcomes[commit_seq] = dict(action)
                    if action.get("success") is True:
                        checkpoint_expected_boundaries.add(seq)
                elif action.get("type") == "network.checkpoint_outcome":
                    boundary_seq = int(action.get("boundarySeq", 0))
                    if boundary_seq < 1 or boundary_seq >= seq:
                        raise ProtocolError("checkpoint outcome references an invalid ordered boundary")
                    checkpoint_outcomes[boundary_seq] = dict(action)
        else:
            records += 1
            if message.get("kind") == "record" and message.get("record_type") == "ack":
                payload = message.get("payload", {})
                commit_seq = int(payload.get("commitSeq", 0))
                digest = payload.get("digest")
                peer = str(message.get("peer", "unknown"))
                if commit_seq > 0 and isinstance(digest, str):
                    acknowledgements.setdefault(commit_seq, {})[peer] = digest
            elif message.get("kind") == "record" and message.get("record_type") == "completion":
                payload = CommitHost._completion_payload(message.get("payload", {}))
                commit_seq = int(payload["commitSeq"])
                peer = str(message.get("peer", "unknown"))
                proposal_completions.setdefault(commit_seq, {})[peer] = payload
            elif message.get("kind") == "record" and message.get("record_type") == "checkpoint":
                payload = verify_checkpoint(message.get("payload", {}))
                peer = str(message.get("peer", "unknown"))
                boundary_seq = int(payload["eventCursor"]["lastCommitSeq"])
                checkpoint_records.setdefault(boundary_seq, {})[peer] = payload
                checkpoint_chains[peer] = {
                    "core": payload["coreDigest"],
                    "model": payload["modelDigest"],
                    "event": int(payload["eventCursor"]["lastEventSeq"]),
                }
                checkpoints += 1
            elif message.get("kind") == "record" and message.get("record_type") == "event":
                payload = verify_event_record(message.get("payload", {}))
                event_records += 1
                peer = str(message.get("peer", "unknown"))
                chain = checkpoint_chains.get(peer)
                if chain:
                    event_seq = int(payload["localEventSeq"])
                    if event_seq != chain["event"] + 1:
                        raise ProtocolError(
                            f"checkpoint event gap for {peer}: expected {chain['event'] + 1}, found {event_seq}"
                        )
                    if payload["preDigest"] != chain["core"] or payload["preModelDigest"] != chain["model"]:
                        raise ProtocolError(f"checkpoint digest discontinuity for {peer} at event {event_seq}")
                    chain.update(core=payload["postDigest"], model=payload["postModelDigest"], event=event_seq)
                    replayed_events += 1
    converged, incomplete = 0, 0
    for seq in commit_sequences:
        values = acknowledgements.get(seq, {})
        unique = set(values.values())
        if len(unique) > 1:
            raise ProtocolError(f"digest divergence at commit {seq}: {values}")
        if len(values) >= 2:
            converged += 1
        else:
            incomplete += 1
    physical_complete = physical_faulted = physical_pending = 0
    for commit_seq, proposal in proposal_commits.items():
        outcome = proposal_outcomes.get(commit_seq)
        if not outcome:
            physical_pending += 1
            continue
        completions = proposal_completions.get(commit_seq, {})
        required = set(outcome.get("peers", []))
        if outcome.get("proposalId") != proposal["proposalId"]:
            raise ProtocolError(f"proposal outcome identity mismatch at commit {commit_seq}")
        if outcome.get("proposalDigest") != proposal["proposalDigest"]:
            raise ProtocolError(f"proposal outcome digest mismatch at commit {commit_seq}")
        if outcome.get("success"):
            if not required or not required <= set(completions):
                raise ProtocolError(f"successful proposal outcome lacks peer completions at commit {commit_seq}")
            selected = [completions[peer] for peer in sorted(required)]
            if any(item.get("success") is not True for item in selected):
                raise ProtocolError(f"successful proposal outcome contains a failed peer at commit {commit_seq}")
            if len({item["resultDigest"] for item in selected}) != 1:
                raise ProtocolError(f"physical result divergence at commit {commit_seq}")
            if len({item["coreDigest"] for item in selected}) != 1:
                raise ProtocolError(f"physical core divergence at commit {commit_seq}")
            physical_complete += 1
        else:
            physical_faulted += 1
    checkpoint_complete = checkpoint_faulted = checkpoint_pending = 0
    for boundary_seq in sorted(checkpoint_expected_boundaries):
        outcome = checkpoint_outcomes.get(boundary_seq)
        if not outcome:
            checkpoint_pending += 1
            continue
        if outcome.get("success") is not True:
            checkpoint_faulted += 1
            continue
        records_at_boundary = checkpoint_records.get(boundary_seq, {})
        required = set(outcome.get("peers", []))
        if not required or not required <= set(records_at_boundary):
            raise ProtocolError(
                f"successful checkpoint outcome lacks peer records at boundary {boundary_seq}"
            )
        selected = [records_at_boundary[peer] for peer in sorted(required)]
        if any(item.get("convergenceKey") != outcome.get("convergenceKey") for item in selected):
            raise ProtocolError(f"checkpoint convergence mismatch at boundary {boundary_seq}")
        for field in ("coreDigest", "modelDigest", "canonicalDigest", "financialDigest"):
            if any(item.get(field) != outcome.get(field) for item in selected):
                raise ProtocolError(f"checkpoint {field} mismatch at boundary {boundary_seq}")
        checkpoint_complete += 1
    print(
        f"audit valid: {commits} commits, {controls} controls, {records} telemetry records, "
        f"{converged} converged, {incomplete} awaiting peer digests, "
        f"physical proposals complete/faulted/pending={physical_complete}/{physical_faulted}/{physical_pending}, "
        f"checkpoint barriers complete/faulted/pending={checkpoint_complete}/{checkpoint_faulted}/{checkpoint_pending}, "
        f"{checkpoints} checkpoints, {event_records} event records ({replayed_events} chained), peers={sorted(peers)}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "host":
            bridge_path = args.bridge or default_bridge(args.peer)
            game_bridge = GameBridge(bridge_path, args.session, args.peer)
            audit = args.audit or (game_bridge.audit_dir / f"{args.session}.ndjson")
            fingerprint = load_manifest(args.manifest)["fingerprint"] if args.manifest else None
            CommitHost(
                game_bridge,
                args.bind,
                args.port,
                audit,
                fingerprint,
                required_peers=tuple(args.required_peer) if args.required_peer else None,
                completion_timeout=args.completion_timeout,
            ).run()
        elif args.command == "client":
            bridge_path = args.bridge or default_bridge(args.peer)
            fingerprint = load_manifest(args.manifest)["fingerprint"] if args.manifest else None
            CommitClient(GameBridge(bridge_path, args.session, args.peer), args.host, args.port, fingerprint).run()
        elif args.command == "replay":
            return replay(args.audit, args.session)
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
