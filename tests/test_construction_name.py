import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "companion"))
from tpf2mp.protocol import ProtocolError, checksum, validate_proposal_transaction
from tpf2mp.proposal_schema import construction_proposal_schema, street_features_schema


def transaction(name="Coleford Airport"):
    value = {
        "schemaVersion": 9, "companyCid": "company:1", "cost": 100,
        "nodes": {}, "edges": {}, "remove": {"edges": {}, "nodes": {}},
        "edgeObjects": {"add": {}, "retain": {}, "remove": {}},
        "constructions": [{"slot": "construction:1", "mode": "build",
            "adapter": "portable-construction", "kind": "station", "sourceCid": "",
            "fileName": "station/air/airfield.con", "name": name,
            "transform": [1,0,0,0,0,1,0,0,0,0,1,0,10,20,0,1],
            "params": {"year": 1940}, "modules": {}, "collateral": {}}],
    }
    return redigest(value)


def redigest(value):
    content = {k: v for k, v in value.items() if k not in ("digest", "transactionId")}
    value["digest"] = checksum(content)
    value["transactionId"] = "proposal:" + value["digest"]
    return value


class ConstructionNameTests(unittest.TestCase):
    def test_named_schema_and_legacy(self):
        value = transaction()
        self.assertEqual(validate_proposal_transaction(value), value)
        self.assertTrue(construction_proposal_schema(9) and street_features_schema(9))
        value["schemaVersion"] = 8
        with self.assertRaises(ProtocolError):
            validate_proposal_transaction(redigest(value))
        del value["constructions"][0]["name"]
        self.assertEqual(validate_proposal_transaction(redigest(value)), value)
        value["schemaVersion"] = 9
        with self.assertRaisesRegex(ProtocolError, "name"):
            validate_proposal_transaction(redigest(value))

    def test_name_bound_and_utf8_byte_limits(self):
        for valid in ("x" * 240, "\u00e9" * 120, "Airport", "\u5317\u4eac"):
            value = transaction(valid)
            self.assertEqual(validate_proposal_transaction(value), value)
        for invalid in (None, True, 5, "", "x" * 241, "\u00e9" * 121, "bad\nname", "bad\x00name"):
            with self.subTest(invalid=invalid), self.assertRaisesRegex(ProtocolError, "name"):
                validate_proposal_transaction(transaction(invalid))
        value = transaction()
        value["constructions"][0]["name"] = "Other Airport"
        with self.assertRaises(ProtocolError):
            validate_proposal_transaction(value)
        value["constructions"][0]["mode"] = "remove"
        with self.assertRaisesRegex(ProtocolError, "name"):
            validate_proposal_transaction(redigest(value))

    def test_real_lua_emission(self):
        lua = os.environ.get("TPF2MP_LUA")
        if not lua:
            self.skipTest("set TPF2MP_LUA for real Lua/Python wire parity")
        result = subprocess.run([lua, str(ROOT / "tests/run_construction_name_tests.lua"),
                                 str(ROOT), "--json"], check=True, capture_output=True,
                                text=True, timeout=10)
        value = json.loads(result.stdout)
        self.assertEqual(validate_proposal_transaction(value), value)


if __name__ == "__main__":
    unittest.main()
