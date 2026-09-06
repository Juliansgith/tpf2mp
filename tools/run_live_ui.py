"""Entry point used by the exact-PID localhost supervisor (not a launcher itself)."""
import argparse
import os
from pathlib import Path
import sys
import subprocess

sys.path.insert(0, str(Path(__file__).resolve().parent))
from live_ui.runner import Runner, read_json
from live_ui.schema import load_suite


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--save", required=True)
    parser.add_argument("--lab")
    parser.add_argument("--output")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    suite = load_suite(args.suite, args.save)
    if args.validate:
        print(f"Valid UI recipe: {suite['id']} ({len(suite['cases'])} cases)")
        return 0
    token = os.environ.get("TPF2MP_LIVE_UI_TOKEN", "")
    if len(token) != 32 or not args.lab or not args.output:
        parser.error("run through run_live_ui_suite.ps1; launch capability and exact lab receipt required")
    lab = read_json(args.lab)
    if lab.get("status") != "ready" or lab.get("mode") != "manual-network" or not lab.get("session", "").startswith("localhost-ui-"):
        parser.error("only a fresh disposable manual UI lab can be controlled")
    if not args.worker:
        try:
            result = subprocess.run([sys.executable, __file__, *sys.argv[1:], "--worker"], timeout=1800,
                                    creationflags=subprocess.CREATE_NO_WINDOW, capture_output=True, text=True)
            Path(args.output).mkdir(parents=True, exist_ok=True)
            (Path(args.output)/"worker.stdout.log").write_text(result.stdout, encoding="utf-8")
            (Path(args.output)/"worker.stderr.log").write_text(result.stderr, encoding="utf-8")
            print(result.stdout, end="")
            if result.stderr:
                print(result.stderr, file=sys.stderr, end="")
            return result.returncode
        except subprocess.TimeoutExpired:
            print("UI suite exceeded its 30-minute watchdog; disposable games will be closed.", file=sys.stderr)
            return 2
    return Runner(lab, token, suite, args.output).run()


if __name__ == "__main__":
    raise SystemExit(main())
