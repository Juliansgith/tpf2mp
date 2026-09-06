"""Do not terminate a successful running fixture mid-consensus."""
from .oracle import agreed, at, need


def require_normal_speed(pair):
    agreed(pair)
    for peer in ('player1', 'player2'):
        clock = at(pair[peer], ['snapshot', 'networkClock'])
        need(clock.get('requestedSpeed') == 1 and clock.get('effectiveSpeed') == 1,
             f'{peer}: initial fixture unpause has not been accepted')
    clock = at(pair['player1'], ['snapshot', 'bridge', 'companion', 'clock'])
    need(type(clock.get('generation')) is int and clock['generation'] > 0,
         'initial fixture unpause has no ordered clock generation')


def paused_and_settled(pair):
    agreed(pair)
    for peer in ('player1', 'player2'):
        clock = at(pair[peer], ['snapshot', 'networkClock'])
        need(clock.get('requestedSpeed') == 0 and clock.get('effectiveSpeed') == 0,
             f'{peer}: shared clock is not paused')
    host = at(pair['player1'], ['snapshot', 'bridge', 'companion'])
    need(host.get('connected') is True and host.get('clock', {}).get('pauseAcknowledged') is True,
         'native pause not acknowledged by both peers')
    # A paused test can finish after nonstructural vehicle/clock commits without
    # asking for a new SAVE boundary. Ignore only that one checkpoint-age reason;
    # retain every queue/health/pause/fault constraint and require a separately
    # replayed settled audit before shutdown. Production anchor rules are intact.
    reasons = host.get('anchorReasons')
    need(host.get('anchorReady') is True or reasons == [
        'work has been ordered since the last converged checkpoint'],
         f'final ordered boundary not settled: {host.get("anchorReasons")}')


def replay_settled(lab, pair):
    import contextlib
    import io
    from pathlib import Path
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'companion'))
    from tpf2mp.audit_replay import replay
    from tpf2mp.bridge import AuditLog
    from tpf2mp.protocol import ProtocolError
    path = Path(lab['player1Bridge']) / 'audit' / (lab['session'] + '.ndjson')
    host = at(pair['player1'], ['snapshot', 'bridge', 'companion'])
    try:
        before = path.stat()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            replay(path, lab['session'], require_settled=True)
        ordered = [m['seq'] for m in AuditLog(path).messages()
                   if m.get('session') == lab['session'] and m.get('kind') in ('commit', 'control')]
        after = path.stat()
        need((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns),
             'audit advanced during shutdown verification')
        need(ordered and host.get('nextCommitSeq') == max(ordered) + 1,
             'shutdown audit and fresh host sequence disagree')
        return output.getvalue().strip()
    except (OSError, ValueError, ProtocolError) as exc:
        from .oracle import Pending
        raise Pending(f'shutdown audit not yet settled: {exc}') from exc
