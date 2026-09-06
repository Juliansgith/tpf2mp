import sys
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from live_ui.desktop import Desktop, InfrastructureError


class KeyboardTests(unittest.TestCase):
    def driver(self, scan):
        driver = object.__new__(Desktop)
        driver.u = Mock()
        driver.u.MapVirtualKeyW.return_value = scan
        return driver

    def test_rotation_letter_has_real_scan_on_press_and_release(self):
        driver = self.driver(0x32)
        with patch('live_ui.desktop.time.sleep'):
            driver._key(77)
        self.assertEqual([c.args for c in driver.u.keybd_event.call_args_list],
                         [(77, 0x32, 0, 0), (77, 0x32, 2, 0)])
        driver.u.MapVirtualKeyW.assert_called_with(77, 4)

    def test_extended_delete_is_not_keypad_delete(self):
        driver = self.driver(0xE053)
        with patch('live_ui.desktop.time.sleep'):
            driver._key(46)
        self.assertEqual([c.args for c in driver.u.keybd_event.call_args_list],
                         [(46, 0x53, 1, 0), (46, 0x53, 3, 0)])

    def test_key_released_after_interrupted_hold(self):
        driver = self.driver(1)
        with patch('live_ui.desktop.time.sleep', side_effect=RuntimeError('interrupted')):
            with self.assertRaises(RuntimeError): driver._key(27)
        driver.u.keybd_event.assert_called_with(27, 1, 2, 0)

    def test_missing_mapping_does_not_send_an_unknown_key(self):
        for scan in (0, 0xE11D):
            driver = self.driver(scan)
            with self.assertRaises(InfrastructureError): driver._key(77)
            driver.u.keybd_event.assert_not_called()

    def test_modifiers_surround_whole_mouse_input_and_release_on_failure(self):
        driver = self.driver(1)
        driver.focus = Mock()
        driver.check = Mock()
        events = []
        driver._key_event = lambda code, released=False: events.append((code, released))
        def failed_input(*args):
            events.append('mouse')
            raise InfrastructureError('covered window')
        driver._input = failed_input
        with patch('live_ui.desktop.time.sleep'):
            with self.assertRaises(InfrastructureError):
                driver.input('player1', {'action':'click', 'modifiers':['shift','c']})
        self.assertEqual(events, [(16,False), (67,False), 'mouse', (67,True), (16,True)])

    def test_parent_cleanup_only_releases_this_steps_inputs(self):
        driver = self.driver(1)
        driver.release_inputs({'action':'drag', 'modifiers':['shift','c']})
        driver.u.mouse_event.assert_called_once_with(4, 0, 0, 0, 0)
        self.assertEqual([c.args for c in driver.u.keybd_event.call_args_list],
                         [(67,1,2,0), (16,1,2,0)])
        driver.u.SetForegroundWindow.assert_not_called()
        driver.u.SetCursorPos.assert_not_called()

    def test_parent_cleanup_releases_control_chord_after_worker_timeout(self):
        driver = self.driver(1)
        driver.release_inputs({'action':'key', 'key':'ctrl+a'})
        self.assertEqual([c.args for c in driver.u.keybd_event.call_args_list],
                         [(65,1,2,0), (17,1,2,0)])
        driver.u.mouse_event.assert_not_called()


if __name__ == '__main__': unittest.main()
