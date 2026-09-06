"""Bilateral native heights, not inferred terrain work from construction costs."""
import math
from .oracle import at, need


def verify_terrain(before, after, spec):
    grids = {}
    for phase, pair in (('before', before), ('after', after)):
        for peer in ('player1', 'player2'):
            data = at(pair[peer], ['terrain'])
            need(isinstance(data, dict) and data.get('bounds') == spec['bounds']
                 and data.get('grid') == spec['grid'], f'{peer}: wrong/missing terrain grid')
            values = data.get('heights')
            need(isinstance(values, list) and len(values) == spec['grid']**2
                 and all(type(v) in (int, float) and math.isfinite(v) for v in values),
                 f'{peer}: incomplete terrain heights')
            grids[phase, peer] = values
        need(all(abs(a-b) <= spec['tolerance'] for a, b in
                 zip(grids[phase, 'player1'], grids[phase, 'player2'])),
             f'peer terrain heights disagree {phase} construction')
    changed = [all(abs(grids['after', p][i]-grids['before', p][i]) >= spec['minDelta']
                   for p in ('player1', 'player2')) for i in range(spec['grid']**2)]
    need(sum(changed) >= spec['minSamples'],
         f'only {sum(changed)} common terrain points changed; expected {spec["minSamples"]}')
