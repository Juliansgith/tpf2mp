"""Pre-game lobby transport and local content checks, without launching a game."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path
from typing import Any

from . import __version__
from .active_content import _ContentHashCache, _tree_content_digest, resolve_active_mod_root
from .native_mod_table import ActiveContentError, read_active_mods
from .relay_api import RelayApiError, RelayCredentials, _request_json

HASH = re.compile(r"[0-9a-f]{64}")
MOD_ID = re.compile(r"(?:!?[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}|\*[0-9]{1,20})")


def configuration_digest(config: dict) -> str:
    try:
        return hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":"),
                                         ensure_ascii=True, allow_nan=False).encode()).hexdigest()
    except (ValueError, TypeError, RecursionError) as exc:
        raise RelayApiError("invalid lobby configuration") from exc


def selected_content(mods: Any, game: Path, mod_directory: Path) -> list[dict]:
    if not isinstance(mods, list) or not 1 <= len(mods) <= 256:
        raise RelayApiError("select 1-256 mods")
    results, seen, roots = [], set(), set()
    # Fresh hashes at Ready: no stat-only cache may attest changed content.
    cache = _ContentHashCache(None)
    for record in mods:
        if not isinstance(record, dict) or set(record) not in ({"id", "version"}, {"id", "version", "digest"}):
            raise RelayApiError("invalid selected mod fields")
        name, version = record["id"], record["version"]
        if not isinstance(name, str) or MOD_ID.fullmatch(name) is None or name.lstrip("!").casefold() in seen:
            raise RelayApiError("invalid or duplicate selected mod")
        if type(version) is not int or not 0 <= version <= 2147483647:
            raise RelayApiError("invalid selected mod version")
        seen.add(name.lstrip("!").casefold())
        try:
            root, _ = resolve_active_mod_root({"id": name, "majorVersion": version}, game, mod_directory)
            if root in roots:
                raise RelayApiError("two selected mod identities resolve to the same installed content")
            roots.add(root)
            content_hash, count = _tree_content_digest(root, cache)
        except (ActiveContentError, OSError) as exc:
            raise RelayApiError(f"required mod is missing or unreadable: {name}") from exc
        if not count:
            raise RelayApiError(f"required mod has no load-bearing content: {name}")
        results.append({"id": name, "version": version, "digest": content_hash})
    if not {"tpf2_mp", "tpf2_mp_1"}.intersection(seen):
        raise RelayApiError("TPF2MP must be enabled")
    return results


def verify_content(config: dict, game: Path, mod_directory: Path) -> None:
    if not isinstance(config, dict):
        raise RelayApiError("host has not configured a world")
    if config.get("release") != __version__:
        raise RelayApiError("both players must use the lobby's TPF2MP release")
    actual = selected_content(config.get("mods"), game, mod_directory)
    for expected, found in zip(config["mods"], actual):
        if expected != found:
            raise RelayApiError(f"installed files differ for {found['id']}; update that mod on both PCs")


def request(credentials: RelayCredentials, command: dict | None = None) -> dict:
    result = _request_json("GET" if command is None else "POST",
        credentials.relay_url + f"/v1/sessions/{credentials.session_id}/lobby",
        token=credentials.token, payload=command, timeout=10)
    if result.get("schemaVersion") != 1 or result.get("sessionId") != credentials.session_id \
            or result.get("role") != credentials.role or type(result.get("revision")) is not int \
            or not 0 <= result["revision"] <= 2147483647 \
            or result.get("phase") not in {"configuring", "generating", "preparing-save", "save-ready", "failed"}:
        raise RelayApiError("invalid lobby response identity")
    config = result.get("config")
    if config is not None:
        if not isinstance(config, dict) or configuration_digest(config) != result.get("configDigest"):
            raise RelayApiError("invalid lobby configuration digest")
    elif result.get("configDigest") is not None:
        raise RelayApiError("unexpected lobby configuration digest")
    if type(result.get("canStart")) is not bool or not isinstance(result.get("peers"), dict):
        raise RelayApiError("invalid lobby readiness response")
    for role, peer in result["peers"].items():
        if role not in {"host", "join"} or not isinstance(peer, dict) \
                or type(peer.get("ready")) is not bool or type(peer.get("online")) is not bool:
            raise RelayApiError("invalid lobby peer response")
    return result


def save_facts(path: Path) -> tuple[dict, list[dict]]:
    """Read native header and hash the same stable save; never trust a sidecar alone."""
    path = path.resolve(strict=True)
    before = path.stat()
    if not path.is_file() or path.suffix.lower() != ".sav" or not 1 <= before.st_size <= 8 * 1024**3:
        raise RelayApiError("select a native .sav file within the 8 GiB transfer limit")
    try:
        header = read_active_mods(path)
    except ActiveContentError as exc:
        raise RelayApiError("cannot verify the native save's active mod list") from exc
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns, before.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise RelayApiError("save changed during verification; wait until saving finishes")
    return {"sha256": digest.hexdigest(), "bytes": after.st_size}, [
        {"id": item["id"], "version": item["majorVersion"]} for item in header["mods"]]


def check_selection(state: dict, revision: int, digest: str) -> dict:
    """Never mark unseen settings Ready after another player edits the lobby."""
    if type(revision) is not int or state["revision"] != revision \
            or not isinstance(digest, str) or HASH.fullmatch(digest) is None \
            or state.get("configDigest") != digest or state.get("config") is None:
        raise RelayApiError("lobby changed; review the refreshed settings before continuing")
    return state["config"]


def catalogue(game: Path, mod_directory: Path) -> list[dict]:
    """List available folder identities. Do not execute mod.lua for display names."""
    game = game.resolve()
    roots = [(mod_directory.resolve().parent, "local"), (game.parent / "mods", "official"),
             (game.parent / "dlcs", "dlc"),
             (game.parent.parent.parent / "workshop/content/1066780", "workshop")]
    result, seen = [], set()
    for root, kind in roots:
        if not root.is_dir():
            continue
        for path in sorted(root.iterdir()):
            if len(result) >= 2048:
                raise RelayApiError("installed mod catalogue exceeds 2048 entries")
            if not path.is_dir() or not (path / "mod.lua").is_file():
                continue
            match = re.fullmatch(r"(.+)_([0-9]+)", path.name)
            if kind == "workshop" and path.name.isdigit():
                # The folder does not encode a Workshop major version. Do not
                # execute arbitrary mod.lua or silently assume version 1.
                name, version = "*" + path.name, None
            elif match:
                name, version = match[1], int(match[2])
                if kind == "dlc":
                    name = "_" + name
                elif kind == "local":
                    # Native ModRep namespaces user-local mods with '!'. A
                    # filesystem-resolvable alias is not a valid native ID.
                    name = "!" + name
            else:
                continue
            identity = (name.casefold(), version)
            if MOD_ID.fullmatch(name) is None or identity in seen:
                continue
            seen.add(identity)
            result.append({"id": name, "version": version, "source": kind,
                           "selectable": version is not None})
    return result
