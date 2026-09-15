from __future__ import annotations

import copy
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tpf2mp import __version__
from tpf2mp.cli import parser
from tpf2mp import lobby_client as client, lobby_cli as cli
from tpf2mp.relay_api import RelayApiError, RelayCredentials


class LobbyClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.game = self.root / "steamapps/common/game/TransportFever2.exe"
        self.game.parent.mkdir(parents=True)
        self.game.touch()
        self.mod = self.root / "local/mods/tpf2_mp_1"
        self.mod.mkdir(parents=True)
        self.script = self.mod / "mod.lua"
        self.script.write_text("return 1", encoding="utf-8")
        self.mods = [{"id": "tpf2_mp", "version": 1}]
        self.config = {"mode": "new", "world": {}, "release": __version__, "saveDigest": None,
                       "mods": client.selected_content(self.mods, self.game, self.mod)}
        self.state = {"schemaVersion": 1, "revision": 1, "config": self.config,
            "configDigest": client.configuration_digest(self.config), "phase": "configuring",
            "peers": {}, "canStart": False, "sessionId": "mp-0123456789abcdef", "role": "host"}
        self.credentials = RelayCredentials("https://relay.example.test", self.state["sessionId"], "host", "a" * 43)

    def args(self, op, *extra):
        return parser().parse_args(["relay-lobby", op, "--credentials", "unused.json", "--revision", "1",
            "--game-executable", str(self.game), "--mod-directory", str(self.mod),
            "--config-digest", self.state["configDigest"], *extra])

    def test_ready_hash_detects_equal_size_equal_mtime_change(self):
        client.verify_content(self.config, self.game, self.mod)
        stat = self.script.stat()
        self.script.write_text("return 2", encoding="utf-8")
        os.utime(self.script, ns=(stat.st_atime_ns, stat.st_mtime_ns))
        with self.assertRaisesRegex(RelayApiError, "installed files differ"):
            client.verify_content(self.config, self.game, self.mod)

    def test_failure_report_is_host_only_and_pins_reviewed_configuration(self):
        args = self.args('failed','--failure-code','generation-failed')
        with mock.patch.object(cli,'read_credentials',return_value=self.credentials), \
                mock.patch.object(cli,'request',return_value=self.state) as send:
            cli.execute(args)
            self.assertEqual(send.call_args.args[1],{'op':'failed','revision':1,'code':'generation-failed'})
            args.config_digest = '0'*64
            with self.assertRaisesRegex(RelayApiError,'lobby changed'): cli.execute(args)
        join = RelayCredentials(self.credentials.relay_url,self.credentials.session_id,'join',self.credentials.token)
        with mock.patch.object(cli,'read_credentials',return_value=join), \
                mock.patch.object(cli,'request',return_value=self.state):
            with self.assertRaisesRegex(RelayApiError,'only the host'): cli.execute(self.args('failed','--failure-code','launch-failed'))

    def test_release_and_mod_fields_fail_closed(self):
        self.config["release"] = "0.0.0"
        with self.assertRaisesRegex(RelayApiError, "release"):
            client.verify_content(self.config, self.game, self.mod)
        for mods in ([], [{"id": "../evil", "version": 1}], [{"id": "tpf2_mp", "version": True}],
                     self.mods + [{"id": "!TPF2_MP", "version": 1}]):
            with self.subTest(mods=mods), self.assertRaises(RelayApiError):
                client.selected_content(mods, self.game, self.mod)
        with self.assertRaisesRegex(RelayApiError, "same installed content"):
            client.selected_content(self.mods + [{"id": "tpf2_mp_1", "version": 1}], self.game, self.mod)

    def test_catalogue_does_not_guess_workshop_version(self):
        workshop = self.root / "steamapps/workshop/content/1066780/123"
        workshop.mkdir(parents=True)
        (workshop / "mod.lua").write_text("error('must not execute')")
        result = client.catalogue(self.game, self.mod)
        self.assertIn({"id": "*123", "version": None, "source": "workshop", "selectable": False}, result)
        self.assertIn({"id": "!tpf2_mp", "version": 1, "source": "local", "selectable": True}, result)

    def test_response_identity_digest_and_readiness_checked(self):
        with mock.patch("tpf2mp.lobby_client._request_json", return_value=self.state):
            self.assertEqual(client.request(self.credentials), self.state)
        for change in ({"revision": True}, {"sessionId": "mp-fedcba9876543210"},
                       {"configDigest": "a" * 64}, {"config": {"n": float('nan')}},
                       {"canStart": 1}, {"peers": {"host": {"ready": "true", "online": True}}}):
            state = {**self.state, **change}
            with self.subTest(change=change), mock.patch("tpf2mp.lobby_client._request_json", return_value=state):
                with self.assertRaises(RelayApiError):
                    client.request(self.credentials)

    def test_ready_keeps_reviewed_revision_after_slow_hash(self):
        calls = []
        def request(credentials, command=None):
            calls.append(copy.deepcopy(command))
            return self.state
        with mock.patch.object(cli, "read_credentials", return_value=self.credentials), \
                mock.patch.object(cli, "request", side_effect=request):
            cli.execute(self.args("ready"))
        self.assertEqual(calls, [None, {"op": "presence"}, {"op": "ready", "revision": 1,
            "configDigest": self.state["configDigest"], "ready": True}])

    def test_unseen_config_and_hash_mismatch_never_send_ready(self):
        for changed in (False, True):
            state = {**self.state, "revision": 2} if changed else self.state
            self.script.write_text("return 3")
            with mock.patch.object(cli, "read_credentials", return_value=self.credentials), \
                    mock.patch.object(cli, "request", return_value=state) as transport:
                with self.assertRaises(RelayApiError):
                    cli.execute(self.args("ready"))
                self.assertEqual(transport.call_count, 1)

    def test_configure_hashes_local_mods_not_draft_claim(self):
        draft = self.root / "draft.json"
        draft.write_text(json.dumps({"world": {"seed": 17}, "mods": self.mods}))
        with mock.patch.object(cli, "read_credentials", return_value=self.credentials), \
                mock.patch.object(cli, "request", return_value=self.state) as transport:
            cli.execute(self.args("configure-new", "--configuration", str(draft)))
            config = transport.call_args.args[1]["config"]
            self.assertEqual(config["mods"], self.config["mods"])
            self.assertEqual(config["world"]["seed"], 17)
            self.assertNotIn(str(self.root), json.dumps(config))

    def test_join_cannot_configure_or_start_or_publish_save(self):
        join = RelayCredentials(self.credentials.relay_url, self.credentials.session_id, "join", "b" * 43)
        for op in ("configure-new", "configure-save", "start", "save-ready", "cancel"):
            with self.subTest(op=op), mock.patch.object(cli, "read_credentials", return_value=join), \
                    mock.patch.object(cli, "request", return_value=self.state) as transport:
                with self.assertRaisesRegex(RelayApiError, "only the host"):
                    cli.execute(self.args(op))
                self.assertEqual(transport.call_count, 1)

    def test_save_header_not_sidecar_and_order_enforced(self):
        save = self.root / "generated.sav"
        save.write_bytes(b"not-a-save")
        with self.assertRaises(RelayApiError):
            client.save_facts(save)
        with mock.patch("tpf2mp.lobby_client.read_active_mods", return_value={"mods": [
                {"id": "tpf2_mp", "majorVersion": 1}]}):
            facts, mods = client.save_facts(save)
        self.assertEqual(facts, {"sha256": hashlib.sha256(b"not-a-save").hexdigest(), "bytes": 10})
        self.assertEqual(mods, self.mods)
        with mock.patch.object(cli, "read_credentials", return_value=self.credentials), \
                mock.patch.object(cli, "request", return_value=self.state) as transport, \
                mock.patch.object(cli, "save_facts", return_value=(facts, [{"id": "missing", "version": 1}])):
            with self.assertRaises(RelayApiError):
                cli.execute(self.args("save-ready", "--save", str(save)))
            self.assertEqual(transport.call_count, 1)


if __name__ == "__main__":
    unittest.main()
