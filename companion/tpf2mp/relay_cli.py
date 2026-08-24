from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from .bridge import atomic_write
from .protocol import ProtocolError
from .relay_api import (
    RelayCredentials,
    close_session,
    create_session,
    decode_invite,
    read_credentials,
    write_credentials,
)
from .relay_diagnostics import RelayDiagnosticReporter
from .relay_tunnel import LocalEndpoint, RelayTunnel


COMMANDS = {
    "relay-session-create",
    "relay-invite-accept",
    "relay-tunnel",
    "relay-diagnostics",
    "relay-session-close",
}


def configure_cli(commands: argparse._SubParsersAction) -> None:
    create = commands.add_parser(
        "relay-session-create",
        help="create a secure relay session without printing its credentials",
    )
    create.add_argument("--relay-url", required=True)
    create.add_argument("--display-name", default="TPF2MP match")
    create.add_argument("--credentials", type=Path, required=True)
    create.add_argument("--invite-receipt", type=Path, required=True)
    create.add_argument("--allow-insecure-loopback", action="store_true")

    join = commands.add_parser(
        "relay-invite-accept",
        help="turn a protected join-code file into a protected role credential",
    )
    join.add_argument("--relay-url", required=True)
    join.add_argument("--invite-file", type=Path, required=True)
    join.add_argument("--credentials", type=Path, required=True)
    join.add_argument("--allow-insecure-loopback", action="store_true")

    tunnel = commands.add_parser(
        "relay-tunnel", help="bridge loopback TCP services through authenticated WSS"
    )
    tunnel.add_argument("--credentials", type=Path, required=True)
    tunnel.add_argument("--match-fingerprint", default="")
    tunnel.add_argument("--match-manifest", type=Path)
    tunnel.add_argument("--gameplay-port", type=int)
    tunnel.add_argument("--save-port", type=int)
    tunnel.add_argument("--status", type=Path)

    diagnostics = commands.add_parser(
        "relay-diagnostics", help="upload bounded structured session diagnostics"
    )
    diagnostics.add_argument("--credentials", type=Path, required=True)
    diagnostics.add_argument(
        "--source", action="append", default=[], metavar="NAME=PATH"
    )
    diagnostics.add_argument("--status", type=Path)
    diagnostics.add_argument("--interval", type=float, default=2.0)

    close = commands.add_parser(
        "relay-session-close", help="close a host-owned relay session"
    )
    close.add_argument("--credentials", type=Path, required=True)


def run_cli(args: argparse.Namespace) -> bool:
    if args.command not in COMMANDS:
        return False
    if args.command == "relay-session-create":
        created = create_session(
            args.relay_url,
            display_name=args.display_name,
            access_token=os.environ.get("TPF2MP_RELAY_CREATE_ACCESS_TOKEN"),
            allow_insecure_loopback=args.allow_insecure_loopback,
        )
        credentials = write_credentials(
            args.credentials,
            RelayCredentials(
                created["relayUrl"], created["sessionId"], "host",
                created["hostToken"],
            ),
        )
        invite_receipt = {
            "schemaVersion": 1,
            "relayUrl": created["relayUrl"],
            "sessionId": created["sessionId"],
            "supportId": created["supportId"],
            "joinCode": created["joinCode"],
            "expiresAt": created["expiresAt"],
            "credentialsPath": str(credentials),
        }
        args.invite_receipt.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(
            args.invite_receipt,
            (json.dumps(invite_receipt, sort_keys=True, separators=(",", ":")) + "\n")
            .encode("utf-8"),
            durable=True,
        )
        try:
            os.chmod(args.invite_receipt, 0o600)
        except OSError:
            pass
        print(f"relay_session_created={created['sessionId']}")
        print(f"relay_credentials={credentials}")
        print(f"relay_invite_receipt={args.invite_receipt.resolve()}")
    elif args.command == "relay-invite-accept":
        invite = args.invite_file.read_text(encoding="utf-8-sig").strip()
        session_id, token = decode_invite(invite)
        credentials = write_credentials(
            args.credentials,
            RelayCredentials(args.relay_url, session_id, "join", token),
        )
        print(f"relay_session_joined={session_id}")
        print(f"relay_credentials={credentials}")
    elif args.command == "relay-tunnel":
        credentials = read_credentials(args.credentials)
        endpoints: dict[str, LocalEndpoint] = {}
        mode = "connect" if credentials.role == "host" else "listen"
        if args.gameplay_port is not None:
            endpoints["gameplay"] = LocalEndpoint(
                mode, "127.0.0.1", args.gameplay_port
            )
        if args.save_port is not None:
            endpoints["save"] = LocalEndpoint(mode, "127.0.0.1", args.save_port)
        RelayTunnel(
            credentials,
            endpoints,
            match_fingerprint=args.match_fingerprint,
            match_manifest_path=args.match_manifest,
            status_path=args.status,
        ).run()
    elif args.command == "relay-diagnostics":
        credentials = read_credentials(args.credentials)
        sources: dict[str, Path] = {}
        for item in args.source:
            name, separator, path = item.partition("=")
            if not separator or not name or not path or name in sources:
                raise ProtocolError("relay diagnostic source must be unique NAME=PATH")
            sources[name] = Path(path)
        RelayDiagnosticReporter(
            credentials,
            sources,
            status_path=args.status,
            interval_seconds=args.interval,
        ).run()
    else:
        credentials = read_credentials(args.credentials)
        close_session(credentials)
        print(f"relay_session_closed={credentials.session_id}")
    return True
