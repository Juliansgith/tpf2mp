from __future__ import annotations

import copy
import json
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tpf2mp import __version__
from tpf2mp.lobby_client import selected_content
from tpf2mp.relay_api import RelayApiError
from tpf2mp.world_generation import native_request, verify_generated


class WorldGenerationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.game = self.root / "game/TransportFever2.exe"
        self.game.parent.mkdir()
        self.game.touch()
        self.mod = self.root / "local/mods/tpf2_mp_1"
        self.mod.mkdir(parents=True)
        (self.mod / "mod.lua").write_text("return {}")
        self.config = {"mode": "new", "release": __version__, "saveDigest": None,
            "mods": selected_content([{"id": "!tpf2_mp", "version": 1}], self.game, self.mod),
            "world": {"seed": 7654321, "year": 1980, "size": "medium", "terrain": "hilly",
                "towns": "low", "industries": "high", "difficulty": "relaxed", "agentMode": "vanilla",
                "townDevelopment": False}}

    def test_native_contract_maps_all_settings_and_namespaces(self):
        self.assertEqual(native_request(self.config,self.game,self.mod),
            "TPF2MP_WORLDGEN_1\n7654321 1980 1 1 0 2 3 1 0\n1\n!tpf2_mp 1\n")

    def test_invalid_world_never_emits_request(self):
        for key, value in [("seed",True),("seed",2147483648),("year",1849),
                           ("size","huge"),("terrain",{}),("difficulty","cheat"),
                           ("townDevelopment",1),("agentMode","disabled")]:
            config = copy.deepcopy(self.config); config["world"][key] = value
            with self.subTest(key=key,value=value), self.assertRaises(RelayApiError):
                native_request(config,self.game,self.mod)

    def test_missing_extra_settings_and_aliases_rejected(self):
        for mutate in (lambda c:c["world"].pop("year"), lambda c:c["world"].update(script="evil"),
                       lambda c:c["mods"][0].update(id="tpf2_mp")):
            config = copy.deepcopy(self.config); mutate(config)
            with self.assertRaises(RelayApiError): native_request(config,self.game,self.mod)

    def test_zero_exit_alone_is_not_world_success(self):
        (self.root / "report.json").write_text(json.dumps({"complete":False,"exitCode":0}))
        with self.assertRaisesRegex(RelayApiError,"did not complete"):
            verify_generated(self.config,self.root/"world.sav",self.root,self.game,self.mod,"mp-0123456789abcdef")

    def test_completed_other_request_is_not_accepted(self):
        (self.root / "report.json").write_text(json.dumps({"complete":True,"exitCode":0,"requestSha256":"0"*64}))
        with self.assertRaisesRegex(RelayApiError,"different request"):
            verify_generated(self.config,self.root/"world.sav",self.root,self.game,self.mod,"mp-0123456789abcdef")

    def completed_fixture(self):
        save = self.root / "world.sav"
        save.touch(); save.with_suffix('.jpg').touch()
        metadata = self.root / 'world.sav.lua'
        metadata.write_text('function data() return {economyDifficulty="relaxed"} end')
        request = native_request(self.config,self.game,self.mod).encode('ascii')
        (self.root/'native-request.txt').write_bytes(request)
        (self.root/'report.json').write_text(json.dumps({'complete':True,'exitCode':0,
            'requestSha256':hashlib.sha256(request).hexdigest(),'savePath':str(save)}))
        events = ['native-save-idle','generator-resource-temperate.gen.lua','native-seed=7654321',
            'native-terrain-hilliness=1','native-terrain-water=0','native-terrain-forest=2',
            'native-parameter-:locations.mapSize=1','native-parameter-:locations.towns.frequency=0',
            'native-parameter-:locations.industry.maxNumberPerArea=2',
            'native-parameter-!tpf2_mp_1:economyDifficulty=3','native-parameter-!tpf2_mp_1:agentMode=1',
            'native-parameter-!tpf2_mp_1:townDevelopment=0','configured-dimensions-44x44']
        (self.root/'native.jsonl').write_text('\n'.join(json.dumps({'event':e}) for e in events))
        header = {'nativeHeaderWords':[0,1980,44,44,0,0,0]}
        self.addCleanup(patch.stopall)
        patch('tpf2mp.world_generation.save_facts',return_value=({'sha256':'a'*64,'bytes':1},
            [{'id':'!tpf2_mp','version':1}])).start()
        patch('tpf2mp.world_generation.read_active_mods',return_value=header).start()
        patch('tpf2mp.world_generation.build_save_sync_manifest',return_value=({'bundleId':'verified'},{})).start()
        return save, header

    def test_complete_engine_evidence_and_saved_policy_required(self):
        save, _ = self.completed_fixture()
        result = verify_generated(self.config,save,self.root,self.game,self.mod,'mp-0123456789abcdef')
        self.assertEqual(result['nativeHeaderWords'][2:4],[44,44])
        (self.root/'world.sav.lua').write_text('function data() return {economyDifficulty="normal"} end')
        with self.assertRaisesRegex(RelayApiError,'economy differs'):
            verify_generated(self.config,save,self.root,self.game,self.mod,'mp-0123456789abcdef')

    def test_wrong_dimensions_cannot_self_attest(self):
        save, header = self.completed_fixture()
        header['nativeHeaderWords'][2:4] = [32,32]
        path = self.root/'native.jsonl'
        path.write_text(path.read_text().replace('44x44','32x32'))
        with self.assertRaisesRegex(RelayApiError,'dimensions'):
            verify_generated(self.config,save,self.root,self.game,self.mod,'mp-0123456789abcdef')

    def test_missing_engine_parameter_rejects_save_ready(self):
        save, _ = self.completed_fixture()
        path = self.root/'native.jsonl'
        path.write_text(path.read_text().replace('townDevelopment=0','townDevelopment=1'))
        with self.assertRaisesRegex(RelayApiError,'settings were not fully observed'):
            verify_generated(self.config,save,self.root,self.game,self.mod,'mp-0123456789abcdef')

    def test_preview_is_required_for_generated_bundle(self):
        save, _ = self.completed_fixture()
        save.with_suffix('.jpg').unlink()
        with self.assertRaisesRegex(RelayApiError,'preview'):
            verify_generated(self.config,save,self.root,self.game,self.mod,'mp-0123456789abcdef')


if __name__ == "__main__": unittest.main()
