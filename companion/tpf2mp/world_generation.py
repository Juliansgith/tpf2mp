"""Data-only native generator contract and proof of a completed disposable world."""
from __future__ import annotations

import json
import hashlib
import re
from pathlib import Path

from .lobby_client import configuration_digest, save_facts, selected_content, verify_content
from .native_mod_table import read_active_mods
from .relay_api import RelayApiError
from .save_metadata import validate_metadata
from .save_sync import build_save_sync_manifest


def verify_preview(config: dict, evidence: Path, game: Path, mod: Path) -> str:
    """Bind native pre-world rendering to the exact selected configuration."""
    encoded = native_request(config, game, mod).encode('ascii')
    report = json.loads((evidence / 'report.json').read_text(encoding='utf-8-sig'))
    if report.get('complete') is not True or report.get('exitCode') != 0 \
            or report.get('requestSha256') != hashlib.sha256(encoded).hexdigest() \
            or (evidence / 'native-request.txt').read_bytes() != encoded:
        raise RelayApiError('preview evidence belongs to an incomplete or different generation')
    events = [json.loads(line) for line in (evidence / 'native.jsonl').read_text().splitlines()]
    names = {e.get('event') for e in events}
    dimension = {'small': 32, 'medium': 44, 'large': 56}[config['world']['size']]
    hilliness = encoded.decode('ascii').splitlines()[1].split()[3]
    if not {'native-preview-ready', 'generator-resource-temperate.gen.lua',
            f"native-seed={config['world']['seed']}", f'configured-dimensions-{dimension}x{dimension}',
            f'native-terrain-hilliness={hilliness}', 'native-terrain-water=0', 'native-terrain-forest=2'} <= names:
        raise RelayApiError('native preview configuration observations are missing')
    digest = hashlib.sha256()
    for filename, limit in (('preview-native.rgba', 1024*1024*4+8), ('preview-markers.json', 2*1024*1024)):
        with (evidence / filename).open('rb') as stream:
            raw = stream.read(limit+1)
        if not raw or len(raw) > limit:
            raise RelayApiError('native preview evidence exceeds bounds')
        digest.update(len(raw).to_bytes(8,'little'))
        digest.update(raw)
    return digest.hexdigest()


def native_request(config: dict, game: Path, mod: Path) -> str:
    verify_content(config, game, mod)
    w = config.get("world")
    keys = {"seed", "year", "size", "terrain", "towns", "industries", "difficulty", "agentMode", "townDevelopment"}
    if config.get("mode") != "new" or not isinstance(w, dict) or set(w) != keys:
        raise RelayApiError("invalid new-world settings")
    for key, minimum, maximum in (("seed", 0, 2147483647), ("year", 1850, 2050)):
        if type(w[key]) is not int or not minimum <= w[key] <= maximum:
            raise RelayApiError("invalid world " + key)
    if type(w["townDevelopment"]) is not bool:
        raise RelayApiError("invalid physical growth setting")
    try:
        values = [w["seed"], w["year"], ("small", "medium", "large").index(w["size"]),
            {"flat": 0, "hilly": 1, "mountainous": 3}[w["terrain"]],
            ("low", "medium", "high").index(w["towns"]),
            ("low", "medium", "high").index(w["industries"]),
            ("normal", "hard", "easy", "relaxed").index(w["difficulty"]),
            ("skeleton", "vanilla", "empty").index(w["agentMode"]), int(w["townDevelopment"])]
    except (KeyError, ValueError, TypeError) as exc:
        raise RelayApiError("unsupported world setting") from exc
    if sum(m["id"] == "!tpf2_mp" and m["version"] == 1 for m in config["mods"]) != 1:
        raise RelayApiError("new worlds require the native local !tpf2_mp v1 identity")
    lines = ["TPF2MP_WORLDGEN_1", " ".join(map(str, values)), str(len(config["mods"]))]
    lines += [f"{m['id']} {m['version']}" for m in config["mods"]]
    return "\n".join(lines) + "\n"


def verify_generated(config: dict, save: Path, evidence: Path, game: Path, mod: Path, session: str) -> dict:
    # A zero process exit or visible world is not proof that saving succeeded.
    encoded_request = native_request(config, game, mod).encode("ascii")
    report = json.loads((evidence / "report.json").read_text(encoding="utf-8-sig"))
    if report.get("complete") is not True or report.get("exitCode") != 0:
        raise RelayApiError("native generation did not complete cleanly")
    if report.get("requestSha256") != hashlib.sha256(encoded_request).hexdigest() \
            or (evidence / "native-request.txt").read_bytes() != encoded_request \
            or Path(report.get("savePath", "")).resolve() != save.resolve():
        raise RelayApiError("generation evidence belongs to a different request or save")
    events = [json.loads(line) for line in (evidence / "native.jsonl").read_text().splitlines()]
    names = {event.get("event") for event in events}
    if not {"native-save-idle", "generator-resource-temperate.gen.lua"} <= names:
        raise RelayApiError("native generation/save completion evidence is missing")
    w = config["world"]
    values = encoded_request.decode("ascii").splitlines()[1].split()
    expected = {f"native-seed={w['seed']}", f"native-terrain-hilliness={values[3]}",
                "native-terrain-water=0", "native-terrain-forest=2"}
    for key, index in (("locations.mapSize",2),("locations.towns.frequency",4),
                       ("locations.industry.maxNumberPerArea",5)):
        expected.add(f"native-parameter-:{key}={values[index]}")
    for key, index in (("economyDifficulty",6),("agentMode",7),("townDevelopment",8)):
        expected.add(f"native-parameter-!tpf2_mp_1:{key}={values[index]}")
    if not expected <= names:
        raise RelayApiError("native generator settings were not fully observed")
    facts, mods = save_facts(save)
    if selected_content(mods, game, mod) != config["mods"]:
        raise RelayApiError("generated world active mods differ from the lobby")
    header = read_active_mods(save)["nativeHeaderWords"]
    dimension = {"small":32,"medium":44,"large":56}[w["size"]]
    if header[1] != w["year"] or header[2:4] != [dimension,dimension] \
            or f"configured-dimensions-{header[2]}x{header[3]}" not in names:
        raise RelayApiError("generated native year/map dimensions do not match the request")
    metadata = validate_metadata(save).read_text(encoding="utf-8-sig")
    difficulties = re.findall(r'\beconomyDifficulty\s*=\s*"([a-z]+)"', metadata)
    if not difficulties or set(difficulties) != {config["world"]["difficulty"]}:
        raise RelayApiError("saved TPF2MP economy differs from the requested difficulty")
    if not save.with_suffix(".jpg").is_file():
        raise RelayApiError("native generation preview is missing")
    bundle, _ = build_save_sync_manifest(save, session)
    return {"schemaVersion": 1, "session": session, "configDigest": configuration_digest(config),
            "save": facts, "savePath": str(save.resolve()), "bundle": bundle,
            "nativeHeaderWords": header}
