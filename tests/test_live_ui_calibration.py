import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from live_ui.calibration import next_case
from live_ui.coverage import check_coverage


class CalibrationTests(unittest.TestCase):
    def suite(self):
        return {"schemaVersion": 1, "id": "calibration", "calibrationIdleSeconds": 10,
                "cases": [{"id": "first", "steps": [{"peer": "player1", "action": "observe"}],
                           "expect": {"outcome": "unchanged"}}]}

    def test_no_calibration_performs_no_io(self):
        self.assertIsNone(next_case({}, "absent", Mock()))

    def test_closed_recipe_and_duplicate_ids(self):
        with tempfile.TemporaryDirectory() as path:
            inbox = Path(path) / "followups"; inbox.mkdir()
            request = inbox / "0002.json"
            case = {"id": "second", "steps": [{"peer": "player2", "action": "observe"}],
                    "expect": {"outcome": "unchanged"}}
            request.write_text(json.dumps(case))
            desktop = Mock()
            self.assertEqual(next_case(self.suite(), path, desktop), case)
            self.assertEqual(desktop.check.call_count, 2)
            case["steps"][0]["action"] = "sendCommand"
            request.write_text(json.dumps(case))
            with self.assertRaises(ValueError):
                next_case(self.suite(), path, desktop)
            case = self.suite()["cases"][0]
            request.write_text(json.dumps(case))
            with self.assertRaises(ValueError):
                next_case(self.suite(), path, desktop)

    def test_stop_and_timeout_are_bounded(self):
        with tempfile.TemporaryDirectory() as path:
            inbox = Path(path) / "followups"; inbox.mkdir()
            (inbox / "STOP").touch()
            self.assertIsNone(next_case(self.suite(), path, Mock()))
        with tempfile.TemporaryDirectory() as path:
            self.assertIsNone(next_case(self.suite(), path, Mock(), clock=iter([0, 11]).__next__))

    def test_calibration_cannot_satisfy_release_coverage(self):
        with self.assertRaises(ValueError):
            check_coverage([], [{"proof": "physical-ui-calibration", "passed": True}], "hash")


if __name__ == "__main__":
    unittest.main()
