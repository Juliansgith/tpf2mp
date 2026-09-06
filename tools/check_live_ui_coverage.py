import argparse
import json
from pathlib import Path
from live_ui.coverage import check_coverage, source_fingerprint


def main():
    parser = argparse.ArgumentParser(description="Fail closed unless required gameplay has fresh native UI proof.")
    parser.add_argument("--report", action="append", default=[])
    parser.add_argument("--requirements", default=str(Path(__file__).resolve().parents[1]/"content/live-ui/required-coverage.json"))
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        required = json.loads(Path(args.requirements).read_text(encoding="utf-8-sig"))["required"]
        reports = [json.loads(Path(p).read_text(encoding="utf-8-sig")) for p in args.report]
        covered = check_coverage(required, reports, source_fingerprint(root))
        print(f"PASS fresh native UI acceptance coverage: {len(covered)} labels")
        return 0
    except (ValueError, KeyError, OSError) as exc:
        print(f"FAIL UI coverage: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
