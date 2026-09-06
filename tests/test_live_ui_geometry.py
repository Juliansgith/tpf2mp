import copy
import math
import unittest
from tools.live_ui.geometry import verify_geometry
from tools.live_ui.oracle import Pending
from tools.live_ui.schema import InvalidSuite, validate_suite


def pair(tracks=0, span=160, gap=0, axis=(1, 0)):
    edges = {}
    for track in range(tracks):
        for index, (start, end) in enumerate(((0, span / 2), (span / 2 + gap, span))):
            def point(distance):
                x = axis[0] * distance - axis[1] * track * 5
                y = axis[1] * distance + axis[0] * track * 5
                return {'position': [x * 10, y * 10, 0]}
            edges[f'edge:{track}:{index}'] = {'carrier': {'kind': 'track'},
                'endpoints': [point(start), point(end)]}
    result = {'geometry': {'schemaVersion': 1, 'complete': True, 'count': len(edges), 'edges': edges}}
    return {'player1': copy.deepcopy(result), 'player2': copy.deepcopy(result)}


class GeometryTests(unittest.TestCase):
    spec = {'axis': [1, 0], 'tracks': 8, 'span': 160, 'tolerance': .25}

    def test_eight_physical_parallel_tracks(self):
        result = verify_geometry(pair(), pair(8), self.spec)
        self.assertEqual(len(result['player1']), 8)
        self.assertEqual(result['player1'][0]['span'], 160)

    def test_identically_wrong_two_tracks_on_both_peers_rejected(self):
        with self.assertRaisesRegex(Pending, 'observed 2'):
            verify_geometry(pair(), pair(2), self.spec)

    def test_identically_wrong_length_rejected(self):
        with self.assertRaisesRegex(Pending, 'observed 80'):
            verify_geometry(pair(), pair(8, span=80), self.spec)

    def test_gap_and_overlap_are_not_full_length_proof(self):
        for gap in (1, -1):
            with self.subTest(gap=gap), self.assertRaisesRegex(Pending, 'gap or overlapping'):
                verify_geometry(pair(), pair(8, gap=gap), self.spec)

    def test_bilateral_geometry_mismatch_rejected(self):
        after = pair(8)
        after['player2']['geometry']['edges']['edge:0:0']['endpoints'][0]['position'][0] = 20
        with self.assertRaisesRegex(Pending, 'differs'):
            verify_geometry(pair(), after, self.spec)

    def test_incomplete_inventory_cannot_pass_empty_map(self):
        after = pair()
        after['player1']['geometry']['complete'] = False
        with self.assertRaisesRegex(Pending, 'complete native'):
            verify_geometry(pair(), after)

    def test_rotated_layout_uses_expected_axis(self):
        axis = [math.sqrt(.5), math.sqrt(.5)]
        verify_geometry(pair(), pair(8, axis=axis), {**self.spec, 'axis': axis})

    def test_schema_rejects_loose_or_unbounded_layout(self):
        suite = {'schemaVersion': 1, 'id': 'geometry-test', 'cases': [
            {'id': 'station', 'steps': [{'peer': 'player1', 'action': 'observe'}],
             'expect': {'outcome': 'built', 'kind': 'construction', 'railLayout': self.spec}}]}
        validate_suite(suite)
        for change in ({'tracks': True}, {'tracks': 1000}, {'axis': [1, 1]},
                       {'tolerance': 10}, {'span': float('nan')}, {'callback': 'hidden'}):
            broken = copy.deepcopy(suite)
            broken['cases'][0]['expect']['railLayout'].update(change)
            with self.subTest(change=change), self.assertRaises(InvalidSuite):
                validate_suite(broken)

    def test_runner_requests_read_only_geometry_from_both_peers(self):
        from tools.live_ui.runner import Observer
        observer = Observer({}, 'token', '.', None)
        requests = []
        observer.geometry = True
        observer.request = lambda peer, channel, **extra: requests.append((peer, channel, extra))
        observer.pair()
        self.assertEqual(sorted(requests), [('player1', 'world', {'geometry': True}),
                                           ('player2', 'world', {'geometry': True})])


if __name__ == '__main__': unittest.main()
