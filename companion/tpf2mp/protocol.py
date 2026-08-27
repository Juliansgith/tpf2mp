from __future__ import annotations

import json
import math
import re
import zlib
from decimal import Decimal, localcontext, ROUND_HALF_UP
from typing import Any, Mapping

from .aboard_milestone_protocol import AboardMilestoneError, validate as validate_aboard_milestone
from .freight_action_protocol import validate_delivery_rows, validate_registration
from .fault_recovery_protocol import validation_error as fault_recovery_validation_error
from .line_registration_protocol import validate_metadata as validate_line_metadata
from .recovery_receipt_protocol import validation_error as receipt_validation_error
from .vehicle_phase_proof import VehiclePhaseProofError, normalise as normalise_vehicle_phase_proof

PROTOCOL_VERSION = 1
MAX_EXACT_INTEGER = 9_007_199_254_740_991

NETWORK_ACTIONS = {
    "match.initialise",
    "match.finish",
    "world.freeze",
    "line.register",
    "fare.adjust",
    "economy.seed_demo",
    "economy.settle",
    "probe.run",
    "probe.mobility",
    "probe.structural",
    "finance.toggle_neutralizer",
    "clock.request",
    "clock.set",
    "clock.rendezvous",
    "vehicle.sync_release",
    "network.sync_fault",
    "network.checkpoint_request",
    "recovery.prepare",
    "recovery.requalify",
    "recovery.resume",
    "recovery.continue",
    "recovery.save_receipt",
    "town.develop",
    "content.industry_attest",
    "freight.industry_bootstrap",
    "freight.milestone",
    "passenger.milestone",
    "proposal.prepare",
    "proposal.build",
    "operation.execute",
}

PROPOSAL_SCHEMA_VERSION = 5
CONSTRUCTION_PROPOSAL_SCHEMA_VERSION = 7
MAX_PROPOSAL_NODES = 256
MAX_PROPOSAL_EDGES = 256
MAX_PROPOSAL_EDGE_OBJECTS = 256
MAX_CONSTRUCTION_PROPOSAL_NODES = 1024
MAX_CONSTRUCTION_PROPOSAL_EDGES = 1024
MAX_STATION_MODULES = 256
MAX_PROPOSAL_REMOVALS = 512
MAX_CONSTRUCTION_COLLATERAL = 64
# A schema-7 construction can return one canonical output for every node, edge,
# and edge object plus a bounded compound construction graph.
MAX_PROPOSAL_OUTPUTS = (
    MAX_CONSTRUCTION_PROPOSAL_NODES
    + MAX_CONSTRUCTION_PROPOSAL_EDGES
    + MAX_PROPOSAL_EDGE_OBJECTS
    + 64
)
LEGACY_OPERATION_SCHEMA_VERSION = 1
FLAT_ALTERNATIVE_OPERATION_SCHEMA_VERSION = 2
STATION_TERMINAL_OPERATION_SCHEMA_VERSION, OPERATION_SCHEMA_VERSION = 3, 4
MAX_OPERATION_STOPS = 256
MAX_OPERATION_ALTERNATIVE_TERMINALS = 64
MAX_OPERATION_ALTERNATIVE_TERMINALS_TOTAL = 1024
MAX_OPERATION_VEHICLE_PARTS = 128
MAX_OPERATION_VEHICLE_BATCH = 256


class ProtocolError(ValueError):
    pass


def _normalise(value: Any) -> Any:
    if value is None or isinstance(value, (str, bool, int)):
        return value
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ProtocolError("non-finite numbers are not valid protocol values")
        return value
    if isinstance(value, (list, tuple)):
        return [_normalise(item) for item in value]
    if isinstance(value, Mapping):
        result: dict[str, Any] = {}
        for key, item in value.items():
            if not isinstance(key, str):
                raise ProtocolError("protocol object keys must be strings")
            result[key] = _normalise(item)
        return result
    raise ProtocolError(f"unsupported protocol value: {type(value).__name__}")


def canonical_json(value: Any) -> str:
    """Match the mod's sorted, compact UTF-8 JSON representation exactly.

    Python's JSON encoder uses the shortest round-trippable float spelling,
    while the Lua mod deliberately uses ``%.17g``. Native proposal research
    contains positions/tangents where those spellings differ, so a generic
    ``json.dumps`` round-trip incorrectly rejected valid game exports.
    """
    normalised = _normalise(value)

    def lua_number(number: float) -> str:
        # The Lua encoder canonicalises both IEEE-754 zero signs to JSON 0.
        # Python's JSON parser also turns an integer spelling of -0 into int 0,
        # so preserving a float's negative sign here would make checksums
        # depend on which conforming parser happened to read the envelope.
        if number == 0.0:
            return "0"
        negative = math.copysign(1.0, number) < 0
        absolute = abs(number)
        if absolute == math.floor(absolute):
            digits = format(Decimal.from_float(absolute), "f").split(".", 1)[0]
            return ("-" if negative else "") + digits

        # Windows' C runtime, used by Build 35924's Lua string.format, rounds
        # exact halfway cases away from zero. Python's format uses ties-to-even
        # and therefore differs for real coordinates such as
        # 3.39746856689453125. Reproduce %.17g explicitly.
        with localcontext() as context:
            context.prec = 1100
            decimal = Decimal.from_float(absolute)
            exponent = decimal.adjusted()
            quantum = Decimal(1).scaleb(exponent - 16)
            rounded = decimal.quantize(quantum, rounding=ROUND_HALF_UP)
            exponent = rounded.adjusted()
            if exponent < -4 or exponent >= 17:
                coefficient = format(rounded.scaleb(-exponent), "f")
                if "." in coefficient:
                    coefficient = coefficient.rstrip("0").rstrip(".")
                exponent_text = f"{abs(exponent):02d}"
                encoded = coefficient + ("e+" if exponent >= 0 else "e-") + exponent_text
            else:
                encoded = format(rounded, "f")
                if "." in encoded:
                    encoded = encoded.rstrip("0").rstrip(".")
        return ("-" if negative else "") + encoded

    def encode(item: Any) -> str:
        if item is None:
            return "null"
        if isinstance(item, bool):
            return "true" if item else "false"
        if isinstance(item, int):
            return str(item)
        if isinstance(item, float):
            return lua_number(item)
        if isinstance(item, str):
            return json.dumps(item, ensure_ascii=False, separators=(",", ":"))
        if isinstance(item, list):
            return "[" + ",".join(encode(nested) for nested in item) + "]"
        if isinstance(item, dict):
            return "{" + ",".join(
                encode(key) + ":" + encode(item[key]) for key in sorted(item)
            ) + "}"
        raise ProtocolError(f"unsupported protocol value: {type(item).__name__}")

    return encode(normalised)


def checksum(value: Any) -> str:
    encoded = canonical_json(value).encode("utf-8")
    return f"{zlib.adler32(encoded) & 0xFFFFFFFF:08x}"


def sign(message: Mapping[str, Any]) -> dict[str, Any]:
    result = dict(_normalise(message))
    result.pop("checksum", None)
    result["checksum"] = checksum(result)
    return result


def verify(message: Mapping[str, Any]) -> dict[str, Any]:
    if not isinstance(message, Mapping):
        raise ProtocolError("message is not an object")
    expected = message.get("checksum")
    if not isinstance(expected, str):
        raise ProtocolError("message has no checksum")
    core = dict(message)
    core.pop("checksum", None)
    actual = checksum(core)
    if actual != expected:
        raise ProtocolError(f"checksum mismatch: expected {expected}, calculated {actual}")
    return dict(message)


def encode_line(message: Mapping[str, Any]) -> bytes:
    return (canonical_json(message) + "\n").encode("utf-8")


def decode_line(data: bytes | str) -> dict[str, Any]:
    if isinstance(data, bytes):
        data = data.decode("utf-8")
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"invalid JSON frame: {exc}") from exc
    if not isinstance(value, dict):
        raise ProtocolError("frame root must be an object")
    return verify(value)


def validate_envelope(message: Mapping[str, Any], session: str) -> None:
    verify(message)
    protocol = message.get("protocol")
    if not isinstance(protocol, int) or isinstance(protocol, bool) \
            or protocol != PROTOCOL_VERSION:
        raise ProtocolError(f"protocol mismatch: {message.get('protocol')}")
    if str(message.get("session", "")) != session:
        raise ProtocolError(f"session mismatch: {message.get('session')}")


def _protocol_int(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise ProtocolError(f"{label} must be an integer")
    return value


def validate_vehicle_schedule(value: Any, *, release: bool) -> dict[str, Any]:
    """Validate the shared departure policy or one concrete reserved slot.

    A disabled object is explicit so Lua never has to encode JSON null.  Older
    station-barrier records omit the field entirely; their callers normalize
    that absence to the disabled form before invoking this validator.
    """
    if not isinstance(value, dict) or value.get("schemaVersion") != 1 \
            or not isinstance(value.get("enabled"), bool):
        raise ProtocolError("vehicle schedule header is invalid")
    if value["enabled"] is False:
        if set(value) != {"schemaVersion", "enabled"}:
            raise ProtocolError("disabled vehicle schedule has unknown fields")
        return dict(value)
    expected = {"schemaVersion", "enabled", "periodSeconds", "phaseSeconds"}
    if release:
        expected |= {"slotIndex", "scheduledDepartureAt"}
    if set(value) != expected:
        raise ProtocolError("enabled vehicle schedule has unknown or missing fields")
    period = _protocol_int(value.get("periodSeconds"), "vehicle schedule periodSeconds")
    phase = _protocol_int(value.get("phaseSeconds"), "vehicle schedule phaseSeconds")
    if not 1 <= period <= 31_536_000 or not 0 <= phase < period:
        raise ProtocolError("vehicle schedule period/phase is outside its supported range")
    if release:
        slot = _protocol_int(value.get("slotIndex"), "vehicle schedule slotIndex")
        scheduled = value.get("scheduledDepartureAt")
        if not 0 <= slot <= 1_000_000_000:
            raise ProtocolError("vehicle schedule slotIndex is outside its supported range")
        if not isinstance(scheduled, (int, float)) or isinstance(scheduled, bool) \
                or not math.isfinite(float(scheduled)) or scheduled < 0 \
                or scheduled > MAX_EXACT_INTEGER \
                or float(scheduled) != phase + slot * period:
            raise ProtocolError("vehicle schedule departure does not match its reserved slot")
    return dict(value)


def _proposal_vec3(value: Any, label: str) -> None:
    if not isinstance(value, dict) or set(value) != {"x", "y", "z"}:
        raise ProtocolError(f"{label} must contain exactly x, y, and z")
    for field in ("x", "y", "z"):
        coordinate = value[field]
        if not isinstance(coordinate, (int, float)) or isinstance(coordinate, bool):
            raise ProtocolError(f"{label}.{field} must be numeric")
        if not math.isfinite(float(coordinate)) or abs(float(coordinate)) > 10_000_000:
            raise ProtocolError(f"{label}.{field} is outside the supported range")


def _proposal_reference(value: Any, node_slots: set[str], label: str) -> None:
    if not isinstance(value, dict) or len(value) != 1:
        raise ProtocolError(f"{label} must contain exactly one canonical or slot reference")
    if "slot" in value:
        if value["slot"] not in node_slots:
            raise ProtocolError(f"{label} references an unknown node slot")
    elif "cid" in value:
        if not isinstance(value["cid"], str) or not value["cid"].startswith("node:"):
            raise ProtocolError(f"{label} contains an invalid canonical node id")
    else:
        raise ProtocolError(f"{label} is not a canonical or slot reference")


def _station_era(year: int) -> str:
    return "a" if year < 1920 else "b" if year < 1980 else "c"


def _stock_station_modules(params: Mapping[str, int], *, cargo: bool, head: bool) -> dict[int, str]:
    """Port of Build 35924 modular_station.con:createTemplateFn."""
    prefix = "station/rail/modular_station/"
    era = _station_era(params["year"])
    variant = "cargo" if cargo else f"era_{era}"
    layout_length = (1, 2, 3, 5, 7)[params["length"]]
    start = -math.floor(layout_length / 2)
    end = math.ceil(layout_length / 2)
    even = (end - start) % 2 == 0
    offset, level = 1, 3
    main_building = prefix + f"main_building_3_{variant}.module"
    if params["tracks"] < 3:
        offset, level = 0, 1
        main_building = prefix + f"main_building_1_{variant}.module"
    elif params["tracks"] < 6:
        offset, level = 0, 2
        main_building = prefix + f"main_building_2_{variant}.module"

    result: dict[int, str] = {}

    def main_id(subtype: str, i: int, j: int, k: int = 0, extra: int = 0) -> int:
        if subtype == "headLeft":
            return 3_400_000 + 300_000 + 1_000 * i + 20 * j + extra
        if subtype == "headRight":
            return 3_400_000 + 400_000 + 1_000 * i + 20 * j + extra
        if subtype == "throughFront":
            return 3_400_000 + 200_000 + 3_000 * i + 40 * j + 10 * k + extra
        return 3_400_000 + 3_000 * i + 40 * j + 10 * k + extra

    def track_id(i: int, j: int) -> int:
        return 8_400_000 + 1_000 * i + 10 * j

    def platform_id(is_cargo: bool, i: int, j: int) -> int:
        return (6_400_000 if is_cargo else 7_400_000) + 1_000 * i + 10 * j

    def addon_id(roof: bool, i: int, j: int) -> int:
        return (10_400_000 if roof else 10_800_000) + 1_000 * i + 10 * j

    def add_track(i: int) -> None:
        if params["trackType"] == 0:
            track = "platform_track_catenary.module" if params["catenary"] else "platform_track.module"
        else:
            track = (
                "platform_high_speed_track_catenary.module"
                if params["catenary"]
                else "platform_high_speed_track.module"
            )
        for j in range(start, end + 1):
            result[track_id(i, j)] = prefix + track

    def add_cargo(i: int) -> None:
        for j in range(start, end + 1):
            result[platform_id(True, i, j)] = prefix + f"platform_cargo_era_{era}.module"

    def add_passenger(i: int) -> None:
        center = math.floor((end - start) / 2) + start
        distance = end - start
        roof = prefix + f"platform_passenger_roof_era_{era}.module"
        curved_roof = prefix + "platform_passenger_roof_curved_era_c.module" if level == 3 and era == "c" else roof
        underpass = prefix + f"addon_platform_passenger_stairs_era_{era}.module"
        platform = prefix + f"platform_passenger_era_{era}.module"
        for j in range(start, end + 1):
            result[platform_id(False, i, j)] = platform
            if not head:
                if j == center or (distance > 3 and j == start + 1) or (distance > 3 and j == end - 1):
                    result[addon_id(False, i, j)] = underpass
                if (j != start and j != end) or end - start <= 3:
                    use_curved = (not even and (j == center or j == center + 1)) or j == center
                    result[addon_id(True, i, j)] = curved_roof if use_curved else roof
            else:
                if j == center or j == start or (distance > 3 and j == end - 1):
                    result[addon_id(False, i, j)] = underpass
                if j != end or j == start or j == start + 1:
                    result[addon_id(True, i, j)] = curved_roof if j == start else roof

    def side_module(side_level: int) -> tuple[str, int]:
        side_offset = 4 + side_level
        if side_level == 3 and variant != "era_c":
            side_offset = 6
        return prefix + f"side_building_{side_level}_{variant}.module", side_offset

    if head:
        multiplier = 2 if cargo else 1
        c = (math.floor((params["tracks"] + 1) / 2) + 1) * multiplier + 1 + params["tracks"]
        c = math.floor(c / 2) - 1
        result[main_id("headLeft", c, -math.floor(layout_length / 2), extra=offset)] = main_building
    else:
        k = 0 if even else 2
        result[3_400_000 + 10 * k + offset] = main_building
        if level >= 3:
            i = 2 if variant == "era_c" else 0
            if layout_length > 5:
                module, extra = side_module(level - 2)
                result[main_id("throughBack", 0, 2, k + i, extra)] = module
                result[main_id("throughBack", 0, -2, k - 1 - i, extra)] = module
                module, extra = side_module(level - 1)
                result[main_id("throughBack", 0, 2, k - 1 + i, extra)] = module
                result[main_id("throughBack", 0, -2, k + 1 - i, extra)] = module
                result[main_id("throughBack", 0, 1, k + 1 + i, extra)] = module
                result[main_id("throughBack", 0, -1, k - 1 - i, extra)] = module
                module, extra = side_module(level)
                result[main_id("throughBack", 0, 1, k - 1 + i // 2, extra)] = module
                result[main_id("throughBack", 0, -1, k + 1 - i // 2, extra)] = module
            elif layout_length > 4:
                module, extra = side_module(level - 2)
                result[main_id("throughBack", 0, 2, k - 2 + i, extra)] = module
                result[main_id("throughBack", 0, -2, k + 1 - i, extra)] = module
                module, extra = side_module(level - 1)
                result[main_id("throughBack", 0, 1, k + 1 + i, extra)] = module
                result[main_id("throughBack", 0, -1, k - 1 - i, extra)] = module
                module, extra = side_module(level)
                result[main_id("throughBack", 0, 1, k - 1 + i // 2, extra)] = module
                result[main_id("throughBack", 0, -1, k + 1 - i // 2, extra)] = module
            elif layout_length > 3:
                module, extra = side_module(level - 2)
                result[main_id("throughBack", 0, 1, k, extra)] = module
                result[main_id("throughBack", 0, -1, k - 1, extra)] = module
                module, extra = side_module(level - 1)
                result[main_id("throughBack", 0, 1, k - 1, extra)] = module
                result[main_id("throughBack", 0, -1, k + 1, extra)] = module
            elif layout_length > 1:
                module, extra = side_module(level - 1)
                result[main_id("throughBack", 0, 1, k - 1, extra)] = module
                result[main_id("throughBack", 0, -1, k + 1, extra)] = module
        elif level >= 2:
            if layout_length > 4:
                module, extra = side_module(2)
                result[main_id("throughBack", 0, 0, k + 2, extra)] = module
                result[main_id("throughBack", 0, -1, k + 2, extra)] = module
                module, extra = side_module(1)
                result[main_id("throughBack", 0, 1, k - 1, extra)] = module
                result[main_id("throughBack", 0, -1, k, extra)] = module
            elif layout_length > 2:
                module, extra = side_module(1)
                result[main_id("throughBack", 0, 0, k + 1, extra)] = module
                result[main_id("throughBack", 0, 0, k - 2, extra)] = module
        else:
            if layout_length > 2:
                module, extra = side_module(1)
                result[main_id("throughBack", 0, 0, k + 1, extra)] = module
                result[main_id("throughBack", 0, 0, k - 2, extra)] = module
            if layout_length > 4:
                module, extra = side_module(1)
                result[main_id("throughBack", 0, 0, k + 2, extra)] = module
                result[main_id("throughBack", 0, -1, k + 1, extra)] = module

    if cargo:
        add_cargo(0)
        add_track(2)
        if params["tracks"] >= 1:
            add_track(3); add_cargo(4)
        if params["tracks"] >= 2:
            add_track(6)
        if params["tracks"] >= 3:
            add_track(7); add_cargo(8)
        if params["tracks"] >= 4:
            add_track(10)
        if params["tracks"] >= 5:
            add_track(11); add_cargo(12)
        if params["tracks"] >= 6:
            add_track(14)
        if params["tracks"] >= 7:
            add_track(15); add_cargo(16)
    else:
        add_passenger(0)
        add_track(1)
        if params["tracks"] >= 1:
            add_track(2); add_passenger(3)
        if params["tracks"] >= 2:
            add_track(4)
        if params["tracks"] >= 3:
            add_track(5); add_passenger(6)
        if params["tracks"] >= 4:
            add_track(7)
        if params["tracks"] >= 5:
            add_track(8); add_passenger(9)
        if params["tracks"] >= 6:
            add_track(10)
        if params["tracks"] >= 7:
            add_track(11); add_passenger(12)
    return result


def _validate_stock_station_graph(nodes: list[dict[str, Any]], edges: list[dict[str, Any]], params: Mapping[str, int]) -> None:
    track_count = params["tracks"] + 1
    if not nodes or not edges:
        raise ProtocolError("station graph is empty")
    adjacency: dict[str, list[str]] = {f"slot:{node['slot']}": [] for node in nodes}
    boundary: set[str] = set()

    def vertex(reference: Any) -> str | None:
        if not isinstance(reference, dict):
            return None
        slot = reference.get("slot")
        if slot is not None:
            key = f"slot:{slot}"
            return key if key in adjacency else None
        cid = reference.get("cid")
        if isinstance(cid, str) and cid.startswith("node:"):
            key = f"cid:{cid}"
            adjacency.setdefault(key, [])
            boundary.add(key)
            return key
        return None

    for edge in edges:
        if edge["carrier"] != "track":
            raise ProtocolError("station graph contains a non-track edge")
        if edge["private"] is not True:
            raise ProtocolError("station graph edges must remain player-owned")
        if edge["catenary"] != (params["catenary"] == 1):
            raise ProtocolError("station graph catenary differs from its module template")
        node0 = vertex(edge["node0"])
        node1 = vertex(edge["node1"])
        if not node0 or not node1 or node0 == node1:
            raise ProtocolError("station graph must reference distinct new or canonical boundary nodes")
        adjacency[node0].append(node1)
        adjacency[node1].append(node0)
    if len(nodes) + len(boundary) != len(edges) + track_count:
        raise ProtocolError("station graph cardinality does not match its track count")
    for key in boundary:
        if len(adjacency[key]) != 1:
            raise ProtocolError("station canonical boundary node must be a path endpoint")
    visited: set[str] = set()
    components = 0
    for slot, neighbours in adjacency.items():
        if not 1 <= len(neighbours) <= 2:
            raise ProtocolError("station track graph is not a set of simple paths")
        if slot in visited:
            continue
        components += 1
        pending = [slot]
        visited.add(slot)
        endpoints = 0
        while pending:
            current = pending.pop()
            if len(adjacency[current]) == 1:
                endpoints += 1
            for neighbour in adjacency[current]:
                if neighbour not in visited:
                    visited.add(neighbour)
                    pending.append(neighbour)
        if endpoints != 2:
            raise ProtocolError("station track component is not an open path")
    if components != track_count:
        raise ProtocolError("station graph component count differs from its track count")


def _validate_proposal_transaction_legacy(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProtocolError("proposal.build transaction must be an object")
    schema_version = value.get("schemaVersion")
    expected_root = {
        "schemaVersion", "companyCid", "cost", "nodes", "edges", "remove", "digest", "transactionId"
    }
    if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        expected_root.add("constructions")
    if set(value) != expected_root:
        raise ProtocolError("proposal transaction has unknown or missing fields")
    if schema_version not in {PROPOSAL_SCHEMA_VERSION, CONSTRUCTION_PROPOSAL_SCHEMA_VERSION}:
        raise ProtocolError("unsupported proposal schemaVersion")
    company = value.get("companyCid")
    if not isinstance(company, str) or not company.startswith("company:") or not company[8:].isdigit():
        raise ProtocolError("proposal transaction has an invalid companyCid")
    cost = _protocol_int(value.get("cost"), "proposal quoted cost")
    if abs(cost) > 1_000_000_000_000:
        raise ProtocolError("proposal quoted cost is outside the supported range")
    nodes, edges, remove = value.get("nodes"), value.get("edges"), value.get("remove")
    node_limit = (
        MAX_CONSTRUCTION_PROPOSAL_NODES
        if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION
        else MAX_PROPOSAL_NODES
    )
    edge_limit = (
        MAX_CONSTRUCTION_PROPOSAL_EDGES
        if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION
        else MAX_PROPOSAL_EDGES
    )
    # A pure track/street replacement (track type, catenary, or equivalent
    # edge upgrade) creates no BASE_NODE outputs. Lua's deterministic encoder
    # spells that empty table as `{}`, just as it does for empty removal lists.
    # Keep the original spelling in the digest view, but iterate it as an empty
    # sequence. Non-empty objects remain invalid and cannot smuggle keyed data.
    lua_empty_nodes = isinstance(nodes, dict) and not nodes
    if (not isinstance(nodes, list) and not lua_empty_nodes) or len(nodes) > node_limit:
        raise ProtocolError("proposal transaction has an invalid node list")
    if not isinstance(edges, list) or not edges or len(edges) > edge_limit:
        raise ProtocolError("proposal transaction has an invalid edge list")
    if not isinstance(remove, dict) or set(remove) != {"edges", "nodes"}:
        raise ProtocolError("proposal transaction has invalid removal lists")

    node_slots: set[str] = set()
    for index, node in enumerate([] if lua_empty_nodes else nodes, 1):
        if not isinstance(node, dict) or set(node) != {"slot", "position"}:
            raise ProtocolError("proposal node has unknown or missing fields")
        expected_slot = f"node:{index}"
        if node.get("slot") != expected_slot or expected_slot in node_slots:
            raise ProtocolError("proposal node slots must be unique and sequential")
        node_slots.add(expected_slot)
        _proposal_vec3(node.get("position"), f"proposal {expected_slot} position")

    for index, edge in enumerate(edges, 1):
        if not isinstance(edge, dict):
            raise ProtocolError("proposal edge must be an object")
        carrier = edge.get("carrier")
        expected_fields = {
            "slot", "carrier", "node0", "node1", "tangent0", "tangent1", "type", "typeIndex",
            "resource", "logicalOwnerCid", "private",
        }
        if carrier == "track":
            expected_fields.add("catenary")
        if set(edge) != expected_fields:
            raise ProtocolError("proposal edge has unknown or missing fields")
        if edge.get("slot") != f"edge:{index}":
            raise ProtocolError("proposal edge slots must be unique and sequential")
        if carrier not in {"street", "track"}:
            raise ProtocolError("proposal edge has an invalid carrier")
        _proposal_reference(edge.get("node0"), node_slots, f"proposal edge:{index} node0")
        _proposal_reference(edge.get("node1"), node_slots, f"proposal edge:{index} node1")
        _proposal_vec3(edge.get("tangent0"), f"proposal edge:{index} tangent0")
        _proposal_vec3(edge.get("tangent1"), f"proposal edge:{index} tangent1")
        _protocol_int(edge.get("type"), f"proposal edge:{index} type")
        _protocol_int(edge.get("typeIndex"), f"proposal edge:{index} typeIndex")
        resource = edge.get("resource")
        if not isinstance(resource, dict) or not {"index"} <= set(resource) <= {"index", "name"}:
            raise ProtocolError("proposal edge has an invalid resource")
        if _protocol_int(resource.get("index"), f"proposal edge:{index} resource index") < 0:
            raise ProtocolError("proposal edge resource index must be non-negative")
        if "name" in resource and (
            not isinstance(resource["name"], str) or not resource["name"] or len(resource["name"]) > 240
        ):
            raise ProtocolError("proposal edge resource name is invalid")
        if edge.get("logicalOwnerCid") != company:
            raise ProtocolError("proposal edge logical owner differs from the transaction company")
        if not isinstance(edge.get("private"), bool):
            raise ProtocolError("proposal edge private flag must be boolean")
        if carrier == "track" and not isinstance(edge.get("catenary"), bool):
            raise ProtocolError("proposal track catenary must be boolean")

    for kind in ("edges", "nodes"):
        values = remove[kind]
        # Lua has only one table type.  Our deterministic encoder therefore
        # represents an empty table as `{}`; once at least one removal exists
        # the same value is unambiguously encoded as a JSON array.  Accept only
        # the *empty* object spelling here and keep it intact so the proposal
        # digest remains byte-for-byte compatible with the game-side digest.
        lua_empty_list = isinstance(values, dict) and not values
        if (not isinstance(values, list) and not lua_empty_list) or len(values) > MAX_PROPOSAL_REMOVALS:
            raise ProtocolError(f"proposal {kind} removal list is invalid")
        if lua_empty_list:
            continue
        prefix = "edge:" if kind == "edges" else "node:"
        if any(not isinstance(cid, str) or not cid.startswith(prefix) for cid in values):
            raise ProtocolError(f"proposal {kind} removal list contains a non-canonical id")
        if values != sorted(set(values)):
            raise ProtocolError(f"proposal {kind} removal list must be sorted and unique")

    if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        if lua_empty_nodes:
            raise ProtocolError("schema 4 station must contain a non-empty track graph")
        if any(remove[kind] not in ({}, []) for kind in ("edges", "nodes")):
            raise ProtocolError("schema 4 station cannot replace existing topology")
        constructions = value.get("constructions")
        if not isinstance(constructions, list) or len(constructions) != 1:
            raise ProtocolError("schema 4 proposal requires one construction")
        construction = constructions[0]
        construction_fields = {"slot", "kind", "fileName", "transform", "params", "modules"}
        if not isinstance(construction, dict) or set(construction) != construction_fields:
            raise ProtocolError("station construction has unknown or missing fields")
        if construction.get("slot") != "construction:1" or construction.get("kind") != "rail_station":
            raise ProtocolError("station construction identity is invalid")
        station_file = "station/rail/modular_station/modular_station.con"
        if construction.get("fileName") != station_file:
            raise ProtocolError("only the stock modular rail station is supported")
        transform = construction.get("transform")
        if not isinstance(transform, list) or len(transform) != 16:
            raise ProtocolError("station transform must be a 4x4 matrix")
        values16: list[float] = []
        for item in transform:
            if not isinstance(item, (int, float)) or isinstance(item, bool) or not math.isfinite(item):
                raise ProtocolError("station transform contains a non-finite number")
            if abs(item) > 10_000_000:
                raise ProtocolError("station transform is outside the supported range")
            values16.append(float(item))
        epsilon = 0.002
        if any(abs(values16[index - 1]) > epsilon for index in (3, 4, 7, 8, 9, 10, 12)):
            raise ProtocolError("station transform is not planar affine")
        if abs(values16[10] - 1) > epsilon or abs(values16[15] - 1) > epsilon:
            raise ProtocolError("station transform has an invalid homogeneous axis")
        a, b, c, d = values16[0], values16[1], values16[4], values16[5]
        if (
            abs(a * a + b * b - 1) > epsilon
            or abs(c * c + d * d - 1) > epsilon
            or abs(a * c + b * d) > epsilon
            or abs(a * d - b * c - 1) > epsilon
        ):
            raise ProtocolError("station transform contains scale, skew, or reflection")
        params = construction.get("params")
        param_fields = {"year", "seed", "trackType", "catenary", "length", "tracks", "paramX", "paramY"}
        if not isinstance(params, dict) or set(params) != param_fields:
            raise ProtocolError("station params have unknown or missing fields")
        numeric_params = {name: _protocol_int(params.get(name), f"station {name}") for name in param_fields}
        if not 1850 <= numeric_params["year"] <= 3000 or not 0 <= numeric_params["seed"] <= 2_147_483_647:
            raise ProtocolError("station year or seed is invalid")
        if (
            numeric_params["trackType"] not in {0, 1}
            or numeric_params["catenary"] not in {0, 1}
            or not 0 <= numeric_params["length"] <= 4
            or not 0 <= numeric_params["tracks"] <= 7
            or any(numeric_params[name] != 0 for name in ("paramX", "paramY"))
        ):
            raise ProtocolError("station layout parameters are outside the stock modular menu range")
        modules = construction.get("modules")
        if not isinstance(modules, list) or not 1 <= len(modules) <= MAX_STATION_MODULES:
            raise ProtocolError("station module list is invalid")
        observed_slots: list[int] = []
        observed_modules: dict[int, str] = {}
        for module in modules:
            if not isinstance(module, dict) or set(module) != {"slot", "name", "variant"}:
                raise ProtocolError("station module has unknown or missing fields")
            slot = _protocol_int(module.get("slot"), "station module slot")
            if module.get("variant") != 0:
                raise ProtocolError("station module set does not match the supported stock template")
            observed_slots.append(slot)
            observed_modules[slot] = module.get("name")
        if observed_slots != sorted(observed_slots) or len(observed_modules) != len(observed_slots):
            raise ProtocolError("station module slots must be sorted and unique")
        expected_module_sets = [
            _stock_station_modules(numeric_params, cargo=cargo, head=head)
            for cargo in (False, True)
            for head in (False, True)
        ]
        if not any(observed_modules == expected_modules for expected_modules in expected_module_sets):
            raise ProtocolError("station module set does not match the supported stock template")
        _validate_stock_station_graph(nodes, edges, numeric_params)

    content = {
        "schemaVersion": value["schemaVersion"],
        "companyCid": company,
        "cost": cost,
        "nodes": nodes,
        "edges": edges,
        "remove": remove,
    }
    if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        content["constructions"] = value["constructions"]
    expected_digest = checksum(content)
    if value.get("digest") != expected_digest:
        raise ProtocolError("proposal transaction digest mismatch")
    if value.get("transactionId") != f"proposal:{expected_digest}":
        raise ProtocolError("proposal transactionId mismatch")
    if len(canonical_json(value).encode("utf-8")) > 512 * 1024:
        raise ProtocolError("proposal transaction exceeds 512 KiB")
    return value


def _proposal_list(value: Any, label: str, maximum: int) -> list[Any]:
    if isinstance(value, list):
        if len(value) > maximum:
            raise ProtocolError(f"{label} exceeds its limit")
        return value
    if isinstance(value, dict) and not value:
        return []
    raise ProtocolError(f"{label} is not a canonical list")


def _portable_resource_name(value: Any, extension: str, label: str, *, allow_empty: bool = False) -> str:
    if allow_empty and value == "":
        return ""
    if (
        not isinstance(value, str)
        or not value
        or len(value) > 240
        or ".." in value
        or value.startswith("/")
        or "\\" in value
        or (len(value) >= 2 and value[0].isalpha() and value[1] == ":")
        or any(ord(char) < 32 for char in value)
        or not value.endswith(extension)
    ):
        raise ProtocolError(f"{label} resource name is invalid")
    return value


_PORTABLE_LOCAL_PARAM_FIELDS = {"entity", "entityId", "localId", "playerEntity", "playerOwned"}


def _validate_portable_plain(value: Any, label: str, *, depth: int = 0, budget: list[int] | None = None) -> None:
    if budget is None:
        budget = [8192]
    if budget[0] <= 0:
        raise ProtocolError(f"{label} exceeds the value limit")
    if depth > 16:
        raise ProtocolError(f"{label} exceeds the depth limit")
    budget[0] -= 1
    if isinstance(value, bool):
        return
    if isinstance(value, (int, float)):
        if not math.isfinite(float(value)) or abs(float(value)) > 1_000_000_000_000:
            raise ProtocolError(f"{label} contains an invalid number")
        return
    if isinstance(value, str):
        if (
            len(value) > 4096
            or any(ord(char) < 32 for char in value)
            or (value.startswith("<") and value.endswith(">"))
        ):
            raise ProtocolError(f"{label} contains an invalid or opaque string")
        return
    if not isinstance(value, dict):
        raise ProtocolError(f"{label} contains a non-portable value")
    for key, nested in value.items():
        if (
            not isinstance(key, str)
            or not key
            or len(key) > 240
            or any(ord(char) < 32 for char in key)
            or key in {"__type", "__truncated"}
        ):
            raise ProtocolError(f"{label} contains an invalid table key")
        if key in _PORTABLE_LOCAL_PARAM_FIELDS:
            raise ProtocolError(f"{label} contains machine-local field {key}")
        _validate_portable_plain(nested, f"{label}.{key}", depth=depth + 1, budget=budget)


def _validate_proposal_transform(value: Any, label: str) -> list[float]:
    if not isinstance(value, list) or len(value) != 16:
        raise ProtocolError(f"{label} transform must be a 4x4 matrix")
    result: list[float] = []
    for item in value:
        if not isinstance(item, (int, float)) or isinstance(item, bool) or not math.isfinite(float(item)):
            raise ProtocolError(f"{label} transform contains a non-finite number")
        if abs(float(item)) > 10_000_000:
            raise ProtocolError(f"{label} transform is outside the supported range")
        result.append(float(item))
    return result


def _validate_edge_reference(value: Any, edge_slots: set[str], label: str) -> None:
    if not isinstance(value, dict) or len(value) != 1 or "slot" not in value:
        raise ProtocolError(f"{label} must reference exactly one new edge slot")
    if value["slot"] not in edge_slots:
        raise ProtocolError(f"{label} references an unknown edge slot")


def validate_proposal_transaction(value: Any) -> dict[str, Any]:
    """Validate schema 5 edge objects and schema 7 portable constructions.

    Empty Lua arrays arrive as ``{}``; the original values are retained in the
    digest view while `_proposal_list` supplies a safe iterable view.
    """
    if not isinstance(value, dict):
        raise ProtocolError("proposal.build transaction must be an object")
    schema_version = value.get("schemaVersion")
    if schema_version not in {PROPOSAL_SCHEMA_VERSION, CONSTRUCTION_PROPOSAL_SCHEMA_VERSION}:
        raise ProtocolError("unsupported proposal schemaVersion")
    expected_root = {
        "schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects",
        "remove", "digest", "transactionId",
    }
    if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        expected_root.add("constructions")
    if set(value) != expected_root:
        raise ProtocolError("proposal transaction has unknown or missing fields")

    company = value.get("companyCid")
    if not isinstance(company, str) or not company.startswith("company:") or not company[8:].isdigit():
        raise ProtocolError("proposal transaction has an invalid companyCid")
    cost = _protocol_int(value.get("cost"), "proposal quoted cost")
    if abs(cost) > 1_000_000_000_000:
        raise ProtocolError("proposal quoted cost is outside the supported range")
    node_limit = (
        MAX_CONSTRUCTION_PROPOSAL_NODES
        if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION
        else MAX_PROPOSAL_NODES
    )
    edge_limit = (
        MAX_CONSTRUCTION_PROPOSAL_EDGES
        if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION
        else MAX_PROPOSAL_EDGES
    )
    nodes = _proposal_list(value.get("nodes"), "proposal nodes", node_limit)
    edges = _proposal_list(value.get("edges"), "proposal edges", edge_limit)

    node_slots: set[str] = set()
    for index, node in enumerate(nodes, 1):
        if not isinstance(node, dict) or set(node) != {"slot", "position"}:
            raise ProtocolError("proposal node has unknown or missing fields")
        slot = f"node:{index}"
        if node.get("slot") != slot:
            raise ProtocolError("proposal node slots must be unique and sequential")
        node_slots.add(slot)
        _proposal_vec3(node.get("position"), f"proposal {slot} position")

    edge_slots: set[str] = set()
    for index, edge in enumerate(edges, 1):
        if not isinstance(edge, dict):
            raise ProtocolError("proposal edge must be an object")
        carrier = edge.get("carrier")
        fields = {
            "slot", "carrier", "node0", "node1", "tangent0", "tangent1", "type", "typeIndex",
            "resource", "logicalOwnerCid", "private",
        }
        if carrier == "track":
            fields.add("catenary")
        if set(edge) != fields:
            raise ProtocolError("proposal edge has unknown or missing fields")
        slot = f"edge:{index}"
        if edge.get("slot") != slot:
            raise ProtocolError("proposal edge slots must be unique and sequential")
        edge_slots.add(slot)
        if carrier not in {"street", "track"}:
            raise ProtocolError("proposal edge has an invalid carrier")
        _proposal_reference(edge.get("node0"), node_slots, f"proposal {slot} node0")
        _proposal_reference(edge.get("node1"), node_slots, f"proposal {slot} node1")
        _proposal_vec3(edge.get("tangent0"), f"proposal {slot} tangent0")
        _proposal_vec3(edge.get("tangent1"), f"proposal {slot} tangent1")
        _protocol_int(edge.get("type"), f"proposal {slot} type")
        _protocol_int(edge.get("typeIndex"), f"proposal {slot} typeIndex")
        resource = edge.get("resource")
        if not isinstance(resource, dict) or not {"index"} <= set(resource) <= {"index", "name"}:
            raise ProtocolError("proposal edge has an invalid resource")
        if _protocol_int(resource.get("index"), f"proposal {slot} resource index") < 0:
            raise ProtocolError("proposal edge resource index must be non-negative")
        if "name" in resource and (
            not isinstance(resource["name"], str) or not resource["name"] or len(resource["name"]) > 240
        ):
            raise ProtocolError("proposal edge resource name is invalid")
        if edge.get("logicalOwnerCid") != company or not isinstance(edge.get("private"), bool):
            raise ProtocolError("proposal edge ownership is invalid")
        if carrier == "track" and not isinstance(edge.get("catenary"), bool):
            raise ProtocolError("proposal track catenary must be boolean")

    remove = value.get("remove")
    if not isinstance(remove, dict) or set(remove) != {"edges", "nodes"}:
        raise ProtocolError("proposal transaction has invalid removal lists")
    removal_values: dict[str, list[Any]] = {}
    for kind, prefix in (("edges", "edge:"), ("nodes", "node:")):
        items = _proposal_list(remove[kind], f"proposal {kind} removals", MAX_PROPOSAL_REMOVALS)
        if any(not isinstance(cid, str) or not cid.startswith(prefix) for cid in items):
            raise ProtocolError(f"proposal {kind} removal list contains a non-canonical id")
        if items != sorted(set(items)):
            raise ProtocolError(f"proposal {kind} removal list must be sorted and unique")
        removal_values[kind] = items

    edge_objects = value.get("edgeObjects")
    if not isinstance(edge_objects, dict) or set(edge_objects) != {"add", "retain", "remove"}:
        raise ProtocolError("proposal edge-object lists are invalid")
    object_adds = _proposal_list(edge_objects["add"], "proposal edge-object additions", MAX_PROPOSAL_EDGE_OBJECTS)
    object_retained = _proposal_list(edge_objects["retain"], "proposal retained edge objects", MAX_PROPOSAL_EDGE_OBJECTS)
    object_removals = _proposal_list(edge_objects["remove"], "proposal edge-object removals", MAX_PROPOSAL_REMOVALS)
    for index, item in enumerate(object_adds, 1):
        fields = {
            "slot", "edge", "param", "oneWay", "left", "model", "name", "category",
            "logicalOwnerCid", "private",
        }
        if not isinstance(item, dict) or set(item) != fields or item.get("slot") != f"edge_object:{index}":
            raise ProtocolError("proposal edge-object slots must be unique and sequential")
        _validate_edge_reference(item.get("edge"), edge_slots, f"edge_object:{index}")
        param = item.get("param")
        if not isinstance(param, (int, float)) or isinstance(param, bool) or not math.isfinite(float(param)) or not 0 <= param <= 1:
            raise ProtocolError("proposal edge-object param is invalid")
        if not all(isinstance(item.get(field), bool) for field in ("oneWay", "left", "private")):
            raise ProtocolError("proposal edge-object flags are invalid")
        _portable_resource_name(item.get("model"), ".mdl", "edge-object model")
        name = item.get("name")
        if not isinstance(name, str) or len(name) > 240 or any(ord(char) < 32 for char in name):
            raise ProtocolError("proposal edge-object name is invalid")
        category = _protocol_int(item.get("category"), "proposal edge-object category")
        if not 0 <= category <= 32 or item.get("logicalOwnerCid") != company:
            raise ProtocolError("proposal edge-object ownership/category is invalid")
    retained_cids: set[str] = set()
    previous_retained: str | None = None
    for item in object_retained:
        if not isinstance(item, dict) or set(item) != {"cid", "edge", "category"}:
            raise ProtocolError("retained edge-object entry is invalid")
        cid = item.get("cid")
        if not isinstance(cid, str) or not cid.startswith("edge_object:") or cid in retained_cids:
            raise ProtocolError("retained edge-object identity is invalid")
        _validate_edge_reference(item.get("edge"), edge_slots, "retained edge object")
        category = _protocol_int(item.get("category"), "retained edge-object category")
        if not 0 <= category <= 32:
            raise ProtocolError("retained edge-object category is invalid")
        key = f"{item['edge']['slot']}:{category:03d}:{cid}"
        if previous_retained is not None and key <= previous_retained:
            raise ProtocolError("retained edge objects must be canonically sorted")
        previous_retained = key
        retained_cids.add(cid)
    if any(not isinstance(cid, str) or not cid.startswith("edge_object:") for cid in object_removals):
        raise ProtocolError("proposal edge-object removal contains a non-canonical id")
    if object_removals != sorted(set(object_removals)) or retained_cids.intersection(object_removals):
        raise ProtocolError("proposal edge-object removals are duplicated, unsorted, or retained")

    if schema_version == PROPOSAL_SCHEMA_VERSION:
        if not edges and not removal_values["edges"] and not removal_values["nodes"] and not object_adds and not object_removals:
            raise ProtocolError("schema 5 proposal contains no world change")
    else:
        constructions = _proposal_list(value.get("constructions"), "proposal constructions", 1)
        if len(constructions) != 1:
            raise ProtocolError("schema 7 proposal requires one construction change")
        construction = constructions[0]
        fields = {
            "slot", "mode", "adapter", "kind", "sourceCid", "fileName",
            "transform", "params", "modules", "collateral",
        }
        if not isinstance(construction, dict) or set(construction) != fields or construction.get("slot") != "construction:1":
            raise ProtocolError("schema 7 construction has unknown or missing fields")
        mode, adapter, kind = construction.get("mode"), construction.get("adapter"), construction.get("kind")
        if mode not in {"build", "upgrade", "remove"}:
            raise ProtocolError("construction change mode is invalid")
        if adapter not in {"stock-rail-station", "portable-construction"}:
            raise ProtocolError("construction adapter is invalid")
        if kind not in {"rail_station", "station", "depot", "construction", "asset"}:
            raise ProtocolError("construction kind is invalid")
        if mode == "build" and kind == "depot" and any(
            edge.get("carrier") == "track"
            and isinstance(endpoint, dict)
            and isinstance(endpoint.get("cid"), str)
            for edge in edges
            for endpoint in (edge.get("node0"), edge.get("node1"))
        ):
            raise ProtocolError(
                "network depot snapped to existing track; place the depot clear of track, "
                "wait for synchronization, then connect it with a separate track build"
            )
        source = construction.get("sourceCid")
        if mode == "build":
            if source != "":
                raise ProtocolError("construction build cannot contain a source")
        else:
            source_prefix = "asset:" if kind == "asset" else "construction:"
            if not isinstance(source, str) or not source.startswith(source_prefix):
                raise ProtocolError("construction upgrade/removal has no canonical source")
        collateral = _proposal_list(
            construction.get("collateral"), "construction collateral", MAX_CONSTRUCTION_COLLATERAL
        )
        previous_collateral: str | None = None
        for item in collateral:
            if not isinstance(item, dict) or set(item) != {"kind", "cid"}:
                raise ProtocolError("construction collateral entry is invalid")
            collateral_kind, cid = item.get("kind"), item.get("cid")
            if collateral_kind not in {"construction", "asset"}:
                raise ProtocolError("construction collateral kind is invalid")
            if not isinstance(cid, str) or not cid.startswith(collateral_kind + ":"):
                raise ProtocolError("construction collateral has no canonical source")
            key = f"{collateral_kind}:{cid}"
            if previous_collateral is not None and key <= previous_collateral:
                raise ProtocolError("construction collateral must be sorted and unique")
            previous_collateral = key
        if mode == "upgrade" and collateral:
            raise ProtocolError("construction upgrade cannot contain collateral demolition")
        source_kind = "asset" if kind == "asset" else "construction"
        if mode != "build" and any(
            item["kind"] == source_kind and item["cid"] == source for item in collateral
        ):
            raise ProtocolError("construction source cannot also be collateral")
        if mode == "remove":
            if (
                construction.get("fileName") != ""
                or construction.get("transform") != {}
                or construction.get("params") != {}
                or construction.get("modules") != {}
            ):
                raise ProtocolError("construction removal contains a build payload")
        else:
            _portable_resource_name(construction.get("fileName"), ".con", "construction")
            transform_values = _validate_proposal_transform(construction.get("transform"), "construction")
            params = construction.get("params")
            if not isinstance(params, dict):
                raise ProtocolError("construction params are invalid")
            _validate_portable_plain(params, "construction params")
            modules = _proposal_list(construction.get("modules"), "construction modules", MAX_STATION_MODULES)
            last_slot = 0
            observed_modules: dict[int, str] = {}
            for module in modules:
                if not isinstance(module, dict) or set(module) != {"slot", "name", "variant", "metadata"}:
                    raise ProtocolError("construction module has unknown or missing fields")
                slot = _protocol_int(module.get("slot"), "construction module slot")
                variant = _protocol_int(module.get("variant"), "construction module variant")
                if slot <= last_slot or not 0 <= variant <= 65535:
                    raise ProtocolError("construction module slot/variant is invalid")
                last_slot = slot
                _portable_resource_name(module.get("name"), ".module", "construction module")
                metadata = module.get("metadata")
                if not isinstance(metadata, dict):
                    raise ProtocolError("construction module metadata is invalid")
                _validate_portable_plain(metadata, "construction module metadata")
                observed_modules[slot] = module["name"]
            if adapter == "stock-rail-station":
                if mode != "build" or kind != "rail_station" or construction.get("fileName") != "station/rail/modular_station/modular_station.con":
                    raise ProtocolError("stock station adapter only supports station placement")
                epsilon = 0.002
                if any(abs(transform_values[index - 1]) > epsilon for index in (3, 4, 7, 8, 9, 10, 12)):
                    raise ProtocolError("station transform is not planar affine")
                if abs(transform_values[10] - 1) > epsilon or abs(transform_values[15] - 1) > epsilon:
                    raise ProtocolError("station transform has an invalid homogeneous axis")
                a, b, c, d = transform_values[0], transform_values[1], transform_values[4], transform_values[5]
                if (
                    abs(a * a + b * b - 1) > epsilon
                    or abs(c * c + d * d - 1) > epsilon
                    or abs(a * c + b * d) > epsilon
                    or abs(a * d - b * c - 1) > epsilon
                ):
                    raise ProtocolError("station transform contains scale, skew, or reflection")
                param_fields = {"year", "seed", "trackType", "catenary", "length", "tracks", "paramX", "paramY"}
                if set(params) != param_fields:
                    raise ProtocolError("station params have unknown or missing fields")
                numeric = {field: _protocol_int(params[field], f"station {field}") for field in param_fields}
                if (
                    not 1850 <= numeric["year"] <= 3000
                    or not 0 <= numeric["seed"] <= 2_147_483_647
                    or numeric["trackType"] not in {0, 1}
                    or numeric["catenary"] not in {0, 1}
                    or not 0 <= numeric["length"] <= 4
                    or not 0 <= numeric["tracks"] <= 7
                    or numeric["paramX"] != 0
                    or numeric["paramY"] != 0
                ):
                    raise ProtocolError("station layout parameters are outside the stock modular menu range")
                if not modules or any(module["variant"] != 0 or module["metadata"] != {} for module in modules):
                    raise ProtocolError("stock station module entry is invalid")
                expected_sets = [
                    _stock_station_modules(numeric, cargo=cargo, head=head)
                    for cargo in (False, True) for head in (False, True)
                ]
                if not any(observed_modules == expected for expected in expected_sets):
                    raise ProtocolError("station module set does not match the supported stock template")
                _validate_stock_station_graph(nodes, edges, numeric)

    content = {
        "schemaVersion": schema_version,
        "companyCid": company,
        "cost": cost,
        "nodes": value["nodes"],
        "edges": value["edges"],
        "edgeObjects": edge_objects,
        "remove": remove,
    }
    if schema_version == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        content["constructions"] = value["constructions"]
    expected_digest = checksum(content)
    if value.get("digest") != expected_digest:
        raise ProtocolError("proposal transaction digest mismatch")
    if value.get("transactionId") != f"proposal:{expected_digest}":
        raise ProtocolError("proposal transactionId mismatch")
    if len(canonical_json(value).encode("utf-8")) > 2 * 1024 * 1024:
        raise ProtocolError("proposal transaction exceeds 2 MiB")
    return value


def _operation_cid(value: Any, kind: str | None = None) -> bool:
    if not isinstance(value, str) or not value or len(value) > 240 or any(ord(c) < 32 for c in value):
        return False
    return kind is None or value.startswith(kind + ":")


def _operation_color(value: Any) -> bool:
    return isinstance(value, dict) and set(value) == {"r", "g", "b"} and all(
        isinstance(value[field], int) and not isinstance(value[field], bool) and 0 <= value[field] <= 1000
        for field in ("r", "g", "b")
    )


def _operation_line(value: Any, schema_version: int) -> None:
    if not isinstance(value, dict) or set(value) != {"stops"}:
        raise ProtocolError("operation line must contain only stops")
    # Lua's JSON encoder serialises an empty array-shaped table as `{}` because
    # it has no numeric key from which to infer arrayness.  Accept that one
    # representation only for the genuine zero-stop New Line state.
    stops = _lua_array(value["stops"], empty=True)
    # Vanilla New Line creates a zero-stop entity and the editor then commits
    # one UpdateLine per stop. Preserve those intermediate native states.
    if not 0 <= len(stops) <= MAX_OPERATION_STOPS:
        raise ProtocolError("operation line has an invalid stop count")
    total_alternatives = 0
    for stop in stops:
        fields = {"stationGroupCid", "station", "terminal"}
        if schema_version != LEGACY_OPERATION_SCHEMA_VERSION:
            fields.add("alternativeTerminals")
        if not isinstance(stop, dict) or set(stop) != fields:
            raise ProtocolError("operation line stop has unknown or missing fields")
        if not _operation_cid(stop["stationGroupCid"], "station_group"):
            raise ProtocolError("operation line stop has an invalid canonical station group")
        for field in ("station", "terminal"):
            if not isinstance(stop[field], int) or isinstance(stop[field], bool) or not 0 <= stop[field] <= 4095:
                raise ProtocolError(f"operation line stop {field} is invalid")
        if schema_version != LEGACY_OPERATION_SCHEMA_VERSION:
            alternatives = _lua_array(stop["alternativeTerminals"], empty=True)
            if schema_version == FLAT_ALTERNATIVE_OPERATION_SCHEMA_VERSION:
                if len(alternatives) % 2 or len(alternatives) // 2 > MAX_OPERATION_ALTERNATIVE_TERMINALS \
                        or any(not isinstance(item, int) or isinstance(item, bool)
                               or not 0 <= item <= 4095 for item in alternatives):
                    raise ProtocolError("operation line stop flat alternative terminals are invalid")
                total_alternatives += len(alternatives) // 2
            elif len(alternatives) > MAX_OPERATION_ALTERNATIVE_TERMINALS or any(
                not isinstance(item, dict) or set(item) != {"station", "terminal"}
                or any(not isinstance(item[field], int) or isinstance(item[field], bool)
                       or not 0 <= item[field] <= 4095 for field in ("station", "terminal"))
                for item in alternatives
            ):
                raise ProtocolError("operation line stop StationTerminal pairs are invalid")
            else:
                total_alternatives += len(alternatives)
            if total_alternatives > MAX_OPERATION_ALTERNATIVE_TERMINALS_TOTAL:
                raise ProtocolError("operation line contains too many alternative terminals")


def _lua_array(value: Any, *, empty: bool = False) -> list[Any]:
    if isinstance(value, list):
        return value
    if empty and isinstance(value, dict) and not value:
        return []
    raise ProtocolError("operation field is not an array")


def _operation_vehicle_config(value: Any) -> None:
    if not isinstance(value, dict) or set(value) != {"vehicles", "vehicleGroups"}:
        raise ProtocolError("operation vehicle config has unknown or missing fields")
    vehicles = _lua_array(value["vehicles"])
    if not 1 <= len(vehicles) <= MAX_OPERATION_VEHICLE_PARTS:
        raise ProtocolError("operation vehicle config has an invalid part count")
    for part in vehicles:
        if not isinstance(part, dict) or set(part) != {"model", "reversed", "loadConfig", "color", "logo"}:
            raise ProtocolError("operation vehicle part has unknown or missing fields")
        model = part["model"]
        if not isinstance(model, str) or not model.startswith("vehicle/") \
                or not model.endswith(".mdl") or ".." in model or "\\" in model \
                or len(model) > 240 or any(ord(c) < 32 for c in model):
            raise ProtocolError("operation vehicle part is not a portable vehicle model")
        if not isinstance(part["reversed"], bool) or not _operation_color(part["color"]):
            raise ProtocolError("operation vehicle part settings are invalid")
        if not isinstance(part["logo"], str) or len(part["logo"]) > 240 or any(ord(c) < 32 for c in part["logo"]):
            raise ProtocolError("operation vehicle logo is invalid")
        load_config = _lua_array(part["loadConfig"])
        if not load_config or len(load_config) > 64 or any(
            not isinstance(item, int) or isinstance(item, bool) or not 0 <= item <= 255
            for item in load_config
        ):
            raise ProtocolError("operation vehicle load config is invalid")
    groups = _lua_array(value["vehicleGroups"])
    if not groups or len(groups) > len(vehicles) or any(
        not isinstance(item, int) or isinstance(item, bool) or not 1 <= item <= len(vehicles)
        for item in groups
    ) or sum(groups) != len(vehicles):
        raise ProtocolError("operation vehicle groups are invalid")


def validate_operation_transaction(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "kind", "companyCid", "data", "digest", "transactionId"
    }:
        raise ProtocolError("operation transaction has unknown or missing fields")
    if value["schemaVersion"] not in {
        LEGACY_OPERATION_SCHEMA_VERSION,
        FLAT_ALTERNATIVE_OPERATION_SCHEMA_VERSION,
        STATION_TERMINAL_OPERATION_SCHEMA_VERSION,
        OPERATION_SCHEMA_VERSION,
    }:
        raise ProtocolError("unsupported operation schemaVersion")
    kind, company, data = value["kind"], value["companyCid"], value["data"]
    if not isinstance(kind, str) or not _operation_cid(company, "company") or not isinstance(data, dict):
        raise ProtocolError("operation transaction identity is invalid")

    unary_vehicle = {"vehicle.reverse", "vehicle.sell", "vehicle.depart"}
    if kind == "line.create":
        if set(data) != {"name", "color", "line"} or not isinstance(data["name"], str) \
                or not data["name"] or len(data["name"]) > 160 or not _operation_color(data["color"]):
            raise ProtocolError("line.create data is invalid")
        _operation_line(data["line"], value["schemaVersion"])
    elif kind == "line.update":
        if set(data) != {"targetCid", "line"} or not _operation_cid(data["targetCid"], "line"):
            raise ProtocolError("line.update data is invalid")
        _operation_line(data["line"], value["schemaVersion"])
    elif kind == "line.delete":
        if set(data) != {"targetCid"} or not _operation_cid(data["targetCid"], "line"):
            raise ProtocolError("line.delete data is invalid")
    elif kind == "vehicle.buy":
        if set(data) != {"depotCid", "config"} or not _operation_cid(data["depotCid"], "depot"):
            raise ProtocolError("vehicle.buy data is invalid")
        _operation_vehicle_config(data["config"])
    elif kind == "vehicle.replace":
        if set(data) != {"targetCid", "config"} or not _operation_cid(data["targetCid"], "vehicle"):
            raise ProtocolError("vehicle.replace data is invalid")
        _operation_vehicle_config(data["config"])
    elif kind == "vehicle.assign":
        if set(data) != {"targetCid", "lineCid", "stopIndex"} \
                or not _operation_cid(data["targetCid"], "vehicle") \
                or not _operation_cid(data["lineCid"], "line") \
                or not isinstance(data["stopIndex"], int) or isinstance(data["stopIndex"], bool) \
                or not -1 <= data["stopIndex"] < MAX_OPERATION_STOPS:
            raise ProtocolError("vehicle.assign data is invalid")
    elif kind == "vehicle.stop":
        if set(data) != {"targetCid", "stopped"} or not _operation_cid(data["targetCid"], "vehicle") \
                or not isinstance(data["stopped"], bool):
            raise ProtocolError("vehicle.stop data is invalid")
    elif kind == "vehicle.send_to_depot":
        if set(data) != {"targetCid", "sellOnArrival"} \
                or not _operation_cid(data["targetCid"], "vehicle") \
                or not isinstance(data["sellOnArrival"], bool):
            raise ProtocolError("vehicle.send_to_depot data is invalid")
    elif kind == "vehicle.maintenance":
        if set(data) != {"targetCid", "valueBasisPoints"} \
                or not _operation_cid(data["targetCid"], "vehicle") \
                or not isinstance(data["valueBasisPoints"], int) \
                or isinstance(data["valueBasisPoints"], bool) \
                or not 0 <= data["valueBasisPoints"] <= 10000:
            raise ProtocolError("vehicle.maintenance data is invalid")
    elif kind == "entity.name":
        if set(data) != {"targetCid", "name"} or not _operation_cid(data["targetCid"]) \
                or not isinstance(data["name"], str) or len(data["name"]) > 160:
            raise ProtocolError("entity.name data is invalid")
    elif kind == "entity.color":
        if set(data) != {"targetCid", "color"} or not _operation_cid(data["targetCid"]) \
                or not _operation_color(data["color"]):
            raise ProtocolError("entity.color data is invalid")
    elif kind == "vehicle.manual_departure":
        if set(data) != {"targetCid", "manual"} or not _operation_cid(data["targetCid"], "vehicle") \
                or not isinstance(data["manual"], bool):
            raise ProtocolError("vehicle.manual_departure data is invalid")
    elif kind in unary_vehicle:
        if set(data) != {"targetCid"} or not _operation_cid(data["targetCid"], "vehicle"):
            raise ProtocolError(f"{kind} data is invalid")
    elif kind == "vehicle.sell_batch":
        targets = data.get("targetCids")
        if value["schemaVersion"] != OPERATION_SCHEMA_VERSION \
                or set(data) != {"targetCids"} or not isinstance(targets, list) \
                or not 2 <= len(targets) <= MAX_OPERATION_VEHICLE_BATCH \
                or any(not _operation_cid(target, "vehicle") for target in targets) \
                or targets != sorted(targets) or len(set(targets)) != len(targets):
            raise ProtocolError("vehicle.sell_batch data is invalid")
    else:
        raise ProtocolError(f"unsupported canonical operation kind: {kind}")

    content = {
        "schemaVersion": value["schemaVersion"], "kind": kind, "companyCid": company, "data": data,
    }
    expected = checksum(content)
    if value["digest"] != expected or value["transactionId"] != f"operation:{expected}":
        raise ProtocolError("operation transaction digest mismatch")
    if len(canonical_json(value).encode("utf-8")) > 512 * 1024:
        raise ProtocolError("operation transaction exceeds 512 KiB")
    return value


def validate_vehicle_phase_proof(value: Any) -> dict[str, Any]:
    try:
        return normalise_vehicle_phase_proof(value)
    except VehiclePhaseProofError as exc:
        raise ProtocolError(str(exc)) from exc


def validate_action(action: Any) -> dict[str, Any]:
    if not isinstance(action, dict):
        raise ProtocolError("action must be an object")
    action_type = action.get("type")
    if action_type not in NETWORK_ACTIONS:
        raise ProtocolError(f"action is not network-safe or supported: {action_type}")
    if "localLineId" in action:
        raise ProtocolError("network actions may not contain machine-local line IDs")
    if action_type in {"line.register", "fare.adjust"} and not isinstance(action.get("lineCid"), str):
        raise ProtocolError(f"{action_type} requires a canonical lineCid")
    if action_type == "line.register":
        if not isinstance(action.get("companyCid"), str):
            raise ProtocolError("line.register requires companyCid")
        if not isinstance(action.get("market"), dict) or not isinstance(action.get("service"), dict):
            raise ProtocolError("line.register requires host-normalized market and service facts")
        # Lua and Python round non-integers differently (Lua's util.integer
        # adds an epsilon before flooring). Numeric facts therefore have to
        # arrive as exact integers or a fractional value would replay to
        # different models on the two sides.
        for payload, fields in (
            (action["market"], ("demand", "votCentsPerHour", "gcOutsideCents", "thetaCents",
                                "waitWeightPm", "transferSeconds", "demandResid")),
            (action["service"], ("headwaySeconds", "journeySeconds", "fareCents", "capacity",
                                  "quality", "transfers", "sharePpm", "shareResid",
                                   "lagLoadPpm", "lastFareCents", "annualVehicleUpkeepCents",
                                   "upkeepResid", "capacityResid", "revenueMultiplierResid")),
        ):
            for field in fields:
                value = payload.get(field)
                if value is None:
                    continue
                if isinstance(value, bool) or not isinstance(value, int):
                    raise ProtocolError(f"line.register {field} must be an integer")
        market_metadata = action["market"].get("metadata", {})
        if isinstance(market_metadata, dict):
            for field in ("townSizeA", "townSizeB"):
                if field in market_metadata and (
                    isinstance(market_metadata[field], bool)
                    or not isinstance(market_metadata[field], int)
                    or not 1 <= market_metadata[field] <= 100_000
                ):
                    raise ProtocolError(f"line.register market {field} is invalid")
        vehicle_costs = action.get("vehicleCosts", {})
        if not isinstance(vehicle_costs, dict):
            raise ProtocolError("line.register vehicleCosts must be an object")
        service_metadata = action["service"].get("metadata", {})
        metadata_error = validate_line_metadata(
            market_metadata, service_metadata, action["service"].get("enabled", True),
        )
        if metadata_error:
            raise ProtocolError(metadata_error)
        service_vehicle_values = _lua_array(
            service_metadata.get("vehicleCids", {}) if isinstance(service_metadata, dict) else {},
            empty=True,
        )
        if not all(
            _operation_cid(value, "vehicle") for value in service_vehicle_values
        ) or len(set(service_vehicle_values)) != len(service_vehicle_values):
            raise ProtocolError("line.register service vehicleCids are invalid")
        service_vehicles = set(service_vehicle_values)
        if isinstance(service_metadata, dict):
            validate_registration(service_metadata, service_vehicle_values,
                                  service_vehicles, _operation_cid, ProtocolError)
        for vehicle_cid, record in vehicle_costs.items():
            if not _operation_cid(vehicle_cid, "vehicle") or vehicle_cid not in service_vehicles:
                raise ProtocolError("line.register vehicleCosts contains an unrelated vehicle")
            if not isinstance(record, dict) or set(record) != {
                "vehicleCid", "companyCid", "annualVehicleUpkeepCents", "upkeepResid"
            }:
                raise ProtocolError("line.register vehicle cost record is malformed")
            if record["vehicleCid"] != vehicle_cid \
                    or record["companyCid"] != action["companyCid"]:
                raise ProtocolError("line.register vehicle cost identity mismatch")
            annual = record["annualVehicleUpkeepCents"]
            residual = record["upkeepResid"]
            if isinstance(annual, bool) or not isinstance(annual, int) \
                    or not 0 <= annual <= 1_000_000_000_000_000 \
                    or isinstance(residual, bool) or not isinstance(residual, int) \
                    or not 0 <= residual < 10_800:
                raise ProtocolError("line.register vehicle cost values are invalid")
    if action_type == "fare.adjust" and not isinstance(action.get("deltaCents"), int):
        raise ProtocolError("fare.adjust requires integer deltaCents")
    if action_type == "economy.settle":
        if not isinstance(action.get("results"), dict):
            raise ProtocolError("economy.settle requires host-computed results")
        if "scheduled" in action and not isinstance(action.get("scheduled"), bool):
            raise ProtocolError("economy.settle requires a scheduled boolean")
        boundary = action.get("boundaryGameTimeSeconds")
        if boundary is not None and (
            isinstance(boundary, bool) or not isinstance(boundary, int) or boundary < 0
        ):
            raise ProtocolError("economy.settle requires a non-negative accounting boundary")
        delivery = action.get("deliverySnapshot")
        if delivery is not None:
            if not isinstance(delivery, dict) or delivery.get("schemaVersion") not in {1, 2, 3}:
                raise ProtocolError("economy.settle delivery snapshot is malformed")
            presentation_epoch = delivery.get("presentationEpoch")
            if isinstance(presentation_epoch, bool) or not isinstance(presentation_epoch, int) \
                    or not 0 <= presentation_epoch <= 1_000_000_000:
                raise ProtocolError("economy.settle delivery snapshot header is invalid")
            if delivery["schemaVersion"] == 1:
                if set(delivery) != {"schemaVersion", "presentationEpoch", "lines"} \
                        or not isinstance(delivery.get("lines"), dict):
                    raise ProtocolError("economy.settle legacy delivery header is invalid")
                passenger_lines, cargo_lines = delivery["lines"], {}
            else:
                if set(delivery) != {
                    "schemaVersion", "presentationEpoch", "passengerLines", "cargoLines"
                } or not isinstance(delivery.get("passengerLines"), dict) \
                        or not isinstance(delivery.get("cargoLines"), dict):
                    raise ProtocolError("economy.settle delivery header is invalid")
                passenger_lines, cargo_lines = delivery["passengerLines"], delivery["cargoLines"]
            for line_cid, row in passenger_lines.items():
                if not _operation_cid(line_cid, "line") or not isinstance(row, dict) \
                        or set(row) != {"deliveredPassengers", "earnedRevenueCents"}:
                    raise ProtocolError("economy.settle passenger delivery line is malformed")
                passengers = row["deliveredPassengers"]
                earned = row["earnedRevenueCents"]
                if isinstance(passengers, bool) or not isinstance(passengers, int) \
                        or not 0 <= passengers <= 1_000_000_000 \
                        or isinstance(earned, bool) or not isinstance(earned, int) \
                        or not 0 <= earned <= 1_000_000_000_000_000:
                    raise ProtocolError("economy.settle passenger delivery values are invalid")
            validate_delivery_rows(cargo_lines, _operation_cid, ProtocolError)
    if action_type == "world.freeze" and not isinstance(action.get("freeze"), bool):
        raise ProtocolError("world.freeze requires a boolean freeze value")
    if action_type == "match.initialise" and "rules" in action:
        rules = action.get("rules")
        if not isinstance(rules, dict):
            raise ProtocolError("match.initialise rules must be an object")
        for field in ("maxEpochs", "valuationTargetCents"):
            if not isinstance(rules.get(field), int) or isinstance(rules.get(field), bool) or rules[field] < 0:
                raise ProtocolError(f"match.initialise rules require non-negative integer {field}")
        for field in ("economyEpochSeconds", "economyStartGameTimeSeconds"):
            if field in rules and (
                not isinstance(rules.get(field), int)
                or isinstance(rules.get(field), bool)
                or rules[field] < 0
            ):
                raise ProtocolError(f"match.initialise rules require non-negative integer {field}")
        if "startingCash" in rules and (
            not isinstance(rules.get("startingCash"), int)
            or isinstance(rules.get("startingCash"), bool)
            or rules["startingCash"] < 0
        ):
            raise ProtocolError("match.initialise rules require non-negative integer startingCash")
        difficulty = rules.get("economyDifficulty")
        multiplier = rules.get("revenueMultiplierPpm")
        multipliers = {"hard": 600_000, "normal": 1_000_000,
                       "easy": 1_500_000, "relaxed": 2_000_000}
        # Historical event records predate the save-owned setting and migrate
        # to Normal. New normalized actions always carry both fields.
        if difficulty is not None or multiplier is not None:
            if difficulty not in multipliers:
                raise ProtocolError("match.initialise rules require a known economyDifficulty")
            if multiplier != multipliers[difficulty]:
                raise ProtocolError("match.initialise economy difficulty multiplier is inconsistent")
    if action_type == "match.finish":
        if not isinstance(action.get("winnerCid"), str) or not isinstance(action.get("reason"), str):
            raise ProtocolError("match.finish requires a canonical winnerCid and reason")
    if action_type in {"probe.mobility", "probe.structural"} and set(action) - {"type"}:
        raise ProtocolError(f"{action_type} has no client-supplied fields")
    if action_type == "clock.request":
        if set(action) != {"type", "requestedSpeed"}:
            raise ProtocolError("clock.request has unknown or missing fields")
        requested = _protocol_int(action.get("requestedSpeed"), "clock requestedSpeed")
        if requested < 0 or requested > 4:
            raise ProtocolError("clock requestedSpeed must be from 0 through 4")
    if action_type == "clock.set":
        if set(action) != {
            "type", "requestedSpeed", "effectiveSpeed", "generation", "reason"
        }:
            raise ProtocolError("clock.set has unknown or missing fields")
        requested = _protocol_int(action.get("requestedSpeed"), "clock requestedSpeed")
        effective = _protocol_int(action.get("effectiveSpeed"), "clock effectiveSpeed")
        generation = _protocol_int(action.get("generation"), "clock generation")
        if requested < 0 or requested > 4 or effective < 0 or effective > requested:
            raise ProtocolError("clock.set has an invalid requested/effective speed")
        if generation < 1 or not isinstance(action.get("reason"), str) or not action["reason"]:
            raise ProtocolError("clock.set requires a positive generation and reason")
    if action_type == "clock.rendezvous":
        expected = {
            "type", "requestedSpeed", "approachSpeed", "releaseSpeed",
            "generation", "targetGameTime", "reason",
        }
        if set(action) != expected:
            raise ProtocolError("clock.rendezvous has unknown or missing fields")
        requested = _protocol_int(action.get("requestedSpeed"), "clock requestedSpeed")
        approach = _protocol_int(action.get("approachSpeed"), "clock approachSpeed")
        release = _protocol_int(action.get("releaseSpeed"), "clock releaseSpeed")
        generation = _protocol_int(action.get("generation"), "clock generation")
        target = action.get("targetGameTime")
        if requested < 0 or requested > 4 or approach < 0 or approach > 4 \
                or release < 0 or release > requested:
            raise ProtocolError("clock.rendezvous has invalid speed fields")
        if generation < 1 or not isinstance(target, (int, float)) or isinstance(target, bool) \
                or not math.isfinite(float(target)) or target < 0:
            raise ProtocolError("clock.rendezvous has an invalid generation or target")
        if not isinstance(action.get("reason"), str) or not action["reason"]:
            raise ProtocolError("clock.rendezvous requires a reason")
    if action_type == "vehicle.sync_release":
        legacy = {
            "type", "vehicleCid", "lineCid", "round", "stopIndex",
            "releaseAtGameTime", "releaseWhilePaused",
        }
        fields = frozenset(action)
        if fields not in {frozenset(legacy), frozenset(legacy | {"schedule"})}:
            raise ProtocolError("vehicle.sync_release has unknown or missing fields")
        if not isinstance(action.get("vehicleCid"), str) \
                or not action["vehicleCid"].startswith("vehicle:"):
            raise ProtocolError("vehicle.sync_release requires a canonical vehicleCid")
        if not isinstance(action.get("lineCid"), str) or not action["lineCid"].startswith("line:"):
            raise ProtocolError("vehicle.sync_release requires a canonical lineCid")
        round_number = _protocol_int(action.get("round"), "vehicle sync round")
        stop_index = _protocol_int(action.get("stopIndex"), "vehicle sync stopIndex")
        release_time = action.get("releaseAtGameTime")
        if round_number < 1 or round_number > 1_000_000_000 or not 0 <= stop_index < 256:
            raise ProtocolError("vehicle.sync_release round/stop is outside its supported range")
        if not isinstance(release_time, (int, float)) or isinstance(release_time, bool) \
                or not math.isfinite(float(release_time)) or release_time < 0:
            raise ProtocolError("vehicle.sync_release release time is invalid")
        if not isinstance(action.get("releaseWhilePaused"), bool):
            raise ProtocolError("vehicle.sync_release releaseWhilePaused must be boolean")
        schedule = validate_vehicle_schedule(
            action.get("schedule", {"schemaVersion": 1, "enabled": False}), release=True
        )
        if schedule["enabled"] and (
            float(release_time) != float(schedule["scheduledDepartureAt"])
            or action["releaseWhilePaused"]
        ):
            raise ProtocolError("scheduled vehicle release time/pause mode is inconsistent")
    if action_type == "town.develop":
        # The host's development batch: canonical town ids to a small whole
        # number of native development calls. Bounded so a malformed or
        # runaway batch cannot flood either world with buildings.
        if set(action) - {"type", "batch"} or "batch" not in action:
            raise ProtocolError("town.develop has unknown or missing fields")
        batch = action["batch"]
        if not isinstance(batch, Mapping) or not batch or len(batch) > 512:
            raise ProtocolError("town.develop batch is empty or too large")
        for town_cid, calls in batch.items():
            if not isinstance(town_cid, str) or not town_cid.startswith("town:") \
                    or len(town_cid) > 320:
                raise ProtocolError("town.develop batch has an invalid town id")
            if not isinstance(calls, int) or isinstance(calls, bool) or not 1 <= calls <= 8:
                raise ProtocolError("town.develop call count is out of range")
    if action_type == "content.industry_attest":
        expected = {
            "type", "peer", "digest", "resourceCount",
            "variantCount", "ambiguousCount",
        }
        if set(action) != expected:
            raise ProtocolError("content.industry_attest has unknown or missing fields")
        peer = action.get("peer")
        digest = action.get("digest")
        if not isinstance(peer, str) or not re.fullmatch(r"player[1-9][0-9]*", peer) \
                or len(peer) > 64:
            raise ProtocolError("content.industry_attest peer is invalid")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{8}", digest):
            raise ProtocolError("content.industry_attest digest is invalid")
        counts = {}
        for field in ("resourceCount", "variantCount", "ambiguousCount"):
            value = action.get(field)
            if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 1_000_000:
                raise ProtocolError(f"content.industry_attest {field} is invalid")
            counts[field] = value
        if counts["resourceCount"] < 1 \
                or counts["variantCount"] < counts["resourceCount"] \
                or counts["ambiguousCount"] > counts["variantCount"]:
            raise ProtocolError("content.industry_attest counts are inconsistent")
    if action_type == "freight.industry_bootstrap":
        from .freight_protocol import validate_industry_bootstrap
        validate_industry_bootstrap(action)
    if action_type in {"freight.milestone", "passenger.milestone"}:
        try:
            validate_aboard_milestone(action, action_type, MAX_EXACT_INTEGER)
        except AboardMilestoneError as exc:
            raise ProtocolError(str(exc)) from exc
    if action_type == "recovery.prepare":
        if set(action) != {"type"}:
            raise ProtocolError("recovery.prepare has client-supplied fields")
    if action_type == "recovery.requalify":
        recovery_error = fault_recovery_validation_error(action, MAX_EXACT_INTEGER)
        if recovery_error:
            raise ProtocolError(recovery_error)
    if action_type == "recovery.resume":
        expected = {
            "type", "fromSession", "boundarySeq", "coreDigest",
            "convergenceKey", "planChecksum", "vehiclePhaseDigest",
        }
        if set(action) != expected:
            raise ProtocolError("recovery.resume has unknown or missing fields")
        source = action.get("fromSession")
        boundary = _protocol_int(action.get("boundarySeq"), "restore boundarySeq")
        if not isinstance(source, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", source):
            raise ProtocolError("recovery.resume source session is invalid")
        if boundary < 1 or boundary > MAX_EXACT_INTEGER:
            raise ProtocolError("recovery.resume boundarySeq is invalid")
        for field in (
            "coreDigest", "convergenceKey", "planChecksum", "vehiclePhaseDigest",
        ):
            value = action.get(field)
            if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{8}", value):
                raise ProtocolError(f"recovery.resume {field} is invalid")
    if action_type == "recovery.continue":
        expected = {
            "type", "fromSession", "sourceStateVersion",
            "sourceCoreDigest", "saveFingerprint",
        }
        if set(action) != expected:
            raise ProtocolError("recovery.continue has unknown or missing fields")
        source = action.get("fromSession")
        if not isinstance(source, str) or not re.fullmatch(
            r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", source
        ):
            raise ProtocolError("recovery.continue source session is invalid")
        source_version = _protocol_int(
            action.get("sourceStateVersion"), "saved-match sourceStateVersion"
        )
        if source_version < 1 or source_version > MAX_EXACT_INTEGER:
            raise ProtocolError("recovery.continue sourceStateVersion is invalid")
        digest = action.get("sourceCoreDigest")
        fingerprint = action.get("saveFingerprint")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{8}", digest):
            raise ProtocolError("recovery.continue sourceCoreDigest is invalid")
        if not isinstance(fingerprint, str) or not re.fullmatch(
            r"[0-9a-f]{64}", fingerprint
        ):
            raise ProtocolError("recovery.continue saveFingerprint is invalid")
    if action_type == "network.checkpoint_request":
        if set(action) != {
            "type", "preparationSeq", "reason", "vehiclePhaseProof",
        }:
            raise ProtocolError("network.checkpoint_request has unknown or missing fields")
        preparation = _protocol_int(
            action.get("preparationSeq"), "checkpoint request preparationSeq"
        )
        reason = action.get("reason")
        if preparation < 1 or preparation > MAX_EXACT_INTEGER:
            raise ProtocolError("network checkpoint request preparationSeq is invalid")
        if not isinstance(reason, str) or reason != f"recovery-prepare:{preparation}":
            raise ProtocolError("network checkpoint request reason is invalid")
        validate_vehicle_phase_proof(action.get("vehiclePhaseProof"))
    if action_type == "recovery.save_receipt":
        # A peer declaring "I wrote a native save of this exact agreed
        # boundary, while paused, with nothing ordered since". The claim is
        # ordered so the other peer sees it, and the host only trusts it after
        # checking its own commit history for the same window.
        receipt_error = receipt_validation_error(action, MAX_EXACT_INTEGER)
        if receipt_error:
            raise ProtocolError(receipt_error)
    if action_type == "network.sync_fault":
        if set(action) != {"type", "scope", "errorCode"}:
            raise ProtocolError("network.sync_fault has unknown or missing fields")
        if action.get("scope") not in {"authored", "clock", "vehicle"}:
            raise ProtocolError("network.sync_fault scope is invalid")
        error_code = action.get("errorCode")
        if not isinstance(error_code, str) or not error_code or len(error_code) > 512:
            raise ProtocolError("network.sync_fault errorCode is invalid")
    if action_type in {"proposal.prepare", "proposal.build"}:
        if set(action) != {"type", "transaction"}:
            raise ProtocolError(f"{action_type} has unknown or missing fields")
        validate_proposal_transaction(action.get("transaction"))
        for index, edge in enumerate(action["transaction"]["edges"], 1):
            resource = edge.get("resource", {})
            if not isinstance(resource.get("name"), str) or not resource["name"]:
                raise ProtocolError(
                    f"proposal edge:{index} requires a stable resource name on the network"
                )
    if action_type == "operation.execute":
        allowed = {"type", "transaction", "originCaptureToken"}
        if not {"type", "transaction"} <= set(action) or set(action) - allowed:
            raise ProtocolError("operation.execute has unknown or missing fields")
        validate_operation_transaction(action.get("transaction"))
        token = action.get("originCaptureToken")
        if token is not None:
            if (
                not isinstance(token, str)
                or len(token) > 160
                or re.fullmatch(
                    r"[A-Za-z0-9_.-]+:(?:line|operation)-origin:[0-9]+", token
                ) is None
            ):
                raise ProtocolError("operation.execute has an invalid optimistic-origin token")
            if action["transaction"]["kind"] not in {
                "line.create", "line.update", "line.delete", "entity.name", "entity.color"
            }:
                raise ProtocolError(
                    "operation.execute optimistic-origin token is invalid for this operation kind"
                )
    return action


def hello(
    session: str,
    peer: str,
    last_commit_seq: int = 0,
    match_fingerprint: str | None = None,
) -> dict[str, Any]:
    return sign(
        {
            "protocol": PROTOCOL_VERSION,
            "session": session,
            "kind": "hello",
            "peer": peer,
            "last_commit_seq": int(last_commit_seq),
            "match_fingerprint": match_fingerprint,
        }
    )
