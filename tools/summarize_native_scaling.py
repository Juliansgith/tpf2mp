"""Summarize phase-aligned native benchmark evidence. Does not estimate FPS."""
import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re


def summarize(report):
    expected = {'paused': 0, 'speed1': 1, 'speed4': 4, 'paused-repeat': 0,
                'camera': 0, 'speed1-repeat': 1} if report.get('workload') == 'scaling' else {}
    phases = {}
    for line in report['markers']:
        match = re.search(r'event=phase-sample-(\S+).*speed=([\d.]+) gameTime=([\d.]+) atEpoch=(\d+)', line)
        if match:
            name, speed, sim, epoch = match.groups()
            phases.setdefault(name, []).append((int(epoch), float(sim), float(speed)))
    output = {}
    for name, markers in phases.items():
        start, end = markers[0][0] + 2, markers[-1][0]
        samples = [s for s in report['samples']
                   if start <= datetime.fromisoformat(s['atUtc'].replace('Z', '+00:00')).timestamp() <= end]
        times = [m for m in markers if start <= m[0] <= end]
        if len(samples) < 2 or len(times) < 2:
            output[name] = {'complete': False, 'reason': 'insufficient aligned samples'}
            continue
        seconds = samples[-1]['wallSeconds'] - samples[0]['wallSeconds']
        waits = Counter(t['wait'] or t['state'] for s in samples for t in s.get('threads', []))
        first_threads = {t['id']: t['cpuSeconds'] for t in samples[0].get('threads', [])}
        busy = sorted([max(0, t['cpuSeconds'] - first_threads[t['id']])
                       for t in samples[-1].get('threads', []) if t['id'] in first_threads], reverse=True)
        output[name] = {
            'complete': name not in expected or all(m[2] == expected[name] for m in times),
            'samples': len(samples), 'wallSeconds': seconds,
            'oneCoreCpuPercent': 100 * (samples[-1]['cpuSeconds'] - samples[0]['cpuSeconds']) / seconds,
            'privateGiB': sum(s['privateBytes'] for s in samples) / len(samples) / 2**30,
            'simulationPerWallSecond': (times[-1][1] - times[0][1]) / (times[-1][0] - times[0][0]),
            'observedSpeeds': sorted(set(m[2] for m in times)),
            'threadStateSampleCounts': dict(waits),
            'topSurvivingThreadCpuSeconds': busy[:5],
        }
    missing = sorted(set(expected) - set(output))
    return {'complete': report['complete'] and bool(output) and not missing and all(p['complete'] for p in output.values()),
            'missingPhases': missing,
            'fpsMeasured': False, 'phases': output,
            'limitations': 'Thread-state counts are snapshots, not blocked durations or lock attribution. Thread CPU assumes no ID reuse within a phase.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(json.loads(args.report.read_text(encoding='utf-8-sig'))), indent=2))
