"""Real HTTP lobby integration against the local relay source, not a deployed server.

Run with companion and ../tf2mp-relay/src on PYTHONPATH and aiohttp installed.
This never launches the game or touches installed mods/saves.
"""
from __future__ import annotations

import asyncio
import json
import os
import tempfile
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer
from tpf2mp.cli import parser
from tpf2mp.lobby_cli import execute
from tpf2mp.relay_api import RelayApiError, RelayCredentials, decode_invite, write_credentials
from tpf2mp_relay.app import create_app
from tpf2mp_relay.config import RelayConfig


async def main(root: Path) -> None:
    settings = RelayConfig(database_path=root / "relay.sqlite3", public_base_url="http://127.0.0.1:8765",
        admin_token="test-admin-" + "a" * 40, token_pepper="test-pepper-" + "b" * 40,
        allow_insecure_development=True)
    async with TestClient(TestServer(create_app(settings))) as http:
        created_response = await http.post("/v1/sessions", json={"clientVersion": "0.44.3-alpha", "displayName": "Local lobby test"})
        assert created_response.status == 201
        created = await created_response.json()
        session, join_token = decode_invite(created["joinCode"])
        base_url = str(http.make_url("/")).rstrip("/")
        peer_paths = {}
        for role, token in (("host", created["hostToken"]), ("join", join_token)):
            peer = root / role
            game = peer / "steamapps/common/game/TransportFever2.exe"
            game.parent.mkdir(parents=True)
            game.touch()
            mod = peer / "mods/tpf2_mp_1"
            mod.mkdir(parents=True)
            (mod / "mod.lua").write_text("return {}", encoding="utf-8")
            credentials = peer / "credentials.json"
            write_credentials(credentials, RelayCredentials(base_url, session, role, token))
            peer_paths[role] = (game, mod, credentials)

        async def call(role, op, state=None, extra=()):
            game, mod, credentials = peer_paths[role]
            args = ["relay-lobby", op, "--credentials", str(credentials), "--game-executable", str(game),
                    "--mod-directory", str(mod)]
            if state is not None:
                args += ["--revision", str(state["revision"])]
                if state["configDigest"]:
                    args += ["--config-digest", state["configDigest"]]
            return await asyncio.to_thread(execute, parser().parse_args(args + list(extra)))

        draft = root / "world.json"
        draft.write_text(json.dumps({"mods": [{"id": "tpf2_mp", "version": 1}], "world": {
            "seed": 83921, "size": "medium", "format": "1:1", "climate": "temperate",
            "terrain": {"hilliness": 2, "water": 2, "forest": 3, "canyon": 2, "mesa": 2,
                "ridge": 2, "land": 2, "islands": 3}, "towns": "medium", "industries": "low",
            "industryTarget": "medium", "vehicles": "all", "nameList": "england",
            "environment": "temperate", "nativeDifficulty": "easy", "year": 1950,
            "difficulty": "easy", "agentMode": "skeleton", "townDevelopment": False}}))
        state = await call("host", "presence")
        state = await call("host", "configure-new", state, ("--configuration", str(draft)))
        assert state["revision"] == 1 and state["config"]["world"]["seed"] == 83921
        state = await call("join", "presence")
        assert state["config"]["world"]["difficulty"] == "easy"

        # Actual bytes differ across the two installations: no Ready request.
        join_script = peer_paths["join"][1] / "mod.lua"
        join_script.write_text("return {changed=true}")
        try:
            await call("join", "ready", state)
            raise AssertionError("changed peer content was accepted")
        except RelayApiError as exc:
            assert "installed files differ" in str(exc)
        state = await call("host", "status")
        assert not state["peers"]["join"]["ready"] and not state["canStart"]
        join_script.write_text("return {}", encoding="utf-8")

        state = await call("host", "ready", state)
        state = await call("join", "ready", state)
        assert state["canStart"]
        stale = state
        state = await call("host", "configure-new", state, ("--configuration", str(draft)))
        assert not state["canStart"] and not any(p["ready"] for p in state["peers"].values())
        try:
            await call("host", "start", stale)
            raise AssertionError("stale start was accepted")
        except RelayApiError as exc:
            assert "revision changed" in str(exc)
        state = await call("host", "ready", state)
        state = await call("join", "ready", state)
        state = await call("host", "start", state)
        assert state["phase"] == "generating"
        assert (await call("join", "status"))["configDigest"] == state["configDigest"]
        state = await call("host", "cancel", state)
        assert state["phase"] == "failed" and state["failure"] == "cancelled"
        print("PASS: real HTTP lobby, two installations, fresh content rejection, Ready reset, stale Start, frozen configuration, cancellation")
        print("NOT TESTED: native map generation, save transfer, game startup, desktop UI")


if __name__ == "__main__":
    old = os.environ.get("TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK")
    os.environ["TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK"] = "1"
    try:
        with tempfile.TemporaryDirectory(prefix="tpf2mp-lobby-") as directory:
            asyncio.run(main(Path(directory)))
    finally:
        if old is None:
            os.environ.pop("TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK", None)
        else:
            os.environ["TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK"] = old
