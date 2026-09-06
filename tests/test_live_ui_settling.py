import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from live_ui.finalize import finalize, CLEANUP_FLAGS
from live_ui.oracle import Pending
from live_ui.settling import paused_and_settled, require_normal_speed
from live_ui.runner import Runner
from test_live_ui_suite import pair


class SettlingTests(unittest.TestCase):
    def ready(self):
        data = pair()
        for p in data:
            data[p]['snapshot']['networkClock'] = dict(requestedSpeed=0, effectiveSpeed=0)
        data['player1']['snapshot']['bridge'] = dict(companion=dict(
            connected=True, clock=dict(pauseAcknowledged=True), anchorReady=True))
        return data

    def test_ready_is_bilateral_pause_plus_ordered_quiescence(self):
        data = self.ready()
        paused_and_settled(data)
        for peer in data:
            for field in ('requestedSpeed', 'effectiveSpeed'):
                edited = copy.deepcopy(data)
                edited[peer]['snapshot']['networkClock'][field] = 4
                with self.assertRaises(Pending):
                    paused_and_settled(edited)
        for field in ('connected', 'anchorReady'):
            edited = copy.deepcopy(data)
            edited['player1']['snapshot']['bridge']['companion'][field] = False
            with self.assertRaises(Pending):
                paused_and_settled(edited)
        data['player1']['snapshot']['bridge']['companion']['clock']['pauseAcknowledged'] = False
        with self.assertRaises(Pending):
            paused_and_settled(data)

    def run_finalizer(self, passed=True, cleanup=True, identity=True, closed=True, settled=True):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            report = dict(schemaVersion=1, session='localhost-ui-test', suite='bus', passed=True,
                          shutdownSettled=settled, seconds=1, cases=[dict(id='journey', status='PASS')])
            status = dict(session='localhost-ui-test' if identity else 'wrong', passed=passed,
                          failure=None if passed else 'one commit awaits peer digests')
            status.update({flag: cleanup for flag in CLEANUP_FLAGS})
            (root/'report.json').write_text(json.dumps(report))
            (root/'status.json').write_text(json.dumps(status))
            valid = finalize(root/'report.json', root/'status.json', closed)
            final = json.loads((root/'report.json').read_text())
            return valid, final, (root/'junit.xml').read_text()

    def test_outer_unsettled_audit_cannot_be_hidden_by_inner_pass(self):
        valid, report, xml = self.run_finalizer(passed=False)
        self.assertFalse(valid)
        self.assertTrue(report['uiCasesPassed'])
        self.assertFalse(report['passed'])
        self.assertFalse(report['supervisorVerified'])
        self.assertIn('one commit', report['error'])
        self.assertIn('suite-integrity', xml)

    def test_shutdown_is_not_a_save_anchor_but_never_ignores_pending_work(self):
        data = self.ready()
        host = data['player1']['snapshot']['bridge']['companion']
        host['anchorReady'] = False
        host['anchorReasons'] = ['work has been ordered since the last converged checkpoint']
        paused_and_settled(data)
        for reason in ('1 ordered action(s) are still settling', 'player2 still has local ordered work pending',
                       'player2 anchor-readiness health is stale', 'unknown future safety condition'):
            host['anchorReasons'].append(reason)
            with self.assertRaises(Pending): paused_and_settled(data)
            host['anchorReasons'].pop()
        for missing in ([], None):
            host['anchorReasons'] = missing
            with self.assertRaises(Pending): paused_and_settled(data)

    def test_initially_paused_fixture_still_clicks_pause_before_verification(self):
        with tempfile.TemporaryDirectory() as folder:
            runner = object.__new__(Runner)
            runner.observer = Mock(terrain=None)
            runner.output = Path(folder)
            runner.lab = {}
            runner.stable = Mock(return_value=self.ready())
            runner.step = Mock()
            runner.settle_shutdown()
            runner.step.assert_called_once_with({'peer': 'player1', 'action': 'click',
                                                 'selector': {'id': 'menu.speedButton0'}})
            self.assertTrue((runner.output/'shutdown-settled.json').exists())

    def test_finalizer_requires_every_cleanup_and_boundary_condition(self):
        for key in ('cleanup', 'identity', 'closed', 'settled'):
            self.assertFalse(self.run_finalizer(**{key: False})[0])
        valid, report, _ = self.run_finalizer()
        self.assertTrue(valid and report['passed'] and report['supervisorVerified'])

    def test_generation_zero_uses_real_unpause_then_pause(self):
        with tempfile.TemporaryDirectory() as folder:
            initial = self.ready()
            initial['player1']['snapshot']['bridge']['companion']['clock']['generation'] = 0
            runner = object.__new__(Runner)
            runner.observer, runner.output, runner.lab = Mock(terrain=None), Path(folder), {}
            runner.stable, runner.step = Mock(return_value=initial), Mock()
            runner.settle_shutdown()
            self.assertEqual([c.args[0]['selector']['id'] for c in runner.step.call_args_list],
                             ['menu.speedButton1', 'menu.speedButton0'])
            self.assertIs(runner.stable.call_args_list[1].args[1], require_normal_speed)

    def test_initial_unpause_must_be_accepted_on_both_peers(self):
        data = self.ready()
        data['player1']['snapshot']['bridge']['companion']['clock']['generation'] = 1
        for peer in data:
            data[peer]['snapshot']['networkClock'].update(requestedSpeed=1, effectiveSpeed=1)
        require_normal_speed(data)
        data['player2']['snapshot']['networkClock']['effectiveSpeed'] = 0
        with self.assertRaises(Pending): require_normal_speed(data)


if __name__ == '__main__':
    unittest.main()
