"""Terrain labels require actual height changes, not a sloped screenshot."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from live_ui.oracle import Pending
from live_ui.terrain import verify_terrain
from live_ui.schema import validate_suite, InvalidSuite


class TerrainProofTests(unittest.TestCase):
    def setUp(self):
        self.spec = dict(bounds=[0, 0, 10, 10], grid=2,
                         minDelta=.1, minSamples=2, tolerance=.02)
        self.before = {p: dict(terrain=dict(bounds=[0, 0, 10, 10], grid=2,
                                         heights=[1, 1, 1, 1]))
                       for p in ('player1', 'player2')}
        self.after = copy.deepcopy(self.before)
        for data in self.after.values():
            data['terrain']['heights'] = [1.25, 1.25, 1, 1]

    def test_bilateral_height_change(self):
        verify_terrain(self.before, self.after, self.spec)

    def test_equal_worlds_without_terraforming_do_not_pass(self):
        with self.assertRaises(Pending):
            verify_terrain(self.before, self.before, self.spec)

    def test_disagreement_before_or_after_is_not_terrain_proof(self):
        for sample in (self.before, self.after):
            sample['player2']['terrain']['heights'][0] += .03
            with self.assertRaises(Pending):
                verify_terrain(self.before, self.after, self.spec)
            sample['player2']['terrain']['heights'][0] -= .03

    def test_partial_wrong_grid_or_nonfinite_evidence_rejected(self):
        for replacement in (None, {}, dict(bounds=[0, 0, 10, 10], grid=2, heights=[1]),
                            dict(bounds=[1, 0, 10, 10], grid=2, heights=[1]*4),
                            dict(bounds=[0, 0, 10, 10], grid=2, heights=[float('nan')]*4),
                            dict(bounds=[0, 0, 10, 10], grid=2, heights=[True]*4)):
            pair = copy.deepcopy(self.after)
            pair['player2']['terrain'] = replacement
            with self.assertRaises(Pending):
                verify_terrain(self.before, pair, self.spec)

    def test_different_changed_points_on_each_peer_rejected(self):
        # Tolerance must not let each peer independently satisfy a different mask.
        self.spec.update(minDelta=.1, minSamples=2, tolerance=.02)
        self.after['player1']['terrain']['heights'] = [1.11, 1.11, 1.09, 1.09]
        self.after['player2']['terrain']['heights'] = [1.09, 1.09, 1.11, 1.11]
        with self.assertRaises(Pending):
            verify_terrain(self.before, self.after, self.spec)

    def test_terrain_recipe_is_bounded_and_needs_pinned_map(self):
        suite = dict(schemaVersion=1, id='terrain', saveSha256='a'*64,
                     viewport=dict(w=1920, h=1040), cases=[dict(id='build',
                     steps=[dict(peer='player1', action='observe')],
                     expect=dict(outcome='built', kind='construction', terrain=self.spec))])
        validate_suite(suite)
        for field, value in [('grid', 10), ('grid', True), ('minSamples', 5),
                             ('minDelta', 0), ('tolerance', .2),
                             ('bounds', [0, 0, 0, 10]), ('bounds', [0, 0, float('inf'), 1])]:
            changed = copy.deepcopy(suite)
            changed['cases'][0]['expect']['terrain'][field] = value
            with self.assertRaises(InvalidSuite):
                validate_suite(changed)
        for field in ('saveSha256', 'viewport'):
            changed = copy.deepcopy(suite)
            del changed[field]
            with self.assertRaises(InvalidSuite):
                validate_suite(changed)

    def test_runner_forwards_only_read_only_terrain_grid(self):
        from live_ui.runner import Observer
        observer = object.__new__(Observer)
        observer.terrain = self.spec
        observer.geometry = False
        requests = []
        def request(peer, channel, **extra):
            requests.append((peer, channel, extra))
            return {}
        observer.request = request
        observer.pair()
        self.assertEqual(len(requests), 2)
        for _, channel, extra in requests:
            self.assertEqual(channel, 'world')
            self.assertEqual(extra, dict(terrain=dict(bounds=[0, 0, 10, 10], grid=2)))


if __name__ == '__main__':
    unittest.main()
