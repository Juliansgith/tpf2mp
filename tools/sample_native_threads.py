"""Read-only Windows thread names and CPU-time deltas; no suspension or injection."""
import argparse
import ctypes as c
from ctypes import wintypes as w
import json
import time


class ThreadEntry(c.Structure):
    _fields_ = [('dwSize', w.DWORD), ('cntUsage', w.DWORD), ('threadId', w.DWORD),
                ('ownerPid', w.DWORD), ('basePri', w.LONG), ('deltaPri', w.LONG), ('flags', w.DWORD)]


def snapshot(pid):
    kernel = c.WinDLL('kernel32', use_last_error=True)
    kernel.CreateToolhelp32Snapshot.argtypes = [w.DWORD, w.DWORD]
    kernel.CreateToolhelp32Snapshot.restype = w.HANDLE
    kernel.Thread32First.argtypes = kernel.Thread32Next.argtypes = [w.HANDLE, c.POINTER(ThreadEntry)]
    kernel.OpenThread.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenThread.restype = w.HANDLE
    kernel.GetThreadDescription.argtypes = [w.HANDLE, c.POINTER(c.c_void_p)]
    kernel.GetThreadDescription.restype = w.LONG
    kernel.GetThreadTimes.argtypes = [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.LocalFree.argtypes = [c.c_void_p]
    kernel.LocalFree.restype = c.c_void_p
    handle = kernel.CreateToolhelp32Snapshot(4, 0)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    result = {}
    entry = ThreadEntry()
    entry.dwSize = c.sizeof(entry)
    try:
        valid = kernel.Thread32First(handle, c.byref(entry))
        while valid:
            if entry.ownerPid == pid:
                thread = kernel.OpenThread(0x0800, False, entry.threadId)
                if thread:
                    try:
                        pointer = c.c_void_p()
                        name = ''
                        if kernel.GetThreadDescription(thread, c.byref(pointer)) == 0 and pointer.value:
                            try:
                                name = c.wstring_at(pointer)
                            finally:
                                kernel.LocalFree(pointer)
                        created, exited, kern, user = (w.FILETIME() for _ in range(4))
                        if kernel.GetThreadTimes(thread, c.byref(created), c.byref(exited), c.byref(kern), c.byref(user)):
                            ticks = lambda value: (value.dwHighDateTime << 32) | value.dwLowDateTime
                            result[entry.threadId] = {'name': name, 'created': ticks(created),
                                                      'cpuSeconds': (ticks(kern) + ticks(user)) / 10000000}
                    finally:
                        kernel.CloseHandle(thread)
            valid = kernel.Thread32Next(handle, c.byref(entry))
    finally:
        kernel.CloseHandle(handle)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid', type=int)
    parser.add_argument('--seconds', type=int, default=10, choices=range(1, 46))
    args = parser.parse_args()
    first = snapshot(args.pid)
    if not first:
        raise RuntimeError('No readable threads for the requested process')
    start = time.monotonic()
    time.sleep(args.seconds)
    second = snapshot(args.pid)
    elapsed = time.monotonic() - start
    rows = []
    for tid, end in second.items():
        begin = first.get(tid)
        if begin and begin['created'] == end['created']:
            rows.append({'id': tid, 'name': end['name'],
                         'cpuSeconds': end['cpuSeconds'] - begin['cpuSeconds'],
                         'oneCorePercent': 100 * (end['cpuSeconds'] - begin['cpuSeconds']) / elapsed})
    complete = bool(rows)
    print(json.dumps({'pid': args.pid, 'complete': complete, 'wallSeconds': elapsed, 'threadCountStart': len(first),
                      'threadCountEnd': len(second), 'scope': 'surviving thread CPU deltas; not wall-time attribution or FPS',
                      'threads': sorted(rows, key=lambda row: row['cpuSeconds'], reverse=True)}, indent=2))
    if not complete:
        raise SystemExit('Incomplete sample: no matching threads survived; target may have exited')


if __name__ == '__main__':
    main()
