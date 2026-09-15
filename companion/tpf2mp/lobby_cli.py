"""Launcher worker commands. Role secrets are read from files, never arguments."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from . import __version__
from .bridge import atomic_write
from .lobby_client import catalogue, check_selection, request, save_facts, selected_content, verify_content
from .relay_api import RelayApiError, read_credentials


def configure_cli(commands: argparse._SubParsersAction) -> None:
    parser = commands.add_parser("relay-lobby", help="verify and update pre-game lobby settings")
    parser.add_argument("operation", choices=("status", "presence", "catalogue", "configure-new",
        "configure-save", "ready", "unready", "start", "save-ready", "cancel", "failed", "generation-request", "generation-verify", "verify-launch",
        "generate", "preview-ready", "preview-download"))
    parser.add_argument("--credentials", type=Path)
    parser.add_argument("--game-executable", type=Path)
    parser.add_argument("--mod-directory", type=Path)
    parser.add_argument("--configuration", type=Path)
    parser.add_argument("--save", type=Path)
    parser.add_argument("--revision", type=int)
    parser.add_argument("--config-digest")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--native-request", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument('--preview-file', type=Path)
    parser.add_argument('--preview-digest')
    parser.add_argument('--generation-id', type=int)
    parser.add_argument("--failure-code", choices=("generation-failed", "save-verification-failed", "launch-failed"))


def require(args: argparse.Namespace, *fields: str) -> None:
    for field in fields:
        if getattr(args, field) is None:
            raise RelayApiError("missing --" + field.replace("_", "-"))


def execute(args: argparse.Namespace) -> dict:
    op = args.operation
    if op == "catalogue":
        require(args, "game_executable", "mod_directory")
        return {"schemaVersion": 1, "mods": catalogue(args.game_executable, args.mod_directory)}
    require(args, "credentials")
    credentials = read_credentials(args.credentials)
    if op == 'preview-download':
        require(args, 'config_digest', 'preview_digest', 'preview_file')
        state = request(credentials, preview=True)
        if state['configDigest'] != args.config_digest or state.get('previewDigest') != args.preview_digest \
                or state['phase'] not in {'preview-ready', 'save-ready'}:
            raise RelayApiError('map preview changed; refresh before viewing')
        from .map_preview import write_bitmap
        write_bitmap(state['preview'], args.preview_file)
        state['preview'].pop('pixels', None)
        return state
    if op in {"status", "presence"}:
        return request(credentials, {"op": "presence"} if op == "presence" else None)
    if op == "verify-launch":
        require(args, "game_executable", "mod_directory", "config_digest", "save")
        state = request(credentials)
        if state["phase"] != "save-ready" or state["configDigest"] != args.config_digest:
            raise RelayApiError("lobby is not ready to launch this configuration")
        verify_content(state["config"], args.game_executable, args.mod_directory)
        facts, mods = save_facts(args.save)
        from .save_metadata import validate_metadata
        validate_metadata(args.save)
        if facts != state.get("save") or selected_content(mods, args.game_executable, args.mod_directory) != state["config"]["mods"]:
            raise RelayApiError("received save differs from the lobby's verified world")
        return state
    if op in {"generation-request", "generation-verify"}:
        from .world_generation import native_request, verify_generated
        require(args, "game_executable", "mod_directory", "config_digest")
        state = request(credentials)
        if credentials.role != "host" or state["phase"] not in {"generating", "preview-generating"} or state["configDigest"] != args.config_digest:
            raise RelayApiError("generation requires the host's locked lobby configuration")
        config = state["config"]
        if op == "generation-request":
            require(args, "native_request")
            if args.native_request.exists():
                raise RelayApiError("refusing to overwrite a native generation request")
            atomic_write(args.native_request, native_request(config, args.game_executable, args.mod_directory).encode("ascii"), durable=True)
            return state
        require(args, "save", "evidence")
        return verify_generated(config, args.save, args.evidence, args.game_executable, args.mod_directory, credentials.session_id)
    require(args, "revision")
    state = request(credentials)
    if state["revision"] != args.revision:
        raise RelayApiError("lobby revision changed; refresh before retrying")
    command = {"op": op, "revision": args.revision}
    if op in {"configure-new", "configure-save", "start", "save-ready", "cancel", "failed", "generate", "preview-ready"} and credentials.role != "host":
        raise RelayApiError("only the host may change world setup")
    if op in {"configure-new", "configure-save", "ready", "start", "save-ready", "generate", "preview-ready"}:
        require(args, "game_executable", "mod_directory")
    if op in {"configure-new", "configure-save"}:
        config = {"release": __version__, "mode": "new", "saveDigest": None, "world": None}
        if op == "configure-new":
            require(args, "configuration")
            with args.configuration.open("rb") as source:
                raw = source.read(128 * 1024 + 1)
            if len(raw) > 128 * 1024:
                raise RelayApiError("world configuration exceeds 128 KiB")
            draft = json.loads(raw.decode("utf-8-sig"))
            if not isinstance(draft, dict) or set(draft) != {"world", "mods"}:
                raise RelayApiError("world configuration must contain only world and mods")
            mods, config["world"] = draft["mods"], draft["world"]
        else:
            require(args, "save")
            facts, mods = save_facts(args.save)
            config.update(mode="existing", saveDigest=facts["sha256"])
        config["mods"] = selected_content(mods, args.game_executable, args.mod_directory)
        command.update(op="configure", config=config)
    elif op in {"ready", "unready", "start", "save-ready", "generate", "preview-ready"}:
        require(args, "config_digest")
        config = check_selection(state, args.revision, args.config_digest)
        command["configDigest"] = args.config_digest
        if state['phase'] == 'preview-ready' and op in {'ready', 'unready', 'start'}:
            require(args, 'preview_digest')
            if args.preview_digest != state.get('previewDigest'):
                raise RelayApiError('map preview changed')
            command['previewDigest'] = args.preview_digest
        if op != "unready":
            verify_content(config, args.game_executable, args.mod_directory)
        if op in {"ready", "unready"}:
            # Hashing a large mod set can take longer than the presence lease.
            # Refresh our lease, but retain the original CAS revision/digest.
            request(credentials, {"op": "presence"})
            command.update(op="ready", ready=op == "ready")
        elif op == 'preview-ready':
            require(args, 'preview_file', 'generation_id', 'evidence')
            if args.generation_id != state.get('generationId'):
                raise RelayApiError('map generation changed')
            from .map_preview import from_file
            from .world_generation import verify_preview
            native_digest = verify_preview(config, args.evidence, args.game_executable, args.mod_directory)
            command.update(generationId=args.generation_id, preview=from_file(args.preview_file), nativeDigest=native_digest)
        elif op == "save-ready":
            require(args, "save")
            if config["mode"] == "new":
                from .world_generation import verify_generated
                require(args, "evidence")
                verify_generated(config, args.save, args.evidence, args.game_executable, args.mod_directory, credentials.session_id)
                if state.get('nativeDigest'):
                    from .world_generation import verify_preview
                    if verify_preview(config, args.evidence, args.game_executable, args.mod_directory) != state['nativeDigest']:
                        raise RelayApiError('final native generation differs from the accepted map preview')
            facts, mods = save_facts(args.save)
            if config["mode"] == "existing" and facts["sha256"] != config["saveDigest"]:
                raise RelayApiError("selected existing save changed after Ready")
            if selected_content(mods, args.game_executable, args.mod_directory) != config["mods"]:
                raise RelayApiError("generated save does not contain the agreed active mods in order")
            command["save"] = facts
    elif op == "cancel":
        command.update(op="failed", code="cancelled")
    elif op == "failed":
        require(args, "failure_code", "config_digest")
        check_selection(state, args.revision, args.config_digest)
        command.update(code=args.failure_code)
    return request(credentials, command, preview=True) if op == 'preview-ready' else request(credentials, command)


def run_cli(args: argparse.Namespace) -> bool:
    if args.command != "relay-lobby":
        return False
    payload = json.dumps(execute(args), sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n"
    if args.output:
        atomic_write(args.output, payload.encode("utf-8"), durable=True)
    else:
        print(payload, end="")
    return True
