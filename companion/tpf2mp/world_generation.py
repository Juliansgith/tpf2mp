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

WORLD_KEYS = {"seed", "year", "size", "format", "climate", "terrain", "towns",
              "industries", "industryTarget", "vehicles", "nameList", "environment",
              "nativeDifficulty", "difficulty", "agentMode", "townDevelopment"}
TERRAIN_KEYS = {"hilliness", "water", "forest", "canyon", "mesa", "ridge", "land", "islands"}
CLIMATES = ("temperate", "dry", "tropical")
GENERATORS = {"temperate": "temperate", "dry": "desert", "tropical": "tropical"}
TERRAIN_ACTIVE = {
    "temperate": ("hilliness", "water", "forest"),
    "dry": ("canyon", "mesa", "ridge", "water", "forest"),
    "tropical": ("hilliness", "land", "forest", "islands"),
}
TERRAIN_LIMITS = {"hilliness": 4, "water": 4, "forest": 6, "canyon": 4,
                  "mesa": 4, "ridge": 4, "land": 4, "islands": 6}
NAME_LISTS = ("europe", "england", "france", "germany", "italy", "korea",
              "netherlands", "norway", "russia", "spain", "sweden", "usa", "asia")
MAP_DIMENSIONS = {
    "small": {"1:1": (32, 32), "1:2": (22, 44), "1:3": (18, 54), "1:4": (16, 64), "1:5": (14, 70)},
    "medium": {"1:1": (44, 44), "1:2": (32, 64), "1:3": (26, 78), "1:4": (22, 88), "1:5": (20, 100)},
    "large": {"1:1": (56, 56), "1:2": (40, 80), "1:3": (32, 96), "1:4": (28, 112), "1:5": (24, 126)},
}


def _expected_native_events(config: dict, *, generated: bool = False,
                            dimensions: bool = True) -> set[str]:
    world = config["world"]
    active = TERRAIN_ACTIVE[world["climate"]]
    width, height = MAP_DIMENSIONS[world["size"]][world["format"]]
    events = {f"generator-resource-{GENERATORS[world['climate']]}.gen.lua",
              f"native-seed={world['seed']}",
              f"native-map-format={('1:1','1:2','1:3','1:4','1:5').index(world['format'])}"}
    if dimensions:
        events.add(f"configured-dimensions-{width}x{height}")
    events.update(f"native-terrain-{key}={world['terrain'][key]}" for key in active)
    if generated:
        events.update({f"native-resource-climate={world['climate']}",
                       f"native-resource-environment={world['environment']}",
                       f"native-resource-vehicles={world['vehicles']}",
                       f"native-resource-nameList={world['nameList']}",
                       f"native-resource-difficulty={world['nativeDifficulty']}"})
    return events


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
    if not ({'native-preview-ready'} | _expected_native_events(config)) <= names:
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
    if config.get("mode") != "new" or not isinstance(w, dict) or set(w) != WORLD_KEYS:
        raise RelayApiError("invalid new-world settings")
    for key, minimum, maximum in (("seed", 0, 2147483647), ("year", 1850, 2050)):
        if type(w[key]) is not int or not minimum <= w[key] <= maximum:
            raise RelayApiError("invalid world " + key)
    if type(w["townDevelopment"]) is not bool or not isinstance(w["terrain"], dict) \
            or set(w["terrain"]) != TERRAIN_KEYS:
        raise RelayApiError("invalid physical growth setting")
    for key, maximum in TERRAIN_LIMITS.items():
        if type(w["terrain"][key]) is not int or not 0 <= w["terrain"][key] <= maximum:
            raise RelayApiError("invalid terrain setting: " + key)
    try:
        values = [w["seed"], w["year"], ("small", "medium", "large").index(w["size"]),
            ("1:1", "1:2", "1:3", "1:4", "1:5").index(w["format"]), CLIMATES.index(w["climate"]),
            *[w["terrain"][key] for key in ("hilliness", "water", "forest", "canyon", "mesa", "ridge", "land", "islands")],
            ("low", "medium", "high").index(w["towns"]),
            ("low", "medium", "high").index(w["industries"]),
            ("disabled", "low", "medium", "high").index(w["industryTarget"]),
            ("easy", "medium", "hard", "very hard").index(w["nativeDifficulty"]),
            ("normal", "hard", "easy", "relaxed").index(w["difficulty"]),
            ("skeleton", "vanilla", "empty").index(w["agentMode"]), int(w["townDevelopment"]),
            ("europe", "usa", "asia", "all").index(w["vehicles"]), NAME_LISTS.index(w["nameList"]),
            CLIMATES.index(w["environment"])]
    except (KeyError, ValueError, TypeError) as exc:
        raise RelayApiError("unsupported world setting") from exc
    if sum(m["id"] == "!tpf2_mp" and m["version"] == 1 for m in config["mods"]) != 1:
        raise RelayApiError("new worlds require the native local !tpf2_mp v1 identity")
    lines = ["TPF2MP_WORLDGEN_2", " ".join(map(str, values)), str(len(config["mods"]))]
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
    if not ({"native-save-idle"} | _expected_native_events(config, generated=True,
                                                             dimensions=False)) <= names:
        raise RelayApiError("native generation/save completion evidence is missing")
    w = config["world"]
    values = encoded_request.decode("ascii").splitlines()[1].split()
    expected = set()
    for key, index in (("locations.mapSize",2),("locations.towns.frequency",13),
                       ("locations.industry.maxNumberPerArea",14),
                       ("locations.industry.targetMaxNumberPerArea",15)):
        expected.add(f"native-parameter-:{key}={values[index]}")
    for key, index in (("economyDifficulty",17),("agentMode",18),("townDevelopment",19)):
        expected.add(f"native-parameter-!tpf2_mp_1:{key}={values[index]}")
    if not expected <= names:
        raise RelayApiError("native generator settings were not fully observed")
    facts, mods = save_facts(save)
    if selected_content(mods, game, mod) != config["mods"]:
        raise RelayApiError("generated world active mods differ from the lobby")
    header = read_active_mods(save)["nativeHeaderWords"]
    expected_dimensions = MAP_DIMENSIONS[w["size"]][w["format"]]
    expected_dimension_event = f"configured-dimensions-{expected_dimensions[0]}x{expected_dimensions[1]}"
    if header[1] != w["year"] or tuple(header[2:4]) != expected_dimensions \
            or expected_dimension_event not in names:
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
