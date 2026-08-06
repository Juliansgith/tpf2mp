from __future__ import annotations

import json
import os
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

from tpf2mp.bridge import AuditLog, GameBridge, atomic_write
from tpf2mp.checkpoint import analyse_bridge, verify_checkpoint, verify_event_record
from tpf2mp.cli import replay
from tpf2mp.manifest import build_manifest, load_manifest, write_manifest
from tpf2mp.network import CommitClient, CommitHost
from tpf2mp.protocol import (
    CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
    MAX_PROPOSAL_OUTPUTS,
    ProtocolError,
    canonical_json,
    checksum,
    decode_line,
    sign,
    validate_action,
)
from tpf2mp.recovery import (
    build_recovery_plan,
    verify_recovery_archive,
    verify_recovery_plan,
    write_recovery_archive,
)
from tpf2mp.research import latest_research, render_markdown, write_report


def wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.025)
    return False


def available_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def proposal_transaction(company: str = "company:2") -> dict:
    content = {
        "schemaVersion": 5,
        "companyCid": company,
        "cost": 25_000,
        "nodes": [
            {"slot": "node:1", "position": {"x": 10, "y": 20, "z": 3}},
            {"slot": "node:2", "position": {"x": 90, "y": 20, "z": 4}},
        ],
        "edges": [
            {
                "slot": "edge:1",
                "carrier": "track",
                "node0": {"slot": "node:1"},
                "node1": {"slot": "node:2"},
                "tangent0": {"x": 80, "y": 0, "z": 1},
                "tangent1": {"x": 80, "y": 0, "z": 1},
                "type": 0,
                "typeIndex": -1,
                "resource": {"index": 1, "name": "standard.lua"},
                "logicalOwnerCid": company,
                "private": True,
                "catenary": True,
            }
        ],
        "edgeObjects": {"add": [], "retain": [], "remove": []},
        "remove": {"edges": [], "nodes": []},
    }
    digest = checksum(content)
    return {**content, "digest": digest, "transactionId": f"proposal:{digest}"}


def redigest_proposal(transaction: dict) -> dict:
    fields = ["schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove"]
    if transaction["schemaVersion"] == CONSTRUCTION_PROPOSAL_SCHEMA_VERSION:
        fields.append("constructions")
    content = {key: transaction[key] for key in fields}
    transaction["digest"] = checksum(content)
    transaction["transactionId"] = f"proposal:{transaction['digest']}"
    return transaction


def portable_construction_transaction(
    company: str = "company:2",
    *,
    kind: str = "construction",
    mode: str = "build",
    source: str = "",
) -> dict:
    construction = {
        "slot": "construction:1",
        "mode": mode,
        "adapter": "portable-construction",
        "kind": kind,
        "sourceCid": source,
        "fileName": "depot/train_depot.con" if kind == "depot" else "asset/bench.con",
        "transform": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 250, 500, 8, 1],
        "params": {
            "seed": 17,
            "year": 1990,
            "variant": {"1": "brick", "2": True},
        },
        "modules": [
            {
                "slot": 1000,
                "name": "depot/train/basic.module",
                "variant": 2,
                "metadata": {"platform": "left"},
            }
        ] if kind == "depot" else {},
    }
    if mode == "remove":
        construction.update({"fileName": "", "transform": {}, "params": {}, "modules": {}})
    content = {
        "schemaVersion": CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        "companyCid": company,
        "cost": 48_500 if mode != "remove" else -4_000,
        "nodes": {},
        "edges": {},
        "edgeObjects": {"add": {}, "retain": {}, "remove": {}},
        "remove": {"edges": {}, "nodes": {}},
        "constructions": [construction],
    }
    digest = checksum(content)
    return {**content, "digest": digest, "transactionId": f"proposal:{digest}"}


def station_proposal_transaction(
    company: str = "company:2",
    *,
    main_building_slot: int = 3_700_000,
    catenary: int = 1,
    transform: list[int | float] | None = None,
) -> dict:
    nodes = [
        {"slot": f"node:{index}", "position": {"x": 100 + index * 2, "y": 200, "z": 5}}
        for index in range(1, 14)
    ]
    edges = [
        {
            "slot": f"edge:{index}",
            "carrier": "track",
            "node0": {"slot": f"node:{index}"},
            "node1": {"slot": f"node:{index + 1}"},
            "tangent0": {"x": 2, "y": 0, "z": 0},
            "tangent1": {"x": 2, "y": 0, "z": 0},
            "type": 0,
            "typeIndex": -1,
            "resource": {"index": 1, "name": "standard.lua"},
            "logicalOwnerCid": company,
            "private": True,
            "catenary": bool(catenary),
        }
        for index in range(1, 13)
    ]
    prefix = "station/rail/modular_station/"
    modules = [
        {"slot": main_building_slot, "name": prefix + "main_building_1_era_c.module", "variant": 0},
        {"slot": 7_400_000, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
        {"slot": 7_400_010, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
        {
            "slot": 8_401_000,
            "name": prefix + ("platform_track_catenary.module" if catenary else "platform_track.module"),
            "variant": 0,
        },
        {
            "slot": 8_401_010,
            "name": prefix + ("platform_track_catenary.module" if catenary else "platform_track.module"),
            "variant": 0,
        },
        {"slot": 10_400_000, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
        {"slot": 10_400_010, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
        {"slot": 10_800_000, "name": prefix + "addon_platform_passenger_stairs_era_c.module", "variant": 0},
    ]
    for module in modules:
        module["metadata"] = {}
    content = {
        "schemaVersion": CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        "companyCid": company,
        "cost": 121_073,
        "nodes": nodes,
        "edges": edges,
        "edgeObjects": {"add": [], "retain": [], "remove": []},
        "remove": {"edges": [], "nodes": []},
        "constructions": [
            {
                "slot": "construction:1",
                "mode": "build",
                "adapter": "stock-rail-station",
                "kind": "rail_station",
                "sourceCid": "",
                "fileName": prefix + "modular_station.con",
                "transform": transform or [0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 100, 200, 5, 1],
                "params": {
                    "year": 1992,
                    "seed": 2,
                    "trackType": 0,
                    "catenary": catenary,
                    "length": 0,
                    "tracks": 0,
                    "paramX": 0,
                    "paramY": 0,
                },
                "modules": modules,
            }
        ],
    }
    digest = checksum(content)
    return {**content, "digest": digest, "transactionId": f"proposal:{digest}"}


def station_with_paths(transaction: dict, path_node_counts: list[int], *, catenary: bool) -> dict:
    company = transaction["companyCid"]
    nodes: list[dict] = []
    edges: list[dict] = []
    for path_index, path_node_count in enumerate(path_node_counts, 1):
        path_slots: list[str] = []
        for path_position in range(1, path_node_count + 1):
            slot = f"node:{len(nodes) + 1}"
            path_slots.append(slot)
            nodes.append({
                "slot": slot,
                "position": {"x": path_position * 2, "y": path_index * 10, "z": 5},
            })
        for path_position in range(path_node_count - 1):
            edges.append({
                "slot": f"edge:{len(edges) + 1}",
                "carrier": "track",
                "node0": {"slot": path_slots[path_position]},
                "node1": {"slot": path_slots[path_position + 1]},
                "tangent0": {"x": 2, "y": 0, "z": 0},
                "tangent1": {"x": 2, "y": 0, "z": 0},
                "type": 0,
                "typeIndex": -1,
                "resource": {"index": 1, "name": "standard.lua"},
                "logicalOwnerCid": company,
                "private": True,
                "catenary": catenary,
            })
    transaction["nodes"], transaction["edges"] = nodes, edges
    for module in transaction["constructions"][0]["modules"]:
        module.setdefault("metadata", {})
    content = {
        key: transaction[key]
        for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove", "constructions")
    }
    transaction["digest"] = checksum(content)
    transaction["transactionId"] = f"proposal:{transaction['digest']}"
    return transaction


def proposal_completion(
    session: str,
    peer: str,
    local_seq: int,
    transaction: dict,
    *,
    commit_seq: int = 1,
    result_digest: str = "11111111",
    core_digest: str = "22222222",
    finance_delta: int = -1234,
    success: bool = True,
) -> dict:
    payload = {
        "proposalId": f"{session}:player2:{commit_seq}",
        "commitSeq": commit_seq,
        "proposalDigest": transaction["digest"],
        "success": success,
        "outputs": [
            {"kind": "node", "cid": f"node:created:{commit_seq}:1", "slot": "node:1"},
            {"kind": "node", "cid": f"node:created:{commit_seq}:2", "slot": "node:2"},
            {"kind": "edge", "cid": f"edge:created:{commit_seq}:1", "slot": "edge:1"},
        ] if success else [],
        "financeDelta": finance_delta,
        "coreDigest": core_digest,
        "resultDigest": result_digest,
    }
    if not success:
        payload.pop("financeDelta")
        payload["errorCode"] = "native-proposal-failed"
    return {
        "kind": "completion",
        "peer": peer,
        "local_seq": local_seq,
        "payload": payload,
    }


def proposal_prepare_ack(
    peer: str,
    local_seq: int,
    prepare_seq: int,
    *,
    success: bool = True,
    digest: str = "22222222",
    error: str | None = None,
) -> dict:
    payload: dict[str, object] = {
        "commitSeq": prepare_seq,
        "success": success,
        "digest": digest,
    }
    if error is not None:
        payload["error"] = error
    return {"kind": "ack", "peer": peer, "local_seq": local_seq, "payload": payload}


def pass_proposal_prepare(host: CommitHost, intent: dict) -> tuple[dict, dict]:
    prepare = host._commit(intent)
    assert prepare is not None
    prepare_seq = int(prepare["seq"])
    host._record_non_intent(proposal_prepare_ack("player1", 90, prepare_seq))
    host._record_non_intent(proposal_prepare_ack("player2", 91, prepare_seq))
    tracker = host.proposal_prepares[prepare_seq]
    build = host.commits[int(tracker["buildSeq"])]
    return prepare, build


def operation_transaction(company: str = "company:2") -> dict:
    content = {
        "schemaVersion": 1,
        "kind": "line.create",
        "companyCid": company,
        "data": {
            "name": "MP Intercity",
            "color": {"r": 80, "g": 420, "b": 1000},
            "line": {
                "stops": [
                    {"stationGroupCid": "station_group:pre:a", "station": 0, "terminal": 0},
                    {"stationGroupCid": "station_group:pre:b", "station": 0, "terminal": 0},
                ]
            },
        },
    }
    digest = checksum(content)
    return {**content, "digest": digest, "transactionId": f"operation:{digest}"}


def operation_completion(
    session: str,
    peer: str,
    local_seq: int,
    transaction: dict,
    *,
    commit_seq: int = 1,
    result_digest: str = "44444444",
    core_digest: str = "55555555",
    finance_delta: int = 0,
    success: bool = True,
) -> dict:
    payload = {
        "operationId": f"{session}:player2:{commit_seq}",
        "commitSeq": commit_seq,
        "operationDigest": transaction["digest"],
        "success": success,
        "outputs": [
            {"kind": "line", "cid": f"line:event:{session}:player2:{commit_seq}:1", "slot": "line:1"}
        ] if success else [],
        "postcondition": {
            "kind": "line.create",
            "targetCid": f"line:event:{session}:player2:{commit_seq}:1",
            "exists": True,
            "stops": transaction["data"]["line"]["stops"],
        } if success else {},
        "financeDelta": finance_delta,
        "coreDigest": core_digest,
        "resultDigest": result_digest,
    }
    if not success:
        payload.pop("financeDelta")
        payload["errorCode"] = "native-operation-failed"
    return {
        "kind": "operation_completion",
        "peer": peer,
        "local_seq": local_seq,
        "payload": payload,
    }


def consensus_checkpoint(
    session: str,
    peer: str,
    local_seq: int,
    boundary_seq: int,
    reason: str,
    *,
    autonomy_frozen: bool = False,
    financial_delta: int = 0,
) -> dict:
    payload = CheckpointTests.checkpoint_payload()
    payload["sessionId"] = session
    payload["peerId"] = peer
    payload["reason"] = reason
    payload["tick"] = boundary_seq * 10
    payload["model"]["autonomyFrozen"] = autonomy_frozen
    payload["modelDigest"] = checksum(payload["model"])
    core = json.loads(json.dumps(payload["model"]))
    core["canonical"] = payload["canonical"]
    core["vehicleSynchronization"] = payload["vehicleSynchronization"]
    payload["coreDigest"] = checksum(core)
    payload["financial"]["companies"]["company:2"]["balance"] += financial_delta
    payload["financialDigest"] = checksum(payload["financial"])
    payload["eventCursor"]["lastCommitSeq"] = boundary_seq
    payload["convergenceKey"] = checksum(
        {
            "checkpointVersion": payload["checkpointVersion"],
            "stateVersion": payload["stateVersion"],
            "protocol": payload["protocol"],
            "sessionId": session,
            "lastCommitSeq": boundary_seq,
            "modelDigest": payload["modelDigest"],
            "canonicalDigest": payload["canonicalDigest"],
            "vehicleSynchronizationDigest": payload["vehicleSynchronizationDigest"],
            "coreDigest": payload["coreDigest"],
            "financialDigest": payload["financialDigest"],
        }
    )
    payload.pop("checkpointDigest", None)
    payload["checkpointDigest"] = checksum(payload)
    return {
        "kind": "checkpoint",
        "peer": peer,
        "local_seq": local_seq,
        "payload": payload,
    }


def vehicle_sync_record(
    peer: str,
    local_seq: int,
    state: str,
    *,
    round_number: int = 1,
    stop_index: int = 0,
    game_time: float = 100.0,
    detail: str = "",
) -> dict:
    return {
        "kind": "vehicle_sync",
        "peer": peer,
        "local_seq": local_seq,
        "payload": {
            "schemaVersion": 1,
            "vehicleCid": "vehicle:event:station-sync:1",
            "lineCid": "line:event:station-sync:1",
            "round": round_number,
            "stopIndex": stop_index,
            "state": state,
            "gameTime": game_time,
            "engineTick": local_seq,
            "detail": detail,
        },
    }


class ProtocolTests(unittest.TestCase):
    def test_cross_language_vector(self) -> None:
        value = {"b": 2, "a": "x"}
        self.assertEqual(canonical_json(value), '{"a":"x","b":2}')
        self.assertEqual(checksum(value), "1ec003d2")

    def test_windows_lua_halfway_float_vector(self) -> None:
        value = {"v": 3.3974685668945313}
        self.assertEqual(canonical_json(value), '{"v":3.3974685668945313}')
        self.assertEqual(checksum(value), "47a605a5")

    def test_signed_zero_is_canonicalised_across_json_parsers(self) -> None:
        self.assertEqual(canonical_json({"transform": [-0.0, 0.0]}), '{"transform":[0,0]}')
        parsed = json.loads('{"transform":[-0,0]}')
        self.assertEqual(canonical_json(parsed), '{"transform":[0,0]}')
        self.assertEqual(checksum({"transform": [-0.0, 0.0]}), checksum(parsed))

    def test_tamper_is_rejected(self) -> None:
        message = sign({"kind": "probe", "value": 1})
        message["value"] = 2
        with self.assertRaises(ProtocolError):
            decode_line(canonical_json(message))

    def test_machine_local_ids_are_rejected_on_the_wire(self) -> None:
        with self.assertRaises(ProtocolError):
            validate_action({"type": "line.register", "localLineId": 42})
        self.assertEqual(
            validate_action({"type": "fare.adjust", "lineCid": "line:pre:abc", "deltaCents": 100})["lineCid"],
            "line:pre:abc",
        )

    def test_match_lifecycle_actions_require_canonical_rules_and_result(self) -> None:
        initial = validate_action(
            {
                "type": "match.initialise",
                "rules": {"startingCash": 5_000_000, "maxEpochs": 24, "valuationTargetCents": 50_000_000},
            }
        )
        self.assertEqual(initial["rules"]["maxEpochs"], 24)
        self.assertEqual(
            validate_action({"type": "match.finish", "winnerCid": "company:2", "reason": "epoch-limit"})[
                "winnerCid"
            ],
            "company:2",
        )
        with self.assertRaises(ProtocolError):
            validate_action({"type": "match.initialise", "rules": {"maxEpochs": -1, "valuationTargetCents": 0}})
        with self.assertRaises(ProtocolError):
            validate_action(
                {
                    "type": "match.initialise",
                    "rules": {"startingCash": -1, "maxEpochs": 24, "valuationTargetCents": 0},
                }
            )

    def test_mobility_sample_is_host_ordered_and_has_no_client_payload(self) -> None:
        self.assertEqual(validate_action({"type": "probe.mobility"}), {"type": "probe.mobility"})
        with self.assertRaises(ProtocolError):
            validate_action({"type": "probe.mobility", "sampleKey": "forged"})

    def test_shared_clock_actions_are_strict_and_bounded(self) -> None:
        self.assertEqual(
            validate_action({"type": "clock.request", "requestedSpeed": 4})["requestedSpeed"],
            4,
        )
        accepted = validate_action({
            "type": "clock.set",
            "requestedSpeed": 4,
            "effectiveSpeed": 2,
            "generation": 7,
            "reason": "adaptive-slowest-peer-cap",
        })
        self.assertEqual(accepted["effectiveSpeed"], 2)
        rendezvous = validate_action({
            "type": "clock.rendezvous",
            "requestedSpeed": 3,
            "approachSpeed": 2,
            "releaseSpeed": 3,
            "generation": 8,
            "targetGameTime": 123.5,
            "reason": "player-request:player1",
        })
        self.assertEqual(rendezvous["targetGameTime"], 123.5)
        release = validate_action({
            "type": "vehicle.sync_release",
            "vehicleCid": "vehicle:event:test:1",
            "lineCid": "line:event:test:1",
            "round": 1,
            "stopIndex": 0,
            "releaseAtGameTime": 130.0,
            "releaseWhilePaused": False,
        })
        self.assertEqual(release["round"], 1)
        with self.assertRaisesRegex(ProtocolError, "0 through 4"):
            validate_action({"type": "clock.request", "requestedSpeed": 5})
        with self.assertRaisesRegex(ProtocolError, "invalid requested/effective"):
            validate_action({
                "type": "clock.set", "requestedSpeed": 1, "effectiveSpeed": 2,
                "generation": 1, "reason": "invalid",
            })
        with self.assertRaisesRegex(ProtocolError, "release time"):
            validate_action({**release, "releaseAtGameTime": float("nan")})

    def test_canonical_proposal_transaction_is_strict_and_tamper_evident(self) -> None:
        transaction = proposal_transaction()
        action = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(action["transaction"]["companyCid"], "company:2")
        self.assertEqual(action["transaction"]["edges"][0]["catenary"], True)

        tampered = json.loads(json.dumps(transaction))
        tampered["nodes"][0]["position"]["x"] = 11
        with self.assertRaisesRegex(ProtocolError, "digest mismatch"):
            validate_action({"type": "proposal.build", "transaction": tampered})

        local_id = json.loads(json.dumps(transaction))
        local_id["edges"][0]["node0"] = {"localId": 1234}
        content = {
            key: local_id[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove")
        }
        local_id["digest"] = checksum(content)
        local_id["transactionId"] = f"proposal:{local_id['digest']}"
        with self.assertRaises(ProtocolError):
            validate_action({"type": "proposal.build", "transaction": local_id})

    def test_signal_payloads_and_retained_edge_objects_are_strict(self) -> None:
        transaction = proposal_transaction()
        transaction["edgeObjects"] = {
            "add": [
                {
                    "slot": "edge_object:1",
                    "edge": {"slot": "edge:1"},
                    "param": 0.45,
                    "oneWay": True,
                    "left": False,
                    "model": "railroad/signal_path_a.mdl",
                    "name": "Block signal",
                    "category": 2,
                    "logicalOwnerCid": "company:2",
                    "private": True,
                }
            ],
            "retain": [
                {
                    "cid": "edge_object:event:test:old-signal",
                    "edge": {"slot": "edge:1"},
                    "category": 2,
                }
            ],
            "remove": ["edge_object:event:test:obsolete"],
        }
        redigest_proposal(transaction)
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["edgeObjects"]["add"][0]["model"], "railroad/signal_path_a.mdl")
        self.assertEqual(accepted["transaction"]["edgeObjects"]["retain"][0]["edge"], {"slot": "edge:1"})

        local_model = json.loads(json.dumps(transaction))
        local_model["edgeObjects"]["add"][0]["model"] = "model-id:314"
        redigest_proposal(local_model)
        with self.assertRaisesRegex(ProtocolError, "model resource name"):
            validate_action({"type": "proposal.build", "transaction": local_model})

        retained_and_removed = json.loads(json.dumps(transaction))
        retained_and_removed["edgeObjects"]["remove"] = ["edge_object:event:test:old-signal"]
        redigest_proposal(retained_and_removed)
        with self.assertRaisesRegex(ProtocolError, "retained"):
            validate_action({"type": "proposal.build", "transaction": retained_and_removed})

    def test_portable_depot_asset_upgrade_and_removal_payloads(self) -> None:
        depot = portable_construction_transaction(kind="depot")
        accepted_depot = validate_action({"type": "proposal.build", "transaction": depot})
        self.assertEqual(accepted_depot["transaction"]["constructions"][0]["kind"], "depot")
        self.assertEqual(
            accepted_depot["transaction"]["constructions"][0]["params"]["variant"]["1"],
            "brick",
        )

        asset = portable_construction_transaction(kind="asset")
        accepted_asset = validate_action({"type": "proposal.build", "transaction": asset})
        self.assertEqual(accepted_asset["transaction"]["nodes"], {})

        upgrade = portable_construction_transaction(
            kind="asset", mode="upgrade", source="asset:event:test:asset"
        )
        upgrade["constructions"][0]["params"]["variant"]["1"] = "steel"
        redigest_proposal(upgrade)
        self.assertEqual(
            validate_action({"type": "proposal.build", "transaction": upgrade})["transaction"]["constructions"][0]["mode"],
            "upgrade",
        )

        removal = portable_construction_transaction(
            kind="asset", mode="remove", source="asset:event:test:asset"
        )
        self.assertEqual(
            validate_action({"type": "proposal.build", "transaction": removal})["transaction"]["constructions"][0]["fileName"],
            "",
        )

        opaque = json.loads(json.dumps(asset))
        opaque["constructions"][0]["params"]["callback"] = "<function>"
        redigest_proposal(opaque)
        with self.assertRaisesRegex(ProtocolError, "opaque string"):
            validate_action({"type": "proposal.build", "transaction": opaque})

        local_field = json.loads(json.dumps(asset))
        local_field["constructions"][0]["params"]["entityId"] = 4501
        redigest_proposal(local_field)
        with self.assertRaisesRegex(ProtocolError, "machine-local field"):
            validate_action({"type": "proposal.build", "transaction": local_field})

        bad_remove = json.loads(json.dumps(removal))
        bad_remove["constructions"][0]["fileName"] = "asset/bench.con"
        redigest_proposal(bad_remove)
        with self.assertRaisesRegex(ProtocolError, "build payload"):
            validate_action({"type": "proposal.build", "transaction": bad_remove})

    def test_stock_station_transaction_and_compound_outputs_are_strict(self) -> None:
        transaction = station_proposal_transaction()
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(
            accepted["transaction"]["schemaVersion"],
            CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        )
        self.assertEqual(len(accepted["transaction"]["nodes"]), 13)
        self.assertEqual(len(accepted["transaction"]["edges"]), 12)

        malformed = json.loads(json.dumps(transaction))
        malformed["constructions"][0]["modules"][3]["name"] = (
            "station/rail/modular_station/platform_track.module"
        )
        content = {
            key: malformed[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove", "constructions")
        }
        malformed["digest"] = checksum(content)
        malformed["transactionId"] = f"proposal:{malformed['digest']}"
        with self.assertRaisesRegex(ProtocolError, "module set"):
            validate_action({"type": "proposal.build", "transaction": malformed})

        # Live capture: the stock through-station uses slot 3400020; the
        # corresponding terminus template above uses 3700000.
        rotated = station_proposal_transaction(
            main_building_slot=3_400_020,
            catenary=0,
            transform=[0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 350, 425, 6, 1],
        )
        accepted_rotated = validate_action({"type": "proposal.build", "transaction": rotated})
        self.assertEqual(accepted_rotated["transaction"]["constructions"][0]["modules"][0]["slot"], 3_400_020)

        unsupported_slot = json.loads(json.dumps(rotated))
        unsupported_slot["constructions"][0]["modules"][0]["slot"] = 3_600_000
        content = {
            key: unsupported_slot[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove", "constructions")
        }
        unsupported_slot["digest"] = checksum(content)
        unsupported_slot["transactionId"] = f"proposal:{unsupported_slot['digest']}"
        with self.assertRaisesRegex(ProtocolError, "module set"):
            validate_action({"type": "proposal.build", "transaction": unsupported_slot})

        prefix = "station/rail/modular_station/"
        cargo = station_proposal_transaction(main_building_slot=3_400_020, catenary=0)
        cargo["constructions"][0]["modules"] = [
            {"slot": 3_400_020, "name": prefix + "main_building_1_cargo.module", "variant": 0},
            {"slot": 6_400_000, "name": prefix + "platform_cargo_era_c.module", "variant": 0},
            {"slot": 6_400_010, "name": prefix + "platform_cargo_era_c.module", "variant": 0},
            {"slot": 8_402_000, "name": prefix + "platform_track.module", "variant": 0},
            {"slot": 8_402_010, "name": prefix + "platform_track.module", "variant": 0},
        ]
        cargo = station_with_paths(cargo, [13], catenary=False)
        self.assertEqual(
            len(validate_action({"type": "proposal.build", "transaction": cargo})["transaction"]["constructions"][0]["modules"]),
            5,
        )

        longer = station_proposal_transaction(main_building_slot=3_400_000, catenary=0)
        longer["constructions"][0]["params"]["length"] = 1
        longer["constructions"][0]["modules"] = [
            {"slot": 3_400_000, "name": prefix + "main_building_1_era_c.module", "variant": 0},
            {"slot": 7_399_990, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 7_400_000, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 7_400_010, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 8_400_990, "name": prefix + "platform_track.module", "variant": 0},
            {"slot": 8_401_000, "name": prefix + "platform_track.module", "variant": 0},
            {"slot": 8_401_010, "name": prefix + "platform_track.module", "variant": 0},
            {"slot": 10_399_990, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_400_000, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_400_010, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_800_000, "name": prefix + "addon_platform_passenger_stairs_era_c.module", "variant": 0},
        ]
        longer = station_with_paths(longer, [19], catenary=False)
        accepted_longer = validate_action({"type": "proposal.build", "transaction": longer})
        self.assertEqual(len(accepted_longer["transaction"]["edges"]), 18)

        two_track = station_proposal_transaction(main_building_slot=3_701_000, catenary=1)
        params = two_track["constructions"][0]["params"]
        params["trackType"], params["tracks"] = 1, 1
        two_track["constructions"][0]["modules"] = [
            {"slot": 3_701_000, "name": prefix + "main_building_1_era_c.module", "variant": 0},
            {"slot": 7_400_000, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 7_400_010, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 7_403_000, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 7_403_010, "name": prefix + "platform_passenger_era_c.module", "variant": 0},
            {"slot": 8_401_000, "name": prefix + "platform_high_speed_track_catenary.module", "variant": 0},
            {"slot": 8_401_010, "name": prefix + "platform_high_speed_track_catenary.module", "variant": 0},
            {"slot": 8_402_000, "name": prefix + "platform_high_speed_track_catenary.module", "variant": 0},
            {"slot": 8_402_010, "name": prefix + "platform_high_speed_track_catenary.module", "variant": 0},
            {"slot": 10_400_000, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_400_010, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_403_000, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_403_010, "name": prefix + "platform_passenger_roof_era_c.module", "variant": 0},
            {"slot": 10_800_000, "name": prefix + "addon_platform_passenger_stairs_era_c.module", "variant": 0},
            {"slot": 10_803_000, "name": prefix + "addon_platform_passenger_stairs_era_c.module", "variant": 0},
        ]
        two_track = station_with_paths(two_track, [13, 13], catenary=True)
        accepted_two_track = validate_action({"type": "proposal.build", "transaction": two_track})
        self.assertEqual(len(accepted_two_track["transaction"]["nodes"]), 26)

        completion = proposal_completion("station-test", "player1", 1, transaction)["payload"]
        completion["outputs"] = [
            {"kind": "construction", "cid": "construction:event:test:1", "slot": "construction:1"},
            {"kind": "station", "cid": "station:event:test:1", "slot": "station:1"},
            {"kind": "station_group", "cid": "station_group:event:test:1", "slot": "station_group:1"},
        ]
        self.assertEqual(len(CommitHost._completion_payload(completion)["outputs"]), 3)

        # Live maximum-size stock station: 8 tracks at 320 m produced 392
        # nodes, 384 edges, and three compound identities (779 outputs).  The
        # completion validator must admit every result a valid schema-7
        # transaction can produce, while retaining a finite protocol bound.
        maximum_outputs = [
            {"kind": "node", "cid": f"node:event:test:{index}", "slot": f"node:{index}"}
            for index in range(1, 1025)
        ]
        maximum_outputs.extend(
            {"kind": "edge", "cid": f"edge:event:test:{index}", "slot": f"edge:{index}"}
            for index in range(1, 1025)
        )
        maximum_outputs.extend(
            {"kind": "edge_object", "cid": f"edge_object:event:test:{index}", "slot": f"edge_object:{index}"}
            for index in range(1, 257)
        )
        maximum_outputs.extend(
            {"kind": "asset", "cid": f"asset:event:test:{index}", "slot": f"asset:{index}"}
            for index in range(1, 62)
        )
        maximum_outputs.extend(
            [
                {"kind": "construction", "cid": "construction:event:test:1", "slot": "construction:1"},
                {"kind": "station", "cid": "station:event:test:1", "slot": "station:1"},
                {"kind": "station_group", "cid": "station_group:event:test:1", "slot": "station_group:1"},
            ]
        )
        completion["outputs"] = maximum_outputs
        self.assertEqual(len(CommitHost._completion_payload(completion)["outputs"]), MAX_PROPOSAL_OUTPUTS)

        completion["outputs"] = maximum_outputs + [
            {"kind": "depot", "cid": "depot:event:test:1", "slot": "depot:1"}
        ]
        with self.assertRaisesRegex(ProtocolError, "outputs are invalid"):
            CommitHost._completion_payload(completion)

    def test_canonical_line_operation_is_strict_and_tamper_evident(self) -> None:
        transaction = operation_transaction()
        action = validate_action({"type": "operation.execute", "transaction": transaction})
        self.assertEqual(action["transaction"]["kind"], "line.create")
        self.assertEqual(action["transaction"]["companyCid"], "company:2")

        optimistic = validate_action(
            {
                "type": "operation.execute",
                "transaction": transaction,
                "originCaptureToken": "player2:line-origin:17",
            }
        )
        self.assertEqual(optimistic["originCaptureToken"], "player2:line-origin:17")

        operation_token = validate_action(
            {
                "type": "operation.execute",
                "transaction": transaction,
                "originCaptureToken": "player2:operation-origin:18",
            }
        )
        self.assertEqual(operation_token["originCaptureToken"], "player2:operation-origin:18")
        for invalid_token in (17, "player2:line-origin:x", "player2:other:17", "x" * 161):
            with self.assertRaisesRegex(ProtocolError, "optimistic-origin token"):
                validate_action(
                    {
                        "type": "operation.execute",
                        "transaction": transaction,
                        "originCaptureToken": invalid_token,
                    }
                )

        for kind, data in (
            ("entity.name", {"targetCid": "line:event:test:1", "name": ""}),
            (
                "entity.color",
                {
                    "targetCid": "line:event:test:1",
                    "color": {"r": 125, "g": 500, "b": 875},
                },
            ),
        ):
            mutation = json.loads(json.dumps(transaction))
            mutation["kind"] = kind
            mutation["data"] = data
            content = {
                key: mutation[key]
                for key in ("schemaVersion", "kind", "companyCid", "data")
            }
            mutation["digest"] = checksum(content)
            mutation["transactionId"] = f"operation:{mutation['digest']}"
            accepted = validate_action(
                {
                    "type": "operation.execute",
                    "transaction": mutation,
                    "originCaptureToken": "player2:operation-origin:19",
                }
            )
            self.assertEqual(accepted["transaction"]["kind"], kind)

        tampered = json.loads(json.dumps(transaction))
        tampered["data"]["line"]["stops"][0]["stationGroupCid"] = "station_group:pre:forged"
        with self.assertRaisesRegex(ProtocolError, "digest mismatch"):
            validate_action({"type": "operation.execute", "transaction": tampered})

        local_id = json.loads(json.dumps(transaction))
        local_id["data"]["localLineId"] = 42
        content = {key: local_id[key] for key in ("schemaVersion", "kind", "companyCid", "data")}
        local_id["digest"] = checksum(content)
        local_id["transactionId"] = f"operation:{local_id['digest']}"
        with self.assertRaises(ProtocolError):
            validate_action({"type": "operation.execute", "transaction": local_id})

    def test_canonical_line_operation_accepts_vanilla_empty_line_encodings(self) -> None:
        for empty_stops in ([], {}):
            transaction = operation_transaction()
            transaction["data"]["line"]["stops"] = empty_stops
            content = {
                key: transaction[key]
                for key in ("schemaVersion", "kind", "companyCid", "data")
            }
            transaction["digest"] = checksum(content)
            transaction["transactionId"] = f"operation:{transaction['digest']}"
            accepted = validate_action({"type": "operation.execute", "transaction": transaction})
            self.assertEqual(accepted["transaction"]["data"]["line"]["stops"], empty_stops)

    def test_canonical_line_operation_accepts_one_stop_editor_state(self) -> None:
        transaction = operation_transaction()
        transaction["kind"] = "line.update"
        transaction["data"] = {
            "targetCid": "line:event:test:1",
            "line": {
                "stops": [
                    {"stationGroupCid": "station_group:pre:a", "station": 3, "terminal": 4}
                ]
            },
        }
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"operation:{transaction['digest']}"
        accepted = validate_action({"type": "operation.execute", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["data"]["line"]["stops"][0]["terminal"], 4)

    def test_canonical_train_purchase_accepts_vanilla_waggons_only(self) -> None:
        content = {
            "schemaVersion": 1,
            "kind": "vehicle.buy",
            "companyCid": "company:2",
            "data": {
                "depotCid": "depot:pre:abc",
                "config": {
                    "vehicles": [
                        {
                            "model": "vehicle/train/db_v100_v2.mdl",
                            "reversed": False,
                            "loadConfig": [0],
                            "color": {"r": 1000, "g": 1000, "b": 1000},
                            "logo": "",
                        },
                        {
                            "model": "vehicle/waggon/open_1910.mdl",
                            "reversed": False,
                            "loadConfig": [0],
                            "color": {"r": 1000, "g": 1000, "b": 1000},
                            "logo": "",
                        },
                    ],
                    "vehicleGroups": [1, 1],
                },
            },
        }
        digest = checksum(content)
        transaction = {
            **content,
            "digest": digest,
            "transactionId": f"operation:{digest}",
        }
        accepted = validate_action({"type": "operation.execute", "transaction": transaction})
        self.assertEqual(
            accepted["transaction"]["data"]["config"]["vehicles"][1]["model"],
            "vehicle/waggon/open_1910.mdl",
        )
        invalid = json.loads(json.dumps(transaction))
        invalid["data"]["config"]["vehicles"][1]["model"] = "vehicle/bus/benz.mdl"
        invalid_content = {
            key: invalid[key] for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        invalid["digest"] = checksum(invalid_content)
        invalid["transactionId"] = f"operation:{invalid['digest']}"
        with self.assertRaisesRegex(ProtocolError, "railway model"):
            validate_action({"type": "operation.execute", "transaction": invalid})

        invalid_load = json.loads(json.dumps(transaction))
        invalid_load["data"]["config"]["vehicles"][0]["loadConfig"] = [-1]
        invalid_load_content = {
            key: invalid_load[key]
            for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        invalid_load["digest"] = checksum(invalid_load_content)
        invalid_load["transactionId"] = f"operation:{invalid_load['digest']}"
        with self.assertRaisesRegex(ProtocolError, "load config"):
            validate_action({"type": "operation.execute", "transaction": invalid_load})

    def test_canonical_vehicle_assignment_accepts_automatic_stop_sentinel_only(self) -> None:
        content = {
            "schemaVersion": 1,
            "kind": "vehicle.assign",
            "companyCid": "company:1",
            "data": {
                "targetCid": "vehicle:pre:abc",
                "lineCid": "line:pre:def",
                "stopIndex": -1,
            },
        }
        digest = checksum(content)
        transaction = {
            **content,
            "digest": digest,
            "transactionId": f"operation:{digest}",
        }
        accepted = validate_action({"type": "operation.execute", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["data"]["stopIndex"], -1)

        invalid = json.loads(json.dumps(transaction))
        invalid["data"]["stopIndex"] = -2
        invalid_content = {
            key: invalid[key] for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        invalid["digest"] = checksum(invalid_content)
        invalid["transactionId"] = f"operation:{invalid['digest']}"
        with self.assertRaisesRegex(ProtocolError, "vehicle.assign"):
            validate_action({"type": "operation.execute", "transaction": invalid})

    def test_proposal_accepts_lua_empty_table_removal_lists_only_when_empty(self) -> None:
        transaction = proposal_transaction()
        transaction["remove"] = {"edges": {}, "nodes": {}}
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"proposal:{transaction['digest']}"
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["remove"], {"edges": {}, "nodes": {}})

        transaction["remove"]["edges"] = {"edge:1": True}
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"proposal:{transaction['digest']}"
        with self.assertRaisesRegex(ProtocolError, "canonical list"):
            validate_action({"type": "proposal.build", "transaction": transaction})

    def test_proposal_accepts_lua_empty_node_list_for_pure_edge_replacement(self) -> None:
        transaction = proposal_transaction("company:1")
        transaction["nodes"] = {}
        transaction["edges"][0]["node0"] = {"cid": "node:event:test:1"}
        transaction["edges"][0]["node1"] = {"cid": "node:event:test:2"}
        transaction["remove"] = {"edges": ["edge:event:test:1"], "nodes": {}}
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"proposal:{transaction['digest']}"
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["nodes"], {})
        self.assertEqual(accepted["transaction"]["edges"][0]["node0"], {"cid": "node:event:test:1"})

        transaction["nodes"] = {"node:1": {"position": {"x": 0, "y": 0, "z": 0}}}
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "companyCid", "cost", "nodes", "edges", "edgeObjects", "remove")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"proposal:{transaction['digest']}"
        with self.assertRaisesRegex(ProtocolError, "canonical list"):
            validate_action({"type": "proposal.build", "transaction": transaction})


class BridgeTests(unittest.TestCase):
    def test_atomic_write_retries_transient_replace_denial(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "companion_status.json"
            destination.write_bytes(b"old\n")
            real_replace = os.replace
            attempts = 0

            def flaky_replace(source: Path | str, target: Path | str) -> None:
                nonlocal attempts
                attempts += 1
                if attempts < 3:
                    error = PermissionError(13, "transient sharing violation", str(target))
                    error.winerror = 5
                    raise error
                real_replace(source, target)

            with mock.patch("tpf2mp.bridge.os.replace", side_effect=flaky_replace), mock.patch(
                "tpf2mp.bridge.time.sleep"
            ) as pause:
                atomic_write(destination, b"new\n")

            self.assertEqual(destination.read_bytes(), b"new\n")
            self.assertEqual(attempts, 3)
            self.assertEqual(pause.call_count, 2)

    def test_outbound_cursor_and_idempotent_inbound(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bridge = GameBridge(directory, "session", "player1")
            message = sign(
                {
                    "protocol": 1,
                    "session": "session",
                    "peer": "player1",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "demo"}},
                }
            )
            atomic_write(bridge.outbox / "000000000001.json", (canonical_json(message) + "\n").encode())
            pending = list(bridge.pending_outbound())
            self.assertEqual([item[0] for item in pending], [1])
            bridge.acknowledge_outbound(1)
            self.assertEqual(list(bridge.pending_outbound()), [])

            commit = sign(
                {
                    "protocol": 1,
                    "session": "session",
                    "seq": 1,
                    "kind": "commit",
                    "origin_peer": "player1",
                    "origin_local_seq": 1,
                    "tick": 0,
                    "payload": {"action": {"type": "demo"}},
                }
            )
            first = bridge.write_inbound(commit)
            second = bridge.write_inbound(commit)
            self.assertEqual(first, second)


class CheckpointTests(unittest.TestCase):
    @staticmethod
    def checkpoint_payload() -> dict:
        model = {
            "initialized": True,
            "companies": {
                "company:1": {"cid": "company:1", "name": "Company 1"},
                "company:2": {"cid": "company:2", "name": "Company 2"},
            },
            "companyOrder": ["company:1", "company:2"],
            "economy": {
                "version": 1,
                "epoch": 0,
                "markets": {},
                "services": {},
                "lastResults": {"markets": {}, "companies": {}, "totalDemand": 0, "totalRevenueCents": 0},
                "ledger": {
                    "settledEpochs": {},
                    "companies": {},
                    "settlementCount": 0,
                    "totalDemand": 0,
                    "totalRevenueCents": 0,
                },
            },
            "autonomyFrozen": False,
        }
        canonical: list[dict] = []
        vehicle_sync = {"schemaVersion": 1, "enabled": True, "vehicles": []}
        core = dict(model)
        core["canonical"] = canonical
        core["vehicleSynchronization"] = vehicle_sync
        cursor = {
            "firstRetainedSeq": 1,
            "lastEventSeq": 1,
            "nextEventSeq": 2,
            "retainedCount": 1,
            "lastCommitSeq": 1,
        }
        financial = {
            "companies": {
                "company:1": {"balance": 5_000_000, "loan": 0},
                "company:2": {"balance": 5_000_000, "loan": 0},
            }
        }
        payload = {
            "checkpointVersion": 3,
            "stateVersion": 11,
            "protocol": 1,
            "sessionId": "checkpoint-test",
            "peerId": "player1",
            "networkMode": "network",
            "tick": 10,
            "reason": "test-anchor",
            "model": model,
            "modelDigest": checksum(model),
            "canonical": canonical,
            "canonicalDigest": checksum(canonical),
            "vehicleSynchronization": vehicle_sync,
            "vehicleSynchronizationDigest": checksum(vehicle_sync),
            "coreDigest": checksum(core),
            "financial": financial,
            "financialDigest": checksum(financial),
            "eventCursor": cursor,
        }
        payload["convergenceKey"] = checksum(
            {
                "checkpointVersion": 3,
                "stateVersion": 11,
                "protocol": 1,
                "sessionId": "checkpoint-test",
                "lastCommitSeq": 1,
                "modelDigest": payload["modelDigest"],
                "canonicalDigest": payload["canonicalDigest"],
                "vehicleSynchronizationDigest": payload["vehicleSynchronizationDigest"],
                "coreDigest": payload["coreDigest"],
                "financialDigest": payload["financialDigest"],
            }
        )
        payload["checkpointDigest"] = checksum(payload)
        return payload

    def test_checkpoint_and_event_integrity_and_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            outbox = root / "game_outbox"
            outbox.mkdir()
            checkpoint = self.checkpoint_payload()
            verify_checkpoint(checkpoint)
            checkpoint_message = sign(
                {
                    "protocol": 1,
                    "session": "checkpoint-test",
                    "peer": "player1",
                    "local_seq": 1,
                    "tick": 10,
                    "kind": "checkpoint",
                    "payload": checkpoint,
                }
            )
            atomic_write(outbox / "000000000001.json", (canonical_json(checkpoint_message) + "\n").encode())

            after_model = json.loads(json.dumps(checkpoint["model"]))
            after_model["autonomyFrozen"] = True
            after_core = dict(after_model)
            after_core["canonical"] = checkpoint["canonical"]
            after_core["vehicleSynchronization"] = checkpoint["vehicleSynchronization"]
            event = {
                "recordVersion": 1,
                "stateVersion": 3,
                "localEventSeq": 2,
                "commitSeq": 2,
                "eventId": "checkpoint-test:player1:2",
                "tick": 11,
                "actor": "player1",
                "action": {"type": "world.freeze", "freeze": True},
                "preDigest": checkpoint["coreDigest"],
                "postDigest": checksum(after_core),
                "preModelDigest": checkpoint["modelDigest"],
                "postModelDigest": checksum(after_model),
                "success": True,
                "portable": True,
            }
            event["recordDigest"] = checksum(event)
            verify_event_record(event)
            event_message = sign(
                {
                    "protocol": 1,
                    "session": "checkpoint-test",
                    "peer": "player1",
                    "local_seq": 2,
                    "tick": 11,
                    "kind": "event",
                    "payload": event,
                }
            )
            atomic_write(outbox / "000000000002.json", (canonical_json(event_message) + "\n").encode())

            stale_event = json.loads(json.dumps(event))
            stale_event["localEventSeq"] = 4
            stale_event["eventId"] = "checkpoint-test:stale-generation:4"
            stale_event.pop("recordDigest", None)
            stale_event["recordDigest"] = checksum(stale_event)
            stale_message = sign(
                {
                    "protocol": 1,
                    "session": "checkpoint-test",
                    "peer": "player1",
                    "local_seq": 99,
                    "tick": 99,
                    "kind": "event",
                    "payload": stale_event,
                }
            )
            stale_path = outbox / "000000000099.json"
            atomic_write(stale_path, (canonical_json(stale_message) + "\n").encode())
            checkpoint_path = outbox / "000000000001.json"
            event_path = outbox / "000000000002.json"
            os.utime(stale_path, ns=(1_000_000_000, 1_000_000_000))
            os.utime(checkpoint_path, ns=(2_000_000_000, 2_000_000_000))
            os.utime(event_path, ns=(3_000_000_000, 3_000_000_000))

            analysis = analyse_bridge(root, "checkpoint-test", peer="player1", anchor="first")
            self.assertEqual(analysis["modelReplay"]["status"], "verified")
            self.assertEqual(analysis["modelReplay"]["portableChanges"], 1)
            self.assertEqual(analysis["finalModelDigest"], checksum(after_model))

    def test_internally_tampered_checkpoint_is_rejected_even_when_resigned(self) -> None:
        payload = self.checkpoint_payload()
        payload["model"]["autonomyFrozen"] = True
        with self.assertRaises(ProtocolError):
            verify_checkpoint(payload)

    def test_legacy_checkpoint_format_remains_readable_for_old_evidence(self) -> None:
        payload = self.checkpoint_payload()
        payload["checkpointVersion"] = 1
        payload.pop("financial")
        payload.pop("financialDigest")
        payload.pop("vehicleSynchronization")
        payload.pop("vehicleSynchronizationDigest")
        legacy_core = dict(payload["model"])
        legacy_core["canonical"] = payload["canonical"]
        payload["coreDigest"] = checksum(legacy_core)
        payload["convergenceKey"] = checksum(
            {
                "checkpointVersion": 1,
                "stateVersion": payload["stateVersion"],
                "protocol": payload["protocol"],
                "sessionId": payload["sessionId"],
                "lastCommitSeq": payload["eventCursor"]["lastCommitSeq"],
                "modelDigest": payload["modelDigest"],
                "canonicalDigest": payload["canonicalDigest"],
                "coreDigest": payload["coreDigest"],
            }
        )
        payload.pop("checkpointDigest", None)
        payload["checkpointDigest"] = checksum(payload)
        self.assertEqual(verify_checkpoint(payload)["checkpointVersion"], 1)

    def test_checkpoint_v2_remains_readable_for_recovery_archives(self) -> None:
        payload = self.checkpoint_payload()
        payload["checkpointVersion"] = 2
        payload.pop("vehicleSynchronization")
        payload.pop("vehicleSynchronizationDigest")
        legacy_core = dict(payload["model"])
        legacy_core["canonical"] = payload["canonical"]
        payload["coreDigest"] = checksum(legacy_core)
        payload["convergenceKey"] = checksum({
            "checkpointVersion": 2,
            "stateVersion": payload["stateVersion"],
            "protocol": payload["protocol"],
            "sessionId": payload["sessionId"],
            "lastCommitSeq": payload["eventCursor"]["lastCommitSeq"],
            "modelDigest": payload["modelDigest"],
            "canonicalDigest": payload["canonicalDigest"],
            "coreDigest": payload["coreDigest"],
            "financialDigest": payload["financialDigest"],
        })
        payload.pop("checkpointDigest", None)
        payload["checkpointDigest"] = checksum(payload)
        self.assertEqual(verify_checkpoint(payload)["checkpointVersion"], 2)

    def test_authorized_vehicle_checkpoint_requires_a_complete_stop_anchor(self) -> None:
        payload = self.checkpoint_payload()
        payload["vehicleSynchronization"]["vehicles"] = [{
            "vehicleCid": "vehicle:event:test:1",
            "lineCid": "line:event:test:1",
            "companyCid": "company:1",
            "lastAuthorizedRound": 1,
            "releaseWhilePaused": False,
        }]
        with self.assertRaisesRegex(ProtocolError, "missing its stop/release anchor"):
            verify_checkpoint(payload)

    def test_audit_replay_chains_checkpoint_event_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            audit = AuditLog(Path(directory) / "audit.ndjson")
            checkpoint = self.checkpoint_payload()
            audit.append(
                sign(
                    {
                        "protocol": 1,
                        "session": "checkpoint-test",
                        "kind": "record",
                        "peer": "player1",
                        "local_seq": 1,
                        "record_type": "checkpoint",
                        "payload": checkpoint,
                    }
                )
            )
            after_model = json.loads(json.dumps(checkpoint["model"]))
            after_model["autonomyFrozen"] = True
            after_core = dict(after_model)
            after_core["canonical"] = checkpoint["canonical"]
            event = {
                "recordVersion": 1,
                "stateVersion": 3,
                "localEventSeq": 2,
                "commitSeq": 2,
                "eventId": "checkpoint-test:player1:2",
                "tick": 11,
                "actor": "player1",
                "action": {"type": "world.freeze", "freeze": True},
                "preDigest": checkpoint["coreDigest"],
                "postDigest": checksum(after_core),
                "preModelDigest": checkpoint["modelDigest"],
                "postModelDigest": checksum(after_model),
                "success": True,
                "portable": True,
            }
            event["recordDigest"] = checksum(event)
            audit.append(
                sign(
                    {
                        "protocol": 1,
                        "session": "checkpoint-test",
                        "kind": "record",
                        "peer": "player1",
                        "local_seq": 2,
                        "record_type": "event",
                        "payload": event,
                    }
                )
            )
            self.assertEqual(replay(audit.path, "checkpoint-test"), 0)


class ManifestTests(unittest.TestCase):
    def test_content_fingerprint_is_deterministic_and_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "game.exe"
            mod = root / "mod"
            companion = root / "companion"
            mod.mkdir()
            companion.mkdir()
            game.write_bytes(b"game-build")
            (mod / "mod.lua").write_text("return 1\n", encoding="utf-8")
            (companion / "protocol.py").write_text("VERSION=1\n", encoding="utf-8")
            first = build_manifest(game, mod, companion)
            second = build_manifest(game, mod, companion)
            self.assertEqual(first["fingerprint"], second["fingerprint"])
            output = root / "manifest.json"
            write_manifest(output, first)
            self.assertEqual(load_manifest(output)["fingerprint"], first["fingerprint"])
            (mod / "mod.lua").write_text("return 2\n", encoding="utf-8")
            changed = build_manifest(game, mod, companion)
            self.assertNotEqual(first["fingerprint"], changed["fingerprint"])


class ResearchReportTests(unittest.TestCase):
    def test_latest_research_export_renders_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "bridge", "research-session", "player1")
            payload = {
                "sessionId": "research-session",
                "peerId": "player1",
                "networkMode": "standalone",
                "tick": 42,
                "capabilities": {"addPlayer": True, "buyVehicle": True},
                "structural": {"digest": "abc123", "towns": [], "lines": [], "vehicleCount": 2},
                "ownership": {"companies": {"company:1": {"total": 2, "byKind": {"vehicle": 2}}}},
                "capture": {
                    "preCommitCount": 3,
                    "nativePreCommitCount": 2,
                    "postCommitCount": 1,
                    "vehicleIntentCount": 1,
                    "vehicleResolvedCount": 1,
                    "claimedCount": 1,
                    "lastProposalSnapshot": {
                        "tick": 41,
                        "sourceId": "streetBuilder",
                        "snapshot": {"__type": "table", "toAdd": {"__type": "table"}},
                    },
                },
                "nativeHook": {
                    "available": True,
                    "active": True,
                    "hookVersion": "0.7.0",
                    "stage": "active",
                    "profile": "Transport Fever 2 Build 35924 (Windows x64)",
                    "validation": {"valid": True, "signatureCount": 17},
                    "setupCalls": 3,
                    "luaStateCount": 48,
                    "wrappedStateCount": 3,
                    "commandObserverStateCount": 1,
                    "commandCalls": 19,
                    "commandList": {
                        "swapCalls": 90,
                        "nonEmptyBatches": 90,
                        "commands": 5493,
                        "tagCounts": [{"tag": 15, "name": "BuildProposal", "count": 2}],
                    },
                    "applyCommand": {
                        "succeeded": 5493,
                        "failed": 0,
                        "unknown": 0,
                        "direct": 19,
                        "tagCounts": [{"tag": 15, "name": "BuildProposal", "count": 2}],
                    },
                    "commandEvents": [
                        {"localSequence": 1, "tag": 15, "name": "BuildProposal", "success": True}
                    ],
                    "suppressedVehicleCommands": {
                        "queued": 0,
                        "captured": 2,
                        "consumed": 2,
                        "invalid": 0,
                        "dropped": 0,
                    },
                    "gates": {
                        "buildProposal": {"enabled": False, "suppressed": 1, "allowed": 2},
                        "commandVisitors": {
                            "enabled": False,
                            "hooked": 23,
                            "suppressedTotal": 1,
                            "allowedTotal": 1,
                            "tagMismatches": 0,
                        },
                    },
                    "scope": "Lua sendCommand call-through plus native command observers",
                },
                "proposals": {"queued": 2, "applied": 1, "failed": 1, "retained": 2},
                "proposalConsensus": {"completed": 1, "failed": 0, "sessionFault": None},
                "checkpointConsensus": {
                    "completed": 2,
                    "failed": 0,
                    "lastAgreed": {"boundarySeq": 7, "convergenceKey": "abcdef12"},
                },
                "knownLimits": ["live validation required"],
            }
            message = sign(
                {
                    "protocol": 1,
                    "session": "research-session",
                    "peer": "player1",
                    "local_seq": 1,
                    "tick": 42,
                    "kind": "research",
                    "payload": payload,
                }
            )
            atomic_write(bridge.outbox / "000000000001.json", (canonical_json(message) + "\n").encode())

            stale_payload = dict(payload)
            stale_payload["tick"] = 7
            stale_message = sign(
                {
                    "protocol": 1,
                    "session": "research-session",
                    "peer": "player1",
                    "local_seq": 99,
                    "tick": 7,
                    "kind": "research",
                    "payload": stale_payload,
                }
            )
            stale_path = bridge.outbox / "000000000099.json"
            atomic_write(stale_path, (canonical_json(stale_message) + "\n").encode())
            current_path = bridge.outbox / "000000000001.json"
            os.utime(stale_path, ns=(1_000_000_000, 1_000_000_000))
            os.utime(current_path, ns=(2_000_000_000, 2_000_000_000))
            self.assertEqual(latest_research(bridge.root, "research-session")["tick"], 42)
            markdown = render_markdown(payload)
            self.assertIn("`addPlayer` | yes", markdown)
            self.assertIn("company:1", markdown)
            self.assertIn("3 / 48 / 3 / 19", markdown)
            self.assertIn("Hook version: `0.7.0`", markdown)
            self.assertIn("Native pre-issue observer states: 1", markdown)
            self.assertIn("BuildProposal GUI/native/apply events: 3 / 2 / 1", markdown)
            self.assertIn("Exact-build validation/signatures: yes / 17", markdown)
            self.assertIn("Native queue swaps / non-empty batches / commands: 90 / 90 / 5493", markdown)
            self.assertIn("Applied commands succeeded / failed / unknown: 5493 / 0 / 0", markdown)
            self.assertIn("Direct engine-state applies (queue bypass): 19", markdown)
            self.assertIn("Queued command tags: BuildProposal=2", markdown)
            self.assertIn("Retained native command timeline entries: 1", markdown)
            self.assertIn(
                "Vehicle capture queued / captured / consumed / invalid / dropped: 0 / 2 / 2 / 0 / 0",
                markdown,
            )
            self.assertIn("BuildProposal gate enabled / suppressed / authorized-through: no / 1 / 2", markdown)
            self.assertIn(
                "Consequential command visitors enabled / hooked / suppressed / authorized-through / mismatches: no / 23 / 1 / 1 / 0",
                markdown,
            )
            self.assertIn("Latest bounded proposal snapshot", markdown)
            self.assertIn("streetBuilder", markdown)
            self.assertIn("Canonical proposals queued/applied/failed/retained: 2 / 1 / 1 / 2", markdown)
            self.assertIn("Physical consensus completed/faulted/session fault: 1 / 0 / unknown", markdown)
            self.assertIn("Checkpoint barriers completed/faulted/last agreed: 2 / 0", markdown)
            output = root / "report.md"
            write_report(bridge.root, "research-session", output)
            self.assertIn("abc123", output.read_text(encoding="utf-8"))


class RecoveryArchiveTests(unittest.TestCase):
    def test_native_save_archive_is_signed_hashed_and_tamper_evident(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            save = root / "populated.sav"
            save.write_bytes(b"native-world")
            Path(str(save) + ".lua").write_text(
                "function data() return {} end", encoding="utf-8"
            )
            save.with_suffix(".jpg").write_bytes(b"preview")
            plan = sign(
                {
                    "format": "tpf2mp-recovery-plan",
                    "version": 1,
                    "protocol": 1,
                    "session": "archive-test",
                    "requiredPeers": ["player1", "player2"],
                    "anchor": {"boundarySeq": 9, "convergenceKey": "abc123"},
                }
            )
            output = root / "archive"
            manifest = write_recovery_archive(
                save, output, "archive-test", "player1", plan
            )
            verified = verify_recovery_archive(manifest, output)
            self.assertEqual(
                verified["association"], "agreed-checkpoint-native-save-candidate"
            )
            self.assertEqual(verified["checkpointAnchor"]["boundarySeq"], 9)
            self.assertEqual(
                {item["role"] for item in verified["save"]["files"]},
                {"save", "metadata", "preview"},
            )
            (output / "populated.sav").write_bytes(b"tampered")
            with self.assertRaisesRegex(ProtocolError, "mismatch"):
                verify_recovery_archive(manifest, output)

    def test_unanchored_archive_is_explicit_and_output_is_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            save = root / "manual.sav"
            save.write_bytes(b"save")
            Path(str(save) + ".lua").write_text("return {}", encoding="utf-8")
            output = root / "manual-archive"
            manifest = write_recovery_archive(save, output, "manual", "player2")
            self.assertEqual(manifest["association"], "unanchored-native-save")
            with self.assertRaisesRegex(ProtocolError, "already exists"):
                write_recovery_archive(save, output, "manual", "player2")


class NetworkIntegrationTests(unittest.TestCase):
    def test_rejected_intent_emits_ordered_replayable_release_control(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "intent-reject-release"
            bridge = GameBridge(root / "host", session, "player1")
            audit = root / "audit.ndjson"
            host = CommitHost(
                bridge, "127.0.0.1", 0, audit, require_connected_peers=False
            )
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player1",
                    "local_seq": 7,
                    "tick": 41,
                    "kind": "intent",
                    "payload": {
                        "action": {
                            "type": "proposal.build",
                            "transaction": proposal_transaction("company:1"),
                        }
                    },
                }
            )
            with self.assertRaisesRegex(ProtocolError, "host-generated"):
                host._commit(intent)
            control = host._reject_intent(
                intent, "proposal.build is host-generated; submit proposal.prepare first"
            )
            self.assertEqual(control["seq"], 1)
            self.assertEqual(control["kind"], "control")
            self.assertEqual(
                control["payload"]["action"],
                {
                    "type": "network.intent_rejected",
                    "originPeer": "player1",
                    "originLocalSeq": 7,
                    "actionType": "proposal.build",
                    "errorCode": "proposal.build is host-generated; submit proposal.prepare first",
                },
            )
            inbound = decode_line((bridge.inbox / "000000000001.json").read_bytes())
            self.assertEqual(inbound, control)
            self.assertEqual(host._reject_intent(intent, "duplicate"), control)
            self.assertEqual(host.next_seq, 2)

            recovered = CommitHost(
                GameBridge(root / "recovered", session, "player1"),
                "127.0.0.1",
                0,
                audit,
                require_connected_peers=False,
            )
            self.assertEqual(recovered.next_seq, 2)
            self.assertEqual(recovered._reject_intent(intent, "duplicate"), control)

    def test_proposal_prepare_rejection_never_commits_or_faults_the_session(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "prepare-reject"
            bridge = GameBridge(root / "host", session, "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            transaction = proposal_transaction("company:2")
            intent = sign({
                "protocol": 1,
                "session": session,
                "peer": "player2",
                "local_seq": 1,
                "tick": 0,
                "kind": "intent",
                "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
            })
            prepare = host._commit(intent)
            self.assertEqual(prepare["seq"], 1)
            host._record_non_intent(proposal_prepare_ack("player1", 2, 1))
            host._record_non_intent(proposal_prepare_ack(
                "player2", 3, 1, success=False,
                error="canonical node has no local geometric match",
            ))
            self.assertEqual(host.proposal_prepares[1]["status"], "rejected")
            self.assertEqual(host.proposal_consensus, {})
            self.assertIsNone(host.session_fault)
            outcome = decode_line((bridge.inbox / "000000000002.json").read_bytes())
            self.assertEqual(
                outcome["payload"]["action"]["type"],
                "network.proposal_prepare_outcome",
            )
            self.assertFalse(outcome["payload"]["action"]["success"])

    def test_shared_clock_steps_down_to_the_slowest_peer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "adaptive-clock"
            bridge = GameBridge(root / "host", session, "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_health = {
                peer: {
                    "receivedAt": sampled_at,
                    "engineTick": 100,
                    "lastCommitSeq": 0,
                    "gameTime": 100.0,
                    "observedSpeed": 0,
                }
                for peer in ("player1", "player2")
            }
            intent = sign({
                "protocol": 1,
                "session": session,
                "peer": "player2",
                "local_seq": 1,
                "tick": 0,
                "kind": "intent",
                "payload": {"action": {"type": "clock.request", "requestedSpeed": 4}},
            })
            commit = host._commit(intent)
            self.assertEqual(commit["payload"]["action"]["type"], "clock.rendezvous")
            self.assertEqual(commit["payload"]["action"]["releaseSpeed"], 4)
            host._record_non_intent(proposal_prepare_ack("player1", 2, 1))
            host._record_non_intent(proposal_prepare_ack("player2", 3, 1))
            self.assertEqual(host.clock_controls[1]["status"], "complete")
            for peer, local_seq in (("player1", 4), ("player2", 5)):
                host._record_non_intent({
                    "kind": "clock_reached",
                    "peer": peer,
                    "local_seq": local_seq,
                    "payload": {
                        "schemaVersion": 1,
                        "generation": 1,
                        "targetGameTime": 100.0,
                        "actualGameTime": 100.0,
                        "engineTick": 101,
                        "success": True,
                        "error": "",
                    },
                })
            release = host.commits[2]["payload"]["action"]
            self.assertEqual(release["type"], "clock.set")
            self.assertEqual(release["effectiveSpeed"], 4)
            host._record_non_intent(proposal_prepare_ack("player1", 6, 2))
            host._record_non_intent(proposal_prepare_ack("player2", 7, 2))

            adjustment_at = time.monotonic()
            host.clock_last_adjustment = adjustment_at - 10.0
            host.clock_health = {
                "player1": {
                    "receivedAt": adjustment_at - 1.0, "engineTick": 100, "lastCommitSeq": 2,
                    "tickRate": 5.0, "observedSpeed": 4, "gameTime": 200.0,
                    "gameRate": 12.0,
                },
                "player2": {
                    "receivedAt": adjustment_at - 1.0, "engineTick": 100, "lastCommitSeq": 2,
                    "tickRate": 1.0, "observedSpeed": 4, "gameTime": 200.0,
                    "gameRate": 12.0,
                },
            }
            host._maybe_adjust_clock_locked(adjustment_at)
            adjustment = host.commits[3]["payload"]["action"]
            self.assertEqual(adjustment["type"], "clock.rendezvous")
            self.assertEqual(adjustment["requestedSpeed"], 4)
            self.assertEqual(adjustment["releaseSpeed"], 3)
            self.assertEqual(adjustment["reason"], "adaptive-slowest-peer-cap")

    def test_clock_skew_compares_heartbeats_at_one_host_time(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "clock-projection", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 1
            host.clock_last_adjustment = sampled_at - 10.0
            host.clock_health = {
                "player1": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "gameTime": 100.0, "observedSpeed": 1,
                    "tickRate": 60.0, "gameRate": 12.0,
                },
                "player2": {
                    "receivedAt": sampled_at - 0.25, "engineTick": 85,
                    "lastCommitSeq": 0, "gameTime": 97.0, "observedSpeed": 1,
                    "tickRate": 60.0, "gameRate": 12.0,
                },
            }
            host._maybe_adjust_clock_locked(sampled_at)
            self.assertAlmostEqual(host.clock_game_time_skew, 0.0, places=6)
            self.assertEqual(host.commits, {},
                "staggered healthy heartbeats caused a false resync")
            host.clock_health["player2"]["gameTime"] = 94.0
            host._maybe_adjust_clock_locked(sampled_at)
            self.assertAlmostEqual(host.clock_game_time_skew, 3.0, places=6)
            self.assertEqual(host.commits[1]["payload"]["action"]["type"], "clock.rendezvous")

    def test_authoritative_pause_corrects_a_native_running_world(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "clock-initial-pause", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_last_adjustment = sampled_at - 10.0
            host.clock_health = {
                peer: {
                    "receivedAt": sampled_at, "engineTick": 100,
                    "lastCommitSeq": 0, "gameTime": 100.0,
                    "observedSpeed": 1, "tickRate": 60.0, "gameRate": 12.0,
                }
                for peer in ("player1", "player2")
            }
            host._maybe_adjust_clock_locked(sampled_at)
            action = host.commits[1]["payload"]["action"]
            self.assertEqual(action["type"], "clock.set")
            self.assertEqual(action["requestedSpeed"], 0)
            self.assertEqual(action["effectiveSpeed"], 0)
            self.assertEqual(action["reason"], "authoritative-pause-enforcement")

    def test_pause_is_a_future_rendezvous_and_absolute_skew_gets_a_catchup_round(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "clock-rendezvous"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 1
            host.clock_health = {
                "player1": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "gameTime": 100.0, "observedSpeed": 1, "tickRate": 60.0,
                    "gameRate": 12.0,
                },
                "player2": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "gameTime": 103.0, "observedSpeed": 1, "tickRate": 60.0,
                    "gameRate": 12.0,
                },
            }
            intent = sign({
                "protocol": 1,
                "session": session,
                "peer": "player1",
                "local_seq": 1,
                "tick": 100,
                "kind": "intent",
                "payload": {"action": {"type": "clock.request", "requestedSpeed": 0}},
            })
            rendezvous = host._commit(intent)
            action = rendezvous["payload"]["action"]
            self.assertEqual(action["type"], "clock.rendezvous")
            self.assertEqual(action["approachSpeed"], 1)
            self.assertEqual(action["releaseSpeed"], 0)
            self.assertGreater(action["targetGameTime"], 103.0)
            self.assertEqual(host.clock_effective_speed, 1)
            host._record_non_intent(proposal_prepare_ack("player1", 2, 1))
            host._record_non_intent(proposal_prepare_ack("player2", 3, 1))

            target = float(action["targetGameTime"])
            for peer, seq, actual in (
                ("player1", 4, target),
                ("player2", 5, target + 1.0),
            ):
                host._record_non_intent({
                    "kind": "clock_reached", "peer": peer, "local_seq": seq,
                    "payload": {
                        "schemaVersion": 1, "generation": 1,
                        "targetGameTime": target, "actualGameTime": actual,
                        "engineTick": 110, "success": True, "error": "",
                    },
                })
            correction = host.commits[2]["payload"]["action"]
            self.assertEqual(correction["type"], "clock.rendezvous")
            self.assertEqual(correction["approachSpeed"], 1)
            self.assertEqual(correction["releaseSpeed"], 0)
            self.assertEqual(correction["targetGameTime"], target + 1.0)
            host._record_non_intent(proposal_prepare_ack("player1", 6, 2))
            host._record_non_intent(proposal_prepare_ack("player2", 7, 2))
            for peer, seq in (("player1", 8), ("player2", 9)):
                host._record_non_intent({
                    "kind": "clock_reached", "peer": peer, "local_seq": seq,
                    "payload": {
                        "schemaVersion": 1, "generation": 2,
                        "targetGameTime": target + 1.0,
                        "actualGameTime": target + 1.0,
                        "engineTick": 120, "success": True, "error": "",
                    },
                })
            final = host.commits[3]["payload"]["action"]
            self.assertEqual(final["type"], "clock.set")
            self.assertEqual(final["effectiveSpeed"], 0)

    def test_paused_resume_catches_even_sub_tolerance_time_skew(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "paused-small-skew"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 0
            host.clock_health = {
                "player1": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "gameTime": 100.0, "observedSpeed": 0,
                },
                "player2": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "gameTime": 100.1, "observedSpeed": 0,
                },
            }
            commit = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 100, "kind": "intent",
                "payload": {"action": {"type": "clock.request", "requestedSpeed": 1}},
            }))
            action = commit["payload"]["action"]
            self.assertEqual(action["type"], "clock.rendezvous")
            self.assertEqual(action["approachSpeed"], 1)
            self.assertEqual(action["targetGameTime"], 100.1)

    def test_vehicle_station_round_waits_for_both_peers_and_retries_are_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "vehicle-station-sync", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            now = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 1
            host.clock_health = {
                peer: {
                    "receivedAt": now, "engineTick": 10, "lastCommitSeq": 0,
                    "gameTime": 100.0, "observedSpeed": 1,
                    "tickRate": 60.0, "gameRate": 12.0,
                }
                for peer in ("player1", "player2")
            }
            host._record_non_intent(vehicle_sync_record("player1", 1, "held", game_time=100.0))
            self.assertEqual(host.commits, {})
            host._record_non_intent(vehicle_sync_record("player2", 2, "held", game_time=101.0))
            release = host.commits[1]["payload"]["action"]
            self.assertEqual(release["type"], "vehicle.sync_release")
            self.assertGreater(release["releaseAtGameTime"], 101.0)
            host._record_non_intent(vehicle_sync_record("player1", 3, "held", game_time=102.0))
            self.assertEqual(len(host.commits), 1, "held retry emitted a second release")
            host._record_non_intent(proposal_prepare_ack("player1", 4, 1))
            host._record_non_intent(proposal_prepare_ack("player2", 5, 1))
            host._record_non_intent(vehicle_sync_record("player1", 6, "released", game_time=120.0))
            host._record_non_intent(vehicle_sync_record("player2", 7, "released", game_time=120.2))
            tracker = next(iter(host.vehicle_sync_rounds.values()))
            self.assertEqual(tracker["status"], "complete")
            self.assertEqual(host.vehicle_sync_releases, 1)
            host._record_non_intent(vehicle_sync_record("player1", 8, "released", game_time=121.0))
            self.assertEqual(host.vehicle_sync_releases, 1, "release retry counted twice")

    def test_vehicle_stop_mismatch_and_release_rejection_fault_the_session_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "vehicle-station-fault", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            host.clock_requested_speed = host.clock_effective_speed = 1
            host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
            host._record_non_intent(vehicle_sync_record(
                "player2", 2, "held", stop_index=1,
            ))
            self.assertIn("vehicle-sync-stop-mismatch", host.session_fault)
            actions = [item["payload"]["action"]["type"] for item in host.commits.values()]
            self.assertIn("network.sync_fault", actions)
            self.assertIn("clock.set", actions)
            host._maybe_adjust_clock_locked(time.monotonic() + 1.0)
            clock_actions = [
                item["payload"]["action"] for item in host.commits.values()
                if item["payload"]["action"]["type"] == "clock.set"
            ]
            self.assertEqual(clock_actions[-1]["requestedSpeed"], 0)
            self.assertEqual(clock_actions[-1]["effectiveSpeed"], 0)

            root2 = root / "release-reject"
            second = CommitHost(
                GameBridge(root2 / "host", "vehicle-release-reject", "player1"),
                "127.0.0.1", 0, root2 / "audit.ndjson",
                require_connected_peers=False,
            )
            second._record_non_intent(vehicle_sync_record("player1", 1, "held"))
            second._record_non_intent(vehicle_sync_record("player2", 2, "held"))
            second._record_non_intent(proposal_prepare_ack(
                "player2", 3, 1, success=False, error="local vehicle mapping is missing",
            ))
            self.assertIn("vehicle-sync-release-rejected", second.session_fault)
            self.assertTrue(second.sync_fault_emitted)

    def test_host_restart_finishes_an_interrupted_vehicle_station_barrier(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "vehicle-restart-release"
            audit_path = root / "audit.ndjson"
            seed = CommitHost(
                GameBridge(root / "seed", session, "player1"),
                "127.0.0.1", 0, audit_path,
                require_connected_peers=False,
            )
            seed.audit.append(seed._record_message(vehicle_sync_record("player1", 1, "held")))
            seed.audit.append(seed._record_message(vehicle_sync_record("player2", 2, "held")))
            recovered = CommitHost(
                GameBridge(root / "recovered", session, "player1"),
                "127.0.0.1", 0, audit_path,
                require_connected_peers=False,
            )
            release = recovered.commits[1]["payload"]["action"]
            self.assertEqual(release["type"], "vehicle.sync_release")
            self.assertEqual(release["round"], 1)
            tracker = next(iter(recovered.vehicle_sync_rounds.values()))
            self.assertEqual(tracker["status"], "release-ordered")

    def test_host_restart_preserves_rejected_clock_and_vehicle_controls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)

            clock_session = "clock-reject-restart"
            clock_audit = root / "clock-audit.ndjson"
            clock_seed = CommitHost(
                GameBridge(root / "clock-seed", clock_session, "player1"),
                "127.0.0.1", 0, clock_audit,
                require_connected_peers=False,
            )
            clock_seed._emit_clock_commit_locked(1, 1, "restore-rejection-test")
            clock_seed.audit.append(clock_seed._record_message(proposal_prepare_ack(
                "player2", 1, 1, success=False, error="native speed rejected",
            )))
            clock_recovered = CommitHost(
                GameBridge(root / "clock-recovered", clock_session, "player1"),
                "127.0.0.1", 0, clock_audit,
                require_connected_peers=False,
            )
            clock_pause = clock_recovered.commits[2]["payload"]["action"]
            self.assertEqual(clock_pause["type"], "clock.set")
            self.assertEqual(clock_pause["effectiveSpeed"], 0)
            self.assertIn("clock-command-rejected", clock_pause["reason"])

            vehicle_session = "vehicle-reject-restart"
            vehicle_audit = root / "vehicle-audit.ndjson"
            vehicle_seed = CommitHost(
                GameBridge(root / "vehicle-seed", vehicle_session, "player1"),
                "127.0.0.1", 0, vehicle_audit,
                require_connected_peers=False,
            )
            vehicle_seed._record_non_intent(vehicle_sync_record("player1", 1, "held"))
            vehicle_seed._record_non_intent(vehicle_sync_record("player2", 2, "held"))
            vehicle_seed.audit.append(vehicle_seed._record_message(proposal_prepare_ack(
                "player2", 3, 1, success=False, error="vehicle mapping rejected",
            )))
            vehicle_recovered = CommitHost(
                GameBridge(root / "vehicle-recovered", vehicle_session, "player1"),
                "127.0.0.1", 0, vehicle_audit,
                require_connected_peers=False,
            )
            self.assertIn("vehicle-sync-release-rejected", vehicle_recovered.session_fault)
            self.assertEqual(
                vehicle_recovered.commits[2]["payload"]["action"]["type"],
                "network.sync_fault",
            )

    def test_line_operation_waits_for_physical_consensus_and_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "operation-consensus"
            bridge = GameBridge(root / "host", session, "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
            )
            transaction = operation_transaction("company:2")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {
                        "action": {
                            "type": "operation.execute",
                            "transaction": transaction,
                            "originCaptureToken": "player2:line-origin:1",
                        }
                    },
                }
            )
            operation_commit = host._commit(intent)
            self.assertEqual(operation_commit["seq"], 1)
            self.assertEqual(
                operation_commit["payload"]["action"]["originCaptureToken"],
                "player2:line-origin:1",
            )
            self.assertEqual(host.operation_consensus[1]["status"], "pending")

            blocked = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player1",
                    "local_seq": 2,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "fare.adjust", "lineCid": "line:test", "deltaCents": 1}},
                }
            )
            with self.assertRaisesRegex(ProtocolError, "physical operation.*awaiting"):
                host._commit(blocked)

            host._record_non_intent(
                operation_completion(session, "player1", 10, transaction, finance_delta=-100)
            )
            self.assertEqual(host.operation_consensus[1]["status"], "pending")
            host._record_non_intent(
                operation_completion(session, "player2", 11, transaction, finance_delta=-250)
            )
            self.assertEqual(host.operation_consensus[1]["status"], "complete")
            outcome = decode_line((bridge.inbox / "000000000002.json").read_bytes())
            action = outcome["payload"]["action"]
            self.assertEqual(action["type"], "network.operation_outcome")
            self.assertTrue(action["success"])
            self.assertEqual(action["financeDelta"], -250)

            reason = f"operation-consensus:{session}:player2:1"
            with self.assertRaisesRegex(ProtocolError, "checkpoint boundary 2"):
                host._commit(blocked)
            host._record_non_intent(consensus_checkpoint(session, "player1", 12, 2, reason))
            host._record_non_intent(consensus_checkpoint(session, "player2", 13, 2, reason))
            self.assertEqual(host.checkpoint_consensus[2]["status"], "complete")
            self.assertEqual(host._commit(blocked)["seq"], 4)

    def test_operation_company_is_bound_to_numbered_peer(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "operation-auth", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False,
            )
            wrong = sign(
                {
                    "protocol": 1,
                    "session": "operation-auth",
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {
                        "action": {
                            "type": "operation.execute",
                            "transaction": operation_transaction("company:1"),
                        }
                    },
                }
            )
            with self.assertRaisesRegex(ProtocolError, "must act for company:2"):
                host._commit(wrong)

            forged_origin = sign(
                {
                    "protocol": 1,
                    "session": "operation-auth",
                    "peer": "player2",
                    "local_seq": 2,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {
                        "action": {
                            "type": "operation.execute",
                            "transaction": operation_transaction("company:2"),
                            "originCaptureToken": "player1:line-origin:2",
                        }
                    },
                }
            )
            with self.assertRaisesRegex(ProtocolError, "must belong to its origin peer"):
                host._commit(forged_origin)

    def test_physical_proposal_requires_roster_and_times_out_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "physical-timeout"
            bridge = GameBridge(root / "host", session, "player1")
            transaction = proposal_transaction("company:1")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player1",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
                }
            )
            guarded = CommitHost(bridge, "127.0.0.1", 0, root / "guarded.ndjson")
            with self.assertRaisesRegex(ProtocolError, "peers are disconnected: player2"):
                guarded._commit(intent)

            host = CommitHost(
                bridge,
                "127.0.0.1",
                0,
                root / "timeout.ndjson",
                completion_timeout=1,
                require_connected_peers=False,
            )
            _, build = pass_proposal_prepare(host, intent)
            build_seq = int(build["seq"])
            host.proposal_consensus[build_seq]["deadline"] = 0
            host._expire_proposals()
            self.assertEqual(host.proposal_consensus[build_seq]["status"], "faulted")
            self.assertIn("proposal-completion-timeout", host.session_fault)
            outcome = decode_line((bridge.inbox / "000000000003.json").read_bytes())
            self.assertFalse(outcome["payload"]["action"]["success"])

    def test_lua_empty_failed_completion_outputs_fault_without_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "physical-lua-empty-failure"
            bridge = GameBridge(root / "host", session, "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
            )
            transaction = proposal_transaction("company:2")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
                }
            )
            _, build = pass_proposal_prepare(host, intent)
            build_seq = int(build["seq"])
            for peer, local_seq in (("player1", 10), ("player2", 11)):
                completion = proposal_completion(
                    session, peer, local_seq, transaction, commit_seq=build_seq, success=False
                )
                completion["payload"]["outputs"] = {}
                host._record_non_intent(completion)

            self.assertEqual(host.proposal_consensus[build_seq]["status"], "faulted")
            self.assertEqual(host.session_fault, "peer-native-proposal-failed")
            self.assertIsNone(host._pending_proposal())
            outcome = decode_line((bridge.inbox / "000000000003.json").read_bytes())
            self.assertEqual(outcome["payload"]["action"]["errorCode"], "peer-native-proposal-failed")

            malformed = proposal_completion(session, "player1", 12, transaction, success=False)["payload"]
            malformed["outputs"] = {"edge:1": {"kind": "edge"}}
            with self.assertRaisesRegex(ProtocolError, "outputs are invalid"):
                CommitHost._completion_payload(malformed)

            failed_operation = operation_completion(
                session, "player1", 13, operation_transaction("company:1"), success=False
            )["payload"]
            failed_operation["outputs"] = {}
            self.assertEqual(CommitHost._operation_completion_payload(failed_operation)["outputs"], {})

    def test_proposal_waits_for_two_physical_completions_before_next_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "physical-consensus"
            bridge = GameBridge(root / "host", session, "player1")
            audit = root / "audit.ndjson"
            host = CommitHost(bridge, "127.0.0.1", 0, audit, require_connected_peers=False)
            transaction = proposal_transaction("company:2")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
                }
            )
            prepare, build = pass_proposal_prepare(host, intent)
            self.assertEqual(prepare["seq"], 1)
            self.assertEqual(build["seq"], 2)

            blocked = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player1",
                    "local_seq": 2,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "fare.adjust", "lineCid": "line:test", "deltaCents": 1}},
                }
            )
            with self.assertRaisesRegex(ProtocolError, "awaiting completion consensus"):
                host._commit(blocked)

            host._record_non_intent(
                proposal_completion(session, "player1", 10, transaction, commit_seq=2)
            )
            self.assertEqual(host.proposal_consensus[2]["status"], "pending")
            host._record_non_intent(
                proposal_completion(
                    session, "player2", 11, transaction, commit_seq=2, finance_delta=-4321
                )
            )
            self.assertEqual(host.proposal_consensus[2]["status"], "complete")
            self.assertIsNone(host.session_fault)
            control = decode_line((bridge.inbox / "000000000003.json").read_bytes())
            self.assertEqual(control["kind"], "control")
            self.assertTrue(control["payload"]["action"]["success"])
            self.assertEqual(control["payload"]["action"]["peers"], ["player1", "player2"])
            self.assertEqual(control["payload"]["action"]["financeDelta"], -4321)

            with self.assertRaisesRegex(ProtocolError, "checkpoint boundary 3"):
                host._commit(blocked)
            reason = f"physical-consensus:{session}:player2:2"
            host._record_non_intent(consensus_checkpoint(session, "player1", 12, 3, reason))
            self.assertEqual(host.checkpoint_consensus[3]["status"], "pending")
            host._record_non_intent(consensus_checkpoint(session, "player2", 13, 3, reason))
            self.assertEqual(host.checkpoint_consensus[3]["status"], "complete")
            checkpoint_control = decode_line((bridge.inbox / "000000000004.json").read_bytes())
            self.assertEqual(checkpoint_control["payload"]["action"]["type"], "network.checkpoint_outcome")
            self.assertTrue(checkpoint_control["payload"]["action"]["success"])
            self.assertEqual(host._commit(blocked)["seq"], 5)
            self.assertEqual(replay(audit, session), 0)
            plan = verify_recovery_plan(build_recovery_plan(audit, session))
            self.assertEqual(plan["anchor"]["boundarySeq"], 3)
            self.assertEqual(plan["requiredPeers"], ["player1", "player2"])
            self.assertEqual(plan["recoveryMode"], "coordinated-identical-save-reload")

    def test_physical_digest_mismatch_faults_the_session_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "physical-divergence"
            bridge = GameBridge(root / "host", session, "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
            )
            transaction = proposal_transaction("company:2")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
                }
            )
            _, build = pass_proposal_prepare(host, intent)
            build_seq = int(build["seq"])
            host._record_non_intent(
                proposal_completion(session, "player1", 10, transaction, commit_seq=build_seq)
            )
            host._record_non_intent(
                proposal_completion(
                    session, "player2", 11, transaction,
                    commit_seq=build_seq, result_digest="33333333"
                )
            )
            self.assertEqual(host.proposal_consensus[build_seq]["status"], "faulted")
            self.assertEqual(host.session_fault, "physical-result-digest-mismatch")
            outcome = decode_line((bridge.inbox / "000000000003.json").read_bytes())
            self.assertFalse(outcome["payload"]["action"]["success"])

            retry = json.loads(json.dumps(intent))
            retry["local_seq"] = 2
            retry = sign(retry)
            with self.assertRaisesRegex(ProtocolError, "session is faulted"):
                host._commit(retry)

    def test_checkpoint_mismatch_and_timeout_fault_the_session_closed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "checkpoint-divergence"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1",
                0,
                root / "audit.ndjson",
                require_connected_peers=False,
            )
            tracker = host._track_checkpoint_boundary(7, "test-checkpoint")
            host.next_seq = 8
            host._record_non_intent(
                consensus_checkpoint(session, "player1", 1, 7, "test-checkpoint")
            )
            host._record_non_intent(
                consensus_checkpoint(session, "player2", 1, 7, "test-checkpoint", financial_delta=1)
            )
            self.assertEqual(tracker["status"], "faulted")
            self.assertEqual(host.session_fault, "checkpoint-convergence-key-mismatch")

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "checkpoint-timeout"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1",
                0,
                root / "audit.ndjson",
                completion_timeout=1,
                require_connected_peers=False,
            )
            tracker = host._track_checkpoint_boundary(4, "test-timeout")
            tracker["deadline"] = 0
            host.next_seq = 5
            host._expire_proposals()
            self.assertEqual(tracker["status"], "faulted")
            self.assertIn("checkpoint-consensus-timeout", host.session_fault)

    def test_host_binds_numbered_peers_to_their_proposal_company(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "host", "proposal-auth", "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
            )
            wrong = sign(
                {
                    "protocol": 1,
                    "session": "proposal-auth",
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {
                        "action": {"type": "proposal.prepare", "transaction": proposal_transaction("company:1")}
                    },
                }
            )
            with self.assertRaisesRegex(ProtocolError, "must act for company:2"):
                host._commit(wrong)

            correct = json.loads(json.dumps(wrong))
            correct["local_seq"] = 2
            correct["payload"]["action"]["transaction"] = proposal_transaction("company:2")
            correct = sign(correct)
            commit = host._commit(correct)
            self.assertIsNotNone(commit)
            self.assertEqual(commit["payload"]["action"]["transaction"]["companyCid"], "company:2")

    def test_host_compares_mobility_digests_by_ordered_sample(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "mobility", "player1"),
                "127.0.0.1",
                available_port(),
                root / "audit.ndjson",
            )
            for peer, digest in (("player1", "abc"), ("player2", "abc")):
                host._record_non_intent(
                    {
                        "kind": "mobility",
                        "peer": peer,
                        "local_seq": 1,
                        "payload": {
                            "sampleKey": "mobility:player1:7",
                            "digest": digest,
                            "vehicleLifecycleDigest": "life",
                            "vehiclePhaseDigest": "phase",
                        },
                    }
                )
            self.assertEqual(host.mobility_digests["mobility:player1:7"], {"player1": "abc", "player2": "abc"})
            self.assertEqual(host.mobility_outcomes["mobility:player1:7"], "converged")
            self.assertEqual(host.vehicle_lifecycle_outcomes["mobility:player1:7"], "converged")
            self.assertEqual(host.vehicle_phase_outcomes["mobility:player1:7"], "converged")
            self.assertEqual(host.vehicle_phase_state, "converged")

            host._record_non_intent(
                {
                    "kind": "mobility",
                    "peer": "player2",
                    "local_seq": 2,
                    "payload": {"sampleKey": "mobility:player1:8", "digest": "different"},
                }
            )
            host._record_non_intent(
                {
                    "kind": "mobility",
                    "peer": "player1",
                    "local_seq": 2,
                    "payload": {"sampleKey": "mobility:player1:8", "digest": "host"},
                }
            )
            self.assertEqual(host.mobility_outcomes["mobility:player1:8"], "diverged")

            for sample in range(9, 12):
                for peer, phase in (("player1", "at-stop-a"), ("player2", "at-stop-b")):
                    host._record_non_intent(
                        {
                            "kind": "mobility",
                            "peer": peer,
                            "local_seq": sample,
                            "payload": {
                                "sampleKey": f"mobility:player1:{sample}",
                                "digest": f"full-{peer}-{sample}",
                                "vehicleLifecycleDigest": "same-lifecycle",
                                "vehiclePhaseDigest": phase,
                            },
                        }
                    )
            self.assertEqual(host.vehicle_phase_divergence_streak, 3)
            self.assertEqual(host.vehicle_phase_state, "warning")
            self.assertEqual(
                host.vehicle_lifecycle_outcomes["mobility:player1:11"], "converged"
            )

    def test_client_intent_is_committed_to_both_game_inboxes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host_bridge = GameBridge(root / "host", "integration", "player1")
            client_bridge = GameBridge(root / "client", "integration", "player2")
            port = available_port()
            host = CommitHost(host_bridge, "127.0.0.1", port, root / "audit.ndjson", "matching-fingerprint")
            client = CommitClient(client_bridge, "127.0.0.1", port, "matching-fingerprint")
            host_thread = threading.Thread(target=host.run, kwargs={"poll_seconds": 0.02}, daemon=True)
            client_thread = threading.Thread(target=client.run, kwargs={"poll_seconds": 0.02, "retry_seconds": 0.05}, daemon=True)
            host_thread.start()
            self.assertTrue(wait_for(lambda: host_thread.is_alive()))
            client_thread.start()
            self.assertTrue(wait_for(lambda: "player2" in host.peers))

            intent = sign(
                {
                    "protocol": 1,
                    "session": "integration",
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 12,
                    "kind": "intent",
                    "payload": {"action": {"type": "fare.adjust", "lineCid": "line:pre:test", "deltaCents": 100}},
                }
            )
            atomic_write(client_bridge.outbox / "000000000001.json", (canonical_json(intent) + "\n").encode())
            host_commit = host_bridge.inbox / "000000000001.json"
            client_commit = client_bridge.inbox / "000000000001.json"
            self.assertTrue(wait_for(lambda: host_commit.exists() and client_commit.exists()))
            decoded = decode_line(client_commit.read_bytes())
            self.assertEqual(decoded["seq"], 1)
            self.assertEqual(decoded["origin_peer"], "player2")
            self.assertEqual(decoded["payload"]["action"]["type"], "fare.adjust")
            self.assertTrue(wait_for(lambda: client_bridge.outbox_cursor == 1))

            client.stop.set()
            host.stop.set()
            client_thread.join(2)
            host_thread.join(2)

    def test_two_bridge_physical_completions_broadcast_ordered_control(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "socket-consensus"
            host_bridge = GameBridge(root / "host", session, "player1")
            client_bridge = GameBridge(root / "client", session, "player2")
            port = available_port()
            host = CommitHost(host_bridge, "127.0.0.1", port, root / "audit.ndjson", "same")
            client = CommitClient(client_bridge, "127.0.0.1", port, "same")
            host_thread = threading.Thread(target=host.run, kwargs={"poll_seconds": 0.01}, daemon=True)
            client_thread = threading.Thread(
                target=client.run, kwargs={"poll_seconds": 0.01, "retry_seconds": 0.05}, daemon=True
            )
            host_thread.start()
            client_thread.start()
            self.assertTrue(wait_for(lambda: "player2" in host.peers))

            transaction = proposal_transaction("company:2")
            intent = sign(
                {
                    "protocol": 1,
                    "session": session,
                    "peer": "player2",
                    "local_seq": 1,
                    "tick": 0,
                    "kind": "intent",
                    "payload": {"action": {"type": "proposal.prepare", "transaction": transaction}},
                }
            )
            atomic_write(client_bridge.outbox / "000000000001.json", (canonical_json(intent) + "\n").encode())
            self.assertTrue(wait_for(lambda: (host_bridge.inbox / "000000000001.json").exists()
                                     and (client_bridge.inbox / "000000000001.json").exists()))

            for bridge, peer, local_seq in (
                (host_bridge, "player1", 1),
                (client_bridge, "player2", 2),
            ):
                envelope = sign(
                    {
                        "protocol": 1,
                        "session": session,
                        "peer": peer,
                        "local_seq": local_seq,
                        "tick": 1,
                        "kind": "ack",
                        "payload": {
                            "commitSeq": 1,
                            "success": True,
                            "digest": "22222222",
                        },
                    }
                )
                atomic_write(
                    bridge.outbox / f"{local_seq:012d}.json",
                    (canonical_json(envelope) + "\n").encode(),
                )

            host_build = host_bridge.inbox / "000000000002.json"
            client_build = client_bridge.inbox / "000000000002.json"
            self.assertTrue(wait_for(lambda: host_build.exists() and client_build.exists()))
            self.assertEqual(
                decode_line(client_build.read_bytes())["payload"]["action"]["type"],
                "proposal.build",
            )

            for bridge, peer, local_seq in (
                (host_bridge, "player1", 2),
                (client_bridge, "player2", 3),
            ):
                completion = proposal_completion(
                    session, peer, local_seq, transaction, commit_seq=2
                )
                envelope = sign(
                    {
                        "protocol": 1,
                        "session": session,
                        "peer": peer,
                        "local_seq": local_seq,
                        "tick": 2,
                        "kind": "completion",
                        "payload": completion["payload"],
                    }
                )
                atomic_write(
                    bridge.outbox / f"{local_seq:012d}.json",
                    (canonical_json(envelope) + "\n").encode(),
                )

            host_control = host_bridge.inbox / "000000000003.json"
            client_control = client_bridge.inbox / "000000000003.json"
            self.assertTrue(wait_for(lambda: host_control.exists() and client_control.exists()))
            outcome = decode_line(client_control.read_bytes())
            self.assertEqual(outcome["kind"], "control")
            self.assertTrue(outcome["payload"]["action"]["success"])
            self.assertEqual(outcome["payload"]["action"]["financeDelta"], -1234)
            self.assertTrue(wait_for(lambda: host_bridge.outbox_cursor == 2 and client_bridge.outbox_cursor == 3))

            reason = f"physical-consensus:{session}:player2:2"
            for bridge, peer, local_seq in (
                (host_bridge, "player1", 3),
                (client_bridge, "player2", 4),
            ):
                checkpoint = consensus_checkpoint(session, peer, local_seq, 3, reason)
                envelope = sign(
                    {
                        "protocol": 1,
                        "session": session,
                        "peer": peer,
                        "local_seq": local_seq,
                        "tick": 2,
                        "kind": "checkpoint",
                        "payload": checkpoint["payload"],
                    }
                )
                atomic_write(
                    bridge.outbox / f"{local_seq:012d}.json",
                    (canonical_json(envelope) + "\n").encode(),
                )
            host_checkpoint_control = host_bridge.inbox / "000000000004.json"
            client_checkpoint_control = client_bridge.inbox / "000000000004.json"
            self.assertTrue(
                wait_for(lambda: host_checkpoint_control.exists() and client_checkpoint_control.exists())
            )
            checkpoint_outcome = decode_line(client_checkpoint_control.read_bytes())
            self.assertEqual(
                checkpoint_outcome["payload"]["action"]["type"], "network.checkpoint_outcome"
            )
            self.assertTrue(checkpoint_outcome["payload"]["action"]["success"])
            self.assertTrue(wait_for(lambda: host_bridge.outbox_cursor == 3 and client_bridge.outbox_cursor == 4))

            client.stop.set()
            host.stop.set()
            client_thread.join(2)
            host_thread.join(2)


if __name__ == "__main__":
    unittest.main()
