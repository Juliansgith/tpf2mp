"""Fresh two-player games per suite; failed gameplay never contaminates the next fixture."""
import argparse
from datetime import datetime
from pathlib import Path
import uuid
from live_ui.batch import execute


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--save', required=True)
    parser.add_argument('--suite', action='append', required=True)
    parser.add_argument('--output')
    parser.add_argument('--skip-static-gate', action='store_true')
    parser.add_argument('--stop-on-failure', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output or root/'runtime/live-ui-batches'/(
        datetime.now().strftime('%Y%m%d-%H%M%S-') + uuid.uuid4().hex[:8])
    return execute(root, args.save, args.suite, output, args.skip_static_gate, args.stop_on_failure)


if __name__ == '__main__':
    raise SystemExit(main())
