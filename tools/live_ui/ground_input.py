"""Translate ground targets into real mouse input; no native build escape hatch."""
import json
import math
from pathlib import Path
import time
import uuid
from .ground_target import locate, TargetingError


def perform(runner, step):
    peer, action = step['peer'], step['action']
    deadline = time.monotonic() + step.get('timeout', 120)
    history, frame = [], None
    record = {'peer': peer, 'input': step, 'samples': history, 'resolved': []}
    path = Path(runner.output) / ('ground-input-' + uuid.uuid4().hex + '.json')
    def sample(point):
        nonlocal frame
        if time.monotonic() >= deadline:
            raise TargetingError('ground targeting timeout; no gameplay click sent')
        move = {'peer': peer, 'action': 'move', 'point': list(point)}
        runner.desktop.input(peer, move)
        tree = runner.observer.request(peer, 'gui', rootId='mainView', includeGround=True)
        cursor = tree.get('groundCursor', {})
        observed = cursor.get('frame')
        row = {'input': move, 'screenPoint': getattr(runner.desktop, 'last_input_point', None),
               'cursor': cursor}
        history.append(row)
        if (type(observed) not in (float, int) or not math.isfinite(observed)
                or observed < 0 or observed != int(observed)
                or frame is not None and observed <= frame):
            raise TargetingError('missing/stale native ground cursor frame')
        frame = observed
        return cursor.get('world')
    try:
        for target in [step['world']] + ([step['toWorld']] if action == 'dragGround' else []):
            resolved = locate(target, sample, tolerance=step.get('tolerance', .15))
            record['resolved'].append(resolved)
        if time.monotonic() >= deadline:
            raise TargetingError('ground targeting timeout; no gameplay click sent')
        point = record['resolved'][0]['point']
        native = {'peer': peer, 'action': {'clickGround': 'click', 'moveGround': 'move',
                                          'dragGround': 'drag'}[action], 'point': point}
        if action == 'dragGround':
            native.update(to=record['resolved'][1]['point'], duration=step.get('duration', 1))
        # The only press occurs here, once, after all readbacks pass. Never retry
        # a potentially issued click/drag following an exception or rejection.
        record['physicalInput'] = native
        runner.desktop.input(peer, native)
        record['issued'] = True
    except BaseException as exc:
        record['error'] = str(exc)
        raise
    finally:
        path.write_text(json.dumps(record, indent=2), encoding='utf-8')
