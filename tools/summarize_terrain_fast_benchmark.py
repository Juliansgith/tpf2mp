"""Summarise run_native_save_benchmark.ps1 evidence for the terrain fast paths.

Reads every <root>/<label>/ directory that holds native-markers.log and
native-hook-status.json, derives the load time from the load-request and
world-ready markers (whole seconds, the benchmark's resolution), and lists
the per-routine wall-clock accounting the hook publishes under
hooks.terrainFast when TPF2MP_NATIVE_TERRAIN_FAST included "timing".
Read-only; prints a table and a JSON summary.
"""
import argparse
import json
import re
import statistics
from pathlib import Path

MARKER = re.compile(r'^\[NATIVE-BENCH\] event=(?P<event>[\w-]+) .*? atEpoch=(?P<epoch>\d+)', re.M)


def load_run(directory):
    markers = (directory / 'native-markers.log').read_text(encoding='utf-8', errors='replace')
    epochs = {m.group('event'): int(m.group('epoch')) for m in MARKER.finditer(markers)}
    status = json.loads((directory / 'native-hook-status.json').read_text(encoding='utf-8'))
    terrain = status['hooks']['terrainFast']
    report = json.loads((directory / 'report.json').read_text(encoding='utf-8-sig'))
    peak_private = max((int(sample['privateBytes']) for sample in report.get('samples', [])), default=0)
    return {
        'label': directory.name,
        'requested': terrain.get('requested'),
        'fast': {key: terrain.get(key) for key in ('align', 'refine', 'minMaxScan', 'blockCopy', 'material')},
        'loadSeconds': epochs.get('world-ready', 0) - epochs.get('load-request', 0)
        if 'world-ready' in epochs and 'load-request' in epochs else None,
        'complete': report.get('complete'),
        'calls': terrain.get('calls', {}),
        'seconds': terrain.get('seconds', {}),
        'peakPrivateGiB': round(peak_private / 2**30, 3),
        'error': terrain.get('error', ''),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--json', type=Path, help='also write the summary here')
    args = parser.parse_args()
    runs = []
    for directory in sorted(args.root.iterdir()):
        if all((directory / name).exists() for name in ('native-markers.log', 'native-hook-status.json', 'report.json')):
            runs.append(load_run(directory))
    header = f"{'run':<22}{'requested':<16}{'load s':>7}{'align s':>9}{'refine s':>9}{'copy s':>8}{'scan s':>8}{'material s':>11}{'peak GiB':>10}"
    print(header)
    for run in runs:
        s = run['seconds']
        print(f"{run['label']:<22}{str(run['requested']):<16}{str(run['loadSeconds']):>7}"
              f"{s.get('align', 0):>9.3f}{s.get('refine', 0):>9.3f}{s.get('blockCopy', 0):>8.3f}"
              f"{s.get('scan', 0):>8.3f}{s.get('material', 0):>11.3f}{run['peakPrivateGiB']:>10.3f}")
    groups = {}
    for run in runs:
        groups.setdefault(run['requested'], []).append(run)
    summary = {'runs': runs, 'groups': {}}
    for requested, group in groups.items():
        loads = [r['loadSeconds'] for r in group if r['loadSeconds'] is not None]
        totals = [sum(v for k, v in r['seconds'].items()) for r in group]
        summary['groups'][requested] = {
            'runs': len(group),
            'meanLoadSeconds': statistics.mean(loads) if loads else None,
            'loadSeconds': loads,
            'meanRoutineSeconds': statistics.mean(totals) if totals else None,
            'meanSeconds': {key: statistics.mean(r['seconds'].get(key, 0) for r in group)
                            for key in ('align', 'refine', 'blockCopy', 'scan', 'material')},
        }
        print(f"\n{requested}: {len(group)} runs, load {loads} s (mean {summary['groups'][requested]['meanLoadSeconds']}), "
              f"routine seconds mean {summary['groups'][requested]['meanRoutineSeconds']:.3f}")
    if args.json:
        args.json.write_text(json.dumps(summary, indent=1), encoding='utf-8')


if __name__ == '__main__':
    main()
