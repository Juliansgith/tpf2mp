"""The GUI harness must never turn missing/partial evidence into a green result."""
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from live_ui.schema import InvalidSuite, load_suite, validate_suite, sha256
from live_ui.oracle import GameFault, Pending, PhysicalRejection, agreed, verify
from live_ui.runner import Runner, select, postcondition
from live_ui.coverage import check_coverage
from live_ui.menu import scroll_step
from live_ui.desktop import Desktop, InfrastructureError


def pair(built=False):
    data = {"busy": False, "native": {"digest": "after" if built else "before", "inventoryComplete": True,
            "inventory": {"counts": {"constructions": {"construction": 1 if built else 0}}}},
            "bindings": {}, "snapshot": {
                "initialized": True, "digest": "same", "modelDigest": "same", "match": {"status": "running"},
                "probes": {"capture": {"proposalCodecFailureCount": 0}},
                "companies": {"company:1": {"balance": 900 if built else 1000}, "company:2": {"balance": 1000}},
                "proposalConsensus": {}, "operationConsensus": {}, "deferredNetworkQueue": {"count": 0},
                "checkpointConsensus": {"lastAgreed": {"boundarySeq": 2 if built else 1}}}}
    if built:
        data["bindings"] = {"construction:1": {"kind": "construction", "exists": True, "metadata": {"owner": "company:1"}}}
    return {"player1": copy.deepcopy(data), "player2": copy.deepcopy(data)}


BUILD = {"outcome": "built", "kind": "construction", "count": 1, "owner": "company:1",
         "finance": {"company:1": "debit", "company:2": "unchanged"}}


class OracleTests(unittest.TestCase):
    def test_existing_junction_recipe_cannot_pass_a_free_depot_or_micro_connector(self):
        recipe = load_suite(ROOT / 'content/live-ui/depot-existing-node.json')
        self.assertNotIn('calibrationIdleSeconds', recipe)
        expect = recipe['cases'][1]['expect']
        self.assertIs(expect['geometry'], True)
        before, after = pair(), pair(True)
        for peer in before:
            before[peer]['native']['inventory']['counts']['constructions']['depot'] = 0
            after[peer]['native']['inventory']['counts']['constructions']['depot'] = 1
            before[peer]['native']['inventory']['counts']['edges'] = {'node': 10, 'edge': 10}
            after[peer]['native']['inventory']['counts']['edges'] = {'node': 11, 'edge': 11}
            after[peer]['depotUi'] = {'missingName': 0}
        verify(before, after, expect)
        for peer in after:
            detached = copy.deepcopy(after)
            detached[peer]['native']['inventory']['counts']['edges']['node'] = 12
            with self.assertRaises(Pending): verify(before, detached, expect)
            residual = copy.deepcopy(after)
            residual[peer]['native']['inventory']['counts']['edges']['edge'] = 12
            with self.assertRaises(Pending): verify(before, residual, expect)

    def test_journey_records_busy_samples_but_fault_and_consensus_still_gate_pass(self):
        class Trace:
            def __init__(self): self.samples = 0
            def observe(self, _):
                self.samples += 1
                raise Pending('still travelling')
        trace = Trace()
        after = pair()
        after['player1']['busy'] = True
        with self.assertRaisesRegex(Pending, 'busy'):
            postcondition(pair(), after, {'outcome':'journey'}, trace)
        self.assertEqual(trace.samples, 1)
        after['player1']['snapshot']['proposalConsensus']['sessionFault'] = 'real-fault'
        with self.assertRaisesRegex(GameFault, 'real-fault'):
            postcondition(pair(), after, {'outcome':'journey'}, trace)
        self.assertEqual(trace.samples, 2)
        with self.assertRaisesRegex(Pending, 'travelling'):
            postcondition(pair(), pair(), {'outcome':'journey'}, trace)
    def test_collection_length_checks_both_peers(self):
        before, after = pair(), pair(True)
        for value in after.values():
            value["stops"] = ["A", "B"]
        expect = {**BUILD, "checks": [{"path": ["stops"], "op": "length", "value": 2}]}
        verify(before, after, expect)
        after["player2"]["stops"] = ["A"]
        with self.assertRaises(Pending):
            verify(before, after, expect)
        after["player2"]["stops"] = 2
        with self.assertRaisesRegex(Pending, "collection"):
            verify(before, after, expect)

    def test_codec_rejection_fails_promptly_but_old_failure_does_not(self):
        before, after = pair(), pair()
        after['player1']['snapshot']['probes']['capture'] = {'proposalCodecFailureCount': 1,
            'lastProposalCodecFailure': {'error': 'invalid edge'}}
        with self.assertRaisesRegex(PhysicalRejection, 'invalid edge'):
            verify(before, after, BUILD)
        before['player1']['snapshot']['probes']['capture'] = copy.deepcopy(after['player1']['snapshot']['probes']['capture'])
        with self.assertRaises(Pending): verify(before, after, BUILD)

    def test_missing_rejection_counter_cannot_be_assumed_zero(self):
        after = pair(True)
        del after['player2']['snapshot']['probes']
        with self.assertRaisesRegex(Pending, 'missing evidence field'):
            verify(pair(), after, BUILD)

    def test_real_bilateral_build_passes(self):
        verify(pair(), pair(True), BUILD)

    def test_native_rejection_fails_promptly_without_calling_it_a_session_fault(self):
        after = pair()
        for value in after.values():
            value["snapshot"]["proposalConsensus"]["lastOutcome"] = {
                "commitSeq": 2, "success": False, "errorCode": "native-proposal-rejected"}
        agreed(after)  # A recoverable rejection can leave a perfectly healthy pair.
        with self.assertRaisesRegex(PhysicalRejection, "native-proposal-rejected"):
            verify(pair(), after, BUILD)
        verify(pair(), after, {"outcome": "unchanged"})
        for value in after.values():
            value["snapshot"]["proposalConsensus"]["lastOutcome"]["commitSeq"] = 1
        with self.assertRaises(Pending):  # Old rejections must not poison later cases.
            verify(pair(), after, BUILD)

    def test_changed_requires_native_mutation_and_fresh_checkpoint(self):
        expect = {"outcome": "changed", "checks": [{"path": ["busy"], "op": "equal", "value": False}]}
        with self.assertRaisesRegex(Pending, "no physical change"):
            verify(pair(), pair(), expect)
        after = pair(True)
        for value in after.values():
            value["snapshot"]["checkpointConsensus"]["lastAgreed"]["boundarySeq"] = 1
        with self.assertRaisesRegex(Pending, "fresh checkpoint"):
            verify(pair(), after, expect)

    def test_equal_unchanged_worlds_cannot_pass_a_build(self):
        with self.assertRaisesRegex(Pending, "observed 0"):
            verify(pair(), pair(), BUILD)

    def test_origin_only_build_fails(self):
        after = pair(True); after["player2"] = pair()["player2"]
        with self.assertRaises(Pending):
            verify(pair(), after, BUILD)

    def test_placeholder_binding_is_not_physical_proof(self):
        after = pair(True)
        for value in after.values():
            value["bindings"]["construction:1"]["exists"] = False
        with self.assertRaises(Pending):
            verify(pair(), after, BUILD)

    def test_no_inventory_is_not_success(self):
        after = pair(True); del after["player2"]["native"]
        with self.assertRaises(Pending):
            verify(pair(), after, BUILD)

    def test_deleted_binding_without_native_deletion_fails(self):
        after = pair()
        for value in after.values():
            value["native"]["inventory"]["counts"]["constructions"]["construction"] = 1
        with self.assertRaisesRegex(Pending, "native construction inventory"):
            verify(pair(True), after, {"outcome": "deleted", "kind": "construction"})

    def test_duplicate_station_is_a_failure(self):
        after = pair(True)
        for value in after.values():
            value["bindings"]["construction:2"] = value["bindings"]["construction:1"]
        with self.assertRaisesRegex(Pending, "observed 2"):
            verify(pair(), after, BUILD)

    def test_no_fresh_checkpoint_fails(self):
        after = pair(True)
        for value in after.values():
            value["snapshot"]["checkpointConsensus"]["lastAgreed"]["boundarySeq"] = 1
        with self.assertRaisesRegex(Pending, "fresh checkpoint"):
            verify(pair(), after, BUILD)

    def test_wrong_owner_and_wrong_wallet_fail(self):
        for corrupt in ("owner", "wallet"):
            with self.subTest(corrupt=corrupt):
                after = pair(True)
                for value in after.values():
                    if corrupt == "owner":
                        value["bindings"]["construction:1"]["metadata"]["owner"] = "company:2"
                    else:
                        value["snapshot"]["companies"]["company:2"]["balance"] = 900
                with self.assertRaises(Pending):
                    verify(pair(), after, BUILD)

    def test_fault_is_terminal_not_retryable(self):
        after = pair(True)
        after["player2"]["snapshot"]["operationConsensus"]["sessionFault"] = {"errorCode": "timeout"}
        with self.assertRaises(GameFault):
            agreed(after)

    def test_not_run_and_blocked_are_red_in_junit(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = Runner({"session": "localhost-ui-test", "player1GamePid": 1, "player2GamePid": 2}, "a"*32,
                            {"id": "empty", "cases": [{"id": "one"}, {"id": "two"}]}, Path(temporary)/"out",
                            desktop_factory=lambda _: (_ for _ in ()).throw(RuntimeError("no desktop")))
            self.assertEqual(runner.run(), 1)
            report = json.loads((runner.output/"report.json").read_text())
            self.assertFalse(report["passed"])
            self.assertEqual([c["status"] for c in report["cases"]], ["NOT_RUN", "NOT_RUN"])
            self.assertIn('failures="2"', (runner.output/"junit.xml").read_text())


class SchemaTests(unittest.TestCase):
    def test_bounded_construction_modifiers_and_height_keys(self):
        suite = copy.deepcopy(self.suite)
        step = {'peer':'player1', 'action':'key', 'key':'period', 'modifiers':['shift']}
        suite['cases'][0]['steps'] = [step]
        validate_suite(suite)
        for key in ('comma', 'm', 'n'):
            step['key'] = key
            validate_suite(suite)
        for modifiers in (['shift','shift'], ['alt'], ['ctrl'], 'shift', [], ['c','shift','c']):
            step['modifiers'] = modifiers
            with self.assertRaises(InvalidSuite): validate_suite(suite)
        step.update(key='c', modifiers=['c'])
        with self.assertRaisesRegex(InvalidSuite, 'conflicts'): validate_suite(suite)

    def test_all_native_carriers_and_journey_only_extended_timeout(self):
        suite = copy.deepcopy(self.suite)
        case = suite['cases'][0]
        case['expect'] = {'outcome':'journey', 'journey':{'lineName':'Test',
            'owner':'company:1', 'vehicles':1, 'stops':2, 'carrier':4, 'models':['vehicle/ship/test.mdl']}}
        case['timeout'] = 1200
        for carrier in range(5):
            case['expect']['journey']['carrier'] = carrier
            validate_suite(suite)
        for carrier in (-1, 5, True, 4.0):
            case['expect']['journey']['carrier'] = carrier
            with self.assertRaises(InvalidSuite): validate_suite(suite)
        case['expect'] = {'outcome':'unchanged'}
        with self.assertRaisesRegex(InvalidSuite, 'only native journeys'): validate_suite(suite)
        case['timeout'] = 600
        validate_suite(suite)

    def test_road_journey_cannot_confuse_bus_and_truck(self):
        suite = copy.deepcopy(self.suite)
        suite['cases'][0]['expect'] = {'outcome':'journey', 'journey':{
            'lineName':'Test', 'owner':'company:1', 'vehicles':1, 'stops':2, 'carrier':0}}
        with self.assertRaisesRegex(InvalidSuite, 'distinguish buses and trucks'):
            validate_suite(suite)
        spec = suite['cases'][0]['expect']['journey']
        spec['models'] = ['vehicle/bus/test.mdl']
        validate_suite(suite)
        for models in ([], [''], [None], 'vehicle/bus/test.mdl'):
            spec['models'] = models
            with self.assertRaises(InvalidSuite): validate_suite(suite)

    def test_explicit_double_click_is_two_released_physical_presses(self):
        from types import SimpleNamespace
        events = []
        desktop = Desktop.__new__(Desktop)
        desktop.focus = lambda peer: 1
        desktop.check = lambda peer, focused=False: 1
        desktop.u = SimpleNamespace(mouse_event=lambda flag, *args: events.append(flag))
        with patch("live_ui.desktop.time.sleep"):
            desktop.input("player1", {"action": "doubleClick"})
        self.assertEqual(events, [2, 4, 2, 4])
        suite = copy.deepcopy(self.suite)
        suite["cases"][0]["steps"][0]["action"] = "doubleClick"
        validate_suite(suite)

    def test_save_rows_must_be_inside_native_scroll_viewport(self):
        status = {"stage": "ready-to-click-pinned-save", "components": {
            "expectedSave": "fixture", "expectedSaveRect": {"x": 20, "y": -4000, "w": 20, "h": 10},
            "expectedSaveClipRect": {"x": 10, "y": 10, "w": 60, "h": 70},
            "menuRect": {"x": 0, "y": 0, "w": 100, "h": 100}}}
        self.assertEqual(scroll_step(status, "fixture"), {"action": "wheel", "point": [.4, .45], "delta": 2400})
        status["components"]["expectedSaveRect"]["y"] = 30
        self.assertIsNone(scroll_step(status, "fixture"))
        status["components"]["expectedSaveRect"]["y"] = 1000
        self.assertLess(scroll_step(status, "fixture")["delta"], 0)
        with self.assertRaises(InfrastructureError): scroll_step(status, "different")
        status["components"]["expectedSaveClipRect"] = None
        with self.assertRaises(InfrastructureError): scroll_step(status, "fixture")

    def test_global_integrity_failure_is_red_in_junit(self):
        with tempfile.TemporaryDirectory() as temporary:
            runner = Runner({"session": "localhost-ui-test"}, "a" * 32,
                            {"id": "integrity", "cases": []}, Path(temporary)/"out")
            runner.results = [{"id": "one", "status": "PASS"}]
            runner.junit({"suite": "integrity", "passed": False, "seconds": 1,
                          "error": "source changed"})
            xml = (runner.output/"junit.xml").read_text()
            self.assertIn('failures="1"', xml)
            self.assertIn('suite-integrity', xml)

    def setUp(self):
        self.suite = load_suite(ROOT/"content/live-ui/ui-smoke.json")

    def test_smoke_is_explicitly_not_construction_coverage(self):
        self.assertTrue(all(c["expect"]["outcome"] == "unchanged" for c in self.suite["cases"]))

    def test_all_checked_in_recipes_validate_without_launching(self):
        for path in sorted((ROOT / "content/live-ui").glob("*.json")):
            if path.name == "required-coverage.json":
                continue
            with self.subTest(recipe=path.name):
                load_suite(path)

    def test_owner_cannot_be_silently_ignored_on_changed_outcome(self):
        self.suite["cases"][0]["expect"] = {"outcome":"changed", "owner":"company:1",
            "checks":[{"path":["busy"], "op":"equal", "value":False}]}
        with self.assertRaisesRegex(InvalidSuite, "owner assertions"):
            validate_suite(self.suite)

    def test_arbitrary_code_and_maximize_are_rejected(self):
        for op in ("custom", "lua", "operation.execute", "maximize", "shell"):
            with self.subTest(op=op):
                s = copy.deepcopy(self.suite); s["cases"][0]["steps"][0]["action"] = op
                with self.assertRaises(InvalidSuite): validate_suite(s)

    def test_coordinates_need_save_pin(self):
        self.suite["cases"][0]["steps"] = [{"peer": "player1", "action": "click", "point": [.5,.5]}]
        with self.assertRaisesRegex(InvalidSuite, "pinned save"): validate_suite(self.suite)

    def test_wrong_fixture_rejected(self):
        self.suite["saveSha256"] = "a"*64
        with tempfile.TemporaryDirectory() as root:
            save = Path(root)/"fixture.sav"; save.write_bytes(b"fixture")
            with self.assertRaisesRegex(InvalidSuite, "differs"): validate_suite(self.suite, save)
            self.suite["saveSha256"] = sha256(save)
            validate_suite(self.suite, save)

    def test_empty_suite_duplicate_case_and_assertion_free_change_rejected(self):
        for edit in (lambda s: s.update(cases=[]), lambda s: s["cases"].append(s["cases"][0]),
                     lambda s: s["cases"][0].update(expect={"outcome": "changed"})):
            s = copy.deepcopy(self.suite); edit(s)
            with self.assertRaises(InvalidSuite): validate_suite(s)

    def test_selector_ambiguity_hidden_and_offscreen_fail(self):
        node = {"id": "buy", "visible": True, "enabled": True, "rect": {"x": 10,"y": 10,"w": 10,"h": 10}}
        tree = {"viewport": {"x":0,"y":0,"w":100,"h":100}, "nodes": [node]}
        self.assertEqual(select(tree, {"id":"buy"}), [.15,.15])
        tree["nodes"].append(copy.deepcopy(node))
        with self.assertRaises(Pending): select(tree, {"id":"buy"})
        tree["nodes"].pop(); node["visible"] = False
        with self.assertRaises(Pending): select(tree, {"id":"buy"})
        node["visible"] = True; node["rect"]["x"] = 110
        with self.assertRaises(Pending): select(tree, {"id":"buy"})

    def test_truncated_tree_does_not_prove_unique_text_or_absence(self):
        tree = {"truncated": True, "viewport": {"x":0,"y":0,"w":100,"h":100}, "nodes": [
            {"id":"buy", "text":"Buy", "visible":True, "enabled":True,
             "rect":{"x":10,"y":10,"w":10,"h":10}}]}
        with self.assertRaisesRegex(InfrastructureError, "unique"):
            select(tree, {"text":"Buy"})
        self.assertEqual(select(tree, {"id":"buy"}), [.15,.15])
        runner = Runner.__new__(Runner)
        runner.observer = type("StubObserver", (), {"request": lambda *args, **kw: tree})()
        with self.assertRaisesRegex(InfrastructureError, "absent"):
            runner.step({"peer":"player1", "action":"waitUi", "selector":{"text":"Missing"}, "absent":True})


class CoverageTests(unittest.TestCase):
    def test_ui_fixture_has_no_competing_automatic_save_input(self):
        source = (ROOT/'tools/run_localhost_live_validation.ps1').read_text()
        self.assertIn("if ($LiveUiSuite) { $arguments += '-DisableUiSaveFallback' }", source)
        self.assertIn("if ($LiveUiSuite) { $hostArgs += @('--automatic-recovery-interval', '0') }", source)

    def test_supervisor_invokes_runner_after_manual_ready_and_requires_report(self):
        source = (ROOT/"tools/run_localhost_live_validation.ps1").read_text()
        self.assertGreater(source.index("--suite $LiveUiSuite"), source.index('Write-Host "MANUAL LAB READY'))
        self.assertIn('no UI report was produced; bootstrap is not gameplay proof', source)

    def test_stale_synthetic_failed_and_missing_evidence_fail(self):
        report = {"proof":"physical-ui-input", "passed":True, "sourceFingerprint":"current",
                  "supervisorVerified":True,
                  "cases":[{"status":"PASS", "coverage":["station"]}]}
        self.assertEqual(check_coverage(["station"], [report], "current"), ["station"])
        for mutation in ({"sourceFingerprint":"old"}, {"proof":"replay"}, {"passed":False}, {"cases":[]},
                         {"supervisorVerified":False}):
            with self.assertRaises(ValueError): check_coverage(["station"], [dict(report, **mutation)], "current")
        with self.assertRaises(ValueError): check_coverage(["station", "depot"], [report], "current")


if __name__ == "__main__":
    unittest.main()
