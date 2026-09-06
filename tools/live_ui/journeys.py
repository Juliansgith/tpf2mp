"""Accumulate native arrival/motion evidence, independently for both peers."""
from .oracle import need
import math


class JourneyProof:
    def __init__(self, spec):
        self.spec = spec
        self.traces = {}
        self.identities = None
        self.line_shape = None

    def observe(self, pair):
        selected = {}
        line_shapes, stop_counts = {}, {}
        for peer in ("player1", "player2"):
            data = pair[peer]
            lines = [line for line in data.get("structure", {}).get("lines", [])
                     if line.get("name") == self.spec["lineName"] and line.get("owner") == self.spec["owner"]]
            need(len(lines) == 1, f"{peer}: expected one uniquely named test line")
            line = lines[0]
            need(line.get("owner") == self.spec["owner"], f"{peer}: wrong line owner")
            need(len(set(line.get("stops", []))) >= self.spec["stops"], f"{peer}: insufficient distinct stops")
            line_shapes[peer] = (line["cid"], line["stops"])
            stop_counts[peer] = len(line["stops"])
            selected[peer] = {cid: row for cid, row in data.get("vehicleTelemetry", {}).items()
                              if row.get("lineCid") == line["cid"]}
            need(len(selected[peer]) == self.spec["vehicles"], f"{peer}: assigned native vehicle count differs")
            need(all(row.get("owner") == self.spec["owner"] for row in selected[peer].values()),
                 f"{peer}: wrong vehicle owner")
            need(all(row.get("carrier") == self.spec["carrier"] for row in selected[peer].values()),
                 f"{peer}: wrong/missing native vehicle carrier")
            if 'models' in self.spec:
                need(all(row.get('models') == self.spec['models'] for row in selected[peer].values()),
                     f'{peer}: wrong/missing native vehicle models')
        identities = set(selected["player1"])
        need(line_shapes["player1"] == line_shapes["player2"], "native line identity/stops differ between peers")
        line_cid, stops = line_shapes['player1']
        line_shape = (line_cid, tuple(stops))
        if self.line_shape is None:
            self.line_shape = line_shape
        need(line_shape == self.line_shape, 'native line changed during the journey test')
        need(identities == set(selected["player2"]), "native vehicle identities differ between peers")
        if self.identities is None:
            self.identities = identities
        need(identities == self.identities, "vehicles changed during the journey test")
        # Collect both peers before deciding readiness: P1 waiting must not
        # prevent P2's arrival from being recorded in this same sample.
        for peer, vehicles in selected.items():
            for cid, row in vehicles.items():
                trace = self.traces.setdefault((peer, cid), {"moving": False, "stops": [], "destinations": [], "samples": 0})
                trace["samples"] += 1
                speed = row.get("speed")
                if type(speed) in (int, float) and math.isfinite(speed) and speed > .1 and row.get("state") == 1:
                    trace["moving"] = True
                stop = row.get("stopIndex")
                if row.get("state") == 2 and type(stop) is int and 0 <= stop < stop_counts[peer] and trace["moving"]:
                    if not trace["stops"] or trace["stops"][-1] != stop:
                        trace["stops"].append(stop)
                        trace['destinations'].append(stops[stop])
                    trace["moving"] = False
        for (peer, cid), trace in self.traces.items():
            need(len(set(trace["destinations"])) >= self.spec["stops"],
                 f"{peer}/{cid}: verified native arrivals after motion: {trace['stops']}")

    def evidence(self):
        return {peer: {cid: trace for (p, cid), trace in self.traces.items() if p == peer}
                for peer in ("player1", "player2")}
