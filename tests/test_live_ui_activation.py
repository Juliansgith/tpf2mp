"""Caption handoff may retry cursor confinement, never a gameplay click."""
import unittest
from unittest.mock import patch

from tools.live_ui.desktop import Desktop, InfrastructureError


class NativeDesktop:
    def __init__(self, races=0, foreign=False, external_move=False, covered=False):
        self.races, self.foreign = races, foreign
        self.external_move, self.covered = external_move, covered
        self.clip = (0, 140, 2000, 2000)
        self.cursor = (0, 0)
        self.foreground, self.positions, self.hits = 2, 0, 0
        self.events, self.releases, self.restores = [], 0, 0

    def GetWindowLongW(self, *args): return 0
    def GetWindowRect(self, hwnd, out):
        out._obj.left, out._obj.top = 100, 100
        out._obj.right, out._obj.bottom = 1100, 1000
        return 1
    def SetWindowPos(self, *args): return 1
    def WindowFromPoint(self, point):
        self.hits += 1
        return 3 if self.covered and self.hits > 1 else 1
    def GetAncestor(self, hwnd, flags): return hwnd
    def SendMessageTimeoutW(self, *args):
        args[-1]._obj.value = 2
        return 1
    def GetClipCursor(self, out):
        out._obj.left, out._obj.top, out._obj.right, out._obj.bottom = self.clip
        return 1
    def GetForegroundWindow(self): return self.foreground
    def GetWindowThreadProcessId(self, hwnd, out):
        out._obj.value = 999 if self.foreign else (10 if hwnd == 1 else 20)
        return 1
    def ClipCursor(self, value):
        if value is None:
            self.releases += 1
            self.clip = (-10000, -10000, 10000, 10000)
        else:
            self.restores += 1
            self.clip = (value._obj.left, value._obj.top, value._obj.right, value._obj.bottom)
        return 1
    def SetCursorPos(self, x, y):
        self.positions += 1
        if self.positions <= self.races:
            self.clip = (0, 140, 2000, 2000)
            self.cursor = (x, 140)
        else:
            self.cursor = (x + 10, y) if self.external_move else (x, y)
        return 1
    def GetCursorPos(self, out):
        out._obj.x, out._obj.y = self.cursor
        return 1
    def mouse_event(self, flags, *args):
        self.events.append(flags)
        if flags == 4: self.foreground = 1


class ActivationTests(unittest.TestCase):
    def run_handoff(self, native):
        driver = object.__new__(Desktop)
        driver.u, driver.activation_pids = native, {10, 20}
        driver.check = lambda peer: 1
        with patch('tools.live_ui.desktop.time.sleep'):
            driver._activate_caption('player1')

    def test_reapplied_peer_clip_retries_before_single_caption_click(self):
        native = NativeDesktop(races=2)
        self.run_handoff(native)
        self.assertEqual(native.positions, 3)
        self.assertEqual(native.events, [2, 4])
        self.assertEqual(native.restores, 0)

    def test_persistent_clip_is_bounded_and_restored_without_click(self):
        native = NativeDesktop(races=100)
        with self.assertRaisesRegex(InfrastructureError, 'persisted'):
            self.run_handoff(native)
        self.assertEqual(native.positions, 15)
        self.assertEqual(native.events, [])
        self.assertEqual(native.restores, 1)

    def test_foreign_confinement_never_released(self):
        native = NativeDesktop(foreign=True)
        with self.assertRaisesRegex(InfrastructureError, "another application's"):
            self.run_handoff(native)
        self.assertEqual((native.releases, native.positions, native.events), (0, 0, []))

    def test_external_move_is_not_retried(self):
        native = NativeDesktop(external_move=True)
        with self.assertRaisesRegex(InfrastructureError, 'without confinement'):
            self.run_handoff(native)
        self.assertEqual(native.positions, 1)
        self.assertEqual(native.events, [])

    def test_caption_covered_after_position_refuses_click(self):
        native = NativeDesktop(covered=True)
        with self.assertRaisesRegex(InfrastructureError, 'became covered'):
            self.run_handoff(native)
        self.assertEqual(native.events, [])


if __name__ == '__main__': unittest.main()
