import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from live_ui.isolated_desktop import IsolatedDesktop
from live_ui.desktop import InfrastructureError


class IsolatedInputTests(unittest.TestCase):
    def desktop(self):
        driver = object.__new__(IsolatedDesktop)
        driver.targets = {'player1': {'pid': 123}}
        driver.check = lambda peer: None
        driver.release_inputs = Mock()
        return driver

    def test_each_step_is_bounded_and_no_shell_is_used(self):
        driver = self.desktop()
        with patch('live_ui.isolated_desktop.subprocess.run', return_value=
                   subprocess.CompletedProcess([], 0, '{"point":{"x":10,"y":20}}', '')) as run:
            driver.input('player1', {'peer': 'player1', 'action': 'click', 'point': [.5, .4]})
        args, options = run.call_args
        self.assertEqual(args[0][-1], '123')
        self.assertEqual(options['timeout'], 20)
        self.assertNotIn('shell', options)
        self.assertEqual(json.loads(options['input'])['step']['action'], 'click')
        self.assertEqual(driver.last_input_point, {'x': 10, 'y': 20})

    def test_timeout_never_retries_possible_partially_issued_click(self):
        driver = self.desktop()
        with patch('live_ui.isolated_desktop.subprocess.run', side_effect=
                   subprocess.TimeoutExpired('worker', 20)) as run:
            with self.assertRaisesRegex(InfrastructureError, 'watchdog'):
                driver.input('player1', {'peer': 'player1', 'action': 'click', 'point': [.5, .4]})
        self.assertEqual(run.call_count, 1)
        driver.release_inputs.assert_called_once()

    def test_failure_and_invalid_receipt_are_not_success(self):
        for result in (subprocess.CompletedProcess([], 1, '', 'refused foreground'),
                       subprocess.CompletedProcess([], 0, 'not json', '')):
            with patch('live_ui.isolated_desktop.subprocess.run', return_value=result):
                with self.assertRaises(InfrastructureError):
                    self.desktop().screenshot('player1', 'test.png')

    def test_dump_watchdog_is_bounded_and_never_retries_input(self):
        driver = self.desktop()
        with tempfile.TemporaryDirectory() as folder:
            driver.failure_directory = folder
            with patch('live_ui.isolated_desktop.subprocess.run', side_effect=[
                    subprocess.TimeoutExpired('input', 20),
                    subprocess.TimeoutExpired('dump', 10)]) as run:
                with self.assertRaisesRegex(InfrastructureError, 'no further input'):
                    driver.input('player1', {'peer': 'player1', 'action': 'click', 'point': [.5, .4]})
            self.assertEqual(run.call_count, 2)
            diagnostic = run.call_args_list[1].kwargs
            self.assertEqual(diagnostic['timeout'], 10)
            self.assertEqual(set(json.loads(diagnostic['input'])), {'dump'})
            self.assertEqual(len(list(Path(folder).glob('*-dump-error.txt'))), 1)

    def test_lost_process_is_checked_before_spawning_input(self):
        driver = self.desktop()
        def gone(_): raise InfrastructureError('process exited')
        driver.check = gone
        with patch('live_ui.isolated_desktop.subprocess.run') as run:
            with self.assertRaises(InfrastructureError): driver.screenshot('player1', 'test.png')
        run.assert_not_called()


if __name__ == '__main__': unittest.main()
