"""Small, closed recipe language: no shell commands, Lua, or gameplay injection."""
import hashlib
import json
import math
import re
from pathlib import Path


class InvalidSuite(ValueError):
    pass


def require(value, message):
    if not value:
        raise InvalidSuite(message)


def sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else _hash(stream)


def _hash(stream):
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(block)
    return digest.hexdigest()


def number(value, low, high):
    return type(value) in (float, int) and math.isfinite(value) and low <= value <= high


def validate_step(step):
    require(isinstance(step, dict), "step must be an object")
    op = step.get("action")
    allowed = {
        "click": {"point", "selector", "button"}, "move": {"point", "selector"},
        "doubleClick": {"point", "selector", "button"},
        "drag": {"point", "to", "duration"}, "wheel": {"point", "delta"},
        "key": {"key"}, "text": {"text"}, "waitUi": {"selector", "absent"},
        "camera": {"camera"}, "observe": set(), "wait": {"seconds"},
        "moveGround": {"world", "tolerance"}, "clickGround": {"world", "tolerance"},
        "dragGround": {"world", "toWorld", "duration", "tolerance"},
    }
    for physical in ('click', 'doubleClick', 'move', 'drag', 'wheel', 'key'):
        allowed[physical].add('modifiers')
    require(op in allowed, f"unsupported input action: {op}")
    require(not set(step) - allowed[op] - {"action", "peer", "timeout"}, f"unknown {op} fields")
    require(step.get("peer") in ("player1", "player2"), "every step requires an explicit peer")
    if 'modifiers' in step:
        modifiers = step['modifiers']
        require(isinstance(modifiers, list) and 1 <= len(modifiers) <= 2
                and all(isinstance(m, str) and m in ('shift', 'c') for m in modifiers)
                and len(set(modifiers)) == len(modifiers), 'invalid construction modifiers')
    require(number(step.get("timeout", 15), 1, 180), "invalid UI timeout")
    if op in ('moveGround', 'clickGround', 'dragGround'):
        for field in ('world', 'toWorld') if op == 'dragGround' else ('world',):
            require(isinstance(step.get(field), list) and len(step[field]) == 2
                    and all(number(v, -99999, 99999) for v in step[field]), 'invalid ground coordinates')
        require(number(step.get('tolerance', .15), .05, 1), 'invalid ground targeting tolerance')
        if op == 'dragGround':
            require(number(step.get('duration', 1), .1, 5), 'invalid ground drag duration')
    for field in ("point", "to"):
        if field in step:
            require(isinstance(step[field], list) and len(step[field]) == 2
                    and all(number(x, 0, 1) for x in step[field]), "points must be normalized client coordinates")
    if op in ("click", "doubleClick", "move"):
        require(("point" in step) != ("selector" in step), "select exactly one point or selector")
    if "button" in step:
        require(step["button"] in ("left", "right"), "invalid mouse button")
    if op == "drag":
        require("point" in step and "to" in step and number(step.get("duration", .6), .1, 5), "invalid drag")
    if op == "wheel":
        require("point" in step and type(step.get("delta")) is int
                and 0 < abs(step["delta"]) <= 12000, "invalid wheel")
    if "selector" in step:
        selector = step["selector"]
        require(isinstance(selector, dict) and selector and not set(selector) - {"id", "text", "path", "selected"}
                and set(selector) & {"id", "text", "path"}
                and all(type(v) is bool if k == "selected" else isinstance(v, str) and 0 < len(v) < 512
                        for k, v in selector.items()), "invalid selector")
    if op == "waitUi":
        require("selector" in step, "waitUi requires a selector")
        require(type(step.get("absent", False)) is bool, "invalid absent flag")
    if op == "key":
        require(step.get("key") in ("escape", "enter", "tab", "backspace", "delete", "space",
                                    "r", "t", "m", "n", "b", "c", "comma", "period", "shift", "ctrl+a"), "key not allowlisted")
        require(not ('modifiers' in step and step['key'] in (*step['modifiers'], 'ctrl+a')),
                'key conflicts with held modifier')
    if op == "text":
        require(isinstance(step.get("text"), str) and len(step["text"]) <= 200
                and not any(ord(c) < 32 for c in step["text"]), "invalid text input")
    if op == "wait":
        require(number(step.get("seconds"), .1, 60), "wait must be <= 60 seconds; use state assertions")
    if op == "camera":
        camera = step.get("camera", {})
        require(set(camera) == {"x", "y", "distance", "angle", "pitch"}
                and all(number(v, -99999, 99999) for v in camera.values())
                and number(camera["distance"], 20, 20000), "invalid camera setup")


def validate_suite(suite, save=None):
    require(isinstance(suite, dict) and suite.get("schemaVersion") == 1, "suite schemaVersion must be 1")
    require(not set(suite) - {"schemaVersion", "id", "saveSha256", "viewport", "cases", "description", "calibrationIdleSeconds"}, "unknown suite fields")
    if "calibrationIdleSeconds" in suite:
        require(type(suite["calibrationIdleSeconds"]) is int and 10 <= suite["calibrationIdleSeconds"] <= 120,
                "calibration idle wait must be bounded to 10..120 seconds")
    require(isinstance(suite.get("id"), str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,79}", suite["id"]), "invalid suite id")
    require(isinstance(suite.get("cases"), list) and 0 < len(suite["cases"]) <= 200, "suite requires 1..200 cases")
    seen = set()
    for case in suite["cases"]:
        require(isinstance(case, dict) and not set(case) - {"id", "steps", "expect", "timeout", "coverage", "blocked"}, "unknown case fields")
        cid = case.get("id")
        require(isinstance(cid, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,99}", cid) and cid not in seen, "invalid/duplicate case id")
        seen.add(cid)
        require(isinstance(case.get("coverage", []), list)
                and all(isinstance(label, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,99}", label)
                        for label in case.get("coverage", [])), "invalid coverage labels")
        if "blocked" in case:
            require(isinstance(case["blocked"], str) and case["blocked"], "blocked case needs an explanation")
            continue
        require(isinstance(case.get("steps"), list) and 0 < len(case["steps"]) <= 300, "case needs input steps")
        require(number(case.get("timeout", 90), 5, 1200), "invalid convergence timeout")
        for step in case["steps"]:
            validate_step(step)
            if any(k in step for k in ("point", "to", "camera", "world", "toWorld")):
                require(isinstance(suite.get("saveSha256"), str)
                        and re.fullmatch(r"[a-f0-9]{64}", suite["saveSha256"]), "map-coordinate recipes require a pinned save SHA256")
                viewport = suite.get("viewport", {})
                require(isinstance(viewport, dict) and set(viewport) == {"w", "h"}
                        and all(type(v) is int and 600 <= v <= 8000 for v in viewport.values()),
                        "map-coordinate recipes require a calibrated viewport")
        expect = case.get("expect")
        require(isinstance(expect, dict) and expect.get("outcome") in ("built", "deleted", "changed", "unchanged", "journey"), "case needs explicit physical outcome")
        require(expect["outcome"] == "journey" or case.get("timeout", 90) <= 600,
                "only native journeys may wait longer than 600 seconds")
        require(not set(expect) - {"outcome", "kind", "count", "inventoryDelta", "owner", "finance", "checks", "journey", "terrain", "geometry", "railLayout"}, "unknown expectation fields")
        if 'geometry' in expect:
            require(expect['geometry'] is True, 'geometry observation must be true')
        if 'railLayout' in expect:
            layout = expect['railLayout']
            require(isinstance(layout, dict) and set(layout) == {'axis', 'tracks', 'span', 'tolerance'},
                    'invalid rail layout assertion')
            require(isinstance(layout['axis'], list) and len(layout['axis']) == 2
                    and all(number(v, -1, 1) for v in layout['axis'])
                    and abs(sum(v*v for v in layout['axis']) - 1) <= .0001, 'rail axis must be a unit vector')
            require(type(layout['tracks']) is int and 1 <= layout['tracks'] <= 32
                    and number(layout['span'], 10, 2000) and number(layout['tolerance'], .05, 1),
                    'invalid rail layout bounds')
            require(expect['outcome'] == 'built' and expect.get('kind') == 'construction',
                    'rail layout asserts newly built station constructions')
        if 'terrain' in expect:
            terrain = expect['terrain']
            require(isinstance(terrain, dict) and set(terrain) ==
                    {'bounds', 'grid', 'minDelta', 'minSamples', 'tolerance'}, 'invalid terrain proof')
            bounds = terrain['bounds']
            require(isinstance(bounds, list) and len(bounds) == 4
                    and all(number(v, -99999, 99999) for v in bounds)
                    and bounds[0] < bounds[2] and bounds[1] < bounds[3], 'invalid terrain bounds')
            require(type(terrain['grid']) is int and 2 <= terrain['grid'] <= 9
                    and type(terrain['minSamples']) is int and 1 <= terrain['minSamples'] <= terrain['grid']**2
                    and number(terrain['minDelta'], .01, 1000)
                    and number(terrain['tolerance'], 0, terrain['minDelta']/2), 'invalid terrain thresholds')
            require(expect['outcome'] in ('built', 'changed', 'deleted'), 'terrain proof requires physical mutation')
            require(isinstance(suite.get('saveSha256'), str) and re.fullmatch(r'[a-f0-9]{64}', suite['saveSha256'])
                    and isinstance(suite.get('viewport'), dict) and set(suite['viewport']) == {'w', 'h'}
                    and all(type(v) is int and 600 <= v <= 8000 for v in suite['viewport'].values()),
                    'terrain coordinates require a pinned save and calibrated viewport')
        if expect["outcome"] == "journey":
            journey = expect.get("journey")
            required_journey = {"lineName", "owner", "vehicles", "stops", "carrier"}
            require(isinstance(journey, dict) and required_journey <= set(journey)
                    and not set(journey) - required_journey - {'models'}
                    and isinstance(journey["lineName"], str) and 0 < len(journey["lineName"]) <= 100
                    and journey["owner"] in ("company:1", "company:2")
                    and type(journey["carrier"]) is int and 0 <= journey["carrier"] <= 4
                    and type(journey["vehicles"]) is int and 1 <= journey["vehicles"] <= 32
                    and type(journey["stops"]) is int and 2 <= journey["stops"] <= 16,
                    "journey requires unique line name, owner, carrier, vehicle count, and at least two stops")
            if 'models' in journey:
                require(isinstance(journey['models'], list) and 1 <= len(journey['models']) <= 128
                        and all(isinstance(m, str) and 0 < len(m) <= 512 for m in journey['models']),
                        'journey models must identify the native vehicle consist')
            require(journey['carrier'] != 0 or 'models' in journey,
                    'ROAD journeys require native model assertions to distinguish buses and trucks')
        else:
            require("journey" not in expect, "journey assertions require journey outcome")
        if "inventoryDelta" in expect:
            require(type(expect["inventoryDelta"]) is int and abs(expect["inventoryDelta"]) <= 10000, "invalid inventory delta")
        if expect["outcome"] in ("built", "deleted"):
            require(expect.get("kind") in ("construction", "depot", "station", "station_group", "edge", "edge_object", "line", "vehicle", "asset"), "physical kind required")
            require(type(expect.get("count", 1)) is int and 1 <= expect.get("count", 1) <= 100, "invalid count")
        if expect["outcome"] == "changed":
            require(expect.get("checks"), "changed outcome needs explicit postconditions")
        if "owner" in expect:
            require(expect["owner"] in ("company:1", "company:2"), "invalid owner")
            require(expect["outcome"] == "built", "owner assertions apply only to newly built objects")
        finance = expect.get("finance", {})
        require(isinstance(finance, dict) and not set(finance) - {"company:1", "company:2"}
                and all(v in ("debit", "credit", "unchanged") for v in finance.values()), "invalid finance policy")
        for check in expect.get("checks", []):
            require(isinstance(check, dict) and set(check) == {"path", "op", "value"}
                    and isinstance(check["path"], list) and check["path"]
                    and all(isinstance(p, (str, int)) for p in check["path"])
                    and check["op"] in ("equal", "delta", "atLeast", "deltaAtLeast", "length"), "invalid postcondition")
            if check['op'] in ('delta', 'deltaAtLeast', 'atLeast', 'length'):
                require(number(check['value'], -(2**53-1), 2**53-1), 'arithmetic postcondition requires a finite number')
            if check['op'] == 'length':
                require(type(check['value']) is int and check['value'] >= 0, 'length requires a nonnegative integer')
    if save and suite.get("saveSha256"):
        require(sha256(save) == suite["saveSha256"], "starting save differs from the calibrated UI fixture")
    return suite


def load_suite(path, save=None):
    return validate_suite(json.loads(Path(path).read_text(encoding="utf-8-sig")), save)
