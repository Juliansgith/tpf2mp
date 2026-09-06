"""Physical Windows input, pinned to exact live game handles. No clipboard/console."""
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import time

KEY_CODES = {"escape": 27, "enter": 13, "tab": 9, "backspace": 8, "delete": 46,
             "space": 32, "shift": 16, "r": 82, "t": 84, "m": 77, "n": 78, "b": 66,
             "c": 67, "comma": 188, "period": 190}


class InfrastructureError(RuntimeError):
    pass


class GameExited(InfrastructureError):
    pass


class Desktop:
    def __init__(self, peers):
        if os.name != "nt":
            raise InfrastructureError("real UI tests require an unlocked Windows desktop")
        from PIL import ImageGrab
        self.grab = ImageGrab.grab
        self.u = C.WinDLL("user32", use_last_error=True)
        self.k = C.WinDLL("kernel32", use_last_error=True)
        self.u.GetForegroundWindow.restype = W.HWND
        self.u.GetAncestor.argtypes = [W.HWND, W.UINT]
        self.u.GetAncestor.restype = W.HWND
        self.u.WindowFromPoint.argtypes = [W.POINT]
        self.u.WindowFromPoint.restype = W.HWND
        self.u.GetCursorPos.argtypes = [C.POINTER(W.POINT)]
        self.u.GetClipCursor.argtypes = [C.POINTER(W.RECT)]
        self.u.ClipCursor.argtypes = [C.c_void_p]
        self.k.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
        self.k.OpenProcess.restype = W.HANDLE
        self.k.WaitForSingleObject.argtypes = [W.HANDLE, W.DWORD]
        self.k.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
        self.k.CloseHandle.argtypes = [W.HANDLE]
        for name in ("GetClientRect", "ClientToScreen", "GetWindowThreadProcessId", "GetWindowRect"):
            getattr(self.u, name).argtypes = [W.HWND, C.c_void_p]
        for name in ("SetForegroundWindow", "BringWindowToTop", "IsWindow", "IsWindowVisible", "IsIconic", "IsZoomed"):
            getattr(self.u, name).argtypes = [W.HWND]
        self.u.ShowWindow.argtypes = [W.HWND, C.c_int]
        self.u.AttachThreadInput.argtypes = [W.DWORD, W.DWORD, W.BOOL]
        self.u.SetWindowPos.argtypes = [W.HWND, W.HWND, C.c_int, C.c_int, C.c_int, C.c_int, W.UINT]
        self.u.MapVirtualKeyW.argtypes = [W.UINT, W.UINT]
        self.u.MapVirtualKeyW.restype = W.UINT
        self.u.keybd_event.argtypes = [W.BYTE, W.BYTE, W.DWORD, C.c_size_t]
        self.u.GetWindowLongW.argtypes = [W.HWND, C.c_int]
        self.u.SendMessageTimeoutW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM, W.UINT, W.UINT, C.POINTER(C.c_size_t)]
        for name in ("SetActiveWindow", "SetFocus"):
            getattr(self.u, name).argtypes = [W.HWND]
            getattr(self.u, name).restype = W.HWND
        self.u.SetThreadDpiAwarenessContext.argtypes = [C.c_void_p]
        self.u.SetThreadDpiAwarenessContext.restype = C.c_void_p
        self.u.SetThreadDpiAwarenessContext(C.c_void_p(-4))
        self.targets = {}
        self.activation_pids = set(peers.values())
        for value in os.environ.get("TPF2MP_LIVE_UI_PIDS", "").split(","):
            if value.isdigit():
                self.activation_pids.add(int(value))
        try:
            for peer, pid in peers.items():
                handle = self.k.OpenProcess(0x100000 | 0x1000, False, pid)
                if not handle:
                    raise InfrastructureError(f"cannot pin game PID {pid}")
                self.targets[peer] = {"pid": pid, "handle": handle}
                length, name = W.DWORD(32768), C.create_unicode_buffer(32768)
                if not self.k.QueryFullProcessImageNameW(handle, 0, name, C.byref(length)) or Path(name.value).name.lower() != "transportfever2.exe":
                    raise InfrastructureError(f"PID {pid} is not TransportFever2.exe")
                windows = []
                callback_type = C.WINFUNCTYPE(W.BOOL, W.HWND, W.LPARAM)
                def collect(hwnd, _):
                    owner = W.DWORD()
                    self.u.GetWindowThreadProcessId(hwnd, C.byref(owner))
                    if owner.value == pid and self.u.IsWindowVisible(hwnd):
                        rect = W.RECT()
                        if self.u.GetClientRect(hwnd, C.byref(rect)) and rect.right > 500 and rect.bottom > 300:
                            windows.append(hwnd)
                    return True
                self.u.EnumWindows(callback_type(collect), 0)
                if len(windows) != 1:
                    raise InfrastructureError(f"PID {pid}: expected one game window, found {len(windows)} (crash dialog?)")
                self.targets[peer]["hwnd"] = windows[0]
        except BaseException:
            self.close()
            raise

    def close(self):
        for target in self.targets.values():
            self.k.CloseHandle(target["handle"])
        self.targets.clear()

    def check(self, peer, focused=False):
        target = self.targets[peer]
        hwnd = target["hwnd"]
        if self.k.WaitForSingleObject(target["handle"], 0) != 258 or not self.u.IsWindow(hwnd):
            raise GameExited(f"{peer} game process/window exited")
        owner = W.DWORD()
        self.u.GetWindowThreadProcessId(hwnd, C.byref(owner))
        if owner.value != target["pid"]:
            raise InfrastructureError("window identity changed; input refused")
        if self.u.IsZoomed(hwnd):
            raise InfrastructureError("suite requires windowed, non-maximized games")
        if focused and self.u.GetForegroundWindow() != hwnd:
            raise InfrastructureError("game lost foreground; input refused (do not use the desktop during tests)")
        return hwnd

    def focus(self, peer):
        hwnd = self.check(peer)
        if self.u.GetForegroundWindow() == hwnd:
            return hwnd
        if self.u.IsIconic(hwnd):
            self.u.ShowWindow(hwnd, 9)  # Restore ONLY a minimized window.
        for _ in range(15):
            # Do not AttachThreadInput/SetFocus across the game's queue: a
            # native loader stall would then also hang the supervising input
            # thread. Use normal activation plus the checked caption fallback.
            self.u.SetWindowPos(hwnd, W.HWND(0), 0, 0, 0, 0, 0x4053)  # ASYNC | NO_MOVE | NO_SIZE | NO_ACTIVATE | SHOW
            self.u.SetForegroundWindow(hwnd)
            if self.u.GetForegroundWindow() == hwnd:
                return hwnd
            time.sleep(.1)
        # Windows can deny programmatic foreground even on an unlocked desktop.
        # A normal click on the verified non-client title bar is permitted, but
        # never click the client, caption buttons, or another app to steal focus.
        self._activate_caption(peer)
        if self.u.GetForegroundWindow() != hwnd:
            raise InfrastructureError(f"Windows refused foreground for {peer}; no gameplay input sent")
        return hwnd

    def _activate_caption(self, peer):
        hwnd = self.check(peer)
        was_topmost = bool(self.u.GetWindowLongW(hwnd, -20) & 8)
        rect = W.RECT()
        self.u.GetWindowRect(hwnd, C.byref(rect))
        point = W.POINT(rect.left + 160, rect.top + 16)
        previous_clip = W.RECT()
        released_clip = False
        clip_owner = None
        try:
            self.u.SetWindowPos(hwnd, W.HWND(-1), 0, 0, 0, 0, 0x4013)  # ASYNC | NO_MOVE | NO_SIZE | NO_ACTIVATE
            time.sleep(.1)
            hit = self.u.GetAncestor(self.u.WindowFromPoint(point), 2)
            result = C.c_size_t()
            packed = ((point.y & 0xffff) << 16) | (point.x & 0xffff)
            responded = self.u.SendMessageTimeoutW(hwnd, 0x84, 0, packed, 2, 500, C.byref(result))
            if hit != hwnd or not responded or result.value != 2:  # HTCAPTION
                raise InfrastructureError("cannot safely activate this window's title bar")
            actual = W.POINT()
            for attempt in range(15):
                self.check(peer)
                current_clip = W.RECT()
                if not self.u.GetClipCursor(C.byref(current_clip)):
                    raise InfrastructureError("cannot read cursor confinement; activation refused")
                if not (current_clip.left <= point.x < current_clip.right
                        and current_clip.top <= point.y < current_clip.bottom):
                    foreground_pid = W.DWORD()
                    self.u.GetWindowThreadProcessId(self.u.GetForegroundWindow(), C.byref(foreground_pid))
                    if foreground_pid.value not in self.activation_pids:
                        raise InfrastructureError("another application's cursor confinement prevents activation")
                    if not released_clip:
                        previous_clip, clip_owner = current_clip, foreground_pid.value
                    if not self.u.ClipCursor(None):
                        raise InfrastructureError("cannot release test peer cursor confinement")
                    released_clip = True
                if not self.u.SetCursorPos(point.x, point.y) or not self.u.GetCursorPos(C.byref(actual)):
                    raise InfrastructureError("cannot position/read cursor for caption activation")
                if (actual.x, actual.y) == (point.x, point.y):
                    break
                # The still-foreground SDL peer can reapply its clip between
                # release and positioning. Retry ONLY this pre-click handoff,
                # only if a fresh clip explains the displacement. An external
                # mouse move is not permission to take over another app.
                raced_clip = W.RECT()
                if not self.u.GetClipCursor(C.byref(raced_clip)) or (
                        raced_clip.left <= point.x < raced_clip.right
                        and raced_clip.top <= point.y < raced_clip.bottom):
                    raise InfrastructureError("cursor moved outside verified caption without confinement; activation refused")
                time.sleep(.01)
            else:
                raise InfrastructureError(f"cursor confinement persisted during caption handoff: target={(point.x, point.y)}, actual={(actual.x, actual.y)}")
            if self.u.GetAncestor(self.u.WindowFromPoint(point), 2) != hwnd:
                raise InfrastructureError("verified caption became covered; activation refused")
            self.u.mouse_event(2, 0, 0, 0, 0)
            try:
                time.sleep(.08)
            finally:
                self.u.mouse_event(4, 0, 0, 0, 0)
            time.sleep(.15)
        finally:
            if released_clip and self.u.GetForegroundWindow() != hwnd:
                foreground_pid = W.DWORD()
                self.u.GetWindowThreadProcessId(self.u.GetForegroundWindow(), C.byref(foreground_pid))
                if foreground_pid.value == clip_owner:
                    self.u.ClipCursor(C.byref(previous_clip))
            if not was_topmost:
                self.u.SetWindowPos(hwnd, W.HWND(-2), 0, 0, 0, 0, 0x4013)

    def point(self, peer, xy):
        hwnd = self.check(peer, True)
        rect = W.RECT()
        if not self.u.GetClientRect(hwnd, C.byref(rect)):
            raise InfrastructureError("cannot read client area")
        point = W.POINT(round(xy[0] * (rect.right - 1)), round(xy[1] * (rect.bottom - 1)))
        if not self.u.ClientToScreen(hwnd, C.byref(point)):
            raise InfrastructureError("cannot map client coordinate")
        hit = self.u.GetAncestor(self.u.WindowFromPoint(point), 2)
        if hit != hwnd:
            raise InfrastructureError("click location is covered by another window; input refused")
        return point

    def screenshot(self, peer, path):
        hwnd = self.check(peer)
        try:
            self.focus(peer)
        except InfrastructureError:
            pass  # A failed-focus screenshot is diagnostic, never input proof.
        rect = W.RECT()
        self.u.GetWindowRect(hwnd, C.byref(rect))
        time.sleep(.15)
        self.grab(bbox=(rect.left, rect.top, rect.right, rect.bottom), all_screens=True).save(path)
        return {"foregroundVerified": self.u.GetForegroundWindow() == hwnd}

    def input(self, peer, step, point=None):
        # Activation can briefly bounce between the two newly loaded SDL
        # windows. Retrying activation before any gameplay input is safe;
        # never retry the actual click/drag/key after it has been issued.
        for attempt in range(3):
            try:
                self.focus(peer)
                time.sleep(.3)
                self.check(peer, True)
                break
            except GameExited:
                raise
            except InfrastructureError:
                if attempt == 2:
                    raise
                time.sleep(.25)
        pressed = []
        try:
            for modifier in step.get('modifiers', []):
                self.check(peer, True)
                code = {'shift': 16, 'c': 67}[modifier]
                self._key_event(code)
                pressed.append(code)
            return self._input(peer, step, point)
        finally:
            # Never leave a construction modifier held after a failed click,
            # focus loss, or interrupted drag. No state spans recipe steps.
            for code in reversed(pressed):
                self._key_event(code, released=True)

    def _input(self, peer, step, point=None):
        op = step["action"]
        point = point or step.get("point")
        if point is not None:
            start = self.point(peer, point)
            stable, samples = 0, []
            for _ in range(12):
                self.check(peer, True)
                self.u.SetCursorPos(start.x, start.y)
                time.sleep(.1)
                actual = W.POINT()
                self.u.GetCursorPos(C.byref(actual))
                samples.append([actual.x, actual.y])
                stable = stable + 1 if (actual.x, actual.y) == (start.x, start.y) else 0
                if stable >= 3:
                    break
            if stable < 3:
                clip = W.RECT()
                self.u.GetClipCursor(C.byref(clip))
                raise InfrastructureError(f"cursor would not settle at target {[start.x, start.y]}; "
                                          f"observed {samples}; clip {[clip.left, clip.top, clip.right, clip.bottom]}; "
                                          "input refused")
            self.last_input_point = {"x": start.x, "y": start.y}
        self.check(peer, True)
        if op == "move":
            return
        if op in ("click", "doubleClick", "drag"):
            down, up = (8, 16) if step.get("button") == "right" else (2, 4)
            self.u.mouse_event(down, 0, 0, 0, 0)
            try:
                if op == "drag":
                    end = self.point(peer, step["to"])
                    for index in range(1, 21):
                        self.check(peer, True)
                        self.u.SetCursorPos(round(start.x + (end.x-start.x)*index/20), round(start.y + (end.y-start.y)*index/20))
                        time.sleep(step.get("duration", .6) / 20)
                else:
                    time.sleep(.04 if op == "doubleClick" else .20)
            finally:
                self.u.mouse_event(up, 0, 0, 0, 0)
            if op == "doubleClick":
                # A requested native double-click, not a retry of a failed
                # gameplay action. Keep both presses within Windows' interval.
                time.sleep(.04)
                self.check(peer, True)
                self.u.mouse_event(down, 0, 0, 0, 0)
                try:
                    time.sleep(.04)
                finally:
                    self.u.mouse_event(up, 0, 0, 0, 0)
        elif op == "wheel":
            self.u.mouse_event(0x800, 0, 0, step["delta"], 0)
        elif op == "key":
            if step["key"] == "ctrl+a":
                self._key_event(17)
                try:
                    self._key(65)
                finally:
                    self._key_event(17, released=True)
            else:
                self._key(KEY_CODES[step["key"]])
        elif op == "text":
            # WM_CHAR goes only to this pinned game's focused control; never clipboard.
            # Support BMP labels; surrogate pairs are sent as UTF-16 units.
            self.u.PostMessageW.argtypes = [W.HWND, W.UINT, W.WPARAM, W.LPARAM]
            encoded = step["text"].encode("utf-16-le")
            for index in range(0, len(encoded), 2):
                self.check(peer, True)
                self.u.PostMessageW(self.targets[peer]["hwnd"], 0x102,
                                    int.from_bytes(encoded[index:index+2], "little"), 1)
        else:
            raise InfrastructureError(f"input action is unsupported: {op}")

    def release_inputs(self, step):
        # A forcibly killed worker cannot run its finally blocks. The parent
        # sends only releases for this step, without activation, movement or a
        # second click. This also works after the target process has exited.
        if step.get('action') in ('click', 'doubleClick', 'drag'):
            self.u.mouse_event(16 if step.get('button') == 'right' else 4, 0, 0, 0, 0)
        keys = [KEY_CODES[m] for m in step.get('modifiers', [])]
        if step.get('action') == 'key':
            keys.extend([17, 65] if step['key'] == 'ctrl+a' else [KEY_CODES[step['key']]])
        for code in reversed(keys):
            self._key_event(code, released=True)

    def _key(self, key):
        self._key_event(key)
        try:
            time.sleep(.08)
        finally:
            self._key_event(key, released=True)

    def _key_event(self, key, released=False):
        # SDL uses the hardware scan code for ordinary gameplay bindings.
        # Sending bScan=0 can leave letter keys unrecognized despite WM_KEYDOWN.
        scan = self.u.MapVirtualKeyW(key, 4)  # MAPVK_VK_TO_VSC_EX
        if not scan or scan >> 8 not in (0, 0xE0):
            raise InfrastructureError(f'unsupported physical key mapping: {key}')
        flags = (1 if scan >> 8 == 0xE0 else 0) | (2 if released else 0)
        self.u.keybd_event(key, scan & 0xff, flags, 0)
