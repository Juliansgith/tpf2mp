"""Private one-step worker; no console or command-injection operations."""
import faulthandler
import json
import os
import re
import sys
from live_ui.desktop import Desktop
from live_ui.schema import validate_step, number


def main():
    pid = int(sys.argv[1])
    if (str(pid) not in os.environ.get('TPF2MP_LIVE_UI_PIDS', '').split(',')
            or not re.fullmatch('[a-f0-9]{32}', os.environ.get('TPF2MP_LIVE_UI_TOKEN', ''))):
        raise RuntimeError('UI worker requires an exact disposable process capability')
    raw = sys.stdin.read(16385)
    if len(raw) > 16384: raise ValueError('UI request exceeds limit')
    request = json.loads(raw)
    screenshot = isinstance(request, dict) and set(request) == {'screenshot'}
    dump = isinstance(request, dict) and set(request) == {'dump'}
    if dump:
        from live_ui.hang_dump import capture
        print(json.dumps(capture(pid, request['dump'])), flush=True)
        return
    if not screenshot:
        if not isinstance(request, dict) or set(request) != {'step', 'point'}:
            raise ValueError('invalid UI request')
        validate_step(request['step'])
        if request['step']['action'] not in ('click', 'doubleClick', 'move', 'drag', 'wheel', 'key', 'text'):
            raise ValueError('worker accepts only physical input')
        if request['point'] is not None and (not isinstance(request['point'], list)
            or len(request['point']) != 2 or not all(number(x, 0, 1) for x in request['point'])):
            raise ValueError('invalid resolved UI point')
    faulthandler.dump_traceback_later(8)
    desktop = Desktop({'target': pid})
    try:
        if screenshot:
            result = desktop.screenshot('target', request['screenshot'])
        else:
            desktop.input('target', request['step'], request['point'])
            result = {'point': getattr(desktop, 'last_input_point', None)}
        print(json.dumps(result), flush=True)
    finally:
        desktop.close()
        faulthandler.cancel_dump_traceback_later()


if __name__ == '__main__': main()
