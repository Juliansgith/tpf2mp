import sys
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from live_ui.ground_input import perform
from live_ui.ground_target import TargetingError
from live_ui.schema import InvalidSuite, validate_step, validate_suite


class FakeDesktop:
    def __init__(self): self.inputs = []; self.last_input_point = None
    def input(self, peer, step):
        self.inputs.append(step)
        self.last_input_point = step.get('point')


class GroundInputTests(unittest.TestCase):
    def test_ground_steps_are_closed_and_require_pinned_fixture(self):
        step = {'peer':'player1','action':'clickGround','world':[12,34]}
        validate_step(step)
        for extra in ({'world':[float('nan'),0]}, {'callback':'buy'}, {'modifiers':['shift']},
                      {'tolerance':100}, {'world':[1,2,3]}, {'action':'nativeBuild'}):
            with self.assertRaises(InvalidSuite): validate_step({**step,**extra})
        suite = {'schemaVersion':1,'id':'ground','cases':[{'id':'target','steps':[step],
                                                       'expect':{'outcome':'unchanged'}}]}
        with self.assertRaisesRegex(InvalidSuite,'pinned save'): validate_suite(suite)
        suite.update(saveSha256='a'*64,viewport={'w':1920,'h':1040})
        validate_suite(suite)

    def setup_runner(self, path, stale=False, native_error=False):
        desktop = FakeDesktop(); frame = 0
        def request(peer, channel, **options):
            nonlocal frame
            self.assertEqual((channel, options), ('gui', {'rootId':'mainView','includeGround':True}))
            if native_error: raise RuntimeError('game stopped answering')
            frame += int(not stale)
            x,y = desktop.last_input_point
            return {'groundCursor': {'frame': frame, 'world': [100*x, 100*y, 10]}}
        return SimpleNamespace(desktop=desktop, observer=SimpleNamespace(request=request), output=path)

    def test_click_after_verified_moves_and_complete_receipt(self):
        with tempfile.TemporaryDirectory() as path:
            runner = self.setup_runner(path)
            perform(runner, {'peer':'player2','action':'clickGround','world':[40,30]})
            presses = [s for s in runner.desktop.inputs if s['action'] != 'move']
            self.assertEqual(len(presses), 1)
            self.assertEqual(presses[0]['action'], 'click')
            self.assertAlmostEqual(presses[0]['point'][0], .4)
            receipt = json.loads(next(Path(path).glob('*.json')).read_text())
            self.assertTrue(receipt['issued']); self.assertGreater(len(receipt['samples']), 3)

    def test_drag_targets_both_ends_before_single_press(self):
        with tempfile.TemporaryDirectory() as path:
            runner = self.setup_runner(path)
            perform(runner, {'peer':'player1','action':'dragGround','world':[30,30],'toWorld':[70,60]})
            presses = [s for s in runner.desktop.inputs if s['action'] != 'move']
            self.assertEqual(len(presses), 1)
            self.assertEqual(presses[0]['action'], 'drag')
            self.assertAlmostEqual(presses[0]['to'][1], .6)

    def test_no_press_after_stale_missing_or_unreachable_readback(self):
        for stale, native_error, target in [(True,False,[40,30]),(False,True,[40,30]),(False,False,[999,999])]:
            with self.subTest(stale=stale,native_error=native_error), tempfile.TemporaryDirectory() as path:
                runner = self.setup_runner(path, stale, native_error)
                with self.assertRaises((TargetingError, RuntimeError)):
                    perform(runner, {'peer':'player1','action':'clickGround','world':target})
                self.assertTrue(all(s['action']=='move' for s in runner.desktop.inputs))
                receipt=json.loads(next(Path(path).glob('*.json')).read_text())
                self.assertIn('error',receipt); self.assertNotIn('issued',receipt)


if __name__ == '__main__': unittest.main()
