from __future__ import annotations

import hashlib
import json
import os
import socket
import tempfile
import threading
import time
import unittest
import zlib
from unittest import mock
from pathlib import Path

from tpf2mp.bridge import AuditLog, GameBridge, atomic_write
from tpf2mp.anchor_io import AnchorRequestStore, anchor_state_message, validate_anchor_state
from tpf2mp.completion_validation import (
    operation_completion_result_digest,
    proposal_completion_result_digest,
)
from tpf2mp.checkpoint import (
    _apply_portable_action,
    _advance_town_development_cursor,
    _advance_town_development_points,
    _evaluate_all_v2,
    _upsert_market_v2,
    _upsert_service_v2,
    analyse_bridge,
    verify_checkpoint,
    verify_event_record,
)
from tpf2mp.freight import (
    advance as advance_freight,
    apply_transport as apply_freight_transport,
    apply_bootstrap as apply_freight_bootstrap,
    deposit_input as deposit_freight_input,
    deposit_input_at_stock as deposit_freight_input_at_stock,
    digest_view as freight_digest_view,
    new_state as new_freight_state,
    withdraw_output as withdraw_freight_output,
)
from tpf2mp.freight_live_report import analyse_freight_audit
from tpf2mp.cli import replay
from tpf2mp.manifest import build_manifest, load_manifest, write_manifest
from tpf2mp.industry_content import (
    IndustryContentCoordinator,
    build_registry as build_industry_registry,
    validate_artifact as validate_industry_artifact,
)
from tpf2mp.network import CommitClient, CommitHost
from tpf2mp.protocol import (
    CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
    FLAT_ALTERNATIVE_OPERATION_SCHEMA_VERSION,
    MAX_PROPOSAL_OUTPUTS,
    OPERATION_SCHEMA_VERSION,
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
from tpf2mp.restore import (
    analyse_restore_points,
    build_restore_plan,
    confirm_restore_readiness,
    verify_restore_plan,
)


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
        "collateral": [],
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
                "collateral": [],
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
    result_digest: str | None = None,
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
        "resultDigest": "",
    }
    if not success:
        payload.pop("financeDelta")
        payload["errorCode"] = "native-proposal-failed"
    payload["resultDigest"] = result_digest or proposal_completion_result_digest(payload)
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
        "schemaVersion": OPERATION_SCHEMA_VERSION,
        "kind": "line.create",
        "companyCid": company,
        "data": {
            "name": "MP Intercity",
            "color": {"r": 80, "g": 420, "b": 1000},
            "line": {
                "stops": [
                    {"stationGroupCid": "station_group:pre:a", "station": 0,
                     "terminal": 0, "alternativeTerminals": []},
                    {"stationGroupCid": "station_group:pre:b", "station": 0,
                     "terminal": 0, "alternativeTerminals": []},
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
    result_digest: str | None = None,
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
        "resultDigest": "",
    }
    if not success:
        payload.pop("financeDelta")
        payload["errorCode"] = "native-operation-failed"
    payload["resultDigest"] = result_digest or operation_completion_result_digest(payload)
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
    # Network consensus accepts only the current format.  The standalone
    # checkpoint fixture remains format 4 to keep archive compatibility
    # covered; promote its empty synchronization view for live-consensus tests.
    payload["checkpointVersion"] = 5
    payload["stateVersion"] = 29
    payload["model"]["freightIndustry"] = {
        "schemaVersion": 2, "ready": False,
        "bootstrapEpoch": 0, "productionEpoch": 0,
        "industries": {}, "totalProduced": {}, "totalConsumed": {},
        "transportCursors": {}, "totalTransported": {}, "totalDelivered": {},
    }
    payload["vehicleSynchronization"]["schemaVersion"] = 4
    payload["vehicleSynchronization"]["cargoPresentation"] = {
        "schemaVersion": 1, "epoch": 0, "lines": [], "vehicles": [],
    }
    payload["vehicleSynchronizationDigest"] = checksum(payload["vehicleSynchronization"])
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
    vehicle_cid: str = "vehicle:event:station-sync:1",
    line_cid: str = "line:event:station-sync:1",
    round_number: int = 1,
    stop_index: int = 0,
    game_time: float = 100.0,
    detail: str = "",
    schedule: dict | None = None,
) -> dict:
    payload = {
        "schemaVersion": 2 if schedule is not None else 1,
        "vehicleCid": vehicle_cid,
        "lineCid": line_cid,
        "round": round_number,
        "stopIndex": stop_index,
        "state": state,
        "gameTime": game_time,
        "engineTick": local_seq,
        "detail": detail,
    }
    if schedule is not None:
        payload["schedule"] = json.loads(json.dumps(schedule))
    return {
        "kind": "vehicle_sync",
        "peer": peer,
        "local_seq": local_seq,
        "payload": payload,
    }


def freight_industry(
    cid: str,
    resource: str,
    capacity: int,
    stocks: list[dict] | dict,
    inputs: list[dict | list],
    outputs: list[dict] | dict,
    params: dict | None = None,
) -> dict:
    recipe = {
        "cid": cid, "resource": resource, "params": params or {},
        "capacity": capacity, "stocks": stocks, "inputs": inputs, "outputs": outputs,
    }
    recipe["recipeDigest"] = checksum({
        "resource": recipe["resource"], "params": recipe["params"],
        "stocks": recipe["stocks"], "inputs": recipe["inputs"],
        "outputs": recipe["outputs"], "capacity": recipe["capacity"],
    })
    return recipe


def freight_fixtures() -> list[dict]:
    return [
        freight_industry(
            "industry:pre:a-farm", "industry/farm.con", 120, {}, [{}],
            [{"cargoType": "GRAIN", "amount": 1}], {"productionLevel": 0},
        ),
        freight_industry(
            "industry:pre:b-mill", "industry/food_processing_plant.con", 60,
            [{"index": 0, "cargoType": "GRAIN", "stockType": "RECEIVING",
              "moreCapacity": 100}],
            [[{"stockIndex": 0, "cargoType": "GRAIN", "amount": 2}]],
            [{"cargoType": "FOOD", "amount": 1}], {"productionLevel": 0},
        ),
        freight_industry(
            "industry:pre:c-consumer", "mod/consumer.con", 60,
            [{"index": 0, "cargoType": "FOOD", "stockType": "RECEIVING",
              "moreCapacity": 0}],
            [[{"stockIndex": 0, "cargoType": "FOOD", "amount": 1}]], {}, {},
        ),
    ]


def freight_bootstrap(epoch: int = 4) -> dict:
    content = {
        "schemaVersion": 1, "contentDigest": "edc7a517",
        "economyEpoch": epoch, "industries": freight_fixtures(),
    }
    return {
        "type": "freight.industry_bootstrap", **content, "digest": checksum(content),
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

    def test_completed_trip_delivery_snapshot_is_strict_and_bounded(self) -> None:
        action = {
            "type": "economy.settle",
            "results": {},
            "scheduled": True,
            "boundaryGameTimeSeconds": 400,
            "deliverySnapshot": {
                "schemaVersion": 1,
                "presentationEpoch": 7,
                "lines": {
                    "line:event:test:1": {
                        "deliveredPassengers": 40,
                        "earnedRevenueCents": 38_000_000,
                    }
                },
            },
        }
        self.assertEqual(validate_action(action), action)
        tampered = json.loads(json.dumps(action))
        tampered["deliverySnapshot"]["lines"]["line:event:test:1"][
            "earnedRevenueCents"
        ] = -1
        with self.assertRaises(ProtocolError):
            validate_action(tampered)

    def test_completed_cargo_delivery_snapshot_is_strict_and_bounded(self) -> None:
        action = {
            "type": "economy.settle", "results": {},
            "deliverySnapshot": {
                "schemaVersion": 2, "presentationEpoch": 9,
                "passengerLines": {},
                "cargoLines": {"line:freight:test": {
                    "contractDigest": "1234abcd",
                    "sourceIndustryCid": "industry:pre:a-farm",
                    "destinationIndustryCid": "industry:pre:b-mill",
                    "destinationStockIndex": 0, "cargoType": "GRAIN",
                    "boardedUnits": 40, "deliveredUnits": 25,
                    "earnedRevenueCents": 25_000_000,
                }},
            },
        }
        self.assertEqual(validate_action(action), action)
        for field, value in (("contractDigest", "NOT-A-DIGEST"),
                             ("cargoType", "grain"),
                             ("destinationStockIndex", 32),
                             ("deliveredUnits", 41)):
            tampered = json.loads(json.dumps(action))
            tampered["deliverySnapshot"]["cargoLines"]["line:freight:test"][field] = value
            with self.subTest(field=field), self.assertRaises(ProtocolError):
                validate_action(tampered)

    def test_freight_aboard_milestone_is_strict_and_portable(self) -> None:
        action = {
            "type": "freight.milestone", "stage": "aboard",
            "lineCid": "line:event:freight-proof",
            "vehicleCid": "vehicle:event:freight-proof",
        }
        self.assertEqual(validate_action(action), action)
        invalid = (
            {**action, "stage": "delivered"},
            {**action, "lineCid": "station_group:event:not-a-line"},
            {**action, "vehicleCid": "line:event:not-a-vehicle"},
            {**action, "lineCid": "line:" + "x" * 236},
            {**action, "unexpected": True},
        )
        for candidate in invalid:
            with self.subTest(candidate=candidate), self.assertRaises(ProtocolError):
                validate_action(candidate)

    def test_match_lifecycle_actions_require_canonical_rules_and_result(self) -> None:
        initial = validate_action(
            {
                "type": "match.initialise",
                "rules": {"startingCash": 5_000_000, "maxEpochs": 24,
                          "valuationTargetCents": 50_000_000,
                          "economyDifficulty": "easy",
                          "revenueMultiplierPpm": 1_500_000},
            }
        )
        self.assertEqual(initial["rules"]["maxEpochs"], 24)
        self.assertEqual(initial["rules"]["economyDifficulty"], "easy")
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
        with self.assertRaisesRegex(ProtocolError, "multiplier is inconsistent"):
            validate_action({
                "type": "match.initialise",
                "rules": {"startingCash": 5_000_000, "maxEpochs": 24,
                          "valuationTargetCents": 0,
                          "economyDifficulty": "hard",
                          "revenueMultiplierPpm": 1_000_000},
            })

    def test_native_samples_are_host_ordered_and_have_no_client_payload(self) -> None:
        self.assertEqual(validate_action({"type": "probe.mobility"}), {"type": "probe.mobility"})
        self.assertEqual(validate_action({"type": "probe.structural"}), {"type": "probe.structural"})
        for action_type in ("probe.mobility", "probe.structural"):
            with self.assertRaises(ProtocolError):
                validate_action({"type": action_type, "sampleKey": "forged"})

    def test_industry_content_attestation_is_strict_and_bounded(self) -> None:
        action = {
            "type": "content.industry_attest", "peer": "player1",
            "digest": "edc7a517", "resourceCount": 16,
            "variantCount": 160, "ambiguousCount": 0,
        }
        self.assertEqual(validate_action(action), action)
        for tampered in (
            {**action, "digest": "not-a-digest"},
            {**action, "resourceCount": 0},
            {**action, "variantCount": 15},
            {**action, "ambiguousCount": True},
            {**action, "extra": 1},
        ):
            with self.assertRaises(ProtocolError):
                validate_action(tampered)

    def test_freight_line_registration_binds_exact_vehicle_capacities(self) -> None:
        action = {
            "type": "line.register", "lineCid": "line:event:freight:1",
            "companyCid": "company:1", "vehicleCosts": {},
            "market": {"cid": "market:freight:test", "kind": "cargo", "demand": 100},
            "service": {
                "lineCid": "line:event:freight:1", "marketCid": "market:freight:test",
                "companyCid": "company:1", "metadata": {
                    "vehicleCids": ["vehicle:event:freight:1", "vehicle:event:freight:2"],
                    "freightContractSchema": 1,
                    "freightContractDigest": "1234abcd",
                    "sourceIndustryCid": "industry:pre:source",
                    "destinationIndustryCid": "industry:pre:sink",
                    "cargoType": "MODDED_CARGO",
                    "cargoCapacityByVehicleCid": {
                        "vehicle:event:freight:1": 12,
                        "vehicle:event:freight:2": 60,
                    },
                    "cargoFleetCapacity": 72,
                    "cargoCapacityPerVehicle": 36,
                },
            },
        }
        self.assertEqual(validate_action(action), action)
        for mutation in ("missing", "fractional", "wrong-total"):
            tampered = json.loads(json.dumps(action))
            capacities = tampered["service"]["metadata"]["cargoCapacityByVehicleCid"]
            if mutation == "missing":
                capacities.pop("vehicle:event:freight:2")
            elif mutation == "fractional":
                capacities["vehicle:event:freight:1"] = 12.5
            else:
                tampered["service"]["metadata"]["cargoFleetCapacity"] = 71
            with self.assertRaises(ProtocolError, msg=mutation):
                validate_action(tampered)

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
        scheduled = validate_action({
            **release,
            "releaseAtGameTime": 125,
            "schedule": {
                "schemaVersion": 1,
                "enabled": True,
                "periodSeconds": 60,
                "phaseSeconds": 5,
                "slotIndex": 2,
                "scheduledDepartureAt": 125,
            },
        })
        self.assertEqual(scheduled["schedule"]["slotIndex"], 2)
        with self.assertRaisesRegex(ProtocolError, "0 through 4"):
            validate_action({"type": "clock.request", "requestedSpeed": 5})
        with self.assertRaisesRegex(ProtocolError, "invalid requested/effective"):
            validate_action({
                "type": "clock.set", "requestedSpeed": 1, "effectiveSpeed": 2,
                "generation": 1, "reason": "invalid",
            })
        with self.assertRaisesRegex(ProtocolError, "release time"):
            validate_action({**release, "releaseAtGameTime": float("nan")})
        with self.assertRaisesRegex(ProtocolError, "reserved slot"):
            validate_action({
                **scheduled,
                "schedule": {**scheduled["schedule"], "scheduledDepartureAt": 126},
            })
        with self.assertRaisesRegex(ProtocolError, "pause mode"):
            validate_action({**scheduled, "releaseWhilePaused": True})

    def test_restore_point_preparation_actions_are_strict(self) -> None:
        self.assertEqual(validate_action({"type": "recovery.prepare"}), {"type": "recovery.prepare"})
        request = validate_action({
            "type": "network.checkpoint_request",
            "preparationSeq": 7,
            "reason": "recovery-prepare:7",
        })
        self.assertEqual(request["preparationSeq"], 7)
        with self.assertRaisesRegex(ProtocolError, "client-supplied fields"):
            validate_action({"type": "recovery.prepare", "boundarySeq": 9})
        with self.assertRaisesRegex(ProtocolError, "reason is invalid"):
            validate_action({**request, "reason": "recovery-prepare:8"})

        resume = {
            "type": "recovery.resume", "fromSession": "saved-session",
            "boundarySeq": 9, "coreDigest": "1234abcd",
            "convergenceKey": "2345bcde", "planChecksum": "3456cdef",
        }
        self.assertEqual(validate_action(resume), resume)
        with self.assertRaisesRegex(ProtocolError, "unknown or missing"):
            validate_action({key: value for key, value in resume.items() if key != "planChecksum"})
        with self.assertRaisesRegex(ProtocolError, "coreDigest"):
            validate_action({**resume, "coreDigest": "not-a-digest"})

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

    def test_removal_only_proposals_are_portable_and_canonically_sorted(self) -> None:
        transaction = proposal_transaction("company:1")
        transaction["nodes"] = {}
        transaction["edges"] = {}
        transaction["edgeObjects"] = {"add": {}, "retain": {}, "remove": {}}
        transaction["remove"] = {
            "edges": ["edge:event:test:a", "edge:event:test:b"],
            "nodes": ["node:event:test:a"],
        }
        redigest_proposal(transaction)
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["remove"]["edges"], transaction["remove"]["edges"])

        for invalid_edges in (
            ["edge:event:test:b", "edge:event:test:a"],
            ["edge:event:test:a", "edge:event:test:a"],
        ):
            malformed = json.loads(json.dumps(transaction))
            malformed["remove"]["edges"] = invalid_edges
            redigest_proposal(malformed)
            with self.assertRaisesRegex(ProtocolError, "sorted and unique"):
                validate_action({"type": "proposal.build", "transaction": malformed})

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

        compound = json.loads(json.dumps(removal))
        topology = proposal_transaction()
        compound.update({
            "nodes": topology["nodes"],
            "edges": topology["edges"],
            "edgeObjects": topology["edgeObjects"],
            "remove": topology["remove"],
        })
        compound["constructions"][0].update({
            "kind": "construction",
            "sourceCid": "construction:pre:house-a",
            "collateral": [
                {"kind": "construction", "cid": "construction:pre:house-b"},
            ],
        })
        redigest_proposal(compound)
        accepted_compound = validate_action({"type": "proposal.build", "transaction": compound})
        self.assertEqual(len(accepted_compound["transaction"]["edges"]), 1)
        self.assertEqual(
            accepted_compound["transaction"]["constructions"][0]["collateral"][0]["cid"],
            "construction:pre:house-b",
        )

        duplicate_source = json.loads(json.dumps(compound))
        duplicate_source["constructions"][0]["collateral"][0]["cid"] = (
            duplicate_source["constructions"][0]["sourceCid"]
        )
        redigest_proposal(duplicate_source)
        with self.assertRaisesRegex(ProtocolError, "source cannot also be collateral"):
            validate_action({"type": "proposal.build", "transaction": duplicate_source})

    def test_stock_station_transaction_and_compound_outputs_are_strict(self) -> None:
        transaction = station_proposal_transaction()
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(
            accepted["transaction"]["schemaVersion"],
            CONSTRUCTION_PROPOSAL_SCHEMA_VERSION,
        )
        self.assertEqual(len(accepted["transaction"]["nodes"]), 13)
        self.assertEqual(len(accepted["transaction"]["edges"]), 12)

        obstructed = json.loads(json.dumps(transaction))
        obstructed["constructions"][0]["collateral"] = [
            {"kind": "construction", "cid": "construction:pre:house-a"},
            {"kind": "construction", "cid": "construction:pre:house-b"},
        ]
        redigest_proposal(obstructed)
        accepted_obstructed = validate_action({"type": "proposal.build", "transaction": obstructed})
        self.assertEqual(
            accepted_obstructed["transaction"]["constructions"][0]["mode"], "build"
        )
        self.assertEqual(
            len(accepted_obstructed["transaction"]["constructions"][0]["collateral"]), 2
        )

        unsorted_collateral = json.loads(json.dumps(obstructed))
        unsorted_collateral["constructions"][0]["collateral"].reverse()
        redigest_proposal(unsorted_collateral)
        with self.assertRaisesRegex(ProtocolError, "sorted and unique"):
            validate_action({"type": "proposal.build", "transaction": unsorted_collateral})

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
        completion["resultDigest"] = proposal_completion_result_digest(completion)
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
        completion["resultDigest"] = proposal_completion_result_digest(completion)
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
                    {"stationGroupCid": "station_group:pre:a", "station": 3,
                     "terminal": 4, "alternativeTerminals": [
                         {"station": 5, "terminal": 6},
                         {"station": 7, "terminal": 8},
                     ]}
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
        self.assertEqual(
            accepted["transaction"]["data"]["line"]["stops"][0]["alternativeTerminals"],
            [{"station": 5, "terminal": 6}, {"station": 7, "terminal": 8}],
        )

    def test_flat_operation_schema_two_remains_auditable_as_station_terminal_pairs(self) -> None:
        transaction = operation_transaction()
        transaction["schemaVersion"] = FLAT_ALTERNATIVE_OPERATION_SCHEMA_VERSION
        transaction["data"]["line"]["stops"][0]["alternativeTerminals"] = [0, 3, 4, 5]
        content = {
            key: transaction[key]
            for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"operation:{transaction['digest']}"
        accepted = validate_action({"type": "operation.execute", "transaction": transaction})
        self.assertEqual(
            accepted["transaction"]["data"]["line"]["stops"][0]["alternativeTerminals"],
            [0, 3, 4, 5],
        )

        transaction["data"]["line"]["stops"][0]["alternativeTerminals"] = [0, 3, 4]
        content["data"] = transaction["data"]
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"operation:{transaction['digest']}"
        with self.assertRaises(ProtocolError):
            validate_action({"type": "operation.execute", "transaction": transaction})

    def test_canonical_vehicle_purchase_accepts_all_portable_vehicle_resources(self) -> None:
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
        road = json.loads(json.dumps(transaction))
        road["data"]["config"]["vehicles"] = [road["data"]["config"]["vehicles"][0]]
        road["data"]["config"]["vehicles"][0]["model"] = "vehicle/bus/benz.mdl"
        road["data"]["config"]["vehicleGroups"] = [1]
        road_content = {
            key: road[key] for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        road["digest"] = checksum(road_content)
        road["transactionId"] = f"operation:{road['digest']}"
        accepted_road = validate_action({"type": "operation.execute", "transaction": road})
        self.assertEqual(
            accepted_road["transaction"]["data"]["config"]["vehicles"][0]["model"],
            "vehicle/bus/benz.mdl",
        )

        invalid = json.loads(json.dumps(transaction))
        invalid["data"]["config"]["vehicles"][1]["model"] = "vehicle/../construction/depot.mdl"
        invalid_content = {
            key: invalid[key] for key in ("schemaVersion", "kind", "companyCid", "data")
        }
        invalid["digest"] = checksum(invalid_content)
        invalid["transactionId"] = f"operation:{invalid['digest']}"
        with self.assertRaisesRegex(ProtocolError, "portable vehicle model"):
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

    def test_canonical_vehicle_lifecycle_scalar_contract(self) -> None:
        cases = {
            "vehicle.reverse": {"targetCid": "vehicle:pre:abc"},
            "vehicle.stop": {"targetCid": "vehicle:pre:abc", "stopped": True},
            "vehicle.maintenance": {
                "targetCid": "vehicle:pre:abc", "valueBasisPoints": 8750,
            },
            "vehicle.depart": {"targetCid": "vehicle:pre:abc"},
            "vehicle.send_to_depot": {
                "targetCid": "vehicle:pre:abc", "sellOnArrival": False,
            },
            "vehicle.manual_departure": {
                "targetCid": "vehicle:pre:abc", "manual": True,
            },
        }
        for kind, data in cases.items():
            content = {
                "schemaVersion": OPERATION_SCHEMA_VERSION,
                "kind": kind,
                "companyCid": "company:2",
                "data": data,
            }
            digest = checksum(content)
            accepted = validate_action({
                "type": "operation.execute",
                "transaction": {
                    **content, "digest": digest, "transactionId": f"operation:{digest}",
                },
            })
            self.assertEqual(accepted["transaction"]["data"], data)

        invalid_cases = {
            "vehicle.stop": {"targetCid": "vehicle:pre:abc", "stopped": 1},
            "vehicle.maintenance": {
                "targetCid": "vehicle:pre:abc", "valueBasisPoints": 10001,
            },
            "vehicle.send_to_depot": {
                "targetCid": "vehicle:pre:abc", "sellOnArrival": 0,
            },
            "vehicle.manual_departure": {
                "targetCid": "vehicle:pre:abc", "manual": "yes",
            },
        }
        for kind, data in invalid_cases.items():
            content = {
                "schemaVersion": OPERATION_SCHEMA_VERSION,
                "kind": kind,
                "companyCid": "company:2",
                "data": data,
            }
            digest = checksum(content)
            with self.assertRaisesRegex(ProtocolError, kind.replace(".", r"\.")):
                validate_action({
                    "type": "operation.execute",
                    "transaction": {
                        **content, "digest": digest,
                        "transactionId": f"operation:{digest}",
                    },
                })

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

    def test_proposal_accepts_collision_safe_anchored_node_references(self) -> None:
        transaction = proposal_transaction("company:1")
        anchored = "node:pre:f9fc0be2:anchor:edge:pre:18b85762"
        transaction["edges"][0]["node0"] = {"cid": anchored}
        transaction["remove"]["nodes"] = [anchored]
        content = {
            key: transaction[key]
            for key in (
                "schemaVersion", "companyCid", "cost", "nodes", "edges",
                "edgeObjects", "remove",
            )
        }
        transaction["digest"] = checksum(content)
        transaction["transactionId"] = f"proposal:{transaction['digest']}"
        accepted = validate_action({"type": "proposal.build", "transaction": transaction})
        self.assertEqual(accepted["transaction"]["edges"][0]["node0"], {"cid": anchored})
        self.assertEqual(accepted["transaction"]["remove"]["nodes"], [anchored])

        malformed = json.loads(json.dumps(transaction))
        malformed["edges"][0]["node0"] = {"cid": "edge:pre:18b85762"}
        content = {
            key: malformed[key]
            for key in (
                "schemaVersion", "companyCid", "cost", "nodes", "edges",
                "edgeObjects", "remove",
            )
        }
        malformed["digest"] = checksum(content)
        malformed["transactionId"] = f"proposal:{malformed['digest']}"
        with self.assertRaisesRegex(ProtocolError, "canonical node id"):
            validate_action({"type": "proposal.build", "transaction": malformed})


class FreightIndustryTests(unittest.TestCase):
    def test_bootstrap_protocol_is_canonical_and_tamper_evident(self) -> None:
        action = freight_bootstrap()
        self.assertEqual(validate_action(action), action)

        tampered = json.loads(json.dumps(action))
        tampered["industries"][0]["outputs"][0]["amount"] = 2
        tampered["digest"] = checksum({
            key: tampered[key]
            for key in ("schemaVersion", "contentDigest", "economyEpoch", "industries")
        })
        with self.assertRaisesRegex(ProtocolError, "recipe digest"):
            validate_action(tampered)

        unordered = json.loads(json.dumps(action))
        unordered["industries"][0], unordered["industries"][1] = (
            unordered["industries"][1], unordered["industries"][0]
        )
        unordered["digest"] = checksum({
            key: unordered[key]
            for key in ("schemaVersion", "contentDigest", "economyEpoch", "industries")
        })
        with self.assertRaisesRegex(ProtocolError, "unordered"):
            validate_action(unordered)

        extra = json.loads(json.dumps(action))
        extra["industries"][0]["localConstructionId"] = 42
        with self.assertRaisesRegex(ProtocolError, "malformed"):
            validate_action(extra)

        no_flow = freight_industry(
            "industry:pre:z-empty", "mod/empty.con", 60, {}, [{}], {}, {},
        )
        content = {
            "schemaVersion": 1, "contentDigest": "edc7a517",
            "economyEpoch": 4, "industries": [no_flow],
        }
        with self.assertRaisesRegex(ProtocolError, "positive flow"):
            validate_action({
                "type": "freight.industry_bootstrap", **content,
                "digest": checksum(content),
            })

    def test_production_and_inventory_match_the_lua_contract(self) -> None:
        action = freight_bootstrap()
        state = new_freight_state()
        apply_freight_bootstrap(
            state, action, {"ready": True, "digest": "edc7a517"}
        )
        first = advance_freight(state, 5, 300)
        self.assertEqual(first["industries"]["industry:pre:a-farm"]["cycles"], 10)
        self.assertEqual(first["industries"]["industry:pre:b-mill"]["cycles"], 0)
        self.assertEqual(
            state["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"], 10
        )

        self.assertEqual(
            deposit_freight_input(state, "industry:pre:b-mill", "GRAIN", 20), 20
        )
        advance_freight(state, 6, 300)
        mill = state["industries"]["industry:pre:b-mill"]
        self.assertEqual(mill["inputStock"][0]["amount"], 10)
        self.assertEqual(mill["outputStock"]["FOOD"], 5)
        self.assertEqual(state["totalConsumed"]["GRAIN"], 10)

        deposit_freight_input(state, "industry:pre:c-consumer", "FOOD", 3)
        advance_freight(state, 7, 300)
        consumer = state["industries"]["industry:pre:c-consumer"]
        self.assertEqual(consumer["lastCycles"], 3)
        self.assertEqual(consumer["inputStock"][0]["amount"], 0)
        self.assertEqual(state["totalConsumed"]["FOOD"], 3)
        self.assertEqual(
            withdraw_freight_output(state, "industry:pre:a-farm", "GRAIN", 7), 23
        )
        self.assertEqual(checksum(freight_digest_view(state)), "f758bc34")

        duplicate = freight_industry(
            "industry:pre:duplicate", "mod/duplicate.con", 60,
            [
                {"index": 0, "cargoType": "GRAIN", "stockType": "RECEIVING", "moreCapacity": 0},
                {"index": 1, "cargoType": "GRAIN", "stockType": "RECEIVING", "moreCapacity": 0},
            ], [[{"stockIndex": 1, "cargoType": "GRAIN", "amount": 1}]], {}, {},
        )
        content = {
            "schemaVersion": 1, "contentDigest": "edc7a517",
            "economyEpoch": 0, "industries": [duplicate],
        }
        duplicate_action = validate_action({
            "type": "freight.industry_bootstrap", **content, "digest": checksum(content),
        })
        duplicate_state = new_freight_state()
        apply_freight_bootstrap(
            duplicate_state, duplicate_action, {"ready": True, "digest": "edc7a517"},
        )
        with self.assertRaisesRegex(ProtocolError, "ambiguous"):
            deposit_freight_input(duplicate_state, duplicate["cid"], "GRAIN", 1)
        self.assertEqual(deposit_freight_input_at_stock(
            duplicate_state, duplicate["cid"], 1, "GRAIN", 2,
        ), 2)

    def test_transport_is_atomic_and_matches_the_lua_stock_contract(self) -> None:
        state = new_freight_state()
        apply_freight_bootstrap(
            state, freight_bootstrap(0), {"ready": True, "digest": "edc7a517"},
        )
        state["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"] = 100
        row = {
            "contractDigest": "1234abcd",
            "sourceIndustryCid": "industry:pre:a-farm",
            "destinationIndustryCid": "industry:pre:b-mill",
            "destinationStockIndex": 0, "cargoType": "GRAIN",
            "boardedUnits": 40, "deliveredUnits": 25,
            "earnedRevenueCents": 25_000_000,
        }
        idle = {**row, "boardedUnits": 0, "deliveredUnits": 0,
                "earnedRevenueCents": 0}
        idle_state = json.loads(json.dumps(state))
        idle_summary = apply_freight_transport(idle_state, {"line:freight:idle": idle})
        self.assertEqual(idle_summary["lines"], 0)
        self.assertNotIn("line:freight:idle", idle_state["transportCursors"])
        summary = apply_freight_transport(state, {"line:freight:test": row})
        self.assertEqual(summary, {
            "lines": 1, "boarded": {"GRAIN": 40}, "delivered": {"GRAIN": 25},
        })
        self.assertEqual(
            state["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"], 60,
        )
        self.assertEqual(
            state["industries"]["industry:pre:b-mill"]["inputStock"][0]["amount"], 25,
        )
        self.assertEqual(state["totalTransported"], {"GRAIN": 40})
        self.assertEqual(state["totalDelivered"], {"GRAIN": 25})

        overdraw = json.loads(json.dumps(state))
        overdraw["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"] = 100
        first = {**row, "contractDigest": "abcdef01", "boardedUnits": 60,
                 "deliveredUnits": 0, "earnedRevenueCents": 0}
        second = {**row, "contractDigest": "87654321", "boardedUnits": 60,
                  "deliveredUnits": 0, "earnedRevenueCents": 0}
        before = canonical_json(overdraw)
        with self.assertRaisesRegex(ProtocolError, "aggregate"):
            apply_freight_transport(overdraw, {
                "line:freight:one": first,
                "line:freight:two": second,
            })
        self.assertEqual(canonical_json(overdraw), before)

        malformed = json.loads(json.dumps(state))
        before = canonical_json(malformed)
        bad = {**row, "contractDigest": "bad"}
        with self.assertRaisesRegex(ProtocolError, "malformed"):
            apply_freight_transport(malformed, {"line:freight:new": bad})
        self.assertEqual(canonical_json(malformed), before)

    def test_portable_replay_and_host_checkpoint_track_bootstrap(self) -> None:
        action = freight_bootstrap()
        model = {
            "economy": {},
            "industryContent": {"ready": True, "digest": "edc7a517"},
        }
        _apply_portable_action(model, action)
        self.assertTrue(model["freightIndustry"]["ready"])
        self.assertEqual(model["freightIndustry"]["productionEpoch"], 4)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "freight-checkpoint"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            committed = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 0, "kind": "intent",
                "payload": {"action": action},
            }))
            self.assertIsNotNone(committed)
            tracker = host.checkpoint_consensus[int(committed["seq"])]
            self.assertEqual(tracker["reason"], "freight-industry-bootstrap")
            self.assertEqual(tracker["status"], "pending")

            restored = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            restored_tracker = restored.checkpoint_consensus[int(committed["seq"])]
            self.assertEqual(restored_tracker["reason"], "freight-industry-bootstrap")


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

    def test_outbound_poll_is_cursor_direct_and_retention_is_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bridge = GameBridge(directory, "session", "player1")
            bridge.outbox_cursor = 4097
            message = sign(
                {
                    "protocol": 1,
                    "session": "session",
                    "peer": "player1",
                    "local_seq": 4098,
                    "tick": 0,
                    "kind": "telemetry",
                    "payload": {},
                }
            )
            old = bridge.outbox / "000000000001.json"
            old_health = sign(
                {
                    "protocol": 1, "session": "session", "peer": "player1",
                    "local_seq": 1, "tick": 0, "kind": "clock_health", "payload": {},
                }
            )
            old.write_bytes((canonical_json(old_health) + "\n").encode())
            durable = bridge.outbox / "000000000002.json"
            old_checkpoint = sign(
                {
                    "protocol": 1, "session": "session", "peer": "player1",
                    "local_seq": 2, "tick": 0, "kind": "checkpoint", "payload": {},
                }
            )
            durable.write_bytes((canonical_json(old_checkpoint) + "\n").encode())
            atomic_write(
                bridge.outbox / "000000004098.json",
                (canonical_json(message) + "\n").encode(),
            )
            with mock.patch(
                "tpf2mp.bridge.Path.glob",
                side_effect=AssertionError("outbound polling enumerated history"),
            ):
                pending = list(bridge.pending_outbound())
            self.assertEqual([item[0] for item in pending], [4098])
            bridge.acknowledge_outbound(4098)
            self.assertFalse(old.exists())
            self.assertTrue(durable.exists())
            cursor = json.loads(bridge.cursor_path.read_text(encoding="utf-8"))
            self.assertEqual(cursor["schemaVersion"], 2)
            self.assertEqual(cursor["pruned_through"], 2)
            self.assertEqual(cursor["ephemeral_retention_messages"], 4096)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            state = root / "companion_state"
            state.mkdir(parents=True)
            (state / "outbox_cursor_session.json").write_text(
                canonical_json({"session": "session", "last_local_seq": 6000}) + "\n",
                encoding="utf-8",
            )
            migrated = GameBridge(root, "session", "player1")
            self.assertEqual(migrated.outbox_cursor, 6000)
            self.assertEqual(migrated.outbox_pruned_through, 1904)

    def test_outbound_poll_never_skips_a_missing_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bridge = GameBridge(directory, "session", "player1")
            later = sign(
                {
                    "protocol": 1,
                    "session": "session",
                    "peer": "player1",
                    "local_seq": 2,
                    "tick": 0,
                    "kind": "telemetry",
                    "payload": {},
                }
            )
            atomic_write(
                bridge.outbox / "000000000002.json",
                (canonical_json(later) + "\n").encode(),
            )
            self.assertEqual(list(bridge.pending_outbound()), [])

    def test_industry_artifacts_merge_into_a_pinned_runtime_registry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            bridge = GameBridge(directory, "industry-session", "player1")
            recipe = {
                "resource": "industry/farm.con",
                "params": {},
                "stocks": {},
                "inputs": [{}],
                "outputs": [{"cargoType": "GRAIN", "amount": 1}],
                "capacity": 200,
            }
            recipe["digest"] = checksum(recipe)
            resource = {
                "fileName": "industry/farm.con",
                "parameters": {},
                "declarationAmbiguous": False,
                "variants": [{
                    "params": {}, "recipe": recipe,
                    "recipeDigests": [recipe["digest"]], "ambiguous": False,
                }],
            }
            artifact = {"schemaVersion": 1, "resource": resource}
            artifact["digest"] = checksum(artifact)
            key = f"{zlib.adler32(resource['fileName'].encode()) & 0xFFFFFFFF:08x}"
            path = bridge.industry_content_dir / f"{key}-{artifact['digest']}.json"
            path.write_text(canonical_json(artifact) + "\n", encoding="utf-8")

            self.assertEqual(validate_industry_artifact(artifact, path)["digest"], artifact["digest"])
            built = build_industry_registry(bridge.industry_content_dir)
            self.assertEqual(built["resourceCount"], 1)
            self.assertEqual(built["variantCount"], 1)
            self.assertEqual(built["ambiguousCount"], 0)

            coordinator = IndustryContentCoordinator(bridge, quiet_seconds=0)
            self.assertTrue(coordinator.refresh(now=1))  # observes the new immutable set
            self.assertTrue(coordinator.refresh(now=1))  # validates and publishes it
            published = json.loads(coordinator.output.read_text(encoding="utf-8"))
            self.assertEqual(published["digest"], built["digest"])
            self.assertEqual(published["session"], "industry-session")
            self.assertEqual(published["peer"], "player1")
            self.assertTrue(coordinator.status()["industryContentReady"])

            artifact["digest"] = "00000000"
            with self.assertRaisesRegex(ProtocolError, "digest"):
                validate_industry_artifact(artifact)


class CheckpointTests(unittest.TestCase):
    def test_completed_passenger_revenue_cursor_pays_exactly_once(self) -> None:
        economy = {
            "version": 6,
            "epoch": 0,
            "params": {},
            "markets": {},
            "services": {},
            "companyCosts": {},
            "vehicleCosts": {},
            "deliveryCursors": {},
            "scheduler": {"schemaVersion": 2, "automatic": True, "epochSeconds": 300},
            "lastResults": {},
            "ledger": {},
        }
        _upsert_market_v2(economy, {
            "cid": "market:test", "kind": "passenger", "demand": 12_000,
            "gcOutsideCents": 100_000_000, "thetaCents": 200,
        })
        _upsert_service_v2(economy, {
            "lineCid": "line:test", "marketCid": "market:test",
            "companyCid": "company:1", "fareCents": 950, "capacity": 320,
            "headwaySeconds": 900, "journeySeconds": 600, "quality": 100,
        })
        delivery = {
            "schemaVersion": 1, "presentationEpoch": 1,
            "lines": {"line:test": {
                "deliveredPassengers": 40, "earnedRevenueCents": 38_000_000,
            }},
        }
        first = _evaluate_all_v2(economy, delivery_snapshot=delivery)
        row = first["markets"]["market:test"]["services"]["line:test"]
        self.assertEqual((row["delivered"], row["grossRevenueCents"]), (40, 38_000_000))
        second = _evaluate_all_v2(economy, delivery_snapshot=delivery)
        row = second["markets"]["market:test"]["services"]["line:test"]
        self.assertEqual((row["delivered"], row["grossRevenueCents"]), (0, 0))
        delivery["lines"]["line:test"]["deliveredPassengers"] = 39
        with self.assertRaisesRegex(ProtocolError, "moved backwards"):
            _evaluate_all_v2(economy, delivery_snapshot=delivery)

    def test_wrong_authored_economy_boundary_rejects_without_mutation(self) -> None:
        economy = {
            "version": 5,
            "epoch": 0,
            "params": {},
            "markets": {},
            "services": {},
            "companyCosts": {
                "company:1": {
                    "companyCid": "company:1",
                    "infrastructureCapitalCents": 87600,
                    "annualInfrastructureUpkeepCents": 8760,
                    "upkeepResid": 0,
                }
            },
            "scheduler": {
                "schemaVersion": 1,
                "automatic": True,
                "epochSeconds": 3600,
                "startGameTimeSeconds": 100,
                "lastBoundaryGameTimeSeconds": 100,
                "nextBoundaryGameTimeSeconds": 3700,
            },
            "lastResults": {},
            "ledger": {},
        }
        before = canonical_json(economy)
        with self.assertRaisesRegex(ProtocolError, "next scheduled accounting interval"):
            _evaluate_all_v2(economy, 9999)
        self.assertEqual(canonical_json(economy), before)

    def test_town_development_replay_matches_lua_accumulator_and_cursor(self) -> None:
        model = {
            "townDevelopment": {
                "schemaVersion": 1,
                "enabled": True,
                "points": {"town:a": 100, "town:b": 350},
                "cursor": {"town:a": 4},
            }
        }
        economy = {
            "markets": {
                "market:a-b": {
                    "metadata": {"townA": "town:a", "townB": "town:b"}
                }
            }
        }
        results = {
            "markets": {
                "market:a-b": {
                    "services": {
                        "line:1": {"allocated": 500},
                        "line:2": {"allocated": 301},
                    }
                }
            }
        }
        due = _advance_town_development_points(model, economy, results)
        self.assertEqual(due, {"town:a": 1, "town:b": 1})
        self.assertEqual(
            model["townDevelopment"]["points"],
            {"town:a": 100, "town:b": 351},
        )
        _advance_town_development_cursor(model, {"town:a": 2, "town:b": 1})
        self.assertEqual(
            model["townDevelopment"]["cursor"],
            {"town:a": 6, "town:b": 1},
        )

    def test_town_development_replay_is_disabled_and_bounded(self) -> None:
        disabled = {
            "townDevelopment": {
                "schemaVersion": 1, "enabled": False, "points": {}, "cursor": {}
            }
        }
        economy = {
            "markets": {
                "market:a-b": {
                    "metadata": {"townA": "town:a", "townB": "town:b"}
                }
            }
        }
        results = {
            "markets": {
                "market:a-b": {"services": {"line:1": {"allocated": 100_000}}}
            }
        }
        self.assertEqual(
            _advance_town_development_points(disabled, economy, results), {}
        )
        self.assertEqual(disabled["townDevelopment"]["points"], {})

        bounded = {
            "townDevelopment": {
                "schemaVersion": 1,
                "enabled": True,
                "points": {"town:a": 3_900, "town:b": 3_900},
                "cursor": {},
            }
        }
        self.assertEqual(
            _advance_town_development_points(bounded, economy, results),
            {"town:a": 2, "town:b": 2},
        )
        self.assertEqual(
            bounded["townDevelopment"]["points"],
            {"town:a": 3_200, "town:b": 3_200},
        )

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
        passenger_presentation = {
            "schemaVersion": 1,
            "epoch": 0,
            "lines": [],
            "vehicles": [],
        }
        vehicle_sync = {
            "schemaVersion": 3,
            "enabled": True,
            "vehicles": [],
            "scheduleReservations": [],
            "passengerPresentation": passenger_presentation,
        }
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
            "checkpointVersion": 4,
            "stateVersion": 24,
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
                "checkpointVersion": payload["checkpointVersion"],
                "stateVersion": payload["stateVersion"],
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

    @staticmethod
    def resign_checkpoint(payload: dict) -> dict:
        payload["modelDigest"] = checksum(payload["model"])
        payload["canonicalDigest"] = checksum(payload["canonical"])
        payload["vehicleSynchronizationDigest"] = checksum(
            payload["vehicleSynchronization"]
        )
        core = json.loads(json.dumps(payload["model"]))
        core["canonical"] = payload["canonical"]
        core["vehicleSynchronization"] = payload["vehicleSynchronization"]
        payload["coreDigest"] = checksum(core)
        payload["convergenceKey"] = checksum({
            "checkpointVersion": payload["checkpointVersion"],
            "stateVersion": payload["stateVersion"],
            "protocol": payload["protocol"],
            "sessionId": payload["sessionId"],
            "lastCommitSeq": payload["eventCursor"]["lastCommitSeq"],
            "modelDigest": payload["modelDigest"],
            "canonicalDigest": payload["canonicalDigest"],
            "vehicleSynchronizationDigest": payload["vehicleSynchronizationDigest"],
            "coreDigest": payload["coreDigest"],
            "financialDigest": payload["financialDigest"],
        })
        payload.pop("checkpointDigest", None)
        payload["checkpointDigest"] = checksum(payload)
        return payload

    @classmethod
    def populated_passenger_checkpoint(cls) -> dict:
        payload = cls.checkpoint_payload()
        payload["model"]["economy"]["epoch"] = 2
        stops = [
            "station_group:event:presentation:a",
            "station_group:event:presentation:b",
        ]
        payload["model"]["economy"]["services"]["line:event:presentation:1"] = {
            "lineCid": "line:event:presentation:1",
            "marketCid": "market:event:presentation:1",
            "companyCid": "company:1",
            "metadata": {"stationGroupCids": stops},
        }
        payload["vehicleSynchronization"]["vehicles"] = [{
            "vehicleCid": "vehicle:event:presentation:1",
            "lineCid": "line:event:presentation:1",
            "companyCid": "company:1",
            "lastAuthorizedRound": 3,
            "stopIndex": 0,
            "releaseAtGameTime": 100,
            "releaseWhilePaused": False,
            "schedule": {"schemaVersion": 1, "enabled": False},
        }]
        payload["vehicleSynchronization"]["passengerPresentation"] = {
            "schemaVersion": 1,
            "epoch": 2,
            "lines": [{
                "lineCid": "line:event:presentation:1",
                "companyCid": "company:1",
                "marketCid": "market:event:presentation:1",
                "epoch": 2,
                "terminalA": "station_group:event:presentation:a",
                "terminalB": "station_group:event:presentation:b",
                "stops": stops,
                "stopCount": 2,
                "routeDigest": checksum(stops),
                "allocated": 65,
                "waitingAToB": 24,
                "waitingBToA": 33,
                "departuresPlanned": 4,
                "departuresAToB": 1,
                "departuresBToA": 0,
                "seatsPerVehicle": 40,
                "boardedTotal": 8,
                "alightedTotal": 0,
                "overflowTotal": 0,
            }],
            "vehicles": [{
                "vehicleCid": "vehicle:event:presentation:1",
                "lineCid": "line:event:presentation:1",
                "companyCid": "company:1",
                "capacity": 40,
                "aboard": 8,
                "lastRound": 3,
                "boardedEpoch": 2,
                "lastStopIndex": 0,
                "lastStationGroupCid": "station_group:event:presentation:a",
                "originStationGroupCid": "station_group:event:presentation:a",
                "destinationStationGroupCid": "station_group:event:presentation:b",
                "boardedTotal": 8,
                "alightedTotal": 0,
                "discardedTotal": 0,
            }],
        }
        return cls.resign_checkpoint(payload)

    @classmethod
    def populated_cargo_checkpoint(cls) -> dict:
        payload = consensus_checkpoint(
            "checkpoint-cargo", "player1", 1, 1, "cargo-test",
        )["payload"]
        stops = ["station_group:event:cargo:source", "station_group:event:cargo:sink"]
        line_cid, vehicle_cid = "line:event:cargo:1", "vehicle:event:cargo:1"
        row = {
            "contractDigest": "1234abcd",
            "sourceIndustryCid": "industry:pre:a-farm",
            "destinationIndustryCid": "industry:pre:b-mill",
            "destinationStockIndex": 0, "cargoType": "GRAIN",
            "boardedUnits": 40, "deliveredUnits": 25,
            "earnedRevenueCents": 25_000_000,
        }
        freight = new_freight_state()
        apply_freight_bootstrap(
            freight, freight_bootstrap(0), {"ready": True, "digest": "edc7a517"},
        )
        freight["industries"]["industry:pre:a-farm"]["outputStock"]["GRAIN"] = 100
        apply_freight_transport(freight, {line_cid: row})
        payload["model"]["freightIndustry"] = freight_digest_view(freight)
        economy = payload["model"]["economy"]
        economy["epoch"] = 1
        economy["markets"] = {
            "market:event:cargo:1": {"kind": "cargo", "demand": 120},
        }
        economy["services"] = {line_cid: {
            "lineCid": line_cid, "marketCid": "market:event:cargo:1",
            "companyCid": "company:1", "metadata": {
                "stationGroupCids": stops,
                "freightContractDigest": row["contractDigest"],
                "sourceIndustryCid": row["sourceIndustryCid"],
                "destinationIndustryCid": row["destinationIndustryCid"],
                "destinationStockIndex": 0, "cargoType": "GRAIN",
            },
        }}
        sync = payload["vehicleSynchronization"]
        sync["vehicles"] = [{
            "vehicleCid": vehicle_cid, "lineCid": line_cid,
            "companyCid": "company:1", "lastAuthorizedRound": 2,
            "stopIndex": 1, "releaseAtGameTime": 100,
            "releaseWhilePaused": False,
            "schedule": {"schemaVersion": 1, "enabled": False},
        }]
        sync["passengerPresentation"]["epoch"] = 1
        sync["cargoPresentation"] = {
            "schemaVersion": 1, "epoch": 1,
            "lines": [{
                "lineCid": line_cid, "companyCid": "company:1",
                "marketCid": "market:event:cargo:1",
                "contractDigest": row["contractDigest"],
                "sourceIndustryCid": row["sourceIndustryCid"],
                "destinationIndustryCid": row["destinationIndustryCid"],
                "destinationStockIndex": 0, "cargoType": "GRAIN",
                "sourceStationGroupCid": stops[0], "destinationStationGroupCid": stops[1],
                "sourceStopIndex": 0, "destinationStopIndex": 1,
                "stops": stops, "routeDigest": checksum(stops),
                "epoch": 1, "allocated": 40, "boardedThisEpoch": 40,
                "capacityPerVehicle": 40, "boardedTotal": 40,
                "deliveredTotal": 25, "earnedRevenueCents": 25_000_000,
                "discardedTotal": 0, "retired": False,
            }],
            "vehicles": [{
                "vehicleCid": vehicle_cid, "lineCid": line_cid,
                "companyCid": "company:1", "capacity": 40, "aboard": 15,
                "lastRound": 2, "boardedEpoch": 1, "lastStopIndex": 1,
                "lastStationGroupCid": stops[1], "boardedFareCents": 1000,
                "boardedDistanceMeters": 10_000, "boardedTotal": 40,
                "deliveredTotal": 25, "earnedRevenueCents": 25_000_000,
                "discardedTotal": 0,
            }],
        }
        return cls.resign_checkpoint(payload)

    def test_current_checkpoint_binds_freight_stock_and_cargo_presentation(self) -> None:
        payload = self.populated_cargo_checkpoint()
        verified = verify_checkpoint(payload)
        self.assertEqual(verified["checkpointVersion"], 5)
        self.assertEqual(
            verified["model"]["freightIndustry"]["totalDelivered"], {"GRAIN": 25},
        )
        cases = (
            (lambda value: value["model"]["freightIndustry"]["totalTransported"].update(
                {"GRAIN": 39}
            ), "transport totals disagree"),
            (lambda value: value["vehicleSynchronization"]["cargoPresentation"][
                "vehicles"
            ][0].update({"aboard": 16}), "vehicle conservation"),
            (lambda value: value["vehicleSynchronization"]["cargoPresentation"][
                "lines"
            ][0].update({"boardedTotal": 41}), "line conservation"),
            (lambda value: value["vehicleSynchronization"]["cargoPresentation"].update(
                {"epoch": 0}
            ), "epoch disagrees"),
            (lambda value: value["vehicleSynchronization"]["cargoPresentation"][
                "lines"
            ][0].update({"contractDigest": "87654321"}), "economy service"),
        )
        for mutate, error in cases:
            tampered = json.loads(json.dumps(payload))
            mutate(tampered)
            self.resign_checkpoint(tampered)
            with self.subTest(error=error), self.assertRaisesRegex(ProtocolError, error):
                verify_checkpoint(tampered)

    def test_freight_live_report_requires_two_peer_settled_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = "freight-live-report"
            audit = AuditLog(Path(directory) / "audit.ndjson")
            player1 = self.populated_cargo_checkpoint()
            line_cid = "line:event:cargo:1"
            player1["sessionId"] = session
            player1["peerId"] = "player1"
            player1["reason"] = "economy-settlement"
            player1["eventCursor"]["lastCommitSeq"] = 1
            player1["model"]["economy"].setdefault("deliveryCursors", {})[line_cid] = {
                "deliveredCargo": 25,
                "earnedRevenueCents": 25_000_000,
            }
            self.resign_checkpoint(player1)
            player2 = json.loads(json.dumps(player1))
            player2["peerId"] = "player2"
            self.resign_checkpoint(player2)

            audit.append(sign({
                "protocol": 1, "session": session, "seq": 1, "kind": "commit",
                "origin_peer": "player1", "origin_local_seq": 1, "tick": 1,
                "payload": {"action": {"type": "economy.settle"}},
            }))
            for local_seq, peer, payload in (
                (1, "player1", player1), (1, "player2", player2),
            ):
                audit.append(sign({
                    "protocol": 1, "session": session, "kind": "record",
                    "peer": peer, "local_seq": local_seq,
                    "record_type": "checkpoint", "payload": payload,
                }))
            audit.append(sign({
                "protocol": 1, "session": session, "seq": 2, "kind": "control",
                "origin_peer": "player1", "tick": 0,
                "payload": {"action": {
                    "type": "network.checkpoint_outcome", "boundarySeq": 1,
                    "reason": "economy-settlement", "success": True,
                    "convergenceKey": player1["convergenceKey"],
                    "coreDigest": player1["coreDigest"],
                    "modelDigest": player1["modelDigest"],
                    "canonicalDigest": player1["canonicalDigest"],
                    "financialDigest": player1["financialDigest"],
                    "peers": ["player1", "player2"],
                }},
            }))
            self.assertEqual(replay(audit.path, session), 0)
            report = analyse_freight_audit(
                audit.path, session, require_stage="settled",
                require_observed_aboard=True,
            )
            self.assertTrue(report["passed"], report["problems"])
            self.assertTrue(report["observedStages"]["aboard"])
            self.assertTrue(report["observedStages"]["delivered"])
            self.assertTrue(report["observedStages"]["settled"])
            self.assertEqual(report["maxima"]["aboard"], 15)
            self.assertEqual(report["maxima"]["settledRevenueCents"], 25_000_000)
            waiting_report = analyse_freight_audit(
                audit.path, session, require_stage="waiting"
            )
            self.assertFalse(waiting_report["passed"])
            self.assertIn(
                "required freight stage was not observed: waiting",
                waiting_report["problems"],
            )

            pending = AuditLog(Path(directory) / "pending-checkpoint.ndjson")
            for message in list(AuditLog(audit.path).messages())[:-1]:
                pending.append(message)
            pending_report = analyse_freight_audit(pending.path, session)
            self.assertFalse(pending_report["passed"])
            self.assertEqual(pending_report["pending"]["checkpoints"], [1])

            missing = AuditLog(Path(directory) / "missing-peer.ndjson")
            for message in AuditLog(audit.path).messages():
                if message.get("kind") == "record" and message.get("peer") == "player2":
                    continue
                missing.append(message)
            with self.assertRaisesRegex(ProtocolError, "lacks freight evidence"):
                analyse_freight_audit(missing.path, session)

    def test_freight_live_report_accepts_automatic_aboard_milestone(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            session = "freight-automatic-aboard"
            audit = AuditLog(Path(directory) / "audit.ndjson")
            reason = "freight-milestone:aboard"
            payloads = []
            for peer in ("player1", "player2"):
                payload = self.populated_cargo_checkpoint()
                payload["sessionId"] = session
                payload["peerId"] = peer
                payload["reason"] = reason
                payload["eventCursor"]["lastCommitSeq"] = 1
                self.resign_checkpoint(payload)
                payloads.append(payload)
            audit.append(sign({
                "protocol": 1, "session": session, "seq": 1, "kind": "commit",
                "origin_peer": "player1", "origin_local_seq": 1, "tick": 1,
                "payload": {"action": {
                    "type": "freight.milestone", "stage": "aboard",
                    "lineCid": "line:event:cargo:1",
                    "vehicleCid": "vehicle:event:cargo:1",
                }},
            }))
            for peer, payload in zip(("player1", "player2"), payloads):
                audit.append(sign({
                    "protocol": 1, "session": session, "kind": "record",
                    "peer": peer, "local_seq": 1,
                    "record_type": "checkpoint", "payload": payload,
                }))
            first = payloads[0]
            audit.append(sign({
                "protocol": 1, "session": session, "seq": 2, "kind": "control",
                "origin_peer": "player1", "tick": 0,
                "payload": {"action": {
                    "type": "network.checkpoint_outcome", "boundarySeq": 1,
                    "reason": reason, "success": True,
                    "convergenceKey": first["convergenceKey"],
                    "coreDigest": first["coreDigest"],
                    "modelDigest": first["modelDigest"],
                    "canonicalDigest": first["canonicalDigest"],
                    "financialDigest": first["financialDigest"],
                    "peers": ["player1", "player2"],
                }},
            }))
            self.assertEqual(replay(audit.path, session), 0)
            report = analyse_freight_audit(
                audit.path, session, require_stage="aboard",
                require_observed_aboard=True,
            )
            self.assertTrue(report["passed"], report["problems"])
            self.assertEqual(report["completedCheckpoints"][0]["reason"], reason)
            self.assertEqual(report["maxima"]["aboard"], 15)

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

    def test_checkpoint_accepts_digest_bound_credit_state(self) -> None:
        payload = self.checkpoint_payload()
        accounts = {
            "company:1": {
                "balance": 4_900_000,
                "loan": 0,
                "insolventSettlements": 1,
                "creditLimit": 500_000_000,
            },
            "company:2": {
                "balance": 5_100_000,
                "loan": 0,
                "insolventSettlements": 0,
                "creditLimit": 500_000_000,
            },
        }
        payload["model"]["networkFinance"] = {
            "version": 1,
            "initialized": True,
            "accounts": json.loads(json.dumps(accounts)),
        }
        payload["financial"]["companies"] = json.loads(json.dumps(accounts))
        payload["modelDigest"] = checksum(payload["model"])
        core = json.loads(json.dumps(payload["model"]))
        core["canonical"] = payload["canonical"]
        core["vehicleSynchronization"] = payload["vehicleSynchronization"]
        payload["coreDigest"] = checksum(core)
        payload["financialDigest"] = checksum(payload["financial"])
        payload["convergenceKey"] = checksum({
            "checkpointVersion": payload["checkpointVersion"],
            "stateVersion": payload["stateVersion"],
            "protocol": payload["protocol"],
            "sessionId": payload["sessionId"],
            "lastCommitSeq": payload["eventCursor"]["lastCommitSeq"],
            "modelDigest": payload["modelDigest"],
            "canonicalDigest": payload["canonicalDigest"],
            "vehicleSynchronizationDigest": payload["vehicleSynchronizationDigest"],
            "coreDigest": payload["coreDigest"],
            "financialDigest": payload["financialDigest"],
        })
        payload.pop("checkpointDigest", None)
        payload["checkpointDigest"] = checksum(payload)
        self.assertEqual(verify_checkpoint(payload)["financial"], payload["financial"])

        tampered = json.loads(json.dumps(payload))
        tampered["financial"]["companies"]["company:1"]["creditLimit"] += 1
        tampered["financialDigest"] = checksum(tampered["financial"])
        tampered["convergenceKey"] = checksum({
            "checkpointVersion": tampered["checkpointVersion"],
            "stateVersion": tampered["stateVersion"],
            "protocol": tampered["protocol"],
            "sessionId": tampered["sessionId"],
            "lastCommitSeq": tampered["eventCursor"]["lastCommitSeq"],
            "modelDigest": tampered["modelDigest"],
            "canonicalDigest": tampered["canonicalDigest"],
            "vehicleSynchronizationDigest": tampered["vehicleSynchronizationDigest"],
            "coreDigest": tampered["coreDigest"],
            "financialDigest": tampered["financialDigest"],
        })
        tampered.pop("checkpointDigest", None)
        tampered["checkpointDigest"] = checksum(tampered)
        with self.assertRaises(ProtocolError):
            verify_checkpoint(tampered)

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
            "schedule": {"schemaVersion": 1, "enabled": False},
        }]
        with self.assertRaisesRegex(ProtocolError, "missing its stop/release anchor"):
            verify_checkpoint(payload)

    def test_checkpoint_binds_exact_passenger_ledger_to_vehicle_sync(self) -> None:
        payload = self.populated_passenger_checkpoint()
        verified = verify_checkpoint(payload)
        self.assertEqual(
            verified["vehicleSynchronization"]["passengerPresentation"]["vehicles"][0]["aboard"],
            8,
        )

        for mutate, error in (
            (
                lambda value: value["vehicleSynchronization"]["passengerPresentation"]
                ["vehicles"][0].__setitem__("aboard", 41),
                "count is invalid",
            ),
            (
                lambda value: value["vehicleSynchronization"]["passengerPresentation"]
                ["vehicles"][0].__setitem__("lastRound", 2),
                "round disagrees",
            ),
            (
                lambda value: value["vehicleSynchronization"]["passengerPresentation"]
                ["vehicles"][0].__setitem__(
                    "destinationStationGroupCid", "station_group:event:wrong"
                ),
                "trip disagrees",
            ),
            (
                lambda value: value["model"]["economy"]["services"]
                ["line:event:presentation:1"]["metadata"].__setitem__(
                    "stationGroupCids",
                    [
                        "station_group:event:presentation:a",
                        "station_group:event:different",
                    ],
                ),
                "disagrees with its economy service",
            ),
        ):
            tampered = json.loads(json.dumps(payload))
            mutate(tampered)
            self.resign_checkpoint(tampered)
            with self.assertRaisesRegex(ProtocolError, error):
                verify_checkpoint(tampered)

    def test_checkpoint_v3_accepts_and_binds_departure_schedule_state(self) -> None:
        payload = self.checkpoint_payload()
        payload["checkpointVersion"] = 3
        schedule = {
            "schemaVersion": 1,
            "enabled": True,
            "periodSeconds": 60,
            "phaseSeconds": 5,
            "slotIndex": 2,
            "scheduledDepartureAt": 125,
        }
        vehicle_sync = {
            "schemaVersion": 2,
            "enabled": True,
            "vehicles": [{
                "vehicleCid": "vehicle:event:test:1",
                "lineCid": "line:event:test:1",
                "companyCid": "company:1",
                "lastAuthorizedRound": 1,
                "stopIndex": 0,
                "releaseAtGameTime": 125,
                "releaseWhilePaused": False,
                "schedule": schedule,
            }],
            "scheduleReservations": [{
                "lineCid": "line:event:test:1",
                "stopIndex": 0,
                "periodSeconds": 60,
                "phaseSeconds": 5,
                "lastSlotIndex": 2,
                "lastScheduledDepartureAt": 125,
            }],
        }
        payload["vehicleSynchronization"] = vehicle_sync
        payload["vehicleSynchronizationDigest"] = checksum(vehicle_sync)
        core = json.loads(json.dumps(payload["model"]))
        core["canonical"] = payload["canonical"]
        core["vehicleSynchronization"] = vehicle_sync
        payload["coreDigest"] = checksum(core)
        payload["convergenceKey"] = checksum({
            "checkpointVersion": payload["checkpointVersion"],
            "stateVersion": payload["stateVersion"],
            "protocol": payload["protocol"],
            "sessionId": payload["sessionId"],
            "lastCommitSeq": payload["eventCursor"]["lastCommitSeq"],
            "modelDigest": payload["modelDigest"],
            "canonicalDigest": payload["canonicalDigest"],
            "vehicleSynchronizationDigest": payload["vehicleSynchronizationDigest"],
            "coreDigest": payload["coreDigest"],
            "financialDigest": payload["financialDigest"],
        })
        payload.pop("checkpointDigest", None)
        payload["checkpointDigest"] = checksum(payload)
        self.assertEqual(
            verify_checkpoint(payload)["vehicleSynchronization"]["schemaVersion"], 2
        )

        tampered = json.loads(json.dumps(payload))
        tampered["vehicleSynchronization"]["scheduleReservations"][0][
            "lastScheduledDepartureAt"
        ] = 126
        with self.assertRaisesRegex(ProtocolError, "reservation is invalid"):
            verify_checkpoint(tampered)

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
                "passengerPresentationDigest": "13579bdf",
                "passengerPresentation": {
                    "schemaVersion": 1,
                    "epoch": 3,
                    "lines": [{"waitingAToB": 7, "waitingBToA": 5}],
                    "vehicles": [{"aboard": 11}],
                },
                "passengerCosmetics": {
                    "nativeAboard": 1,
                    "nativeWaiting": 2,
                    "targetWritesEnabled": False,
                    "appliedWrites": 0,
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
            self.assertIn("Authoritative passenger ledger digest/epoch: `13579bdf` / 3", markdown)
            self.assertIn("Authoritative passenger lines/vehicles/aboard/waiting: 1 / 1 / 11 / 12", markdown)
            self.assertIn("Native cosmetic aboard/waiting; target writes/applied: 1 / 2; no / 0", markdown)
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
            self.assertIn(
                "Physical consensus completed/rejected/faulted/session fault: 1 / 0 / 0 / unknown",
                markdown,
            )
            self.assertIn("Checkpoint barriers completed/faulted/last agreed: 2 / 0", markdown)
            output = root / "report.md"
            write_report(bridge.root, "research-session", output)
            self.assertIn("abc123", output.read_text(encoding="utf-8"))


class RestorePointTests(unittest.TestCase):
    SESSION = "restore-test"

    def _audit(self, root: Path, entries: list[dict]) -> Path:
        path = root / "audit.ndjson"
        with path.open("w", encoding="utf-8") as handle:
            for entry in entries:
                handle.write(json.dumps(sign(entry)) + "\n")
        return path

    def _checkpoint(self, seq: int, boundary: int, core: str = "core-1") -> dict:
        return {
            "protocol": 1, "session": self.SESSION, "peer": "player1",
            "seq": seq, "kind": "control", "tick": seq,
            "payload": {"action": {
                "type": "network.checkpoint_outcome", "boundarySeq": boundary,
                "success": True, "convergenceKey": f"key-{boundary}", "coreDigest": core,
            }},
        }

    def _receipt(self, seq: int, peer: str, boundary: int, sha: str, core: str = "core-1") -> dict:
        return {
            "protocol": 1, "session": self.SESSION, "peer": peer,
            "origin_peer": peer, "seq": seq, "kind": "commit", "tick": seq,
            "payload": {"action": {
                "type": "recovery.save_receipt", "boundarySeq": boundary,
                "savedAtUnix": 1000 + seq, "saveSha256": sha,
                "coreDigest": core, "convergenceKey": f"key-{boundary}", "paused": True,
            }},
        }

    def _commit(self, seq: int, peer: str = "player2") -> dict:
        return {
            "protocol": 1, "session": self.SESSION, "peer": peer, "origin_peer": peer,
            "seq": seq, "kind": "commit", "tick": seq,
            "payload": {"action": {"type": "world.freeze", "freeze": True}},
        }

    def test_restore_point_requires_every_peer_to_have_saved(self) -> None:
        sha_a = "a" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audit = self._audit(root, [
                self._checkpoint(1, 4),
                self._receipt(2, "player1", 4, sha_a),
            ])
            analysis = analyse_restore_points(audit, self.SESSION, ("player1", "player2"))
            point = analysis["points"][0]
            self.assertFalse(point["ready"])
            self.assertIn("missing save receipts: player2", point["reasons"])
            self.assertIsNone(analysis["latestReady"])
            with self.assertRaisesRegex(ProtocolError, "no restore point is ready"):
                build_restore_plan(audit, self.SESSION, required_peers=("player1", "player2"))

    def test_a_save_taken_after_later_commits_is_refused(self) -> None:
        # The save would contain work past the boundary, so resuming from it
        # would silently start the peers from different worlds.
        sha_a, sha_b = "a" * 64, "b" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audit = self._audit(root, [
                self._checkpoint(1, 4),
                self._receipt(2, "player1", 4, sha_a),
                self._commit(3),
                self._receipt(4, "player2", 4, sha_b),
            ])
            point = analyse_restore_points(audit, self.SESSION, ("player1", "player2"))["points"][0]
            self.assertFalse(point["ready"])
            self.assertTrue(
                any("saved after 1 ordered commit" in reason for reason in point["reasons"]),
                point["reasons"],
            )

    def test_peers_attesting_different_state_is_refused(self) -> None:
        sha_a, sha_b = "a" * 64, "b" * 64
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            audit = self._audit(root, [
                self._checkpoint(1, 4),
                self._receipt(2, "player1", 4, sha_a, core="core-1"),
                self._receipt(3, "player2", 4, sha_b, core="core-DIFFERENT"),
            ])
            point = analyse_restore_points(audit, self.SESSION, ("player1", "player2"))["points"][0]
            self.assertFalse(point["ready"])
            self.assertIn(
                "peers attested different world state for this boundary", point["reasons"]
            )

    def test_conflicting_duplicate_receipt_and_pre_outcome_receipt_are_refused(self) -> None:
        sha_a, sha_b, sha_c = "a" * 64, "b" * 64, "c" * 64
        with tempfile.TemporaryDirectory() as directory:
            audit = self._audit(Path(directory), [
                self._receipt(1, "player1", 4, sha_a),
                self._checkpoint(2, 4),
                self._receipt(3, "player1", 4, sha_b),
                self._receipt(4, "player2", 4, sha_c),
            ])
            point = analyse_restore_points(
                audit, self.SESSION, ("player1", "player2")
            )["points"][0]
            self.assertFalse(point["ready"])
            self.assertIn(
                "player1 filed conflicting duplicate save receipts", point["reasons"]
            )
            self.assertIn(
                "player1 save receipt precedes its checkpoint outcome", point["reasons"]
            )

    def test_receipt_must_match_checkpoint_convergence_key(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            first = self._receipt(2, "player1", 4, "a" * 64)
            second = self._receipt(3, "player2", 4, "b" * 64)
            first["payload"]["action"]["convergenceKey"] = "wrong-key"
            second["payload"]["action"]["convergenceKey"] = "wrong-key"
            audit = self._audit(Path(directory), [self._checkpoint(1, 4), first, second])
            point = analyse_restore_points(
                audit, self.SESSION, ("player1", "player2")
            )["points"][0]
            self.assertFalse(point["ready"])
            self.assertIn(
                "save receipts do not match the agreed checkpoint convergence key",
                point["reasons"],
            )

    def test_ready_restore_point_builds_a_plan_and_verifies_saves_on_disk(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            saves = root / "saves"
            saves.mkdir()
            player1 = saves / "player1.sav"
            player2 = saves / "player2.sav"
            player1.write_bytes(b"world-at-boundary-4-player1")
            player2.write_bytes(b"world-at-boundary-4-player2")
            sha1 = hashlib.sha256(player1.read_bytes()).hexdigest()
            sha2 = hashlib.sha256(player2.read_bytes()).hexdigest()

            audit = self._audit(root, [
                self._checkpoint(1, 2),
                self._commit(2),
                self._checkpoint(3, 4),
                self._receipt(4, "player1", 4, sha1),
                self._receipt(5, "player2", 4, sha2),
            ])
            analysis = analyse_restore_points(audit, self.SESSION, ("player1", "player2"))
            self.assertEqual(analysis["latestReady"]["boundarySeq"], 4)
            # Boundary 2 has no receipts and must not be offered.
            self.assertFalse(analysis["points"][0]["ready"])

            plan = build_restore_plan(audit, self.SESSION, required_peers=("player1", "player2"))
            verified = verify_restore_plan(plan)
            self.assertEqual(verified["boundarySeq"], 4)
            self.assertEqual(verified["resumeSession"], f"{self.SESSION}-r4")
            self.assertEqual(verified["peerSaves"]["player1"]["saveSha256"], sha1)
            self.assertEqual(verified["peerSaves"]["player1"]["boundarySeq"], 4)

            ready = confirm_restore_readiness(plan, {"player1": player1, "player2": player2})
            self.assertTrue(ready["ready"], ready["problems"])
            self.assertEqual(ready["resumeSession"], f"{self.SESSION}-r4")

            # An edited save must be refused rather than resumed.
            player2.write_bytes(b"tampered")
            drifted = confirm_restore_readiness(plan, {"player1": player1, "player2": player2})
            self.assertFalse(drifted["ready"])
            self.assertFalse(drifted["peers"]["player2"]["ok"])
            self.assertTrue(
                any("no longer matches" in problem for problem in drifted["problems"])
            )

            missing = confirm_restore_readiness(plan, {"player1": player1})
            self.assertFalse(missing["ready"])
            self.assertIn("player2 save was not supplied", missing["problems"])

            core = dict(plan)
            core.pop("checksum")
            core["requiredPeers"] = ["player1", "player1"]
            duplicate_roster = sign(core)
            with self.assertRaisesRegex(ProtocolError, "roster contains duplicates"):
                verify_restore_plan(duplicate_roster)

            core = dict(plan)
            core.pop("checksum")
            core["peerSaves"] = json.loads(json.dumps(core["peerSaves"]))
            core["peerSaves"]["player2"]["boundarySeq"] = 99
            mixed_boundary = sign(core)
            with self.assertRaisesRegex(ProtocolError, "names a different boundary"):
                verify_restore_plan(mixed_boundary)

    def test_game_event_copies_of_receipts_do_not_invalidate_the_ordered_receipts(self) -> None:
        first = self._receipt(2, "player1", 4, "a" * 64)
        second = self._receipt(3, "player2", 4, "b" * 64)
        event_copies = []
        for local_seq, receipt in enumerate((first, second), start=1):
            event_copies.append({
                "protocol": 1, "session": self.SESSION, "peer": receipt["origin_peer"],
                "local_seq": local_seq, "kind": "record", "record_type": "event",
                "payload": {"action": dict(receipt["payload"]["action"])},
            })
        with tempfile.TemporaryDirectory() as directory:
            audit = self._audit(Path(directory), [
                self._checkpoint(1, 4), first, event_copies[0], second, event_copies[1],
            ])
            plan = build_restore_plan(
                audit, self.SESSION, boundary_seq=4,
                required_peers=("player1", "player2"),
            )
            self.assertEqual(verify_restore_plan(plan)["boundarySeq"], 4)

    def test_save_receipt_action_is_strictly_validated(self) -> None:
        base = {
            "type": "recovery.save_receipt", "boundarySeq": 4, "savedAtUnix": 10,
            "saveSha256": "a" * 64, "coreDigest": "core-1",
            "convergenceKey": "key-4", "paused": True,
        }
        validate_action(base)
        for mutation in (
            {"paused": False},
            {"boundarySeq": 0},
            {"saveSha256": "nothex" * 10},
            {"savedAtUnix": -1},
            {"coreDigest": ""},
        ):
            broken = dict(base)
            broken.update(mutation)
            with self.assertRaises(ProtocolError):
                validate_action(broken)
        extra = dict(base)
        extra["unexpected"] = 1
        with self.assertRaises(ProtocolError):
            validate_action(extra)

    def test_town_development_is_strict_and_opens_a_checkpoint_boundary(self) -> None:
        action = {"type": "town.develop", "batch": {"town:pre:a": 8}}
        self.assertEqual(validate_action(action), action)
        for batch in (
            {}, {"city:pre:a": 1}, {"town:pre:a": 0},
            {"town:pre:a": 9}, {"town:pre:a": 1.5},
        ):
            with self.assertRaises(ProtocolError):
                validate_action({"type": "town.develop", "batch": batch})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "town-checkpoint"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            committed = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 0, "kind": "intent",
                "payload": {"action": action},
            }))
            tracker = host.checkpoint_consensus[committed["seq"]]
            self.assertEqual(tracker["reason"], "town-development")
            self.assertEqual(tracker["status"], "pending")

            restored = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            self.assertEqual(
                restored.checkpoint_consensus[committed["seq"]]["reason"],
                "town-development",
            )

    def test_freight_milestone_opens_and_restores_its_checkpoint_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "freight-milestone-checkpoint"
            audit = root / "audit.ndjson"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            action = {
                "type": "freight.milestone", "stage": "aboard",
                "lineCid": "line:event:freight-proof",
                "vehicleCid": "vehicle:event:freight-proof",
            }
            commit = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 10, "kind": "intent",
                "payload": {"action": action},
            }))
            boundary = int(commit["seq"])
            self.assertEqual(
                host.checkpoint_consensus[boundary]["reason"],
                "freight-milestone:aboard",
            )
            host._record_non_intent(consensus_checkpoint(
                session, "player1", 1, boundary, "freight-milestone:aboard"
            ))
            host._record_non_intent(consensus_checkpoint(
                session, "player2", 1, boundary, "freight-milestone:aboard"
            ))
            self.assertEqual(host.checkpoint_consensus[boundary]["status"], "complete")

            restored = CommitHost(
                GameBridge(root / "restored", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            self.assertEqual(
                restored.checkpoint_consensus[boundary]["reason"],
                "freight-milestone:aboard",
            )
            self.assertEqual(restored.checkpoint_consensus[boundary]["status"], "complete")
            self.assertEqual(replay(audit, session), 0)

    def test_restore_analysis_refuses_to_mix_sessions_implicitly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            second_session = self._checkpoint(2, 5)
            second_session["session"] = "other-session"
            audit = self._audit(root, [self._checkpoint(1, 4), second_session])
            with self.assertRaisesRegex(ProtocolError, "multiple sessions"):
                analyse_restore_points(audit)


class AnchorCoordinatorTests(unittest.TestCase):
    def _host(self, root: Path) -> CommitHost:
        bridge = GameBridge(root / "host", "anchor-test", "player1")
        return CommitHost(
            bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
        )

    def _converge(self, host: CommitHost, boundary: int) -> None:
        host.last_agreed_checkpoint = {
            "boundarySeq": boundary, "convergenceKey": f"key-{boundary}",
            "coreDigest": "core-1",
        }
        host.commits[boundary] = sign({
            "protocol": 1, "session": "anchor-test", "peer": "player1",
            "seq": boundary, "kind": "commit", "tick": 0,
            "payload": {"action": {
                "type": "network.checkpoint_outcome", "boundarySeq": boundary,
                "success": True, "convergenceKey": f"key-{boundary}", "coreDigest": "core-1",
            }},
        })
        now = time.monotonic()
        for peer in host.required_peers:
            host.clock_health[peer] = {
                "schemaVersion": 3,
                "requestedSpeed": 0,
                "effectiveSpeed": 0,
                "generation": host.clock_pause_acknowledged_generation,
                "engineTick": 100,
                "lastCommitSeq": boundary,
                "proposalPending": False,
                "localWorkPending": False,
                "deferredIntentCount": 0,
                "rendezvousGeneration": 0,
                "rendezvousState": "idle",
                "rendezvousTargetTime": 0,
                "observedSpeed": 0,
                "gameTime": 100.0,
                "receivedAt": now,
            }

    def test_anchor_refuses_while_running_or_faulted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = self._host(root)
            save = root / "world.sav"
            save.write_bytes(b"world")

            # No converged boundary and no acknowledged pause.
            state = host.anchor.readiness()
            self.assertFalse(state["ready"])
            self.assertIn("no checkpoint boundary has converged yet", state["reasons"])
            with self.assertRaisesRegex(ProtocolError, "save cannot be anchored"):
                host.anchor.anchor_save(save, 1000)

            self._converge(host, 4)
            self.assertIn(
                "the shared clock is not paused on every peer",
                host.anchor.readiness()["reasons"],
            )

            host.clock_pause_acknowledged = True
            self.assertTrue(host.anchor.readiness()["ready"])

            host.session_fault = "operation-consensus-failed"
            self.assertIn(
                "the session has already faulted; restore instead of anchoring",
                host.anchor.readiness()["reasons"],
            )

    def test_work_ordered_after_the_boundary_blocks_anchoring(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = self._host(root)
            self._converge(host, 4)
            host.clock_pause_acknowledged = True
            self.assertTrue(host.anchor.readiness()["ready"])

            host.commits[9] = sign({
                "protocol": 1, "session": "anchor-test", "peer": "player2",
                "origin_peer": "player2", "seq": 9, "kind": "commit", "tick": 0,
                "payload": {"action": {"type": "world.freeze", "freeze": True}},
            })
            self.assertIn(
                "work has been ordered since the last converged checkpoint",
                host.anchor.readiness()["reasons"],
            )

    def test_local_game_queue_or_stale_health_blocks_a_false_ready_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            host = self._host(Path(directory))
            self._converge(host, 4)
            host.clock_pause_acknowledged = True
            host.clock_health["player2"]["localWorkPending"] = True
            self.assertIn(
                "player2 still has local ordered work pending",
                host.anchor.readiness()["reasons"],
            )
            host.clock_health["player2"]["localWorkPending"] = False
            host.clock_health["player2"]["receivedAt"] = time.monotonic() - 10
            self.assertIn(
                "player2 anchor-readiness health is stale",
                host.anchor.readiness()["reasons"],
            )

    def test_anchoring_files_one_ordered_receipt_and_reports_restorability(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = self._host(root)
            self._converge(host, 4)
            host.clock_pause_acknowledged = True
            save = root / "world.sav"
            save.write_bytes(b"world-at-boundary-4")
            expected = hashlib.sha256(save.read_bytes()).hexdigest()

            result = host.anchor.anchor_save(save, 1717171717)
            self.assertTrue(result["filed"])
            self.assertEqual(result["saveSha256"], expected)
            self.assertEqual(result["boundarySeq"], 4)
            self.assertTrue(result["paused"])

            receipts = [
                message for message in host.commits.values()
                if (message.get("payload") or {}).get("action", {}).get("type")
                == "recovery.save_receipt"
            ]
            self.assertEqual(len(receipts), 1)
            self.assertEqual(receipts[0]["origin_peer"], "player1")

            # A receipt is an attestation, not work: it must not block a
            # second peer from anchoring the same boundary.
            self.assertTrue(host.anchor.readiness()["ready"])
            # Only this peer has filed, so nothing is restorable yet.
            self.assertEqual(host.anchor.restorable(), [])

            repeat = host.anchor.anchor_save(save, 1717171800)
            self.assertFalse(repeat["filed"])
            self.assertEqual(repeat["saveSha256"], expected)

            # The other peer files for the same boundary.
            host.commits[99] = sign({
                "protocol": 1, "session": "anchor-test", "peer": "player2",
                "origin_peer": "player2", "seq": 99, "kind": "commit", "tick": 0,
                "payload": {"action": {
                    "type": "recovery.save_receipt", "boundarySeq": 4,
                    "savedAtUnix": 1717171999, "saveSha256": "b" * 64,
                    "coreDigest": "core-1", "convergenceKey": "key-4", "paused": True,
                }},
            })
            self.assertEqual(host.anchor.restorable(), [4])
            status = host.anchor.status()
            self.assertEqual(status["restorePoints"], [4])
            self.assertEqual(status["anchorsFiled"], [4])

    def test_a_missing_save_is_refused_before_any_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = self._host(root)
            self._converge(host, 4)
            host.clock_pause_acknowledged = True
            with self.assertRaisesRegex(ProtocolError, "is missing or is not a .sav"):
                host.anchor.anchor_save(root / "absent.sav", 1000)
            self.assertEqual(host.anchor.restorable(), [])

    def test_receipt_claim_must_match_current_ready_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            host = self._host(Path(directory))
            self._converge(host, 4)
            host.clock_pause_acknowledged = True
            receipt = {
                "type": "recovery.save_receipt", "boundarySeq": 5,
                "savedAtUnix": 1000, "saveSha256": "a" * 64,
                "coreDigest": "core-1", "convergenceKey": "key-4", "paused": True,
            }
            with self.assertRaisesRegex(ProtocolError, "boundarySeq does not match"):
                host.anchor.validate_receipt(receipt, "player2")

    def test_one_action_pauses_and_requests_matching_checkpoints(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            host = self._host(Path(directory))
            host.clock_pause_acknowledged = True
            now = time.monotonic()
            for peer in host.required_peers:
                host.clock_health[peer] = {
                    "schemaVersion": 3, "requestedSpeed": 0, "effectiveSpeed": 0,
                    "generation": 0, "engineTick": 10, "lastCommitSeq": 1,
                    "proposalPending": False, "localWorkPending": False,
                    "deferredIntentCount": 0, "rendezvousGeneration": 0,
                    "rendezvousState": "idle", "rendezvousTargetTime": 0,
                    "observedSpeed": 0, "gameTime": 100.0, "receivedAt": now,
                }
            prepare = host._commit(sign({
                "protocol": 1, "session": "anchor-test", "peer": "player1",
                "local_seq": 1, "tick": 0, "kind": "intent",
                "payload": {"action": {"type": "recovery.prepare"}},
            }))
            self.assertEqual(prepare["seq"], 1)
            self.assertTrue(host.anchor_preparation.maintain())
            self.assertTrue(host.anchor_preparation.maintain())
            self.assertEqual(host.anchor_preparation.status()["anchorPreparationStatus"], "checkpointing")
            request = decode_line((host.bridge.inbox / "000000000002.json").read_bytes())
            self.assertEqual(request["payload"]["action"]["type"], "network.checkpoint_request")
            self.assertEqual(request["payload"]["action"]["preparationSeq"], 1)

            reason = "recovery-prepare:1"
            host._record_non_intent(consensus_checkpoint("anchor-test", "player1", 2, 2, reason))
            host._record_non_intent(consensus_checkpoint("anchor-test", "player2", 3, 2, reason))
            self.assertEqual(host.last_agreed_checkpoint["boundarySeq"], 2)
            self.assertEqual(host.anchor_preparation.status()["anchorPreparationStatus"], "converged")
            restored = self._host(Path(directory))
            self.assertEqual(restored.last_agreed_checkpoint["boundarySeq"], 2)
            self.assertEqual(
                restored.anchor_preparation.status()["anchorPreparationStatus"], "converged"
            )
            for sample in host.clock_health.values():
                sample["lastCommitSeq"] = 3
                sample["receivedAt"] = time.monotonic()
            self.assertTrue(host.anchor_preparation.maintain())
            self.assertTrue(host.anchor.readiness()["ready"])
            self.assertEqual(host.anchor_preparation.status()["anchorPreparationStatus"], "ready")

    def test_matching_manual_exports_open_a_paused_tip_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            host = self._host(Path(directory))
            host.next_seq = 5
            host.clock_pause_acknowledged = True
            host._record_non_intent(
                consensus_checkpoint("anchor-test", "player1", 1, 4, "manual-ui")
            )
            self.assertEqual(host.checkpoint_consensus[4]["status"], "pending")
            host._record_non_intent(
                consensus_checkpoint("anchor-test", "player2", 2, 4, "manual-ui")
            )
            self.assertEqual(host.checkpoint_consensus[4]["status"], "complete")
            self.assertEqual(host.last_agreed_checkpoint["boundarySeq"], 4)


class AnchorRequestStoreTests(unittest.TestCase):
    def test_client_receipt_uses_persistent_negative_sequence_and_acknowledges(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "client", "anchor-io", "player2")
            store = AnchorRequestStore(bridge)
            save = root / "world.sav"
            save.write_bytes(b"world-at-boundary")
            request_id = "a" * 32
            request = {
                "schemaVersion": 1, "session": "anchor-io", "peer": "player2",
                "requestId": request_id, "boundarySeq": 9,
                "coreDigest": "core-9", "convergenceKey": "key-9",
                "savePath": str(save), "savedAtUnix": 1717171717,
            }
            atomic_write(
                store.requests / f"{request_id}.json",
                (json.dumps(request) + "\n").encode("utf-8"),
            )
            state = validate_anchor_state(anchor_state_message(
                "anchor-io", "player1", {
                    "ready": True, "boundarySeq": 9, "coreDigest": "core-9",
                    "convergenceKey": "key-9", "reasons": [],
                },
            ))
            first = list(store.client_intents(state))
            second = list(store.client_intents(state))
            self.assertEqual(len(first), 1)
            self.assertEqual(first, second)
            self.assertLess(first[0]["local_seq"], 0)
            self.assertEqual(
                first[0]["payload"]["action"]["saveSha256"],
                hashlib.sha256(save.read_bytes()).hexdigest(),
            )
            self.assertTrue(store.record_receipt(first[0]["local_seq"], True, None))
            self.assertEqual(list(store.client_intents(state)), [])
            self.assertEqual(store.status()["localAnchorsFiled"], [9])

    def test_client_refuses_request_for_another_boundary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "client", "anchor-io", "player2")
            store = AnchorRequestStore(bridge)
            save = root / "world.sav"
            save.write_bytes(b"world")
            request = {
                "schemaVersion": 1, "session": "anchor-io", "peer": "player2",
                "requestId": "b" * 32, "boundarySeq": 8,
                "coreDigest": "core-8", "convergenceKey": "key-8",
                "savePath": str(save), "savedAtUnix": 1,
            }
            atomic_write(
                store.requests / ("b" * 32 + ".json"),
                (json.dumps(request) + "\n").encode("utf-8"),
            )
            state = {
                "ready": True, "boundarySeq": 9, "coreDigest": "core-9",
                "convergenceKey": "key-9", "reasons": [],
            }
            self.assertEqual(list(store.client_intents(state)), [])


class HostLocalSequenceTests(unittest.TestCase):
    @staticmethod
    def _intent(session: str, local_seq: int, action: dict) -> dict:
        return sign({
            "protocol": 1,
            "session": session,
            "peer": "player1",
            "local_seq": local_seq,
            "tick": 0,
            "kind": "intent",
            "payload": {"action": action},
        })

    @staticmethod
    def _host_action(freeze: bool) -> dict:
        return {"type": "world.freeze", "freeze": freeze}

    def test_host_intents_use_a_restart_stable_negative_sequence_namespace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "host", "host-sequence-test", "player1")
            audit = root / "audit.ndjson"
            host = CommitHost(
                bridge, "127.0.0.1", 0, audit, require_connected_peers=False
            )
            game = host._commit(self._intent(
                "host-sequence-test", 1_000_000_000,
                {"type": "world.freeze", "freeze": True},
            ))
            synthetic = host.emit_local_intent(self._host_action(False))
            self.assertEqual(game["origin_local_seq"], 1_000_000_000)
            self.assertLess(synthetic["origin_local_seq"], 0)
            self.assertNotEqual(game["origin_local_seq"], synthetic["origin_local_seq"])

            restored = CommitHost(
                GameBridge(root / "host", "host-sequence-test", "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            next_synthetic = restored.emit_local_intent(self._host_action(True))
            self.assertLess(
                next_synthetic["origin_local_seq"], synthetic["origin_local_seq"]
            )
            self.assertTrue(next_synthetic["payload"]["action"]["freeze"])


class IndustryContentConsensusTests(unittest.TestCase):
    @staticmethod
    def _intent(session: str, peer: str, local_seq: int, digest: str) -> dict:
        return sign({
            "protocol": 1, "session": session, "peer": peer,
            "local_seq": local_seq, "tick": 0, "kind": "intent",
            "payload": {"action": {
                "type": "content.industry_attest", "peer": peer,
                "digest": digest, "resourceCount": 16,
                "variantCount": 160, "ambiguousCount": 0,
            }},
        })

    def test_matching_content_converges_and_survives_audit_reload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, session = Path(directory), "industry-content-match"
            audit = root / "audit.ndjson"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            host._commit(self._intent(session, "player1", 1, "edc7a517"))
            host._commit(self._intent(session, "player2", 1, "edc7a517"))
            self.assertTrue(host.industry_content_consensus.result["ready"])
            self.assertEqual(host.industry_content_consensus.result["digest"], "edc7a517")
            self.assertIsNone(host.session_fault)
            restored = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            self.assertTrue(restored.industry_content_consensus.result["ready"])
            self.assertEqual(
                sorted(restored.industry_content_consensus.attestations),
                ["player1", "player2"],
            )

    def test_mismatched_content_faults_after_ordering_both_claims(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root, session = Path(directory), "industry-content-mismatch"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            host._commit(self._intent(session, "player1", 1, "edc7a517"))
            mismatch = host._commit(self._intent(session, "player2", 1, "11111111"))
            self.assertEqual(mismatch["seq"], 2)
            self.assertEqual(host.session_fault, "industry-content-mismatch")
            self.assertFalse(host.industry_content_consensus.result["ready"])


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

    def test_receipt_bound_restore_archive_matches_its_peer_save_attestation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            save = root / "player1.sav"
            save.write_bytes(b"player1-boundary-9")
            Path(str(save) + ".lua").write_text("return {}", encoding="utf-8")
            sha = hashlib.sha256(save.read_bytes()).hexdigest()
            peer_save = {
                "saveSha256": sha, "savedAtUnix": 1000, "receiptCommitSeq": 10,
                "boundarySeq": 9, "coreDigest": "core-9", "convergenceKey": "key-9",
            }
            plan = sign({
                "format": "tpf2mp-restore-plan", "version": 2, "protocol": 1,
                "session": "archive-test", "resumeSession": "archive-test-r9",
                "generatedAtUtc": "2026-08-06T00:00:00+00:00", "boundarySeq": 9,
                "convergenceKey": "key-9", "coreDigest": "core-9",
                "requiredPeers": ["player1", "player2"],
                "peerSaves": {
                    "player1": peer_save,
                    "player2": {**peer_save, "saveSha256": "b" * 64, "receiptCommitSeq": 11},
                },
                "steps": ["restore both peers"],
            })
            output = root / "receipt-bound"
            manifest = write_recovery_archive(
                save, output, "archive-test", "player1", plan
            )
            verified = verify_recovery_archive(manifest, output)
            self.assertEqual(
                verified["association"], "coordinated-receipt-bound-restore-save"
            )
            self.assertEqual(verified["restoreAttestation"]["saveSha256"], sha)
            self.assertEqual(verified["checkpointAnchor"]["boundarySeq"], 9)

            other = root / "other.sav"
            other.write_bytes(b"wrong-save")
            Path(str(other) + ".lua").write_text("return {}", encoding="utf-8")
            refused = root / "refused"
            with self.assertRaisesRegex(ProtocolError, "does not match"):
                write_recovery_archive(
                    other, refused, "archive-test", "player1", plan
                )
            self.assertFalse(refused.exists())


class NetworkIntegrationTests(unittest.TestCase):
    @staticmethod
    def _settlement_intent(session: str, local_seq: int) -> dict:
        return sign({
            "protocol": 1, "session": session, "peer": "player1",
            "local_seq": local_seq, "tick": local_seq, "kind": "intent",
            "payload": {"action": {
                "type": "economy.settle", "results": {},
                "deliverySnapshot": {
                    "schemaVersion": 2, "presentationEpoch": 0,
                    "passengerLines": {}, "cargoLines": {},
                },
            }},
        })

    def test_economy_settlement_requires_and_restores_checkpoint_consensus(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "settlement-checkpoint"
            audit = root / "audit.ndjson"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            commit = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 0, "kind": "intent",
                "payload": {"action": {
                    "type": "economy.settle", "results": {},
                    "deliverySnapshot": {
                        "schemaVersion": 2, "presentationEpoch": 0,
                        "passengerLines": {}, "cargoLines": {},
                    },
                }},
            }))
            boundary = int(commit["seq"])
            self.assertEqual(
                host.checkpoint_consensus[boundary]["reason"], "economy-settlement"
            )
            host._record_non_intent(consensus_checkpoint(
                session, "player1", 2, boundary, "economy-settlement"
            ))
            host._record_non_intent(consensus_checkpoint(
                session, "player2", 3, boundary, "economy-settlement"
            ))
            self.assertEqual(host.checkpoint_consensus[boundary]["status"], "complete")
            restored = CommitHost(
                GameBridge(root / "restored", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            self.assertEqual(
                restored.checkpoint_consensus[boundary]["reason"], "economy-settlement"
            )
            self.assertEqual(restored.checkpoint_consensus[boundary]["status"], "complete")

    def test_settlement_barrier_survives_restart_and_repeated_pressure(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "settlement-restart-stress"
            audit = root / "audit.ndjson"
            host = CommitHost(
                GameBridge(root / "host-before-restart", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            first = host._commit(self._settlement_intent(session, 1))
            first_boundary = int(first["seq"])
            host._record_non_intent(consensus_checkpoint(
                session, "player1", 1, first_boundary, "economy-settlement"
            ))
            self.assertEqual(
                set(host.checkpoint_consensus[first_boundary]["checkpoints"]),
                {"player1"},
            )

            # Reconstruct in the exact interrupted state. The first peer's
            # evidence must survive and physical work must not overtake it.
            host = CommitHost(
                GameBridge(root / "host-after-restart", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            pending = host._pending_checkpoint()
            self.assertIsNotNone(pending)
            self.assertEqual(pending["boundarySeq"], first_boundary)
            self.assertEqual(set(pending["checkpoints"]), {"player1"})
            blocked_actions = (
                self._settlement_intent(session, 1001),
                sign({
                    "protocol": 1, "session": session, "peer": "player1",
                    "local_seq": 1002, "tick": 0, "kind": "intent",
                    "payload": {"action": {
                        "type": "proposal.prepare",
                        "transaction": proposal_transaction("company:1"),
                    }},
                }),
                sign({
                    "protocol": 1, "session": session, "peer": "player1",
                    "local_seq": 1003, "tick": 0, "kind": "intent",
                    "payload": {"action": {
                        "type": "operation.execute",
                        "transaction": operation_transaction("company:1"),
                    }},
                }),
            )
            for blocked in blocked_actions:
                with self.assertRaisesRegex(
                    ProtocolError, f"checkpoint boundary {first_boundary}"
                ):
                    host._commit(blocked)

            host._write_status("running")
            status = json.loads(host.bridge.status_path.read_text(encoding="utf-8"))
            self.assertEqual(status["pendingCheckpointSeq"], first_boundary)
            self.assertEqual(status["pendingCheckpointReason"], "economy-settlement")
            self.assertEqual(
                status["checkpointCounts"],
                {"pending": 1, "complete": 0, "faulted": 0},
            )

            host._record_non_intent(consensus_checkpoint(
                session, "player2", 2, first_boundary, "economy-settlement"
            ))
            last_boundary = first_boundary
            # Thirty-two total settlements is long enough to exercise repeated
            # commit/outcome alternation without turning this into a slow soak.
            for iteration in range(2, 33):
                commit = host._commit(self._settlement_intent(session, iteration))
                last_boundary = int(commit["seq"])
                self.assertIsNone(host.session_fault)
                self.assertEqual(host._pending_checkpoint()["boundarySeq"], last_boundary)
                host._record_non_intent(consensus_checkpoint(
                    session, "player1", iteration * 2 + 1,
                    last_boundary, "economy-settlement",
                ))
                host._record_non_intent(consensus_checkpoint(
                    session, "player2", iteration * 2 + 2,
                    last_boundary, "economy-settlement",
                ))
                self.assertEqual(
                    host.checkpoint_consensus[last_boundary]["status"], "complete"
                )

            self.assertIsNone(host._pending_checkpoint())
            self.assertEqual(len(host.checkpoint_consensus), 32)
            self.assertEqual(host.last_agreed_checkpoint["boundarySeq"], last_boundary)
            self.assertEqual(host.next_seq, 65)
            host._write_status()
            status = json.loads(host.bridge.status_path.read_text(encoding="utf-8"))
            self.assertIsNone(status["pendingCheckpointSeq"])
            self.assertEqual(status["lastAgreedCheckpointSeq"], last_boundary)
            self.assertEqual(status["lastAgreedCheckpointReason"], "economy-settlement")
            self.assertEqual(
                status["checkpointCounts"],
                {"pending": 0, "complete": 32, "faulted": 0},
            )

            restored = CommitHost(
                GameBridge(root / "host-final", session, "player1"),
                "127.0.0.1", 0, audit, require_connected_peers=False,
            )
            self.assertIsNone(restored._pending_checkpoint())
            self.assertEqual(len(restored.checkpoint_consensus), 32)
            self.assertTrue(all(
                tracker["status"] == "complete"
                for tracker in restored.checkpoint_consensus.values()
            ))
            self.assertEqual(
                restored.last_agreed_checkpoint["boundarySeq"], last_boundary
            )
            self.assertEqual(replay(audit, session), 0)

    def test_checkpoint_opening_actions_require_connected_roster(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "checkpoint-roster-gate"
            audit = root / "audit.ndjson"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, audit,
            )
            actions = (
                self._settlement_intent(session, 1),
                sign({
                    "protocol": 1, "session": session, "peer": "player1",
                    "local_seq": 2, "tick": 0, "kind": "intent",
                    "payload": {"action": {"type": "probe.structural"}},
                }),
                sign({
                    "protocol": 1, "session": session, "peer": "player1",
                    "local_seq": 3, "tick": 0, "kind": "intent",
                    "payload": {"action": {
                        "type": "freight.milestone", "stage": "aboard",
                        "lineCid": "line:event:proof",
                        "vehicleCid": "vehicle:event:proof",
                    }},
                }),
            )
            for intent in actions:
                with self.assertRaisesRegex(
                    ProtocolError, "consensus-bound action.*player2"
                ):
                    host._commit(intent)
            self.assertEqual(host.next_seq, 1)
            self.assertEqual(list(host.audit.messages()), [])
            self.assertIsNone(host._pending_checkpoint())

    def test_receipt_bound_restore_blocks_gameplay_until_fresh_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session, source, boundary = "restore-source-r9", "restore-source", 9
            probe = consensus_checkpoint(session, "player1", 1, 1, "probe")
            core = probe["payload"]["coreDigest"]
            save = {
                "saveSha256": "a" * 64, "savedAtUnix": 100,
                "receiptCommitSeq": 10, "boundarySeq": boundary,
                "coreDigest": core, "convergenceKey": "1234abcd",
            }
            plan = sign({
                "format": "tpf2mp-restore-plan", "version": 2, "protocol": 1,
                "session": source, "resumeSession": session,
                "generatedAtUtc": "2026-08-06T00:00:00+00:00",
                "boundarySeq": boundary, "convergenceKey": "1234abcd",
                "coreDigest": core, "requiredPeers": ["player1", "player2"],
                "peerSaves": {
                    "player1": save,
                    "player2": {**save, "saveSha256": "b" * 64, "receiptCommitSeq": 11},
                },
                "steps": ["load each attested save"],
            })
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False, restore_plan=plan,
            )
            with self.assertRaisesRegex(ProtocolError, "restore handshake"):
                host._commit(sign({
                    "protocol": 1, "session": session, "peer": "player1",
                    "local_seq": 1, "tick": 0, "kind": "intent",
                    "payload": {"action": {"type": "world.freeze", "freeze": True}},
                }))
            commit = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 2, "tick": 0, "kind": "intent",
                "payload": {"action": host.restore_session.expected_action()},
            }))
            self.assertEqual(commit["seq"], 1)
            reason = f"restore-resume:{plan['checksum']}"
            host._record_non_intent(consensus_checkpoint(session, "player1", 3, 1, reason))
            host._record_non_intent(consensus_checkpoint(session, "player2", 4, 1, reason))
            self.assertEqual(host.restore_session.state, "complete")
            self.assertEqual(host.last_agreed_checkpoint["boundarySeq"], 1)

    def test_generic_ordered_action_rejection_faults_instead_of_hanging_checkpoint(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "authored-rejection"
            host = CommitHost(
                GameBridge(root / "host", session, "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            commit = host._commit(sign({
                "protocol": 1, "session": session, "peer": "player1",
                "local_seq": 1, "tick": 0, "kind": "intent",
                "payload": {"action": {"type": "world.freeze", "freeze": True}},
            }))
            host._record_non_intent(proposal_prepare_ack(
                "player2", 2, int(commit["seq"]), success=False,
                error="native projection failed",
            ))

            self.assertIn("ordered-action-rejected:1:player2", host.session_fault)
            fault = host.commits[2]["payload"]["action"]
            self.assertEqual(fault["type"], "network.sync_fault")
            self.assertEqual(fault["scope"], "authored")

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

    def test_clock_skew_ignores_samples_from_adjacent_authority_generations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "clock-generation-window", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 1
            host.clock_generation = 8
            host.clock_last_adjustment = sampled_at - 10.0
            host.clock_health = {
                "player1": {
                    "receivedAt": sampled_at, "engineTick": 19815,
                    "lastCommitSeq": 14, "gameTime": 3124.8,
                    "observedSpeed": 1, "effectiveSpeed": 1,
                    "generation": 8, "tickRate": 60.0, "gameRate": 12.0,
                },
                "player2": {
                    "receivedAt": sampled_at - 0.05, "engineTick": 21376,
                    "lastCommitSeq": 13, "gameTime": 3122.2,
                    "observedSpeed": 0, "effectiveSpeed": 0,
                    "generation": 7, "tickRate": 60.0, "gameRate": 0.0,
                },
            }

            host._maybe_adjust_clock_locked(sampled_at)

            self.assertIsNone(host.clock_game_time_skew)
            self.assertFalse(host.clock_skew_samples_comparable)
            self.assertGreater(host.clock_projected_game_time_skew, 2.0)
            self.assertEqual(host.commits, {},
                "a half-applied clock generation caused a false resync")

            host.clock_health["player2"].update({
                "receivedAt": sampled_at,
                "lastCommitSeq": 14,
                "gameTime": 3124.8,
                "observedSpeed": 1,
                "effectiveSpeed": 1,
                "generation": 8,
                "gameRate": 12.0,
            })
            host._maybe_adjust_clock_locked(sampled_at)
            self.assertAlmostEqual(host.clock_game_time_skew, 0.0, places=6)
            self.assertTrue(host.clock_skew_samples_comparable)
            self.assertEqual(host.commits, {})

    def test_recovered_clock_ack_timeout_is_not_left_as_current_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "recovered-clock-warning", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 1
            host.clock_healthy_since = sampled_at - 20.0
            host.clock_last_adjustment = sampled_at - 20.0
            host.clock_health = {
                peer: {
                    "receivedAt": sampled_at, "engineTick": 100,
                    "lastCommitSeq": 0, "gameTime": 100.0,
                    "observedSpeed": 1, "tickRate": 60.0, "gameRate": 12.0,
                }
                for peer in ("player1", "player2")
            }
            host.last_error = "clock-ack-timeout:player2"
            host._maybe_adjust_clock_locked(sampled_at)
            self.assertIsNone(host.last_error)

            host.last_error = "vehicle-sync-timeout:vehicle:1"
            host._maybe_adjust_clock_locked(sampled_at)
            self.assertEqual(host.last_error, "vehicle-sync-timeout:vehicle:1")

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

    def test_unilateral_native_pause_is_fenced_immediately_then_waits_for_resume(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "native-pause-fence", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            sampled_at = time.monotonic()
            host.clock_requested_speed = host.clock_effective_speed = 4
            host.clock_generation = 8
            host.clock_last_adjustment = sampled_at
            host.clock_health = {
                "player1": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "requestedSpeed": 4, "effectiveSpeed": 4, "generation": 8,
                    "gameTime": 101.0, "observedSpeed": 4,
                    "tickRate": 60.0, "gameRate": 96.0,
                },
                "player2": {
                    "receivedAt": sampled_at, "engineTick": 100, "lastCommitSeq": 0,
                    "requestedSpeed": 4, "effectiveSpeed": 4, "generation": 8,
                    "gameTime": 99.0, "observedSpeed": 0,
                    "tickRate": 60.0, "gameRate": 0.0,
                },
            }
            host._maybe_adjust_clock_locked(sampled_at)
            fence = host.commits[1]["payload"]["action"]
            self.assertEqual(fence["type"], "clock.set")
            self.assertEqual(fence["requestedSpeed"], 4)
            self.assertEqual(fence["effectiveSpeed"], 0)
            self.assertEqual(fence["generation"], 9)
            self.assertEqual(fence["reason"], "native-peer-pause-fence:player2")
            self.assertEqual(
                host.synchronization.status()["clock"]["pauseFence"]["status"],
                "fence-ordered",
            )
            host._maybe_adjust_clock_locked(sampled_at + 20.0)
            self.assertEqual(len(host.commits), 1,
                "native pause fence waited for the generic adaptive delay")

            host._record_non_intent(proposal_prepare_ack("player1", 1, 1))
            host._record_non_intent(proposal_prepare_ack("player2", 2, 1))
            resumed_at = time.monotonic()
            host.clock_health = {
                "player1": {
                    "receivedAt": resumed_at, "engineTick": 110, "lastCommitSeq": 1,
                    "requestedSpeed": 4, "effectiveSpeed": 0, "generation": 9,
                    "gameTime": 101.0, "observedSpeed": 0,
                    "tickRate": 60.0, "gameRate": 0.0,
                },
                "player2": {
                    "receivedAt": resumed_at, "engineTick": 110, "lastCommitSeq": 1,
                    "requestedSpeed": 4, "effectiveSpeed": 0, "generation": 9,
                    "gameTime": 99.0, "observedSpeed": 0,
                    "tickRate": 60.0, "gameRate": 0.0,
                },
            }
            host._maybe_adjust_clock_locked(resumed_at)
            self.assertEqual(len(host.commits), 1,
                "the host resumed while the native modal pause was still open")

            host.clock_health["player2"]["observedSpeed"] = 4
            host.clock_health["player2"]["gameRate"] = 96.0
            host._maybe_adjust_clock_locked(resumed_at)
            catch_up = host.commits[2]["payload"]["action"]
            self.assertEqual(catch_up["type"], "clock.rendezvous")
            self.assertEqual(catch_up["approachSpeed"], 1)
            self.assertEqual(catch_up["releaseSpeed"], 4)
            self.assertEqual(catch_up["targetGameTime"], 101.0)
            self.assertIn(":resume-observed", catch_up["reason"])
            self.assertEqual(
                host.synchronization.status()["clock"]["lastPauseFence"]["status"],
                "catch-up-ordered",
            )

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
            host.vehicle_sync_slot_reservations[
                "line:event:station-sync:1#0"
            ] = {
                "lineCid": "line:event:station-sync:1",
                "stopIndex": 0,
                "periodSeconds": 778,
                "phaseSeconds": 223,
                "slotIndex": 1,
                "scheduledDepartureAt": 1001.0,
            }
            host._record_non_intent(vehicle_sync_record("player1", 1, "held", game_time=100.0))
            self.assertEqual(host.commits, {})
            host._record_non_intent(vehicle_sync_record("player2", 2, "held", game_time=101.0))
            release = host.commits[1]["payload"]["action"]
            self.assertEqual(release["type"], "vehicle.sync_release")
            self.assertGreater(release["releaseAtGameTime"], 101.0)
            self.assertLessEqual(
                release["releaseAtGameTime"] - 101.0, 24.0,
                "an unscheduled line exceeded its two-second network safety guard",
            )
            self.assertEqual(
                release["schedule"], {"schemaVersion": 1, "enabled": False}
            )
            self.assertEqual(
                host.vehicle_sync_slot_reservations, {},
                "prompt release retained a historical timetable reservation",
            )
            self.assertEqual(
                host.synchronization.status()["vehicleSync"]["pendingByStatus"],
                {"release-ordered": 1},
            )
            host._record_non_intent(vehicle_sync_record("player1", 3, "held", game_time=102.0))
            self.assertEqual(len(host.commits), 1, "held retry emitted a second release")
            host._record_non_intent(proposal_prepare_ack("player1", 4, 1))
            host._record_non_intent(proposal_prepare_ack("player2", 5, 1))
            host._record_non_intent(vehicle_sync_record("player1", 6, "released", game_time=120.0))
            host._record_non_intent(vehicle_sync_record("player2", 7, "released", game_time=120.2))
            self.assertEqual(host.vehicle_sync_rounds, {}, "completed round was not pruned")
            self.assertEqual(host.vehicle_sync_releases, 1)
            self.assertEqual(host.vehicle_sync_pruned_rounds, 1)
            self.assertEqual(host.vehicle_sync_scheduled_releases, 0)
            self.assertEqual(host.vehicle_sync_unscheduled_releases, 1)
            host._record_non_intent(vehicle_sync_record("player1", 8, "released", game_time=121.0))
            self.assertEqual(host.vehicle_sync_releases, 1, "release retry counted twice")

    def test_acknowledged_shared_pause_suspends_vehicle_round_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [1_000.0]
            monotonic = lambda: now[0]
            with mock.patch(
                "tpf2mp.synchronization.time.monotonic", side_effect=monotonic
            ), mock.patch(
                "tpf2mp.vehicle_barrier.time.monotonic", side_effect=monotonic
            ):
                host = CommitHost(
                    GameBridge(root / "host", "long-shared-pause", "player1"),
                    "127.0.0.1", 0, root / "audit.ndjson",
                    require_connected_peers=False,
                )
                host.clock_requested_speed = host.clock_effective_speed = 1
                host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
                tracker = next(iter(host.vehicle_sync_rounds.values()))
                self.assertEqual(tracker["deadline"], 1_180.0)

                now[0] = 1_001.0
                pause = host._emit_clock_commit_locked(1, 0, "long-user-pause")
                self.assertFalse(host.clock_pause_acknowledged)
                host._record_non_intent(proposal_prepare_ack("player1", 2, pause["seq"]))
                host._record_non_intent(proposal_prepare_ack("player2", 1, pause["seq"]))
                self.assertTrue(host.clock_pause_acknowledged)
                self.assertEqual(host.clock_pause_acknowledged_generation, 1)
                self.assertEqual(
                    host.synchronization.status()["vehicleSync"]["timeoutPausedRounds"], 1
                )

                now[0] = 1_401.0
                host.synchronization.expire(now[0])
                self.assertIsNone(host.session_fault, "shared pause consumed active timeout budget")

                resume = host._emit_clock_commit_locked(1, 1, "long-user-pause-ended")
                now[0] = 1_451.0
                host.synchronization.expire(now[0])
                self.assertTrue(
                    host.clock_pause_acknowledged,
                    "pending resume incorrectly restarted the vehicle timeout",
                )
                host._record_non_intent(proposal_prepare_ack("player1", 3, resume["seq"]))
                host._record_non_intent(proposal_prepare_ack("player2", 2, resume["seq"]))
                self.assertFalse(host.clock_pause_acknowledged)
                self.assertEqual(host.clock_pause_acknowledged_generation, 2)
                self.assertEqual(tracker["deadline"], 1_630.0)

                host.synchronization.vehicle.expire(1_629.999)
                self.assertIsNone(host.session_fault)
                host.synchronization.vehicle.expire(1_630.0)
                self.assertEqual(
                    host.session_fault,
                    "vehicle-sync-timeout:vehicle:event:station-sync:1:1",
                )

    def test_stale_clock_ack_cannot_regress_acknowledged_pause_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "pause-generation-order", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            first_pause = host._emit_clock_commit_locked(1, 0, "initial-pause")
            host._record_non_intent(proposal_prepare_ack("player1", 1, first_pause["seq"]))
            host._record_non_intent(proposal_prepare_ack("player2", 1, first_pause["seq"]))
            stale_resume = host._emit_clock_commit_locked(1, 1, "stale-resume")
            newer_pause = host._emit_clock_commit_locked(1, 0, "newer-pause")
            host._record_non_intent(proposal_prepare_ack("player1", 2, newer_pause["seq"]))
            host._record_non_intent(proposal_prepare_ack("player2", 2, newer_pause["seq"]))
            host._record_non_intent(proposal_prepare_ack("player1", 3, stale_resume["seq"]))
            host._record_non_intent(proposal_prepare_ack("player2", 3, stale_resume["seq"]))

            self.assertTrue(host.clock_pause_acknowledged)
            self.assertEqual(host.clock_pause_acknowledged_generation, 3)

    def test_vehicle_round_latency_excludes_acknowledged_pause_duration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [3_000.0]
            monotonic = lambda: now[0]
            with mock.patch(
                "tpf2mp.synchronization.time.monotonic", side_effect=monotonic
            ), mock.patch(
                "tpf2mp.vehicle_barrier.time.monotonic", side_effect=monotonic
            ):
                host = CommitHost(
                    GameBridge(root / "host", "pause-adjusted-latency", "player1"),
                    "127.0.0.1", 0, root / "audit.ndjson",
                    require_connected_peers=False,
                )
                host.clock_requested_speed = host.clock_effective_speed = 1
                host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
                host._record_non_intent(vehicle_sync_record("player2", 1, "held"))

                now[0] = 3_001.0
                pause = host._emit_clock_commit_locked(1, 0, "latency-pause")
                host._record_non_intent(proposal_prepare_ack("player1", 2, pause["seq"]))
                host._record_non_intent(proposal_prepare_ack("player2", 2, pause["seq"]))
                now[0] = 3_401.0
                resume = host._emit_clock_commit_locked(1, 1, "latency-resume")
                host._record_non_intent(proposal_prepare_ack("player1", 3, resume["seq"]))
                host._record_non_intent(proposal_prepare_ack("player2", 3, resume["seq"]))

                now[0] = 3_404.0
                host._record_non_intent(vehicle_sync_record("player1", 4, "released"))
                host._record_non_intent(vehicle_sync_record("player2", 4, "released"))
                telemetry = host.synchronization.status()["vehicleSync"]
                self.assertEqual(telemetry["averageRoundLatencyMs"], 4_000.0)
                self.assertEqual(telemetry["maxRoundLatencyMs"], 4_000.0)
                self.assertEqual(telemetry["timeoutPausedRounds"], 0)

    def test_unacknowledged_pause_does_not_suspend_vehicle_round_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [2_000.0]
            monotonic = lambda: now[0]
            with mock.patch(
                "tpf2mp.synchronization.time.monotonic", side_effect=monotonic
            ), mock.patch(
                "tpf2mp.vehicle_barrier.time.monotonic", side_effect=monotonic
            ):
                host = CommitHost(
                    GameBridge(root / "host", "unacknowledged-pause", "player1"),
                    "127.0.0.1", 0, root / "audit.ndjson",
                    require_connected_peers=False,
                )
                host.clock_requested_speed = host.clock_effective_speed = 1
                host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
                now[0] = 2_001.0
                pause = host._emit_clock_commit_locked(1, 0, "missing-peer-pause")
                host._record_non_intent(proposal_prepare_ack("player1", 2, pause["seq"]))
                self.assertFalse(host.clock_pause_acknowledged)
                self.assertFalse(
                    host.synchronization.status()["vehicleSync"]["timeoutPaused"]
                )

                host.synchronization.vehicle.expire(2_180.0)
                self.assertEqual(
                    host.session_fault,
                    "vehicle-sync-timeout:vehicle:event:station-sync:1:1",
                )

    def test_connected_quiescent_modal_pause_protects_pending_deadlines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [1_000.0]
            monotonic = lambda: now[0]
            with mock.patch(
                "tpf2mp.synchronization.time.monotonic", side_effect=monotonic
            ), mock.patch(
                "tpf2mp.vehicle_barrier.time.monotonic", side_effect=monotonic
            ):
                host = CommitHost(
                    GameBridge(root / "host", "connected-modal-pause", "player1"),
                    "127.0.0.1", 0, root / "audit.ndjson",
                    require_connected_peers=False,
                )
                host.consensus.monotonic = monotonic
                host.clock_requested_speed = host.clock_effective_speed = 1
                host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
                tracker = next(iter(host.vehicle_sync_rounds.values()))
                host.clock_health["player2"] = {
                    "receivedAt": 1_000.0,
                    "engineTick": 100,
                    "lastCommitSeq": 0,
                    "requestedSpeed": 1,
                    "effectiveSpeed": 1,
                    "generation": 0,
                    "gameTime": 100.0,
                    "observedSpeed": 1,
                }

                now[0] = 1_001.0
                pause = host._emit_clock_commit_locked(1, 0, "modal-pause-fence")
                host._record_non_intent(proposal_prepare_ack("player1", 2, pause["seq"]))
                self.assertFalse(host.clock_pause_acknowledged)

                now[0] = 1_004.0
                host.synchronization.expire(now[0])
                status = host.synchronization.status()
                self.assertTrue(status["clock"]["pauseProtected"])
                self.assertEqual(
                    status["clock"]["pauseProtectionMode"],
                    "connected-quiescent-modal",
                )
                self.assertEqual(status["clock"]["pauseQuiescentPeers"], ["player2"])
                self.assertFalse(status["clock"]["pauseAcknowledged"])
                self.assertTrue(status["vehicleSync"]["timeoutPaused"])
                self.assertEqual(status["vehicleSync"]["timeoutPausedRounds"], 1)

                now[0] = 1_404.0
                host.synchronization.expire(now[0])
                self.assertIsNone(host.session_fault)
                self.assertEqual(host.clock_controls[pause["seq"]]["status"], "pending")
                self.assertEqual(len(host.commits), 1, "protected pause emitted timeout spam")

                host._record_non_intent(proposal_prepare_ack("player2", 1, pause["seq"]))
                status = host.synchronization.status()
                self.assertTrue(status["clock"]["pauseAcknowledged"])
                self.assertEqual(status["clock"]["pauseProtectionMode"], "acknowledged")

                now[0] = 1_405.0
                resume = host._emit_clock_commit_locked(1, 1, "modal-pause-ended")
                now[0] = 1_410.0
                host._record_non_intent(proposal_prepare_ack("player1", 3, resume["seq"]))
                host._record_non_intent(proposal_prepare_ack("player2", 2, resume["seq"]))
                status = host.synchronization.status()
                self.assertFalse(status["clock"]["pauseProtected"])
                self.assertFalse(status["vehicleSync"]["timeoutPaused"])
                self.assertEqual(tracker["deadline"], 1_586.0)

                host.synchronization.vehicle.expire(1_585.999)
                self.assertIsNone(host.session_fault)
                host.synchronization.vehicle.expire(1_586.0)
                self.assertEqual(
                    host.session_fault,
                    "vehicle-sync-timeout:vehicle:event:station-sync:1:1",
                )

    def test_disconnected_quiescent_peer_does_not_protect_deadlines(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = [2_000.0]
            monotonic = lambda: now[0]
            with mock.patch(
                "tpf2mp.synchronization.time.monotonic", side_effect=monotonic
            ), mock.patch(
                "tpf2mp.vehicle_barrier.time.monotonic", side_effect=monotonic
            ):
                host = CommitHost(
                    GameBridge(root / "host", "disconnected-modal-pause", "player1"),
                    "127.0.0.1", 0, root / "audit.ndjson",
                    require_connected_peers=True,
                )
                host.consensus.monotonic = monotonic
                host.clock_requested_speed = host.clock_effective_speed = 1
                host._record_non_intent(vehicle_sync_record("player1", 1, "held"))
                host.clock_health["player2"] = {
                    "receivedAt": 2_000.0,
                    "engineTick": 100,
                    "lastCommitSeq": 0,
                    "requestedSpeed": 1,
                    "effectiveSpeed": 1,
                    "generation": 0,
                    "gameTime": 100.0,
                    "observedSpeed": 1,
                }

                now[0] = 2_001.0
                pause = host._emit_clock_commit_locked(1, 0, "disconnected-pause")
                host._record_non_intent(proposal_prepare_ack("player1", 2, pause["seq"]))
                now[0] = 2_004.0
                host.synchronization.expire(now[0])
                status = host.synchronization.status()
                self.assertFalse(status["clock"]["pauseProtected"])
                self.assertFalse(status["vehicleSync"]["timeoutPaused"])

                host.synchronization.vehicle.expire(2_180.0)
                self.assertEqual(
                    host.session_fault,
                    "vehicle-sync-timeout:vehicle:event:station-sync:1:1",
                )

    def test_departure_schedule_allocates_unique_slots_under_fifty_train_burst(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "vehicle-schedule-burst", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            policy = {
                "schemaVersion": 1,
                "enabled": True,
                "periodSeconds": 60,
                "phaseSeconds": 5,
            }
            line_cid = "line:event:schedule-burst:1"
            for index in range(50):
                host._record_non_intent(vehicle_sync_record(
                    "player1", index + 1, "held",
                    vehicle_cid=f"vehicle:event:schedule-burst:{index + 1}",
                    line_cid=line_cid,
                    game_time=100,
                    schedule=policy,
                ))
            self.assertEqual(host.vehicle_sync_peak_pending, 50)
            for index in range(50):
                host._record_non_intent(vehicle_sync_record(
                    "player2", index + 1, "held",
                    vehicle_cid=f"vehicle:event:schedule-burst:{index + 1}",
                    line_cid=line_cid,
                    game_time=100,
                    schedule=policy,
                ))

            releases = [item["payload"]["action"] for item in host.commits.values()]
            self.assertEqual(len(releases), 50)
            slots = [item["schedule"]["slotIndex"] for item in releases]
            self.assertEqual(slots, list(range(slots[0], slots[0] + 50)))
            self.assertTrue(all(
                item["releaseAtGameTime"] == 5 + item["schedule"]["slotIndex"] * 60
                and item["releaseWhilePaused"] is False
                for item in releases
            ))

            for index in range(50):
                vehicle_cid = f"vehicle:event:schedule-burst:{index + 1}"
                for peer in ("player1", "player2"):
                    host._record_non_intent(vehicle_sync_record(
                        peer, index + 51, "released",
                        vehicle_cid=vehicle_cid,
                        line_cid=line_cid,
                        game_time=releases[index]["releaseAtGameTime"],
                        schedule=policy,
                    ))
            telemetry = host.synchronization.status()["vehicleSync"]
            self.assertEqual(host.vehicle_sync_rounds, {})
            self.assertEqual(telemetry["prunedRounds"], 50)
            self.assertEqual(telemetry["scheduledReleases"], 50)
            self.assertEqual(telemetry["unscheduledReleases"], 0)
            self.assertEqual(telemetry["slotReservations"], 1)
            self.assertIsNone(host.session_fault)

    def test_different_departure_policies_fault_before_release(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            host = CommitHost(
                GameBridge(root / "host", "vehicle-schedule-mismatch", "player1"),
                "127.0.0.1", 0, root / "audit.ndjson",
                require_connected_peers=False,
            )
            first = {
                "schemaVersion": 1, "enabled": True,
                "periodSeconds": 60, "phaseSeconds": 5,
            }
            second = {**first, "periodSeconds": 90}
            host._record_non_intent(vehicle_sync_record(
                "player1", 1, "held", schedule=first,
            ))
            host._record_non_intent(vehicle_sync_record(
                "player2", 1, "held", schedule=second,
            ))
            self.assertIn("vehicle-sync-schedule-mismatch", host.session_fault)
            self.assertFalse(any(
                item["payload"]["action"]["type"] == "vehicle.sync_release"
                for item in host.commits.values()
            ))

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
            audit = root / "audit.ndjson"
            host = CommitHost(
                bridge, "127.0.0.1", 0, audit, require_connected_peers=False
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
            self.assertEqual(replay(audit, session), 0)

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

    def test_identical_empty_native_rejection_is_recoverable_and_checkpointed(self) -> None:
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
                completion["payload"]["resultDigest"] = proposal_completion_result_digest(
                    completion["payload"]
                )
                host._record_non_intent(completion)

            self.assertEqual(host.proposal_consensus[build_seq]["status"], "rejected")
            self.assertIsNone(host.session_fault)
            self.assertIsNone(host._pending_proposal())
            outcome = decode_line((bridge.inbox / "000000000003.json").read_bytes())
            action = outcome["payload"]["action"]
            self.assertFalse(action["success"])
            self.assertTrue(action["recoverable"])
            self.assertEqual(action["errorCode"], "native-proposal-rejected")
            self.assertEqual(action["coreDigest"], "22222222")
            pending_checkpoint = host._pending_checkpoint()
            self.assertIsNotNone(pending_checkpoint)
            self.assertEqual(pending_checkpoint["boundarySeq"], 3)
            self.assertEqual(
                pending_checkpoint["reason"],
                f"physical-rejection:{session}:player2:{build_seq}",
            )

            reason = f"physical-rejection:{session}:player2:{build_seq}"
            host._record_non_intent(consensus_checkpoint(session, "player1", 12, 3, reason))
            host._record_non_intent(consensus_checkpoint(session, "player2", 13, 3, reason))
            self.assertEqual(host.checkpoint_consensus[3]["status"], "complete")
            self.assertIsNone(host.session_fault)
            self.assertEqual(replay(root / "audit.ndjson", session), 0)

            plan = verify_recovery_plan(build_recovery_plan(root / "audit.ndjson", session))
            self.assertIsNone(plan.get("laterFault"))
            restored = CommitHost(
                bridge,
                "127.0.0.1",
                0,
                root / "audit.ndjson",
                require_connected_peers=False,
            )
            self.assertEqual(restored.proposal_consensus[build_seq]["status"], "rejected")
            self.assertIsNone(restored.session_fault)
            self.assertEqual(restored.last_agreed_checkpoint["boundarySeq"], 3)

            malformed = proposal_completion(session, "player1", 12, transaction, success=False)["payload"]
            malformed["outputs"] = {"edge:1": {"kind": "edge"}}
            with self.assertRaisesRegex(ProtocolError, "outputs are invalid"):
                CommitHost._completion_payload(malformed)

            failed_operation = operation_completion(
                session, "player1", 13, operation_transaction("company:1"), success=False
            )["payload"]
            failed_operation["outputs"] = {}
            failed_operation["resultDigest"] = operation_completion_result_digest(
                failed_operation
            )
            self.assertEqual(CommitHost._operation_completion_payload(failed_operation)["outputs"], {})

    def test_failed_proposal_is_fatal_if_rejection_has_residue_or_changed_core(self) -> None:
        cases = (
            ("core", "native-rejection-mutated-prepared-core"),
            ("outputs", "failed-native-proposal-left-canonical-outputs"),
            ("mixed", "mixed-native-proposal-results"),
        )
        for case, expected_error in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                session = f"physical-rejection-{case}"
                bridge = GameBridge(root / "host", session, "player1")
                host = CommitHost(
                    bridge,
                    "127.0.0.1",
                    0,
                    root / "audit.ndjson",
                    require_connected_peers=False,
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
                        "payload": {
                            "action": {"type": "proposal.prepare", "transaction": transaction}
                        },
                    }
                )
                _, build = pass_proposal_prepare(host, intent)
                build_seq = int(build["seq"])
                first = proposal_completion(
                    session,
                    "player1",
                    10,
                    transaction,
                    commit_seq=build_seq,
                    success=False,
                )
                second = proposal_completion(
                    session,
                    "player2",
                    11,
                    transaction,
                    commit_seq=build_seq,
                    success=case == "mixed",
                )
                if case == "core":
                    first["payload"]["coreDigest"] = "33333333"
                    second["payload"]["coreDigest"] = "33333333"
                elif case == "outputs":
                    output = {
                        "kind": "edge",
                        "cid": "edge:created:2:1",
                        "slot": "edge:1",
                    }
                    first["payload"]["outputs"] = [output]
                    second["payload"]["outputs"] = [dict(output)]
                first["payload"]["resultDigest"] = proposal_completion_result_digest(
                    first["payload"]
                )
                second["payload"]["resultDigest"] = proposal_completion_result_digest(
                    second["payload"]
                )
                host._record_non_intent(first)
                host._record_non_intent(second)

                self.assertEqual(host.proposal_consensus[build_seq]["status"], "faulted")
                self.assertEqual(host.session_fault, expected_error)
                outcome = decode_line((bridge.inbox / "000000000003.json").read_bytes())
                self.assertFalse(outcome["payload"]["action"].get("recoverable", False))
                self.assertEqual(outcome["payload"]["action"]["errorCode"], expected_error)

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
            divergent = proposal_completion(
                session, "player2", 11, transaction, commit_seq=build_seq
            )
            divergent["payload"]["outputs"][0]["cid"] = (
                f"node:created:{build_seq}:different"
            )
            divergent["payload"]["resultDigest"] = proposal_completion_result_digest(
                divergent["payload"]
            )
            host._record_non_intent(divergent)
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

    def test_line_register_is_company_bound_not_host_only(self) -> None:
        # Registration is automatic now, so a client's own line must be able to
        # enter the economy; it still may not register for a rival company.
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bridge = GameBridge(root / "host", "register-auth", "player1")
            host = CommitHost(
                bridge, "127.0.0.1", 0, root / "audit.ndjson", require_connected_peers=False
            )

            def registration(company: str, service_company: str) -> dict:
                return {
                    "type": "line.register",
                    "lineCid": "line:event:register-auth:player2:4:1",
                    "companyCid": company,
                    "market": {
                        "cid": "market:auth", "name": "Auth", "demand": 1000,
                        "votCentsPerHour": 450, "gcOutsideCents": 2500, "thetaCents": 250,
                    },
                    "service": {
                        "lineCid": "line:event:register-auth:player2:4:1",
                        "marketCid": "market:auth", "companyCid": service_company,
                        "name": "Client service", "headwaySeconds": 600,
                        "journeySeconds": 1200, "fareCents": 1000, "capacity": 400,
                        "quality": 100,
                    },
                }

            def envelope(action: dict, local_seq: int) -> dict:
                return sign({
                    "protocol": 1, "session": "register-auth", "peer": "player2",
                    "local_seq": local_seq, "tick": 0, "kind": "intent",
                    "payload": {"action": action},
                })

            with self.assertRaisesRegex(ProtocolError, "must act for company:2"):
                host._commit(envelope(registration("company:1", "company:1"), 1))
            with self.assertRaisesRegex(ProtocolError, "service company must match"):
                host._commit(envelope(registration("company:2", "company:1"), 2))

            commit = host._commit(envelope(registration("company:2", "company:2"), 3))
            self.assertIsNotNone(commit)
            self.assertEqual(commit["payload"]["action"]["companyCid"], "company:2")

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

    def test_client_save_request_becomes_an_ordered_peer_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "socket-anchor"
            host_bridge = GameBridge(root / "host", session, "player1")
            client_bridge = GameBridge(root / "client", session, "player2")
            port = available_port()
            host = CommitHost(host_bridge, "127.0.0.1", port, root / "audit.ndjson", "same")
            client = CommitClient(client_bridge, "127.0.0.1", port, "same")
            host_thread = threading.Thread(
                target=host.run, kwargs={"poll_seconds": 0.01}, daemon=True
            )
            client_thread = threading.Thread(
                target=client.run,
                kwargs={"poll_seconds": 0.01, "retry_seconds": 0.05}, daemon=True,
            )
            host_thread.start()
            client_thread.start()
            try:
                self.assertTrue(wait_for(lambda: "player2" in host.peers))
                boundary = 4
                host.commits[boundary] = sign({
                    "protocol": 1, "session": session, "seq": boundary,
                    "kind": "control", "origin_peer": "player1", "tick": 0,
                    "payload": {"action": {
                        "type": "network.checkpoint_outcome", "boundarySeq": boundary,
                        "success": True, "convergenceKey": "key-4",
                        "coreDigest": "core-4",
                    }},
                })
                host.next_seq = boundary + 1
                host.last_agreed_checkpoint = {
                    "boundarySeq": boundary, "convergenceKey": "key-4",
                    "coreDigest": "core-4",
                }
                host.clock_pause_acknowledged = True
                now = time.monotonic()
                for peer in host.required_peers:
                    host.clock_health[peer] = {
                        "schemaVersion": 3, "requestedSpeed": 0, "effectiveSpeed": 0,
                        "generation": host.clock_pause_acknowledged_generation,
                        "engineTick": 1, "lastCommitSeq": boundary,
                        "proposalPending": False, "localWorkPending": False,
                        "deferredIntentCount": 0, "rendezvousGeneration": 0,
                        "rendezvousState": "idle", "rendezvousTargetTime": 0,
                        "observedSpeed": 0, "gameTime": 100.0, "receivedAt": now,
                    }
                host._write_status()
                self.assertTrue(wait_for(
                    lambda: client.anchor_state is not None
                    and client.anchor_state.get("ready") is True
                ))

                save = root / "player2.sav"
                save.write_bytes(b"client-world-at-four")
                request_id = "c" * 32
                request = {
                    "schemaVersion": 1, "session": session, "peer": "player2",
                    "requestId": request_id, "boundarySeq": boundary,
                    "coreDigest": "core-4", "convergenceKey": "key-4",
                    "savePath": str(save), "savedAtUnix": 1717171717,
                }
                atomic_write(
                    client.anchor_requests.requests / f"{request_id}.json",
                    (json.dumps(request) + "\n").encode("utf-8"),
                )
                self.assertTrue(wait_for(
                    lambda: client.anchor_requests.status()["localAnchorsFiled"] == [4]
                ))
                peer_receipts = [
                    message for message in host.commits.values()
                    if message.get("origin_peer") == "player2"
                    and (message.get("payload") or {}).get("action", {}).get("type")
                    == "recovery.save_receipt"
                ]
                self.assertEqual(len(peer_receipts), 1)
                self.assertLess(peer_receipts[0]["origin_local_seq"], 0)
            finally:
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
