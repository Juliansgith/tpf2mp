"""Run independent UI recipes in fresh pairs; never mask failed attempts."""
import json
from pathlib import Path
import subprocess
import time
from .schema import load_suite
from .coverage import source_fingerprint
from .runner import read_json, write_json


def execute(root, save, suites, output, skip_static=False, stop_on_failure=False, run=subprocess.run):
    root, save, output = Path(root).resolve(), Path(save).resolve(), Path(output).resolve()
    paths = [Path(p).resolve() for p in suites]
    if not paths or len(paths) > 50 or len(set(paths)) != len(paths):
        raise ValueError("batch requires 1..50 distinct suite files")
    # Validate the WHOLE batch before deploying or starting any game.
    validated = [load_suite(p, save) for p in paths]
    if len({s['id'] for s in validated}) != len(validated):
        raise ValueError("batch suite IDs must be unique")
    output.mkdir(parents=True, exist_ok=False)
    fingerprint = source_fingerprint(root)
    report = {"schemaVersion": 1, "sourceFingerprint": fingerprint, "passed": False, "runs": []}
    try:
        for index, (path, suite) in enumerate(zip(paths, validated)):
            # A stop file never kills a live game mid-command: let the current
            # supervisor finish its audit/cleanup, then leave remaining cases unrun.
            if (output / 'STOP').exists():
                report['stopped'] = 'operator requested stop after current suite cleanup'
                break
            receipt_path = output / f"{index:02d}-receipt.json"
            log_path = output / f"{index:02d}-launch.log"
            args = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                    str(root/'tools/run_live_ui_suite.ps1'), "-StartingSave", str(save),
                    "-Suite", str(path), "-ResultPath", str(receipt_path)]
            if skip_static or index > 0:
                args.append("-SkipStaticGate")
            item = {"suite": suite["id"], "status": "RUNNING", "log": str(log_path)}
            report["runs"].append(item)
            write_json(output/'report.json', report)
            print(f"UI batch {index+1}/{len(paths)}: {suite['id']}", flush=True)
            started = time.monotonic()
            with log_path.open("xb") as log:
                completed = run(args, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            item.update(exitCode=completed.returncode, seconds=time.monotonic()-started)
            try:
                receipt = read_json(receipt_path)
                item.update(session=receipt["session"], report=receipt["report"], runStatus=receipt["runStatus"])
                if receipt.get("cleanupComplete") is not True:
                    raise ValueError("disposable cleanup was not proven; refusing the next launch")
            except (OSError, ValueError, KeyError) as exc:
                item.update(status="INFRA_BLOCKED", error=str(exc)); break
            try:
                result = read_json(receipt["report"])
                if result.get("suite") != suite["id"] or result.get("session") != receipt["session"]:
                    raise ValueError("UI report identity does not match launch receipt")
                if result.get("sourceFingerprint") != fingerprint or source_fingerprint(root) != fingerprint:
                    raise ValueError("candidate source changed; refusing to combine mixed-version results")
                if result.get("proof") != "physical-ui-input":
                    raise ValueError("report is not real physical-UI evidence")
                item["status"] = "PASS" if (completed.returncode == 0 and result.get("passed") is True
                                            and result.get('supervisorVerified') is True) else "FAIL"
                item["error"] = result.get("error")
            except (OSError, ValueError, KeyError) as exc:
                item.update(status="INFRA_BLOCKED", error=str(exc))
            write_json(output/'report.json', report)
            print(f"{item['status']}: {suite['id']}", flush=True)
            if source_fingerprint(root) != fingerprint or (stop_on_failure and item["status"] != "PASS"):
                break
    finally:
        for suite in validated[len(report["runs"]):]:
            report["runs"].append({"suite": suite["id"], "status": "NOT_RUN"})
        report["passed"] = all(row["status"] == "PASS" for row in report["runs"])
        write_json(output/'report.json', report)
    return 0 if report["passed"] else 1
