"""A synced purchase/assignment alone must never pass transport-operation proof."""
import copy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from live_ui.journeys import JourneyProof
from live_ui.oracle import Pending


def observation(state, stop=0, speed=0):
    value = {"structure": {"lines": [{"cid": "line:1", "name": "UI test",
              "owner": "company:1", "stops": ["station:1", "station:2"], "vehicles": 1}]},
             "vehicleTelemetry": {"vehicle:1": {"lineCid": "line:1", "owner": "company:1",
                "state": state, "stopIndex": stop, "speed": speed, "carrier": 1}}}
    return {p: copy.deepcopy(value) for p in ("player1", "player2")}


class JourneyTests(unittest.TestCase):
    def test_other_company_may_use_the_same_native_line_name(self):
        proof = self.proof()
        for args in [(1, 0, 4), (2, 0, 0), (1, 1, 6), (2, 1, 0)]:
            pair = observation(*args)
            for value in pair.values():
                rival = copy.deepcopy(value['structure']['lines'][0])
                rival.update(cid='line:rival', owner='company:2')
                value['structure']['lines'].append(rival)
            if args[0:2] == (2, 1):
                proof.observe(pair)
            else:
                with self.assertRaises(Pending): proof.observe(pair)

    def test_same_carrier_wrong_native_model_cannot_pass(self):
        proof = self.proof()
        proof.spec.update(carrier=0, models=['vehicle/bus/test.mdl'])
        pair = observation(1, 0, 4)
        for value in pair.values():
            value['vehicleTelemetry']['vehicle:1'].update(carrier=0, models=['vehicle/bus/test.mdl'])
        pair['player2']['vehicleTelemetry']['vehicle:1']['models'] = ['vehicle/truck/test.mdl']
        with self.assertRaisesRegex(Pending, 'native vehicle models'): proof.observe(pair)

    def proof(self):
        return JourneyProof({"lineName": "UI test", "owner": "company:1",
                             "vehicles": 1, "stops": 2, "carrier": 1})

    def test_wrong_carrier_cannot_qualify_a_transport_family(self):
        pair = observation(1, 0, 4)
        pair["player2"]["vehicleTelemetry"]["vehicle:1"]["carrier"] = 3
        with self.assertRaisesRegex(Pending, "carrier"):
            self.proof().observe(pair)

    def test_two_real_arrivals_separated_by_motion_on_both_peers(self):
        proof = self.proof()
        for args in [(1, 0, 4), (2, 0, 0), (1, 1, 6)]:
            with self.assertRaises(Pending):
                proof.observe(observation(*args))
        proof.observe(observation(2, 1))

    def test_changing_line_stops_mid_trip_cannot_combine_unrelated_arrivals(self):
        proof = self.proof()
        for args in [(1, 0, 4), (2, 0, 0)]:
            with self.assertRaises(Pending):
                proof.observe(observation(*args))
        for args in [(1, 1, 6), (2, 1, 0)]:
            changed = observation(*args)
            for value in changed.values():
                value['structure']['lines'][0]['stops'] = ['station:3', 'station:4']
            with self.assertRaisesRegex(Pending, 'line changed'):
                proof.observe(changed)

    def test_duplicate_stop_indices_do_not_count_as_distinct_destinations(self):
        proof = self.proof()
        for args in [(1, 0, 4), (2, 0, 0), (1, 2, 6), (2, 2, 0)]:
            repeated = observation(*args)
            for value in repeated.values():
                value['structure']['lines'][0]['stops'] = ['station:1', 'station:2', 'station:1']
            with self.assertRaises(Pending):
                proof.observe(repeated)

    def test_assignment_or_stopped_train_is_not_a_journey(self):
        proof = self.proof()
        for _ in range(10):
            with self.assertRaises(Pending):
                proof.observe(observation(2, 0))

    def test_stop_index_changes_without_motion_do_not_count(self):
        proof = self.proof()
        for stop in (0, 1, 0, 1):
            with self.assertRaises(Pending):
                proof.observe(observation(2, stop))

    def test_peer_one_success_does_not_hide_peer_two_stuck(self):
        proof = self.proof()
        for args in [(1, 0, 4), (2, 0, 0), (1, 1, 6), (2, 1, 0)]:
            pair = observation(*args)
            pair["player2"] = observation(2, 0)["player2"]
            with self.assertRaises(Pending):
                proof.observe(pair)

    def test_missing_or_zero_speed_cannot_prove_departure(self):
        proof = self.proof()
        for stop in (0, 1):
            for state in (1, 2):
                pair = observation(state, stop)
                pair["player1"]["vehicleTelemetry"]["vehicle:1"].pop("speed")
                with self.assertRaises(Pending):
                    proof.observe(pair)

    def test_vehicle_identity_must_be_bilateral(self):
        proof = self.proof()
        pair = observation(1, 0, 4)
        pair["player2"]["vehicleTelemetry"]["vehicle:2"] = pair["player2"]["vehicleTelemetry"].pop("vehicle:1")
        with self.assertRaises(Pending):
            proof.observe(pair)

    def test_out_of_range_stops_and_nonfinite_speed_do_not_count(self):
        for speed, stop in ((float("inf"), 0), (4, 999)):
            proof = self.proof()
            for index in (stop, stop + 1):
                for state in (1, 2):
                    with self.assertRaises(Pending):
                        proof.observe(observation(state, index, speed if state == 1 else 0))

    def test_wrong_owner_and_one_stop_line_reject(self):
        for field, value in (("owner", "company:2"), ("stops", ["station:1"])):
            pair = observation(1, 0, 4)
            pair["player1"]["structure"]["lines"][0][field] = value
            with self.assertRaises(Pending):
                self.proof().observe(pair)


if __name__ == "__main__":
    unittest.main()
