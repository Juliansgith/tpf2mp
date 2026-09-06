"""Shutdown must prove the complete ordered audit, not just equal snapshots."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'tools'))
sys.path.insert(0, str(ROOT/'companion'))
from live_ui.settling import replay_settled
from live_ui.oracle import Pending
from tpf2mp.protocol import ProtocolError


class ShutdownAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root/'audit').mkdir()
        self.path = self.root/'audit/localhost-ui-audit.ndjson'
        self.path.write_text('test audit')
        self.lab = dict(player1Bridge=str(self.root), session='localhost-ui-audit')
        self.pair = {'player1': {'snapshot': {'bridge': {'companion': {'nextCommitSeq': 3}}}}}

    def run_replay(self, effect=None, seq=2):
        messages = [dict(session=self.lab['session'], kind='commit', seq=seq)]
        with patch('tpf2mp.audit_replay.replay', side_effect=effect) as replay, \
                patch('tpf2mp.bridge.AuditLog.messages', return_value=iter(messages)):
            result = replay_settled(self.lab, self.pair)
            replay.assert_called_once_with(self.path, self.lab['session'], require_settled=True)
            return result

    def test_requires_replay_settled_and_same_host_sequence(self):
        self.run_replay()
        with self.assertRaises(Pending): self.run_replay(seq=1)
        with self.assertRaises(Pending): self.run_replay(seq=3)

    def test_unacknowledged_commit_blocks_shutdown(self):
        with self.assertRaisesRegex(Pending, 'await peer digests'):
            self.run_replay(ProtocolError('audit is valid but not settled: 1 commit(s) await peer digests'))

    def test_live_append_during_check_requires_another_sample(self):
        def append(*args, **kwargs):
            with self.path.open('a') as stream: stream.write('new data')
        with self.assertRaisesRegex(Pending, 'advanced'):
            self.run_replay(append)

    def test_missing_audit_is_not_success(self):
        self.path.unlink()
        with self.assertRaises(Pending): self.run_replay()


if __name__ == '__main__': unittest.main()
