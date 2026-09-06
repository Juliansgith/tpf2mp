import copy
import unittest
from pathlib import Path

from tools.live_ui.oracle import validate_before_input
from tools.live_ui.schema import load_suite, validate_suite, InvalidSuite


class NumericEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.check = {'path': ['counts', 'edge'], 'op': 'deltaAtLeast', 'value': 1}
        self.expect = {'checks': [self.check]}
        self.pair = {p: {'counts': {'edge': 0}} for p in ('player1', 'player2')}

    def test_numeric_delta_preflight(self):
        validate_before_input(self.pair, self.expect)

    def test_collection_path_rejected_before_input(self):
        self.check['path'] = ['counts']
        with self.assertRaisesRegex(ValueError, 'numeric before input'):
            validate_before_input(self.pair, self.expect)

    def test_both_peers_and_finite_nonboolean_numbers_required(self):
        for invalid in (True, None, [], {}, '0', float('nan'), float('inf')):
            with self.subTest(invalid=invalid):
                self.pair['player2']['counts']['edge'] = invalid
                with self.assertRaises(ValueError):
                    validate_before_input(self.pair, self.expect)

    def test_future_nondelta_field_not_required_yet(self):
        self.check.update(path=['not-created-yet'], op='length')
        validate_before_input(self.pair, self.expect)

    def test_closed_numeric_recipe_expectations(self):
        root = Path(__file__).resolve().parents[1]
        base = load_suite(root/'content/live-ui/track-build.json')
        for invalid in (True, {}, '1', float('nan'), float('inf')):
            recipe = copy.deepcopy(base)
            recipe['cases'][1]['expect']['checks'][0]['value'] = invalid
            with self.subTest(invalid=invalid), self.assertRaises(InvalidSuite):
                validate_suite(recipe)

    def test_preflight_is_before_input_dispatch(self):
        # Source-order contract supplements the pure validation cases.
        source = (Path(__file__).resolve().parents[1]/'tools/live_ui/runner.py').read_text()
        self.assertLess(source.index("validate_before_input(before, case['expect'])"),
                        source.index('for index, step in enumerate(case["steps"]):'))


if __name__ == '__main__':
    unittest.main()
