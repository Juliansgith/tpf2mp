import argparse
from live_ui.finalize import finalize

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Finalize provisional UI proof after audit and cleanup')
    parser.add_argument('--report', required=True)
    parser.add_argument('--status', required=True)
    parser.add_argument('--processes-closed', action='store_true')
    args = parser.parse_args()
    raise SystemExit(0 if finalize(args.report, args.status, args.processes_closed) else 1)
