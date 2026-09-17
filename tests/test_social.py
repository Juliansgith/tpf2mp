from __future__ import annotations

import json
import socket
import tempfile
import threading
import time
import unittest
from pathlib import Path

from tpf2mp.bridge import GameBridge, atomic_write
from tpf2mp.client import CommitClient
from tpf2mp.network import CommitHost
from tpf2mp.protocol import ProtocolError, canonical_json, sign
from tpf2mp.social import (
    MAX_FILE_CHARACTERS,
    MAX_INCOMING_ITEMS,
    MAX_PARAMS_CHARACTERS,
    SocialRelay,
    social_frame,
    validate_social_document,
    validate_social_frame,
    validate_social_item,
)

SESSION = "mp-0123456789abcdef"


def wait_for(predicate, timeout: float = 10.0) -> bool:
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


def social_item(
    identifier: int = 1,
    peer: str = "player2",
    channel: str = "chat",
    body: dict | None = None,
    at: int = 1789000000,
) -> dict:
    return {
        "id": identifier,
        "peer": peer,
        "channel": channel,
        "at": at,
        "body": {"text": "wait for me"} if body is None else body,
    }


def social_document(
    items: list, peer: str = "player1", seq: int = 1, session: str = SESSION
) -> dict:
    return {
        "schemaVersion": 1, "session": session, "peer": peer,
        "seq": seq, "items": items,
    }


def publish(path: Path, document: dict) -> None:
    atomic_write(path, (canonical_json(document) + "\n").encode("utf-8"))


def curve(offset: float = 0.0) -> list:
    return [offset + index * 1.5 for index in range(8)]


def detail(
    terrain: int = 0,
    file: str = "street/town_small_new.lua",
    bus: int = 1,
    tram: int = 2,
    catenary: int = 1,
    structure: str | None = None,
) -> list:
    if structure is None:
        structure = "" if terrain == 0 else "bridge/stone_new.module"
    return [0.5, -12.25, 0.125, -0.0625, terrain, file, bus, tram, catenary,
            structure]


def wide_preview(identifier: int, peer: str = "player1") -> dict:
    return social_item(identifier, peer, "preview", {
        "kind": "rail", "invalid": False,
        "curves": [curve(123456.78125 + index) for index in range(24)],
    })


def maximal_preview(identifier: int, peer: str = "player1") -> dict:
    """The largest road/rail preview the contract permits, detail included."""

    wide = [-123456.78901234567 - index / 3.0 for index in range(8)]
    entry = [
        -98765.43210987654, 87654.32109876543, -0.33333333333333331,
        0.66666666666666663, 2, "a" * MAX_FILE_CHARACTERS, 1, 2, 1,
        "b" * MAX_FILE_CHARACTERS,
    ]
    return social_item(identifier, peer, "preview", {
        "kind": "rail", "invalid": True,
        "curves": [list(wide) for _ in range(24)],
        "details": [list(entry) for _ in range(24)],
    })


class SocialItemValidationTests(unittest.TestCase):
    def test_chat_text_is_bounded_printable_and_exactly_keyed(self) -> None:
        for text in ("h", "wait for me", "x" * 240):
            self.assertEqual(
                validate_social_item(social_item(body={"text": text}))["body"],
                {"text": text},
            )
        for body in (
            {"text": ""},
            {"text": "x" * 241},
            {"text": "two\nlines"},
            {"text": "bell\x07"},
            {"text": "ok", "extra": 1},
            {"text": 5},
            {"text": None},
            {},
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(body=body))

    def test_ping_carries_coordinates_only_for_look(self) -> None:
        for kind in ("wait", "ready", "pause"):
            item = validate_social_item(
                social_item(channel="ping", body={"kind": kind})
            )
            self.assertEqual(item["body"], {"kind": kind})
        look = validate_social_item(
            social_item(channel="ping", body={"kind": "look", "x": 12, "y": -3.5})
        )
        self.assertEqual(look["body"], {"kind": "look", "x": 12.0, "y": -3.5})
        blind = validate_social_item(social_item(channel="ping", body={"kind": "look"}))
        self.assertEqual(blind["body"], {"kind": "look"})
        for body in (
            {"kind": "look", "x": 1.0},
            {"kind": "look", "x": 1.0, "y": 2.0, "z": 3.0},
            {"kind": "wait", "x": 1.0, "y": 2.0},
            {"kind": "look", "x": float("inf"), "y": 2.0},
            {"kind": "look", "x": float("nan"), "y": 2.0},
            {"kind": "look", "x": "1", "y": 2.0},
            {"kind": "look", "x": True, "y": 2.0},
            {"kind": "poke"},
            {"kind": None},
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="ping", body=body))

    def test_preview_bounds_curves_transforms_and_construction_files(self) -> None:
        off = validate_social_item(
            social_item(channel="preview", body={"kind": "off"})
        )
        self.assertEqual(off["body"], {"kind": "off"})
        for kind in ("road", "rail"):
            for count in (1, 24):
                item = validate_social_item(social_item(channel="preview", body={
                    "kind": kind, "invalid": True,
                    "curves": [curve(float(index)) for index in range(count)],
                }))
                self.assertEqual(len(item["body"]["curves"]), count)
        construction = validate_social_item(social_item(channel="preview", body={
            "kind": "construction", "invalid": False,
            "file": "asset/industry/farm_2-1.con",
            "x": 1.0, "y": 2.0, "z": 3.0,
            "transf": [float(index) for index in range(16)],
        }))
        self.assertEqual(construction["body"]["file"], "asset/industry/farm_2-1.con")
        for body in (
            {"kind": "off", "invalid": False},
            {"kind": "road", "invalid": False, "curves": []},
            {"kind": "road", "invalid": False,
             "curves": [curve(float(index)) for index in range(25)]},
            {"kind": "road", "invalid": False, "curves": [curve()[:7]]},
            {"kind": "road", "invalid": False, "curves": [curve() + [1.0]]},
            {"kind": "road", "invalid": False, "curves": [[float("inf")] * 8]},
            {"kind": "road", "invalid": False, "curves": curve()},
            {"kind": "road", "invalid": "no", "curves": [curve()]},
            {"kind": "rail", "curves": [curve()]},
            {"kind": "hover", "invalid": False, "curves": [curve()]},
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=body))

    def test_construction_preview_file_charset_and_length(self) -> None:
        def body(name: str) -> dict:
            return {
                "kind": "construction", "invalid": False, "file": name,
                "x": 0.0, "y": 0.0, "z": 0.0, "transf": [0.0] * 16,
            }

        self.assertEqual(
            validate_social_item(
                social_item(channel="preview", body=body("a" * 124 + ".con"))
            )["body"]["file"],
            "a" * 124 + ".con",
        )
        for name in (
            "a" * 125 + ".con", "station.txt", "sta tion.con", "sta:tion.con",
            "station.con\n", "st" + chr(228) + "tion.con", ".con", "", "STATION.CON",
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=body(name)))
        for missing in ("x", "y", "z", "transf", "invalid", "file"):
            broken = body("asset/x.con")
            broken.pop(missing)
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=broken))
        short = body("asset/x.con")
        short["transf"] = [0.0] * 15
        with self.assertRaises(ProtocolError):
            validate_social_item(social_item(channel="preview", body=short))

    def test_path_preview_details_are_optional_and_curve_aligned(self) -> None:
        def body(count: int, details: object) -> dict:
            return {
                "kind": "road", "invalid": False,
                "curves": [curve(float(index)) for index in range(count)],
                "details": details,
            }

        plain = validate_social_item(social_item(channel="preview", body={
            "kind": "road", "invalid": False, "curves": [curve()],
        }))
        self.assertEqual(set(plain["body"]), {"kind", "invalid", "curves"})
        for count in (1, 24):
            item = validate_social_item(social_item(
                channel="preview",
                body=body(count, [detail(index % 3) for index in range(count)]),
            ))
            self.assertEqual(set(item["body"]),
                             {"kind", "invalid", "curves", "details"})
            self.assertEqual(len(item["body"]["details"]), count)
            self.assertEqual(item["body"]["details"][0], detail(0))
        tunnelled = validate_social_item(social_item(
            channel="preview",
            body=body(2, [detail(1), detail(2, structure="tunnel/x-1.module")]),
        ))
        self.assertEqual(tunnelled["body"]["details"][1][9], "tunnel/x-1.module")
        for broken in (
            body(2, [detail()]),
            body(1, [detail(), detail()]),
            body(1, []),
            body(1, detail()),
            body(1, "details"),
            body(1, [detail()[:9]]),
            body(1, [detail() + [0]]),
            body(1, [tuple(detail())]),
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=broken))

    def test_path_preview_detail_slots_are_typed_and_bounded(self) -> None:
        def body(entry: list) -> dict:
            return {
                "kind": "rail", "invalid": False, "curves": [curve()],
                "details": [entry],
            }

        for slot in range(4):
            for bad in (float("inf"), float("nan"), "0", True, None):
                entry = detail()
                entry[slot] = bad
                with self.assertRaises(ProtocolError):
                    validate_social_item(
                        social_item(channel="preview", body=body(entry))
                    )
        accepted = validate_social_item(social_item(
            channel="preview", body=body(detail(2, "a" * MAX_FILE_CHARACTERS)),
        ))
        self.assertEqual(len(accepted["body"]["details"][0][5]),
                         MAX_FILE_CHARACTERS)
        for entry in (
            detail(3),
            detail(-1),
            detail(0.0),
            detail(True),
            detail(0, structure="bridge/stone_new.module"),
            detail(1, structure=""),
            detail(2, structure="a" * (MAX_FILE_CHARACTERS + 1)),
            detail(1, structure="bridge stone.module"),
            detail(1, structure=7),
            detail(file="street/sma ll.lua"),
            detail(file="street/small.lua\n"),
            detail(file="street/sm" + chr(228) + "ll.lua"),
            detail(file=""),
            detail(file="a" * (MAX_FILE_CHARACTERS + 1)),
            detail(file=5),
            detail(bus=2),
            detail(bus=True),
            detail(bus=-1),
            detail(tram=3),
            detail(tram=1.0),
            detail(catenary=2),
            detail(catenary=False),
        ):
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=body(entry)))

    def test_construction_preview_params_are_optional_and_printable(self) -> None:
        def body(params: object = None) -> dict:
            value = {
                "kind": "construction", "invalid": False, "file": "asset/x.con",
                "x": 0.0, "y": 0.0, "z": 0.0, "transf": [0.0] * 16,
            }
            if params is not None:
                value["params"] = params
            return value

        plain = validate_social_item(social_item(channel="preview", body=body()))
        self.assertEqual(
            set(plain["body"]),
            {"kind", "invalid", "file", "x", "y", "z", "transf"},
        )
        for params in ("p", "1;2;3 module=4", "~" * MAX_PARAMS_CHARACTERS):
            item = validate_social_item(
                social_item(channel="preview", body=body(params))
            )
            self.assertEqual(
                set(item["body"]),
                {"kind", "invalid", "file", "x", "y", "z", "transf", "params"},
            )
            self.assertEqual(item["body"]["params"], params)
        for params in (
            "", "x" * (MAX_PARAMS_CHARACTERS + 1), "two\nlines", "bell\x07",
            "tab\there", "wide" + chr(233), "trail\x7f", 5, True, None, ["1"],
        ):
            broken = body()
            broken["params"] = params
            with self.assertRaises(ProtocolError):
                validate_social_item(social_item(channel="preview", body=broken))

    def test_item_envelope_rejects_unknown_keys_peers_channels_and_ids(self) -> None:
        accepted = validate_social_item(social_item(0, "player1"), "player1")
        self.assertEqual(accepted["id"], 0)
        broken = [
            {**social_item(), "extra": 1},
            {key: value for key, value in social_item().items() if key != "at"},
            {**social_item(), "peer": "player3"},
            {**social_item(), "peer": 2},
            {**social_item(), "channel": "shout"},
            {**social_item(), "id": -1},
            {**social_item(), "id": True},
            {**social_item(), "id": 1.0},
            {**social_item(), "at": -1},
            {**social_item(), "body": ["text"]},
        ]
        for value in broken + ["item", None, 7]:
            with self.assertRaises(ProtocolError):
                validate_social_item(value)
        with self.assertRaises(ProtocolError):
            validate_social_item(social_item(1, "player2"), "player1")


class SocialFrameValidationTests(unittest.TestCase):
    def test_frame_accepts_one_ascending_batch_from_the_other_peer(self) -> None:
        frame = social_frame(SESSION, "player2", [
            social_item(1), social_item(4, channel="ping", body={"kind": "ready"}),
        ])
        self.assertEqual(
            set(frame), {"checksum", "items", "kind", "peer", "protocol", "session"}
        )
        accepted = validate_social_frame(frame, SESSION, "player1")
        self.assertEqual(accepted["peer"], "player2")
        self.assertEqual([item["id"] for item in accepted["items"]], [1, 4])

    def test_frame_rejects_foreign_session_and_unusable_peers(self) -> None:
        frame = social_frame(SESSION, "player2", [social_item(1)])
        with self.assertRaises(ProtocolError):
            validate_social_frame(frame, "mp-other", "player1")
        with self.assertRaises(ProtocolError):
            validate_social_frame(frame, SESSION, "player2")
        with self.assertRaises(ProtocolError):
            validate_social_frame(
                social_frame(SESSION, "player3", [social_item(1, "player3")]),
                SESSION, "player1",
            )
        with self.assertRaises(ProtocolError):
            validate_social_frame(
                social_frame(SESSION, "player2", [social_item(1, "player1")]),
                SESSION, "player1",
            )

    def test_frame_rejects_empty_unordered_oversized_and_unsigned_batches(self) -> None:
        for items in (
            [],
            [social_item(index) for index in range(1, 34)],
            [social_item(2), social_item(1)],
            [social_item(2), social_item(2)],
        ):
            with self.assertRaises(ProtocolError):
                validate_social_frame(
                    social_frame(SESSION, "player2", items), SESSION, "player1"
                )
        unsigned = social_frame(SESSION, "player2", [social_item(1)])
        unsigned.pop("checksum")
        with self.assertRaises(ProtocolError):
            validate_social_frame(unsigned, SESSION, "player1")
        extra = sign({**social_frame(SESSION, "player2", [social_item(1)]), "tick": 3})
        with self.assertRaises(ProtocolError):
            validate_social_frame(extra, SESSION, "player1")
        wrong_kind = sign({
            **{key: value for key, value in
               social_frame(SESSION, "player2", [social_item(1)]).items()
               if key != "checksum"},
            "kind": "intent",
        })
        with self.assertRaises(ProtocolError):
            validate_social_frame(wrong_kind, SESSION, "player1")

    def test_frame_rejects_more_than_thirty_two_kibibytes(self) -> None:
        items = [wide_preview(index, "player2") for index in range(1, 17)]
        frame = social_frame(SESSION, "player2", items)
        self.assertGreater(len(canonical_json(frame).encode("utf-8")), 32 * 1024)
        with self.assertRaises(ProtocolError):
            validate_social_frame(frame, SESSION, "player1")
        small = social_frame(SESSION, "player2", items[:4])
        self.assertLessEqual(len(canonical_json(small).encode("utf-8")), 32 * 1024)
        self.assertEqual(len(validate_social_frame(small, SESSION, "player1")["items"]), 4)

    def test_a_maximal_detailed_preview_still_fits_one_frame(self) -> None:
        frame = social_frame(SESSION, "player2", [maximal_preview(1, "player2")])
        size = len(canonical_json(frame).encode("utf-8"))
        self.assertLessEqual(size, 32 * 1024)
        accepted = validate_social_frame(frame, SESSION, "player1")
        body = accepted["items"][0]["body"]
        self.assertEqual(len(body["curves"]), 24)
        self.assertEqual(len(body["details"]), 24)
        self.assertEqual(len(body["details"][0][5]), MAX_FILE_CHARACTERS)
        self.assertEqual(len(body["details"][0][9]), MAX_FILE_CHARACTERS)


class SocialDocumentValidationTests(unittest.TestCase):
    def test_document_header_session_peer_and_limits_are_exact(self) -> None:
        document = social_document([social_item(3, "player1")], "player1", 9)
        accepted = validate_social_document(document, SESSION, "player1", 32)
        self.assertEqual(accepted["seq"], 9)
        self.assertEqual(accepted["items"][0]["id"], 3)
        self.assertEqual(
            validate_social_document(
                social_document([], "player1", 0), SESSION, "player1", 32
            )["items"],
            [],
        )
        for value in (
            {**document, "schemaVersion": 2},
            {**document, "session": "mp-other"},
            {**document, "peer": "player2"},
            {**document, "seq": -1},
            {**document, "extra": 1},
            social_document([social_item(index) for index in range(33)], "player1"),
            "document",
        ):
            with self.assertRaises(ProtocolError):
                validate_social_document(value, SESSION, "player1", 32)


class SocialRelayTests(unittest.TestCase):
    def relay(self, directory: str, peer: str = "player1") -> SocialRelay:
        return SocialRelay(GameBridge(Path(directory) / peer, SESSION, peer))

    def test_pump_forwards_new_items_once_and_ignores_broken_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            relay = self.relay(directory)
            sent: list[dict] = []
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            publish(relay.outgoing_path, social_document(
                [social_item(1, "player1"), social_item(2, "player1")], "player1", 1
            ))
            self.assertEqual(relay.pump_outgoing(sent.append), 2)
            self.assertEqual(sent[0]["kind"], "social")
            self.assertEqual(sent[0]["peer"], "player1")
            self.assertEqual([item["id"] for item in sent[0]["items"]], [1, 2])
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            publish(relay.outgoing_path, social_document(
                [social_item(1, "player1"), social_item(2, "player1")], "player1", 2
            ))
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            publish(relay.outgoing_path, social_document(
                [social_item(2, "player1"), social_item(3, "player1")], "player1", 3
            ))
            self.assertEqual(relay.pump_outgoing(sent.append), 1)
            self.assertEqual([item["id"] for item in sent[1]["items"]], [3])
            self.assertEqual(relay.forwarded, 3)
            self.assertEqual(relay.status(), {
                "forwarded": 3, "received": 0, "dropped": 0,
            })

    def test_pump_never_raises_on_malformed_or_foreign_outboxes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            relay = self.relay(directory)
            sent: list[dict] = []
            relay.outgoing_path.write_bytes(b"{not json")
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            self.assertEqual(relay.drop_reasons.get("unreadable-outgoing"), 1)
            publish(relay.outgoing_path, social_document(
                [social_item(1, "player1")], "player1", 1, session="mp-other"
            ))
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            self.assertEqual(relay.drop_reasons.get("invalid-outgoing"), 1)
            publish(relay.outgoing_path, social_document(
                [social_item(1, "player2")], "player2", 2
            ))
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            self.assertEqual(relay.drop_reasons.get("invalid-outgoing"), 2)
            relay.outgoing_path.write_bytes(b"x" * (64 * 1024 + 1))
            self.assertEqual(relay.pump_outgoing(sent.append), 0)
            self.assertEqual(relay.drop_reasons.get("oversized-outgoing"), 1)
            self.assertEqual(sent, [])
            self.assertEqual(relay.status()["dropped"], 4)

    def test_pump_trims_a_batch_that_exceeds_the_frame_budget(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            relay = self.relay(directory)
            sent: list[dict] = []
            publish(relay.outgoing_path, social_document(
                [wide_preview(index) for index in range(1, 17)], "player1", 1
            ))
            forwarded = relay.pump_outgoing(sent.append)
            self.assertGreater(forwarded, 0)
            self.assertLess(forwarded, 16)
            self.assertLessEqual(
                len(canonical_json(sent[0]).encode("utf-8")), 32 * 1024
            )
            self.assertEqual(sent[0]["items"][-1]["id"], 16)
            self.assertGreater(relay.drop_reasons.get("outgoing-frame-too-large", 0), 0)

    def test_incoming_ring_trims_to_sixty_four_and_dedupes_by_peer_and_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            relay = self.relay(directory)
            for batch in range(3):
                items = [
                    social_item(batch * 30 + index, "player2")
                    for index in range(1, 31)
                ]
                self.assertEqual(
                    relay.accept_frame(social_frame(SESSION, "player2", items)), 30
                )
            document = json.loads(relay.incoming_path.read_text(encoding="utf-8"))
            self.assertEqual(document["schemaVersion"], 1)
            self.assertEqual(document["session"], SESSION)
            self.assertEqual(document["peer"], "player2")
            self.assertEqual(document["seq"], 3)
            self.assertEqual(len(document["items"]), MAX_INCOMING_ITEMS)
            self.assertEqual(document["items"][0]["id"], 90 - MAX_INCOMING_ITEMS + 1)
            self.assertEqual(document["items"][-1]["id"], 90)
            validate_social_document(document, SESSION, "player2", MAX_INCOMING_ITEMS)

            replay = social_frame(SESSION, "player2", [
                social_item(89, "player2"), social_item(90, "player2"),
                social_item(91, "player2"),
            ])
            self.assertEqual(relay.accept_frame(replay), 1)
            self.assertEqual(relay.drop_reasons.get("duplicate-item"), 2)
            self.assertEqual(relay.accept_frame(replay), 0)
            self.assertEqual(relay.drop_reasons.get("duplicate-item"), 5)
            reread = json.loads(relay.incoming_path.read_text(encoding="utf-8"))
            self.assertEqual(reread["seq"], 4)
            self.assertEqual(reread["items"][-1]["id"], 91)
            self.assertEqual(relay.received, 91)
            self.assertEqual(relay.status()["dropped"], 5)

    def test_accept_frame_counts_invalid_frames_without_raising(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            relay = self.relay(directory)
            for message in (
                social_frame("mp-other", "player2", [social_item(1)]),
                social_frame(SESSION, "player1", [social_item(1, "player1")]),
                social_frame(SESSION, "player2", []),
                {"kind": "social"},
                None,
            ):
                self.assertEqual(relay.accept_frame(message), 0)
            self.assertEqual(relay.drop_reasons.get("invalid-frame"), 5)
            self.assertFalse(relay.incoming_path.exists())
            self.assertEqual(relay.status(), {
                "forwarded": 0, "received": 0, "dropped": 5,
            })


class SocialChannelIntegrationTests(unittest.TestCase):
    def test_social_items_cross_a_live_socket_in_both_directions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            session = "mp-socialintegration"
            host_bridge = GameBridge(root / "host", session, "player1")
            client_bridge = GameBridge(root / "client", session, "player2")
            port = available_port()
            host = CommitHost(
                host_bridge, "127.0.0.1", port, root / "audit.ndjson", "same"
            )
            client = CommitClient(client_bridge, "127.0.0.1", port, "same")
            host_thread = threading.Thread(
                target=host.run, kwargs={"poll_seconds": 0.01}, daemon=True
            )
            client_thread = threading.Thread(
                target=client.run,
                kwargs={"poll_seconds": 0.01, "retry_seconds": 0.05}, daemon=True,
            )
            host_thread.start()
            try:
                client_thread.start()
                self.assertTrue(wait_for(lambda: "player2" in host.peers))
                self.assertTrue(wait_for(lambda: client.synchronized))

                publish(client_bridge.state_dir / "social_out.json", {
                    "schemaVersion": 1, "session": session, "peer": "player2",
                    "seq": 1, "items": [
                        social_item(1, "player2", body={"text": "wait for me"}),
                        social_item(2, "player2", "ping",
                                    {"kind": "look", "x": 120.5, "y": -40.25}),
                    ],
                })
                host_inbox = host_bridge.state_dir / "social_in.json"
                self.assertTrue(wait_for(host_inbox.is_file))
                received = json.loads(host_inbox.read_text(encoding="utf-8"))
                self.assertEqual(received["peer"], "player2")
                self.assertEqual([item["id"] for item in received["items"]], [1, 2])
                self.assertEqual(received["items"][0]["body"], {"text": "wait for me"})
                self.assertEqual(
                    received["items"][1]["body"],
                    {"kind": "look", "x": 120.5, "y": -40.25},
                )

                publish(host_bridge.state_dir / "social_out.json", {
                    "schemaVersion": 1, "session": session, "peer": "player1",
                    "seq": 1, "items": [
                        social_item(7, "player1", "preview", {
                            "kind": "road", "invalid": True, "curves": [curve(4.0)],
                        }),
                    ],
                })
                client_inbox = client_bridge.state_dir / "social_in.json"
                self.assertTrue(wait_for(client_inbox.is_file))
                echoed = json.loads(client_inbox.read_text(encoding="utf-8"))
                self.assertEqual(echoed["peer"], "player1")
                self.assertEqual([item["id"] for item in echoed["items"]], [7])
                self.assertEqual(echoed["items"][0]["body"]["kind"], "road")

                # Advisory frames never enter the ordered commit path.
                self.assertEqual(host.next_seq, 1)
                self.assertFalse(list(host_bridge.inbox.glob("*.json")))
                self.assertFalse(list(client_bridge.inbox.glob("*.json")))
                status = json.loads(
                    host_bridge.status_path.read_text(encoding="utf-8")
                )
                self.assertEqual(
                    set(status["social"]), {"forwarded", "received", "dropped"}
                )
                self.assertTrue(wait_for(
                    lambda: json.loads(
                        host_bridge.status_path.read_text(encoding="utf-8")
                    )["social"] == {"forwarded": 1, "received": 2, "dropped": 0}
                ))
            finally:
                client.stop.set()
                host.stop.set()
                if client_thread.ident is not None:
                    client_thread.join(2)
                host_thread.join(2)


if __name__ == "__main__":
    unittest.main()
