"""Shared plumbing for the offline TPF2MP terrain fast-path proofs.

Adapted from silver2127's tpf2-bigmap (commit 4f0de6f), MIT licence,
Copyright (c) 2026 silver2127 -- tools/test_terrain_align_fast.py,
tools/test_terrain_refine.py and tools/test_terrain_minmax.py. What the three
scripts share (argument handling, the kernel32 entry points and the fake host
seam) lives here; each proof stays one file, as in the original project.

The proofs run the stock machine code of TransportFever2.exe (Build 35924)
beside the replacement in tpf2mp_hook_build35924.dll inside this process. No
game process and no installed file is touched. Loading the hook DLL here is
safe: its worker thread sees that the host process is not the pinned game
build, publishes a "rejected" status file under %TEMP%\\tpf2mp_native and exits
without installing anything.

These files are deliberately NOT named test_*.py: pytest must not collect them
in CI, where numpy, capstone, pefile and the game executable are all absent.
tests/test_native_terrain_fast_proof.py runs them as subprocesses when the
environment provides both.
"""
import argparse
import ctypes as C
import importlib.util
import os
import sys
from pathlib import Path

IMAGE = 0x140000000                                  # TransportFever2.exe preferred base
ROOT = Path(__file__).resolve().parents[2]           # repository root
DEFAULT_DLL = ROOT / 'runtime' / 'native-build' / 'Release' / 'tpf2mp_hook_build35924.dll'
REQUIRED = ('numpy', 'capstone', 'pefile')

# TPF2MP_TerrainFastTestInstall argument bits and result bits
# (native/include/tpf2mp/native_terrain_fast.hpp).
FEATURE_ALIGN, FEATURE_REFINE, FEATURE_MINMAX = 1, 2, 4
STATUS_ALIGN, STATUS_REFINE, STATUS_MINMAX_SCAN, STATUS_BLOCK_COPY = 1, 2, 4, 8

# tpf2mp::terrain_fast::Host services. Every one takes the opaque context first
# and returns int for ABI stability: non-zero means success.
basetype = C.CFUNCTYPE(C.c_uint64, C.c_void_p)
verifytype = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.POINTER(C.c_uint8), C.c_size_t)
hooktype = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.c_void_p, C.POINTER(C.c_void_p))
patchtype = C.CFUNCTYPE(C.c_int, C.c_void_p, C.c_uint64, C.POINTER(C.c_uint8), C.c_size_t)


class Host(C.Structure):
    """struct Host { context; module_base; verify_bytes; install_hook; patch_bytes; }."""
    _fields_ = [('context', C.c_void_p), ('module_base', basetype), ('verify_bytes', verifytype),
                ('install_hook', hooktype), ('patch_bytes', patchtype)]


def fail(message):
    """One line on stderr and a non-zero exit: the harness cannot run here."""
    print(f'ERROR: {message}', file=sys.stderr)
    raise SystemExit(2)


def require_dependencies():
    missing = [name for name in REQUIRED if importlib.util.find_spec(name) is None]
    if missing:
        fail(f"missing Python package(s): {', '.join(missing)} "
             f"(pip install {' '.join(REQUIRED)})")


def parse_args(description):
    """--exe/--dll, defaulting to TPF2MP_GAME_EXECUTABLE/TPF2MP_NATIVE_HOOK_DLL."""
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument('--exe', default=os.environ.get('TPF2MP_GAME_EXECUTABLE'),
                        help='Build 35924 TransportFever2.exe (default: $TPF2MP_GAME_EXECUTABLE)')
    parser.add_argument('--dll', default=os.environ.get('TPF2MP_NATIVE_HOOK_DLL') or str(DEFAULT_DLL),
                        help='tpf2mp_hook_build35924.dll (default: $TPF2MP_NATIVE_HOOK_DLL, '
                             'else runtime/native-build/Release under the repository root)')
    args = parser.parse_args()
    if not args.exe:
        fail('no game executable: set TPF2MP_GAME_EXECUTABLE or pass --exe PATH '
             '(Build 35924 TransportFever2.exe)')
    exe, dll = Path(args.exe), Path(args.dll)
    if not exe.is_file():
        fail(f'game executable not found: {exe}')
    if not dll.is_file():
        fail(f'native hook DLL not found: {dll} (build native/ or set TPF2MP_NATIVE_HOOK_DLL)')
    return exe, dll


def kernel32():
    k32 = C.WinDLL('kernel32', use_last_error=True)
    k32.VirtualAlloc.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.c_uint32]
    k32.VirtualAlloc.restype = C.c_void_p
    k32.VirtualProtect.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32, C.POINTER(C.c_uint32)]
    k32.VirtualFree.argtypes = [C.c_void_p, C.c_size_t, C.c_uint32]
    k32.GetProcAddress.argtypes = [C.c_void_p, C.c_char_p]
    k32.GetProcAddress.restype = C.c_void_p
    k32.RtlAddFunctionTable.argtypes = [C.c_void_p, C.c_uint32, C.c_uint64]
    return k32


def load_dll(path):
    try:
        return C.CDLL(str(path))
    except OSError as exc:                            # noqa: BLE001 - reported as one line
        fail(f'cannot load {path}: {exc}')


def export(dll, name):
    """One clear line instead of a ctypes traceback when the DLL predates the fast paths."""
    try:
        return getattr(dll, name)
    except AttributeError:
        fail(f'{name} is missing from {dll._name}: rebuild the native hook DLL')


def installer(dll):
    """TPF2MP_TerrainFastTestInstall(host, features, error, size) -> (status mask, error text)."""
    entry = export(dll, 'TPF2MP_TerrainFastTestInstall')
    entry.argtypes = [C.POINTER(Host), C.c_int, C.POINTER(C.c_char), C.c_size_t]
    entry.restype = C.c_int

    def install(host, features):
        error = C.create_string_buffer(1024)
        mask = entry(C.byref(host), features, error, len(error))
        return mask, error.value.decode('utf-8', 'replace')
    return install
