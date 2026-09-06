"""Bound native window activation/input so a crashed GUI cannot hang the runner."""
import json
from pathlib import Path
import subprocess
import sys
import uuid
from .desktop import Desktop, InfrastructureError


class IsolatedDesktop(Desktop):
    failure_directory = None

    def _execute(self, peer, request):
        self.check(peer)
        pid = self.targets[peer]['pid']
        command = [sys.executable, str(Path(__file__).resolve().parents[1]/'live_ui_isolated_step.py'), str(pid)]
        try:
            result = subprocess.run(command, input=json.dumps(request), capture_output=True, text=True,
                timeout=20, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        except subprocess.TimeoutExpired as exc:
            details = '20-second physical UI watchdog'
            if self.failure_directory:
                folder = Path(self.failure_directory)
                stem = f'input-timeout-{peer}-{uuid.uuid4().hex}'
                stderr = exc.stderr.decode(errors='replace') if isinstance(exc.stderr, bytes) else exc.stderr
                (folder/(stem+'.log')).write_text(stderr or details, encoding='utf-8')
                try:
                    # DbgHelp can also block on a hung game. A separate bounded
                    # diagnostic worker must never prevent fixture cleanup.
                    dump = subprocess.run(command, input=json.dumps({'dump': str(folder/(stem+'.dmp'))}),
                        capture_output=True, text=True, timeout=10,
                        creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
                    if dump.returncode != 0:
                        raise RuntimeError(dump.stderr[-4000:])
                except Exception as dump_error:
                    (folder/(stem+'-dump-error.txt')).write_text(str(dump_error), encoding='utf-8')
            raise InfrastructureError(f'{peer}: {details}; no further input sent') from exc
        if result.returncode != 0:
            raise InfrastructureError(f'{peer}: isolated UI action failed: {result.stderr[-4000:]}')
        try:
            return json.loads(result.stdout)
        except ValueError as exc:
            raise InfrastructureError('isolated UI action returned an invalid receipt') from exc

    def input(self, peer, step, point=None):
        try:
            result = self._execute(peer, {'step': step, 'point': point})
        except BaseException:
            self.release_inputs(step)
            raise
        self.last_input_point = result.get('point')

    def screenshot(self, peer, path):
        return self._execute(peer, {'screenshot': str(path)})
