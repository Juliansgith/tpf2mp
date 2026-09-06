"""Local-only stack dump for a failed UI fixture, never a relay upload.

No full process memory is requested. DbgHelp runs in the input helper process,
under its existing watchdog, against an already pinned test-game PID.
"""
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import re


def capture(pid, destination):
    import msvcrt
    if not re.fullmatch(r"[0-9a-fA-F]{32}", os.environ.get("TPF2MP_LIVE_UI_TOKEN", "")):
        raise RuntimeError("hang dumps require the disposable UI test token")
    if str(pid) not in os.environ.get("TPF2MP_LIVE_UI_PIDS", "").split(","):
        raise RuntimeError("hang dump PID is not owned by this UI run")
    kernel = C.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [W.DWORD, W.BOOL, W.DWORD]
    kernel.OpenProcess.restype = W.HANDLE
    kernel.CloseHandle.argtypes = [W.HANDLE]
    kernel.QueryFullProcessImageNameW.argtypes = [W.HANDLE, W.DWORD, W.LPWSTR, C.POINTER(W.DWORD)]
    process = kernel.OpenProcess(0x0400 | 0x0010, False, pid)
    if not process:
        raise C.WinError(C.get_last_error())
    try:
        length, name = W.DWORD(32768), C.create_unicode_buffer(32768)
        if not kernel.QueryFullProcessImageNameW(process, 0, name, C.byref(length)) or Path(name.value).name.lower() != "transportfever2.exe":
            raise RuntimeError("hang dump target is not the game")
        dbg = C.WinDLL("dbghelp", use_last_error=True)
        dbg.MiniDumpWriteDump.argtypes = [W.HANDLE, W.DWORD, W.HANDLE, W.DWORD, C.c_void_p, C.c_void_p, C.c_void_p]
        dbg.MiniDumpWriteDump.restype = W.BOOL
        with Path(destination).open("xb") as output:
            # MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules. Stack-only;
            # not MiniDumpWithFullMemory or private heap data.
            if not dbg.MiniDumpWriteDump(process, pid, msvcrt.get_osfhandle(output.fileno()), 0x1020, None, None, None):
                raise C.WinError(C.get_last_error())
        return {"path": str(destination), "bytes": Path(destination).stat().st_size,
                "fullMemory": False, "uploaded": False}
    finally:
        kernel.CloseHandle(process)
