import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
from live_ui.batch import execute


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.save = self.root/'fixture.sav'; self.save.write_bytes(b'fixture')
        self.paths = []
        for index in range(2):
            suite = {'schemaVersion': 1, 'id': f'suite-{index}', 'cases': [
                {'id': 'observe', 'steps': [{'peer': 'player1', 'action': 'observe'}],
                 'expect': {'outcome': 'unchanged'}}]}
            path = self.root/f'suite-{index}.json'; path.write_text(json.dumps(suite)); self.paths.append(path)
        self.calls = []

    def run_batch(self, outcomes, cleanup=True, receipt=True, stop_after_first=False):
        def child(args, **kwargs):
            index = len(self.calls); self.calls.append(args)
            if stop_after_first:
                (self.root/'batch/STOP').touch()
            target = Path(args[args.index('-ResultPath')+1])
            result = target.with_name(f'result-{index}.json')
            result.write_text(json.dumps({'suite': f'suite-{index}', 'session': f'localhost-ui-{index}',
                'sourceFingerprint': 'fixed', 'passed': outcomes[index], 'proof': 'physical-ui-input',
                'supervisorVerified': True}))
            if receipt:
                target.write_text(json.dumps({'session': f'localhost-ui-{index}', 'report': str(result),
                    'runStatus': 'status.json', 'cleanupComplete': cleanup}))
            return subprocess.CompletedProcess(args, 0 if outcomes[index] else 1)
        with patch('live_ui.batch.source_fingerprint', return_value='fixed'):
            return execute(self.root, self.save, self.paths, self.root/'batch', run=child)

    def test_fresh_pair_per_suite_and_static_gate_once(self):
        self.assertEqual(self.run_batch([True, True]), 0)
        self.assertEqual(len(self.calls), 2)
        self.assertNotIn('-SkipStaticGate', self.calls[0]); self.assertIn('-SkipStaticGate', self.calls[1])
        self.assertNotEqual(self.calls[0][-1], self.calls[1][-2])

    def test_failure_retained_even_if_next_fresh_suite_passes(self):
        self.assertEqual(self.run_batch([False, True]), 1)
        report = json.loads((self.root/'batch/report.json').read_text())
        self.assertEqual([r['status'] for r in report['runs']], ['FAIL', 'PASS'])
        self.assertFalse(report['passed'])

    def test_cleanup_not_proven_stops_next_launch(self):
        self.assertEqual(self.run_batch([True, True], cleanup=False), 1)
        self.assertEqual(len(self.calls), 1)
        report = json.loads((self.root/'batch/report.json').read_text())
        self.assertEqual(report['runs'][1]['status'], 'NOT_RUN')

    def test_missing_receipt_stops_next_launch(self):
        self.assertEqual(self.run_batch([True, True], receipt=False), 1)
        self.assertEqual(len(self.calls), 1)

    def test_stop_waits_for_current_supervisor_cleanup_then_leaves_rest_unrun(self):
        self.assertEqual(self.run_batch([True, True], stop_after_first=True), 1)
        self.assertEqual(len(self.calls), 1)
        report = json.loads((self.root/'batch/report.json').read_text())
        self.assertEqual([r['status'] for r in report['runs']], ['PASS', 'NOT_RUN'])
        self.assertIn('operator requested', report['stopped'])

    def test_malformed_second_suite_prevents_all_launches(self):
        self.paths[1].write_text('{"schemaVersion": 999}')
        with self.assertRaises(ValueError): self.run_batch([True, True])
        self.assertEqual(self.calls, [])


if __name__ == '__main__': unittest.main()
