"""State-driven UI scenarios, evidence, and nonzero failure results."""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import time
import uuid
import xml.etree.ElementTree as ET

from .desktop import Desktop, GameExited, InfrastructureError
from .isolated_desktop import IsolatedDesktop
from .coverage import source_fingerprint
from .oracle import GameFault, Pending, PhysicalRejection, agreed, verify, validate_before_input
from .journeys import JourneyProof
from .calibration import next_case
from .terrain import verify_terrain
from .settling import paused_and_settled, replay_settled, require_normal_speed
from .ground_input import perform as ground_input
from .geometry import verify_geometry


def write_json(path, value):
    path = Path(path)
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text(json.dumps(value, indent=2, ensure_ascii=True), encoding="utf-8")
    # Windows can deny replacement while the game's brief io.open() read is
    # holding the old request without delete sharing. Retry only this atomic
    # file handoff, with the SAME nonce and immutable payload, for at most 2s.
    # No physical input, gameplay command, or observer re-evaluation is retried.
    for attempt in range(81):
        try:
            temp.replace(path)
            return
        except PermissionError:
            if attempt == 80:
                raise
            time.sleep(.025)


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def postcondition(before, pair, expect, journey=None):
    # Observe transient arrivals even while a checkpoint is converging. The
    # case still cannot pass (or ignore a fault) until verify accepts the pair.
    progress = None
    if journey:
        try:
            journey.observe(pair)
        except Pending as exc:
            progress = exc
    verify(before, pair, expect)
    if 'terrain' in expect:
        verify_terrain(before, pair, expect['terrain'])
    if expect.get('geometry') or 'railLayout' in expect:
        verify_geometry(before, pair, expect.get('railLayout'))
    if progress:
        raise progress


def select(tree, selector):
    if tree.get("truncated") and not set(selector) & {"id", "path"}:
        raise InfrastructureError("truncated GUI tree cannot prove a text selector is unique")
    matches = []
    for node in tree.get("nodes", []):
        rect = node.get("rect")
        if (node.get("visible") is not True or node.get("enabled") is not True
                or not rect or rect.get("w", 0) <= 0 or rect.get("h", 0) <= 0):
            continue
        if all(node.get(key) == value for key, value in selector.items()):
            matches.append(node)
    # Duplicated labels or off-screen UI are calibration errors, never guessed.
    if len(matches) != 1:
        raise Pending(f"selector {selector}: expected one visible control, found {len(matches)}")
    rect, viewport = matches[0]["rect"], tree.get("viewport") or {}
    if viewport.get("w", 0) <= 0 or viewport.get("h", 0) <= 0:
        raise InfrastructureError("GUI viewport is unavailable")
    xy = [(rect["x"] + rect["w"] / 2 - viewport["x"]) / viewport["w"],
          (rect["y"] + rect["h"] / 2 - viewport["y"]) / viewport["h"]]
    if not all(0 < x < 1 for x in xy):
        raise Pending(f"selector {selector} is outside the visible viewport")
    return xy


class Observer:
    def __init__(self, lab, token, output, desktop):
        self.lab, self.token, self.output, self.desktop = lab, token, output, desktop
        self.terrain = None
        self.geometry = False

    def request(self, peer, channel, action="observe", **extra):
        self.desktop.check(peer)
        request_id = uuid.uuid4().hex
        prefix = Path(self.lab[f"{peer}Bridge"]) / "launcher" / ("ui-test-" + channel)
        request = dict(id=request_id, token=self.token, session=self.lab["session"], action=action, **extra)
        write_json(str(prefix) + ".request.json", request)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            self.desktop.check(peer)
            try:
                receipt = read_json(str(prefix) + ".response.json")
                if receipt.get("id") == request_id and receipt.get("session") == self.lab["session"] and receipt.get("peer") == peer:
                    write_json(self.output / f"{peer}-{channel}-{request_id}.json", receipt)
                    if receipt.get("success") is not True:
                        raise InfrastructureError(f"{peer} {channel} observer: {receipt.get('error')}")
                    return receipt["value"]
            except (OSError, ValueError):
                pass
            time.sleep(.1)
        raise InfrastructureError(f"{peer} {channel} observer did not answer a fresh request in 20 seconds")

    def pair(self):
        extra = {'terrain': {k: self.terrain[k] for k in ('bounds', 'grid')}} if self.terrain else {}
        if self.geometry:
            extra['geometry'] = True
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = {peer: pool.submit(self.request, peer, "world", **extra) for peer in ("player1", "player2")}
            return {peer: future.result() for peer, future in futures.items()}


class Runner:
    def __init__(self, lab, token, suite, output, desktop_factory=IsolatedDesktop):
        self.lab, self.token, self.suite, self.output = lab, token, suite, Path(output)
        self.output.mkdir(parents=True, exist_ok=False)
        self.desktop_factory = desktop_factory
        self.results = []
        self.source_fingerprint = source_fingerprint(Path(__file__).resolve().parents[2])

    def stable(self, timeout, predicate):
        deadline, last_reason, stable_key, count = time.monotonic() + timeout, "no samples", None, 0
        while time.monotonic() < deadline:
            pair = self.observer.pair()
            try:
                predicate(pair)
                key = tuple((pair[p]["snapshot"]["digest"], pair[p]["native"]["digest"]) for p in ("player1", "player2"))
                count = count + 1 if key == stable_key else 1
                stable_key = key
                if count >= 2:
                    return pair
                last_reason = "waiting for second fresh stable sample"
            except Pending as exc:
                count = 0
                last_reason = str(exc)
            time.sleep(.4)
        raise Pending(f"timed out: {last_reason}")

    def step(self, step):
        peer, action = step["peer"], step["action"]
        if action == "wait":
            deadline = time.monotonic() + step["seconds"]
            while time.monotonic() < deadline:
                self.desktop.check("player1"); self.desktop.check("player2")
                time.sleep(.1)
        elif action == "observe":
            self.observer.request(peer, "gui", includePreview=True)
            image_path = self.output / f"observation-{peer}-{uuid.uuid4().hex}.png"
            receipt = self.desktop.screenshot(peer, image_path)
            write_json(image_path.with_suffix(".json"), receipt)
        elif action == "camera":
            self.observer.request(peer, "gui", "camera", camera=step["camera"])
            time.sleep(.5)
        elif action in ('moveGround', 'clickGround', 'dragGround'):
            ground_input(self, step)
            time.sleep(.2)
        else:
            xy = None
            if "selector" in step:
                deadline = time.monotonic() + step.get("timeout", 15)
                while True:
                    target = {"rootId": step["selector"]["id"]} if "id" in step["selector"] else {}
                    tree = self.observer.request(peer, "gui", **target)
                    try:
                        if step.get("absent"):
                            if tree.get("truncated"):
                                raise InfrastructureError("truncated GUI tree cannot prove a control is absent")
                            matches = [n for n in tree.get("nodes", []) if n.get("visible") is True
                                       and all(n.get(k) == v for k, v in step["selector"].items())]
                            if not matches:
                                break
                            raise Pending("control is still visible")
                        xy = select(tree, step["selector"])
                        break
                    except Pending as exc:
                        if time.monotonic() >= deadline:
                            raise InfrastructureError(f"UI control not found; inspect the saved UI tree: {exc}") from exc
                    time.sleep(.2)
            if action != "waitUi":
                self.desktop.input(peer, step, xy)
                time.sleep(.2)

    def capture(self, label):
        for peer in ("player1", "player2"):
            try:
                receipt = self.desktop.screenshot(peer, self.output / f"{label}-{peer}.png")
                write_json(self.output / f"{label}-{peer}-screenshot.json", receipt)
            except Exception as exc:
                write_json(self.output / f"{label}-{peer}-screenshot-error.json", {"error": str(exc)})

    def settle_shutdown(self):
        self.observer.terrain = None
        self.observer.geometry = False
        pair = self.stable(60, agreed)
        clock = pair['player1']['snapshot'].get('bridge', {}).get('companion', {}).get('clock', {})
        if clock.get('generation') == 0:
            # The native selected Pause toggle emits no command when clicked.
            # Exercise real 1x -> Pause input to create an acknowledged generation
            # for a never-unpaused fixture; do not synthesize a clock intent.
            self.step({'peer': 'player1', 'action': 'click', 'selector': {'id': 'menu.speedButton1'}})
            self.stable(60, require_normal_speed)
        # Initial paused fixtures have generation zero, not an acknowledged
        # network pause. Explicitly request Pause even when the icon says zero.
        self.step({'peer': 'player1', 'action': 'click', 'selector': {'id': 'menu.speedButton0'}})
        print('UI suite: waiting for native pause and final ordered boundary before cleanup', flush=True)
        def final_boundary(sample):
            paused_and_settled(sample)
            summary = replay_settled(self.lab, sample)
            write_json(self.output / 'shutdown-audit.json', {'summary': summary})
        ready = self.stable(120, final_boundary)
        write_json(self.output / 'shutdown-settled.json', ready)

    def run(self):
        started = time.time()
        failure = None
        shutdown_settled = False
        try:
            self.desktop = self.desktop_factory({p: self.lab[f"{p}GamePid"] for p in ("player1", "player2")})
            self.desktop.failure_directory = self.output
            self.observer = Observer(self.lab, self.token, self.output, self.desktop)
            write_json(self.output / "suite.json", self.suite)
            self.capture("initial")
            for case in self.suite["cases"]:
                item = {"id": case["id"], "status": "RUNNING", "steps": [], "coverage": case.get("coverage", [])}
                self.results.append(item)
                case_start = time.monotonic()
                journey = JourneyProof(case["expect"]["journey"]) if case.get("expect", {}).get("outcome") == "journey" else None
                print(f"UI case: {case['id']}", flush=True)
                if "blocked" in case:
                    item.update(status="BLOCKED", error=case["blocked"], seconds=0)
                    continue
                try:
                    self.observer.terrain = case['expect'].get('terrain')
                    self.observer.geometry = bool(case['expect'].get('geometry') or case['expect'].get('railLayout'))
                    if self.suite.get("viewport"):
                        for peer in ("player1", "player2"):
                            viewport = self.observer.request(peer, "gui", rootId="mainView")["viewport"]
                            if any(viewport[k] != v for k, v in self.suite["viewport"].items()):
                                raise InfrastructureError("game viewport differs from the calibrated map fixture")
                    before = self.stable(60, agreed)
                    validate_before_input(before, case['expect'])
                    write_json(self.output / f"{case['id']}-before.json", before)
                    for index, step in enumerate(case["steps"]):
                        step_start = time.monotonic()
                        self.step(step)
                        item["steps"].append({"index": index, "input": step,
                                              "screenPoint": getattr(self.desktop, "last_input_point", None)
                                              if step["action"] in ("click", "doubleClick", "move", "drag", "wheel", "moveGround", "clickGround", "dragGround") else None,
                                              "seconds": time.monotonic()-step_start})
                        write_json(self.output / "progress.json", self.results)
                    # A brief initial taxi/departure can complete while two
                    # screenshots switch foreground. Begin sampling immediately
                    # after a journey's input; final screenshots remain mandatory.
                    if not journey:
                        self.capture(case["id"] + "-clicked")
                    after = self.stable(case.get("timeout", 90),
                        lambda pair: postcondition(before, pair, case["expect"], journey))
                    write_json(self.output / f"{case['id']}-after.json", after)
                    item["status"] = "PASS"
                except (Pending, GameFault, GameExited, PhysicalRejection) as exc:
                    item.update(status="FAIL", error=str(exc)); failure = str(exc)
                except Exception as exc:
                    item.update(status="INFRA_BLOCKED", error=str(exc)); failure = str(exc)
                finally:
                    item["seconds"] = time.monotonic() - case_start
                    if journey:
                        write_json(self.output / f"{case['id']}-journeys.json", journey.evidence())
                    self.capture(case["id"] + "-final")
                    for peer in ("player1", "player2"):
                        try:
                            # Click-time observation can precede native replay. Preserve
                            # the final processor result too, including on clean rejection.
                            tree = self.observer.request(peer, "gui", rootId="mainView")
                            write_json(self.output / f"{case['id']}-{peer}-final-gui.json", tree)
                        except Exception as exc:
                            write_json(self.output / f"{case['id']}-{peer}-final-gui-error.json", {"error": str(exc)})
                print(f"{item['status']} {item['id']}: {item.get('error', 'both physical worlds verified')}", flush=True)
                write_json(self.output / "progress.json", self.results)
                if failure:
                    # Never run a second test on a potentially corrupted fixture.
                    break
                if case is self.suite["cases"][-1]:
                    followup = next_case(self.suite, self.output, self.desktop)
                    if followup:
                        self.suite["cases"].append(followup)
                        write_json(self.output / "suite.json", self.suite)
            if not failure and all(item['status'] == 'PASS' for item in self.results):
                self.settle_shutdown()
                shutdown_settled = True
        except Exception as exc:
            failure = str(exc)
        finally:
            if hasattr(self, "desktop"):
                self.desktop.close()
            completed = {item["id"] for item in self.results}
            for case in self.suite["cases"]:
                if case["id"] not in completed:
                    self.results.append({"id": case["id"], "status": "NOT_RUN", "error": failure or "prior case failed", "seconds": 0})
            if self.source_fingerprint != source_fingerprint(Path(__file__).resolve().parents[2]):
                failure = failure or "source changed during live test; rerun the candidate"
            passed = not failure and len(self.results) == len(self.suite["cases"]) and all(c["status"] == "PASS" for c in self.results)
            report = {"schemaVersion": 1, "suite": self.suite["id"], "session": self.lab["session"],
                      "passed": passed, "proof": "physical-ui-calibration" if self.suite.get("calibrationIdleSeconds") else "physical-ui-input", "seconds": time.time()-started,
                      "sourceFingerprint": self.source_fingerprint, "error": failure, "cases": self.results}
            report['shutdownSettled'] = shutdown_settled
            report['supervisorVerified'] = False  # Filled only after audit replay and exact-PID cleanup.
            write_json(self.output / "report.json", report)
            self.junit(report)
        return 0 if report["passed"] else 1

    def junit(self, report):
        failures = sum(c["status"] != "PASS" for c in self.results)
        global_failure = not report["passed"] and failures == 0
        suite = ET.Element("testsuite", name=report["suite"], tests=str(len(self.results) + int(global_failure)),
                           failures=str(failures + int(global_failure)), time=str(report["seconds"]))
        for case in self.results:
            item = ET.SubElement(suite, "testcase", name=case["id"], time=str(case.get("seconds", 0)))
            if case["status"] != "PASS":
                ET.SubElement(item, "failure", type=case["status"], message=case.get("error", case["status"]))
        if global_failure:
            item = ET.SubElement(suite, "testcase", name="suite-integrity", time="0")
            ET.SubElement(item, "failure", type="INVALID_EVIDENCE", message=report.get("error") or "suite failed")
        ET.ElementTree(suite).write(self.output / "junit.xml", encoding="utf-8", xml_declaration=True)
