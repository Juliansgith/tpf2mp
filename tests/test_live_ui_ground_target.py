import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
import math
import unittest
from live_ui.ground_target import locate, TargetingError


class GroundTargetTests(unittest.TestCase):
    def test_rotated_scaled_ground_projection(self):
        def sample(p): return [1000*p[1]-2200, 1400*p[0]-1700, 7]
        wanted = sample((.71, .22))
        result = locate(wanted[:2], sample)
        self.assertLess(math.dist(result['point'], (.71, .22)), .0001)
        self.assertGreaterEqual(len(result['samples']), 5)

    def test_perspective_ground_projection(self):
        def sample(p): return [(p[0]-.5)*1000/(1+.5*p[1]), 800*p[1]/(1+.5*p[1]), 8]
        target = sample((.80, .62))
        result = locate(target[:2], sample)
        self.assertLess(math.dist(result['world'][:2], target[:2]), .15)

    def test_stale_cursor_does_not_lead_to_a_guessed_click(self):
        with self.assertRaisesRegex(TargetingError, 'stale'):
            locate([1, 2], lambda p: [0, 0, 0])

    def test_nonfinite_unreachable_and_invalid_inputs_fail_closed(self):
        for value in (None, [0, 0], [0, 0, float('nan')], [True, 0, 0]):
            with self.assertRaises(TargetingError): locate([1, 2], lambda p: value)
        with self.assertRaises(TargetingError): locate([100, 100], lambda p: [*p, 0])
        with self.assertRaises(TargetingError): locate([1, 2], lambda p: [*p, 0], max_reads=100)

    def test_at_target_still_requires_a_second_matching_sample(self):
        values = iter(([1, 2, 3], [4, 5, 6]))
        with self.assertRaisesRegex(TargetingError, 'changed'):
            locate([1, 2], lambda p: next(values))


if __name__ == '__main__': unittest.main()
