"""Opt-in real native generation -> local relay transfer -> two loaded worlds.

No clicks or console paste. Uses disposable named worlds, an ephemeral local
relay, real authenticated HTTP/WS, and the normal host preparation worker.
The two local processes share one test-owned autosave guard; this is not a
substitute for a two-computer acceptance gate. Never run during another game.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer
from tpf2mp.cli import parser
from tpf2mp.lobby_cli import execute
from tpf2mp.relay_api import RelayCredentials, decode_invite, write_credentials
from tpf2mp_relay.app import create_app
from tpf2mp_relay.config import RelayConfig


async def run(args):
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[1]
    settings = RelayConfig(database_path=root / 'relay.sqlite3', public_base_url='http://127.0.0.1:8765',
        admin_token=os.urandom(32).hex(), token_pepper=os.urandom(32).hex(), allow_insecure_development=True)
    report = {'passed': False}
    async with TestClient(TestServer(create_app(settings))) as http:
        response = await http.post('/v1/sessions', json={'clientVersion':'native-lobby-acceptance','displayName':'Disposable local world'})
        assert response.status == 201
        created = await response.json()
        session, token = decode_invite(created['joinCode'])
        report['session'] = session
        credentials = {}
        for role, secret in (('host',created['hostToken']),('join',token)):
            credentials[role] = root / (role+'-credentials.json')
            write_credentials(credentials[role], RelayCredentials(str(http.make_url('/')).rstrip('/'),session,role,secret))
        async def call(role, op, state=None, extra=()):
            argv = ['relay-lobby',op,'--credentials',str(credentials[role]),'--game-executable',str(args.game),
                    '--mod-directory',str(args.mod)]
            if state is not None:
                argv += ['--revision',str(state['revision'])]
                if state['configDigest']: argv += ['--config-digest',state['configDigest']]
                if state['phase'] == 'preview-ready': argv += ['--preview-digest',state['previewDigest']]
            return await asyncio.to_thread(execute, parser().parse_args(argv+list(extra)))
        async def powershell(script, arguments, label):
            env = dict(os.environ)
            # A developer may start this from PowerShell 7; let Windows
            # PowerShell discover its own 5.1 modules rather than 7.x first.
            env.pop('PSModulePath', None)
            env['TPF2MP_ALLOW_INSECURE_RELAY_LOOPBACK'] = '1'
            ps = str(Path(env['WINDIR'])/'System32/WindowsPowerShell/v1.0/powershell.exe')
            with (root/(label+'.log')).open('wb') as log:
                process = await asyncio.create_subprocess_exec(ps,'-NoProfile','-ExecutionPolicy','Bypass',
                    '-File',str(repo/'tools'/script),*map(str,arguments),cwd=repo,env=env,stdout=log,stderr=log)
                code = await process.wait()
            if code: raise RuntimeError(f'{label} exited {code}; see retained log')
        try:
            state = await call('host','presence')
            state = await call('host','configure-new',state,('--configuration',str(args.configuration)))
            if args.preview:
                preview_results = []
                for attempt in range(2):
                    state = await call('host','generate',state)
                    await powershell('start_lobby_match.ps1',[
                        '-CredentialsPath',credentials['host'],'-GameExecutable',args.game,'-ModDirectory',args.mod,
                        '-ConfigDigest',state['configDigest'],'-AllowInsecureLoopback','-PrepareOnly'],f'preview-{attempt}')
                    state = await call('host','status')
                    assert state['phase'] == 'preview-ready' and state['save'] is None
                    for role in ('host','join'):
                        await call(role,'preview-download',state,('--preview-file',str(root/f'{role}-{attempt}.bmp')))
                    assert (root/f'host-{attempt}.bmp').read_bytes() == (root/f'join-{attempt}.bmp').read_bytes()
                    preview_results.append({k:state[k] for k in ('generationId','previewDigest','nativeDigest')})
                    assert all(not p['ready'] for p in state['peers'].values())
                    if attempt == 0:
                        await call('host','presence')
                        state = await call('host','ready',state)
                assert preview_results[0]['nativeDigest'] == preview_results[1]['nativeDigest']
                assert preview_results[0]['previewDigest'] != preview_results[1]['previewDigest']
                report['previews'] = preview_results
                await call('host','presence')
            await call('join','presence')
            state = await call('host','ready',state)
            state = await call('join','ready',state)
            state = await call('host','start',state)
            digest = state['configDigest']
            print(f'Generating {session}',flush=True)
            await powershell('start_lobby_match.ps1',[
                '-CredentialsPath',credentials['host'],'-GameExecutable',args.game,'-ModDirectory',args.mod,
                '-ConfigDigest',digest,'-AllowInsecureLoopback','-PrepareOnly'],'generate')
            state = await call('host','status')
            assert state['phase'] == 'save-ready'
            report['lobby'] = state
            prepared = Path(os.environ['LOCALAPPDATA'])/'TPF2MP/sessions'/session/'player1/lobby-prepared-world.json'
            world = json.loads(prepared.read_text(encoding='utf-8-sig'))
            report['world'] = world
            if args.prepare_only:
                report['passed'] = True
                print('PASS native previews + regeneration + both peers download + accepted final generation',flush=True)
                return
            print('Generated save verified; transferring through relay and loading both worlds',flush=True)
            pair_args = [
                '-StartingSave',world['savePath'],'-GameExecutable',args.game,'-LocalModsPath',args.mod.parent,
                '-Session',session,'-HostCredentials',credentials['host'],'-JoinCredentials',credentials['join'],
                '-ConfigDigest',digest,'-AgentMode',state['config']['world']['agentMode']]
            if state['config']['world']['townDevelopment']: pair_args.append('-TownDevelopment')
            await powershell('run_lobby_native_acceptance.ps1',pair_args,'pair')
            pair = json.loads((repo/'runtime/lobby-native-acceptance'/session/'report.json').read_text(encoding='utf-8-sig'))
            assert pair['passed']
            report.update(passed=True,pair=pair)
            print(f'PASS generation + relay transfer + direct loads + checkpoint: {session}',flush=True)
        except Exception as exc:
            report['error'] = str(exc)
            raise
        finally:
            (root/'report.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
            for path in credentials.values(): path.unlink(missing_ok=True)


if __name__ == '__main__':
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--game',type=Path,required=True)
    cli.add_argument('--mod',type=Path,required=True)
    cli.add_argument('--configuration',type=Path,required=True)
    cli.add_argument('--output',type=Path,required=True)
    cli.add_argument('--preview',action='store_true')
    cli.add_argument('--prepare-only',action='store_true')
    asyncio.run(run(cli.parse_args()))
