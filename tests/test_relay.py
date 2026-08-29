from __future__ import annotations

import base64
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

from tpf2mp.relay_api import (
    RelayApiError,
    RelayCredentials,
    decode_invite,
    read_credentials,
    validate_relay_url,
    websocket_url,
    write_credentials,
)
from tpf2mp.relay_diagnostics import RelayDiagnosticReporter
from tpf2mp.relay_tunnel import LocalEndpoint, RelayTunnel


def invite(session: str, token: str) -> str:
    payload = json.dumps(
        {"s": session, "t": token}, sort_keys=True, separators=(",", ":")
    ).encode("ascii")
    return "TPF2MP1." + base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")


class RelayApiTests(unittest.TestCase):
    def test_invite_and_url_validation_fail_closed(self) -> None:
        session = "mp-0123456789abcdef"
        token = "a" * 43
        self.assertEqual(decode_invite(invite(session, token)), (session, token))
        with self.assertRaises(RelayApiError):
            decode_invite("TPF2MP1.e30")
        with self.assertRaises(RelayApiError):
            validate_relay_url("http://relay.example.test")
        with self.assertRaises(RelayApiError):
            validate_relay_url("https://user:password@relay.example.test")
        self.assertEqual(
            websocket_url("https://relay.example.test", session, "gameplay"),
            "wss://relay.example.test/v1/tunnel/mp-0123456789abcdef/gameplay",
        )

    def test_protected_credential_schema_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "credentials.json"
            expected = RelayCredentials(
                "https://relay.example.test",
                "mp-0123456789abcdef",
                "host",
                "a" * 43,
            )
            write_credentials(path, expected)
            self.assertEqual(read_credentials(path), expected)
            raw = json.loads(path.read_text(encoding="utf-8"))
            raw["extra"] = True
            path.write_text(json.dumps(raw), encoding="utf-8")
            with self.assertRaises(RelayApiError):
                read_credentials(path)


class RelayTunnelTests(unittest.TestCase):
    def test_roles_are_pinned_to_loopback_endpoint_modes(self) -> None:
        host = RelayCredentials(
            "https://relay.example.test", "mp-0123456789abcdef", "host", "a" * 43
        )
        join = RelayCredentials(
            "https://relay.example.test", "mp-0123456789abcdef", "join", "b" * 43
        )
        RelayTunnel(host, {"gameplay": LocalEndpoint("connect", "127.0.0.1", 29742)})
        RelayTunnel(join, {"gameplay": LocalEndpoint("listen", "127.0.0.1", 29742)})
        with self.assertRaises(RelayApiError):
            RelayTunnel(host, {"gameplay": LocalEndpoint("listen", "127.0.0.1", 29742)})
        with self.assertRaises(RelayApiError):
            RelayTunnel(join, {"gameplay": LocalEndpoint("listen", "0.0.0.0", 29742)})

    def test_manifest_fingerprint_is_read_at_connection_time(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            manifest = Path(root) / "match-manifest.json"
            credentials = RelayCredentials(
                "https://relay.example.test",
                "mp-0123456789abcdef",
                "join",
                "b" * 43,
            )
            tunnel = RelayTunnel(
                credentials,
                {"gameplay": LocalEndpoint("listen", "127.0.0.1", 29742)},
                match_manifest_path=manifest,
            )
            self.assertEqual(tunnel._current_fingerprint(), "")
            manifest.write_text(json.dumps({"fingerprint": "c" * 64}), encoding="utf-8")
            self.assertEqual(tunnel._current_fingerprint(), "c" * 64)

    def test_verified_save_channel_completes_once_without_reconnecting(self) -> None:
        credentials = RelayCredentials(
            "https://relay.example.test", "mp-0123456789abcdef", "host", "a" * 43
        )
        endpoint = LocalEndpoint("connect", "127.0.0.1", 29743)
        tunnel = RelayTunnel(credentials, {"save": endpoint})
        local = mock.Mock()
        websocket = mock.Mock()
        tunnel._connect_websocket = mock.Mock(return_value=websocket)
        tunnel._expect_paired = mock.Mock()
        tunnel._connect_local = mock.Mock(return_value=local)
        tunnel._bridge = mock.Mock()

        tunnel._channel_loop("save", endpoint)

        tunnel._connect_websocket.assert_called_once_with("save")
        tunnel._bridge.assert_called_once_with("save", local, websocket)
        self.assertEqual(tunnel.status.channels["save"]["state"], "complete")
        self.assertTrue(tunnel.status.channels["save"]["oneShotComplete"])


class RelayDiagnosticsTests(unittest.TestCase):
    def test_reporter_reads_only_explicit_bounded_sources(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "companion.log"
            status = Path(root) / "status.json"
            log.write_text("first line\nsecond error\n", encoding="utf-8")
            status.write_text(json.dumps({"state": "connected"}), encoding="utf-8")
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef",
                    "host",
                    "a" * 43,
                ),
                {"companion": log, "status": status},
            )
            events, advances = reporter._collect()
            self.assertEqual(len(events), 3)
            self.assertEqual(events[1]["severity"], "error")
            self.assertEqual({item[0].name for item in advances}, {"companion", "status"})
            for cursor, offset, identity, snapshot_hash, critical_hash in advances:
                cursor.offset = offset
                cursor.identity = identity
                cursor.last_snapshot_hash = snapshot_hash
                cursor.last_critical_hash = critical_hash
            self.assertEqual(reporter._collect()[0], [])
            with self.assertRaises(RelayApiError):
                RelayDiagnosticReporter(
                    reporter.credentials, {"save": Path(root) / "world.sav"}
                )

    def test_batch_cap_does_not_skip_unuploaded_lines(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "companion.log"
            log.write_text(
                "".join(f"line-{index:03d}\n" for index in range(200)),
                encoding="utf-8",
            )
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef",
                    "host",
                    "a" * 43,
                ),
                {"companion": log},
            )
            first, advances = reporter._collect()
            self.assertEqual(len(first), 40)
            self.assertEqual(first[-1]["payload"]["message"], "line-039")
            observed = list(first)
            while advances:
                for cursor, offset, identity, snapshot_hash, critical_hash in advances:
                    cursor.offset = offset
                    cursor.identity = identity
                    cursor.last_snapshot_hash = snapshot_hash
                    cursor.last_critical_hash = critical_hash
                batch, advances = reporter._collect()
                observed.extend(batch)
                if not batch:
                    break
            self.assertEqual(len(observed), 200)
            self.assertEqual(observed[40]["payload"]["message"], "line-040")
            self.assertEqual(observed[-1]["payload"]["message"], "line-199")

    def test_rotation_cursor_advances_only_after_upload_acceptance(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "companion.log"
            log.write_text("old\n", encoding="utf-8")
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef",
                    "host",
                    "a" * 43,
                ),
                {"companion": log},
            )
            _, accepted = reporter._collect()
            for cursor, offset, identity, snapshot_hash, critical_hash in accepted:
                cursor.offset = offset
                cursor.identity = identity
                cursor.last_snapshot_hash = snapshot_hash
                cursor.last_critical_hash = critical_hash

            replacement = Path(root) / "replacement.log"
            replacement.write_text("replacement-first\nreplacement-second\n", encoding="utf-8")
            os.replace(replacement, log)
            failed_batch, _ = reporter._collect()
            retry_batch, _ = reporter._collect()
            self.assertEqual(failed_batch, retry_batch)
            self.assertEqual(
                [event["payload"]["message"] for event in retry_batch],
                ["replacement-first", "replacement-second"],
            )

    def test_status_is_sampled_but_fault_transitions_are_immediate(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            status = Path(root) / "status.json"
            status.write_text(
                json.dumps({"status": "connected", "updatedAtUnix": 1}),
                encoding="utf-8",
            )
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef", "host", "a" * 43,
                ),
                {"companion.status": status},
            )
            first, advances = reporter._collect()
            self.assertEqual(len(first), 1)
            cursor, offset, identity, snapshot_hash, critical_hash = advances[0]
            cursor.offset, cursor.identity = offset, identity
            cursor.last_snapshot_hash = snapshot_hash
            cursor.last_critical_hash = critical_hash
            cursor.last_snapshot_emitted_at = time.time()

            status.write_text(
                json.dumps({"status": "connected", "updatedAtUnix": 2}),
                encoding="utf-8",
            )
            self.assertEqual(reporter._collect()[0], [])
            status.write_text(
                json.dumps({"status": "faulted", "updatedAtUnix": 3}),
                encoding="utf-8",
            )
            changed, _ = reporter._collect()
            self.assertEqual(len(changed), 1)

    def test_nested_relay_channel_state_transition_is_immediate(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            status = Path(root) / "relay-status.json"
            status.write_text(json.dumps({
                "channels": {"gameplay": {"state": "paired", "bytesSent": 1}},
                "updatedAtUnix": 1,
            }), encoding="utf-8")
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef", "host", "a" * 43,
                ),
                {"relay.status": status},
            )
            _, advances = reporter._collect()
            cursor, offset, identity, snapshot_hash, critical_hash = advances[0]
            cursor.offset, cursor.identity = offset, identity
            cursor.last_snapshot_hash = snapshot_hash
            cursor.last_critical_hash = critical_hash
            cursor.last_snapshot_emitted_at = time.time()
            status.write_text(json.dumps({
                "channels": {"gameplay": {"state": "retrying", "bytesSent": 1}},
                "updatedAtUnix": 2,
            }), encoding="utf-8")
            changed, _ = reporter._collect()
            self.assertEqual(len(changed), 1)

    def test_game_stdout_keeps_failures_and_discards_routine_engine_noise(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "stdout.txt"
            log.write_text(
                "Loading shader cache\n"
                '[TPF2MP] {"event":"action","success":true}\n'
                '[TPF2MP] {"event":"action","success":false,"error":"boom"}\n',
                encoding="utf-8",
            )
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef", "host", "a" * 43,
                ),
                {"game.stdout": log},
            )
            events, _ = reporter._collect()
            self.assertEqual(len(events), 1)
            self.assertIn('"success":false', events[0]["payload"]["message"])

    def test_secrets_and_local_identity_are_redacted_before_upload(self) -> None:
        with tempfile.TemporaryDirectory() as root:
            log = Path(root) / "companion.log"
            status = Path(root) / "status.json"
            secret = "abcDEF123_-" * 5
            invite_code = invite("mp-0123456789abcdef", "z" * 43)
            log.write_text(
                f"Authorization: Bearer {secret} {invite_code} "
                "C:\\Users\\PrivateName\\save.sav 100.69.37.25 "
                "[fd7a:115c:a1e0::1]\n",
                encoding="utf-8",
            )
            status.write_text(
                json.dumps({"joinToken": secret, "path": "/home/private/save.sav"}),
                encoding="utf-8",
            )
            reporter = RelayDiagnosticReporter(
                RelayCredentials(
                    "https://relay.example.test",
                    "mp-0123456789abcdef",
                    "host",
                    "a" * 43,
                ),
                {"companion": log, "status": status},
            )
            events, _ = reporter._collect()
            rendered = json.dumps(events)
            for forbidden in (
                secret, invite_code, "PrivateName", "100.69.37.25",
                "fd7a:115c:a1e0::1", "/home/private",
            ):
                self.assertNotIn(forbidden, rendered)


if __name__ == "__main__":
    unittest.main()
