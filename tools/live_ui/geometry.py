"""Independent physical rail-layout assertions, not captured preview params."""
import math
from .oracle import at, need


def geometry_agreed(pair):
    for peer in ('player1', 'player2'):
        geometry = at(pair[peer], ['geometry'])
        need(geometry.get('schemaVersion') == 1 and geometry.get('complete') is True,
             f'{peer}: complete native edge geometry required')
        need(isinstance(geometry.get('edges'), dict)
             and type(geometry.get('count')) is int
             and geometry['count'] == len(geometry['edges']), f'{peer}: incomplete native edge map')
    need(pair['player1']['geometry'] == pair['player2']['geometry'], 'native edge geometry differs between peers')


def rail_layout(old, new, spec):
    previous = at(old, ['geometry', 'edges'])
    current = at(new, ['geometry', 'edges'])
    axis_x, axis_y = spec['axis']
    tolerance = spec['tolerance']
    segments = []
    for cid in set(current) - set(previous):
        edge = current[cid]
        if edge.get('carrier', {}).get('kind') != 'track':
            continue
        points = []
        for endpoint in edge.get('endpoints', []):
            position = endpoint.get('position')
            need(isinstance(position, list) and len(position) == 3
                 and all(type(v) in (int, float) and math.isfinite(v) for v in position),
                 'native track position unavailable')
            x, y, _ = (v / 10 for v in position)  # Native descriptor decimetres.
            points.append((x * axis_x + y * axis_y, -x * axis_y + y * axis_x))
        need(len(points) == 2, 'native track requires two endpoints')
        need(abs(points[0][1] - points[1][1]) <= tolerance, 'station rail is not parallel to expected axis')
        start, end = sorted(p[0] for p in points)
        need(end - start > .001, 'degenerate station rail segment')
        segments.append(((points[0][1] + points[1][1]) / 2, start, end))
    groups = []
    for offset, start, end in sorted(segments):
        if not groups or abs(offset - groups[-1]['offset']) > tolerance:
            groups.append({'offset': offset, 'intervals': []})
        groups[-1]['intervals'].append((start, end))
    need(len(groups) == spec['tracks'], f"expected {spec['tracks']} physical tracks, observed {len(groups)}")
    result = []
    for group in groups:
        intervals = sorted(group['intervals'])
        minimum, maximum = intervals[0]
        for start, end in intervals[1:]:
            need(abs(start - maximum) <= tolerance, 'native station rail has a gap or overlapping segment')
            maximum = max(maximum, end)
        span = maximum - minimum
        need(abs(span - spec['span']) <= tolerance,
             f"expected native track span {spec['span']}m, observed {span}m")
        result.append({'offset': group['offset'], 'span': span, 'segments': len(intervals)})
    return result


def verify_geometry(before, after, spec=None):
    geometry_agreed(before)
    geometry_agreed(after)
    if spec:
        return {peer: rail_layout(before[peer], after[peer], spec) for peer in ('player1', 'player2')}
