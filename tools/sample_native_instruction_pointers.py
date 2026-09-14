"""Intrusive diagnostic for an explicitly disposable x64 game, not an FPS benchmark.

Briefly suspends selected hot threads, reads RIP, immediately resumes in finally.
No memory or register writes. Samples include waiting instructions, not CPU-only
samples or full call stacks. Never run during a comparison benchmark.
"""
import argparse
from collections import Counter
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
from pathlib import Path
import time
from sample_native_threads import snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pid', type=int)
    parser.add_argument('--disposable-benchmark', action='store_true', required=True)
    parser.add_argument('--samples', type=int, choices=range(10, 301), default=100)
    args = parser.parse_args()
    kernel = c.WinDLL('kernel32', use_last_error=True)
    psapi = c.WinDLL('psapi', use_last_error=True)
    for name, restype, argtypes in [
        ('OpenProcess', w.HANDLE, [w.DWORD,w.BOOL,w.DWORD]),
        ('OpenThread', w.HANDLE, [w.DWORD,w.BOOL,w.DWORD]),
        ('CloseHandle', w.BOOL, [w.HANDLE]),
        ('GetProcessIdOfThread', w.DWORD, [w.HANDLE]),
        ('SuspendThread', w.DWORD, [w.HANDLE]),
        ('ResumeThread', w.DWORD, [w.HANDLE]),
        ('GetThreadContext', w.BOOL, [w.HANDLE,c.c_void_p]),
        ('QueryFullProcessImageNameW', w.BOOL, [w.HANDLE,w.DWORD,w.LPWSTR,c.POINTER(w.DWORD)]),
    ]:
        function = getattr(kernel,name); function.restype=restype; function.argtypes=argtypes
    class ModuleInfo(c.Structure):
        _fields_=[('base',c.c_void_p),('size',w.DWORD),('entry',c.c_void_p)]
    psapi.EnumProcessModules.argtypes=[w.HANDLE,c.POINTER(w.HMODULE),w.DWORD,c.POINTER(w.DWORD)]
    psapi.GetModuleInformation.argtypes=[w.HANDLE,w.HMODULE,c.POINTER(ModuleInfo),w.DWORD]
    psapi.GetModuleFileNameExW.argtypes=[w.HANDLE,w.HMODULE,w.LPWSTR,w.DWORD]
    process=kernel.OpenProcess(0x410,False,args.pid)
    if not process: raise c.WinError(c.get_last_error())
    try:
        path=c.create_unicode_buffer(32768); length=w.DWORD(len(path))
        if not kernel.QueryFullProcessImageNameW(process,0,path,c.byref(length)): raise c.WinError(c.get_last_error())
        executable=Path(path.value)
        if executable.name.lower() != 'transportfever2.exe': raise ValueError('Stock game process required')
        if hashlib.sha256(executable.read_bytes()).hexdigest() != '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c':
            raise ValueError('Unpinned game binary')
        modules=(w.HMODULE*2048)(); needed=w.DWORD()
        if not psapi.EnumProcessModules(process,modules,c.sizeof(modules),c.byref(needed)): raise c.WinError(c.get_last_error())
        if needed.value > c.sizeof(modules): raise ValueError('Module list truncated')
        ranges=[]
        for handle in modules[:needed.value//c.sizeof(w.HMODULE)]:
            info=ModuleInfo(); name=c.create_unicode_buffer(32768)
            if psapi.GetModuleInformation(process,handle,c.byref(info),c.sizeof(info)) and psapi.GetModuleFileNameExW(process,handle,name,len(name)):
                ranges.append((info.base,info.size,Path(name.value).name))
        first=snapshot(args.pid); time.sleep(1); second=snapshot(args.pid)
        hot=sorted((tid for tid in second if tid in first and first[tid]['created']==second[tid]['created']),
                   key=lambda tid: second[tid]['cpuSeconds']-first[tid]['cpuSeconds'],reverse=True)[:3]
        results=[]
        for tid in hot:
            thread=kernel.OpenThread(0x80a,False,tid)
            if not thread: continue
            try:
                if kernel.GetProcessIdOfThread(thread)!=args.pid: raise ValueError('Thread owner changed')
                storage=c.create_string_buffer(1248)
                aligned=(c.addressof(storage)+15)&~15
                counts=Counter(); hold=[]
                for _ in range(args.samples):
                    c.c_uint32.from_address(aligned+48).value=0x100001
                    began=time.perf_counter()
                    previous=kernel.SuspendThread(thread)
                    if previous==0xffffffff: raise c.WinError(c.get_last_error())
                    try:
                        if not kernel.GetThreadContext(thread,aligned): raise c.WinError(c.get_last_error())
                        rip=c.c_uint64.from_address(aligned+248).value
                    finally:
                        if kernel.ResumeThread(thread)==0xffffffff: raise c.WinError(c.get_last_error())
                    hold.append((time.perf_counter()-began)*1000)
                    match=next(((name,rip-base) for base,size,name in ranges if base<=rip<base+size),('unknown',rip))
                    counts[match]+=1
                    time.sleep(.02)
                results.append({'thread':tid,'selectionCpuSeconds':second[tid]['cpuSeconds']-first[tid]['cpuSeconds'],
                    'maximumSuspendReadResumeMs':max(hold),'samples':[{'module':m,'rva':hex(r),'count':n} for (m,r),n in counts.most_common()]})
            finally: kernel.CloseHandle(thread)
        print(json.dumps({'pid':args.pid,'scope':'intrusive instruction residency, not CPU profile or call stacks','threads':results},indent=2))
    finally: kernel.CloseHandle(process)


if __name__=='__main__': main()
