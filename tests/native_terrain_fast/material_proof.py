"""Compare TPF2MP's fast material-index selection with ORIGINAL executable code, natively.

The stock MaterialIndexManager pixel selection (Steam 35924 RVA
0x315f20..0x3163ba) is self-contained -- no calls, two RIP-relative loads -- so
this proof does not map the whole image like the other three. It copies the
1178 function bytes into a VirtualAlloc'd block and relocates only those two
constants: the 0.25f at 0x2f20a14 and the 63x63 float dither table at
0x2f87d20. The copy then runs beside TPF2MP_TerrainFastTestMaterial from
tpf2mp_hook_build35924.dll and complete output buffers (including the bytes
neither call writes) must be identical. No game process or game file is
touched.

Adapted from silver2127's tpf2-bigmap tools/test_material_index.py
(commit 4f0de6f), MIT licence, Copyright (c) 2026 silver2127. The bigmap
BigmapTest* exports and its Tpf2mpHost seam are replaced by TPF2MP's
TPF2MP_TerrainFastTest* exports and tpf2mp::terrain_fast::Host; the GOG cases
are dropped (TPF2MP pins the Steam build only), "disabled" becomes an empty
feature mask, and each refusal is read back from the error buffer.

  python tests/native_terrain_fast/material_proof.py [--exe EXE] [--dll DLL]
"""
import ctypes as C
import random
import struct
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import harness  # noqa: E402 - sibling module, standard library only

harness.require_dependencies()

import capstone  # noqa: E402 - presence checked above, so the failure is one line
import numpy as np  # noqa: E402
import pefile  # noqa: E402

IMAGE = harness.IMAGE
FUNC, FUNC_END = 0x315f20, 0x3163ba
PROLOGUE = bytes.fromhex('48894c24085556574154415541564157')
QUARTER, DITHER = 0x2f20a14, 0x2f87d20          # 0.25f; 63 x 63 dither thresholds
CONSTANTS = {QUARTER: (0x2000, 4), DITHER: (0x3000, 63 * 63 * 4)}

# TPF2MP_TerrainFastTestInstall bits for the material path
# (native/include/tpf2mp/native_terrain_fast.hpp). harness.py carries the bits
# of the three fast paths that predate it.
FEATURE_MATERIAL, STATUS_MATERIAL = 16, 32

U = C.c_size_t
# (block, tile, job, origin) packed int32 pairs, then overlay/layers/cell/base/output.
ARGS = [C.c_uint64] * 4 + [C.POINTER(U), C.POINTER(C.c_uint8), C.POINTER(C.c_int32),
                           C.POINTER(U), C.POINTER(U)]
FN = C.CFUNCTYPE(None, *ARGS)


def load_stock(pe, k32):
    """Copy the stock routine into this process, relocating its two constants."""
    raw = bytearray(pe.get_data(FUNC, FUNC_END - FUNC))
    if bytes(raw[:16]) != PROLOGUE:
        harness.fail(f'unexpected build: no Build 35924 prologue at {FUNC:#x}')
    dis = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    dis.detail = True
    instructions = list(dis.disasm(bytes(raw), IMAGE + FUNC))
    assert sum(i.size for i in instructions) == len(raw), 'body does not disassemble cleanly'
    assert instructions[-1].mnemonic == 'ret'
    assert not any(i.group(capstone.CS_GRP_CALL) for i in instructions), 'not self-contained'
    block = k32.VirtualAlloc(None, 0x10000, 0x3000, 0x40)
    assert block
    relocated = []
    for ins in instructions:
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
                target = ins.address + ins.size + op.mem.disp - IMAGE
                off, _ = CONSTANTS[target]              # KeyError: an unexpected global read
                pos = ins.address - (IMAGE + FUNC)
                struct.pack_into('<i', raw, pos + ins.disp_offset, off - pos - ins.size)
                relocated.append(target)
        if ins.group(capstone.CS_GRP_JUMP) and ins.operands[0].type == capstone.x86.X86_OP_IMM:
            assert FUNC <= ins.operands[0].imm - IMAGE < FUNC_END, ins   # stays inside the copy
    assert sorted(relocated) == sorted(CONSTANTS), relocated
    for rva, (off, size) in CONSTANTS.items():
        C.memmove(block + off, pe.get_data(rva, size), size)
    C.memmove(block, bytes(raw), len(raw))
    return block, FN(block), C.cast(block + CONSTANTS[DITHER][0], C.POINTER(C.c_float))


def main():
    exe, dll_path = harness.parse_args(__doc__.splitlines()[0])
    pe = pefile.PE(str(exe), fast_load=True)
    k32 = harness.kernel32()
    block, stock, dither = load_stock(pe, k32)
    dll = harness.load_dll(dll_path)
    fast = harness.export(dll, 'TPF2MP_TerrainFastTestMaterial')
    fast.argtypes = [FN, C.POINTER(C.c_float)] + ARGS
    fast.restype = None
    rng = random.Random(35924)
    nrng = np.random.default_rng(35924)

    # One MaterialIndexManager call site's arguments: 40 material layers, each
    # with its own 132x132 float heightmap vector and a material id byte at +12.
    stride = 132
    heightmaps = [nrng.uniform(-.05, 1.05, (stride * stride)).astype(np.float32) for _ in range(40)]
    vectors = [(U * 3)(a.ctypes.data, a.ctypes.data + a.nbytes, a.ctypes.data + a.nbytes)
               for a in heightmaps]
    entries = (C.c_uint8 * (24 * 40))()
    for i, v in enumerate(vectors):
        struct.pack_into('<Q', entries, i * 24, C.addressof(v))
        entries[i * 24 + 12] = [0, 1, 0xe9, 0xff, 17, 93][i % 6]   # 0xe9 is the "keep looking" sentinel
    layers = (C.c_uint8 * 48)()
    struct.pack_into('<Q', layers, 0, C.addressof(entries))
    struct.pack_into('<i', layers, 36, stride)
    overlayData = (C.c_uint8 * 65536)()
    mask = (C.c_uint32 * 2048)()                      # one bit per pixel
    overlay = (U * 6)(C.addressof(overlayData), C.addressof(overlayData) + 65536, 0,
                      C.addressof(mask), 0, 0)
    baseData = (C.c_uint8 * 65536)()
    base = (U * 3)(C.addressof(baseData), C.addressof(baseData) + 65536, 0)
    out1, out2 = (C.c_uint8 * 65536)(), (C.c_uint8 * 65536)()
    output1 = (U * 3)(C.addressof(out1), C.addressof(out1) + 65536, 0)
    output2 = (U * 3)(C.addressof(out2), C.addressof(out2) + 65536, 0)
    cell = (C.c_int32 * 2)(0, 0)
    stats = {'cases': 0}

    def pair(x, y):
        return (x & 0xffffffff) | ((y & 0xffffffff) << 32)

    def run(n, w, h, jx, jy, kind):
        """One comparison; returns the shared arguments for the benchmark."""
        struct.pack_into('<i', layers, 40, n)
        layers[24] = rng.choice([0, 1, 7, 0xe9, 0xff])            # fallback material
        for data in (baseData, overlayData):
            if kind == 'empty':
                C.memset(C.addressof(data), 0, 65536)
            else:
                a = nrng.choice(np.array([0, 0, 0, 0, 1, 0xe9, 0xff, 19], dtype=np.uint8), 65536)
                C.memmove(C.addressof(data), a.ctypes.data, 65536)
        a = nrng.integers(0, 2 ** 32, 2048, dtype=np.uint32)
        C.memmove(C.addressof(mask), a.ctypes.data, a.nbytes)
        overlay[1] = overlay[0] if kind == 'no_overlay' else overlay[0] + 65536
        C.memset(C.addressof(out1), 0x42, 65536)
        C.memset(C.addressof(out2), 0x42, 65536)
        cell[0], cell[1] = rng.randrange(2), rng.randrange(2)
        shift = -2000 if stats['cases'] % 2 else 0                 # also negative tile origins
        args = [pair(w, h), pair(1200 + shift, 1800 + shift), pair(jx, jy),
                pair(31 + shift, 11 + shift), overlay, layers, cell, base]
        stock(*args, output1)
        fast(stock, dither, *args, output2)
        if bytes(out1) != bytes(out2):
            bad = [i for i, (x, y) in enumerate(zip(out1, out2)) if x != y]
            raise AssertionError(dict(n=n, w=w, h=h, jx=jx, jy=jy, kind=kind, count=len(bad),
                                      first=[(i, out1[i], out2[i]) for i in bad[:8]]))
        return args

    # 1. Every batch shape: layer counts around the 8-layer batches and their
    #    9-layer overlap, empty / mixed overlay data, and a missing overlay.
    for n in (-1, 0, 1, 7, 8, 9, 15, 16, 17, 24, 32, 33, 40):
        for kind in ('empty', 'mixed', 'no_overlay'):
            for w, h, jx, jy in [(8, 8, 0, 0), (16, 8, 7, 21), (32, 32, 7, 7), (13, 7, 5, 9)]:
                run(n, w, h, jx, jy, kind)
                stats['cases'] += 1
    print(f"PASS: {stats['cases']} native original-code comparisons; complete output buffers identical")

    # 2. Layer misses exercise every batch and the final fallback, not only top-layer hits.
    for a in heightmaps:
        a.fill(-1.0)
    for n in (1, 8, 9, 16, 17, 33, 40):
        run(n, 16, 16, 4, 9, 'empty')
        stats['cases'] += 1
    print('PASS: all-layer misses, overlapping batch boundaries, fallback and sentinel material IDs')

    # 3. Unsupported geometry and overlapping input/output storage forward the
    #    untouched arguments to the original.
    calls = []

    @FN
    def fallback(*args):
        calls.append(args[:4])
    args = [pair(0, 8), pair(1, 1), pair(0, 0), pair(0, 0), overlay, layers, cell, base, output2]
    fast(fallback, dither, *args)
    assert calls == [tuple(args[:4])], calls
    args[0] = pair(8, 8)                              # supported shape, but output aliases the base
    args[-1] = (U * 3)(base[0], base[1], base[2])
    fast(fallback, dither, *args)
    assert len(calls) == 2 and calls[1] == tuple(args[:4]), calls
    print('PASS: unsupported geometry and overlapping input/output buffers fall back to original')

    # 4. Installer: the prologue, the whole embedded body and the 0.25f
    #    constant are verified against the executable before the hook, and any
    #    mismatch or hook failure refuses with its own text. TPF2MP's seam
    #    passes the context first, takes no steal count (MinHook measures the
    #    prologue itself) and has no log service or GOG build, so those bigmap
    #    checks and cases are gone.
    install = harness.installer(dll)
    expected_verify = [(FUNC, 16), (FUNC, FUNC_END - FUNC), (QUARTER, 4)]
    refusal = {('verify', 0): 'material: prologue mismatch at 0x315f20',
               ('verify', 1): 'material: byte mismatch in the function body at 0x315f20',
               ('verify', 2): 'material: constant mismatch at 0x2f20a14',
               'hook': 'material: hook failed'}
    for failure in ['none', 'disabled', 'hook'] + [('verify', i) for i in range(len(expected_verify))]:
        events, errors = [], []

        @harness.basetype
        def getbase(context):
            return IMAGE

        @harness.verifytype
        def verify(context, rva, ptr, size):
            events.append(('verify', rva, size))
            if C.string_at(ptr, size) != pe.get_data(rva, size):
                errors.append(('bytes', hex(rva), size))
            return failure != ('verify', len(events) - 1)

        @harness.hooktype
        def hook(context, target, detour, original):
            events.append(('hook',))
            if target != IMAGE + FUNC or not detour:
                errors.append('hook')
            original[0] = block
            return failure != 'hook'

        @harness.patchtype
        def patcher(context, rva, ptr, size):
            events.append(('patch', rva, size))        # the material path patches nothing
            return 1
        host = harness.Host(None, getbase, verify, hook, patcher)
        mask_out, error = install(host, 0 if failure == 'disabled' else FEATURE_MATERIAL)
        assert mask_out == (STATUS_MATERIAL if failure == 'none' else 0), (failure, mask_out, error)
        assert not errors, (failure, errors)
        refusals = [part for part in error.split('; ') if part]   # AppendError joins with "; "
        assert refusals == ([] if failure in ('none', 'disabled') else [refusal[failure]]), \
            (failure, error)
        verified = [('verify', r, n) for r, n in expected_verify]
        if failure == 'disabled':
            assert events == [] and error == ''
        elif isinstance(failure, tuple):
            assert events == verified[:failure[1] + 1], (failure, events)
        else:
            assert events == verified + [('hook',)], (failure, events)
    print(f'PASS: installer verifies the 16-byte prologue, all {FUNC_END - FUNC} body bytes and the '
          f'0.25f constant against the executable; an empty feature mask, each mismatch and a hook '
          f'failure refuse without hooking')

    # 5. Warm-cache native microbenchmarks; not an end-to-end game speedup.
    print('--- native micro-benchmarks (warm cache, one core; not an in-game load time) ---')
    for label, fill in (('all layers miss', -1.0), ('top layer hits', 2.0)):
        for a in heightmaps:
            a.fill(fill)
        for i in range(40):
            entries[i * 24 + 12] = 1 + i
        args = run(40, 64, 64, 1, 1, 'empty')
        stats['cases'] += 1
        best = []
        for which in range(2):
            timings = []
            for _ in range(5):
                t = time.perf_counter()
                for _ in range(100):
                    if which == 0:
                        stock(*args, output1)
                    else:
                        fast(stock, dither, *args, output2)
                timings.append((time.perf_counter() - t) / 100)
            best.append(min(timings))
        assert bytes(out1) == bytes(out2)
        print(f'material index 64x64 tile, 40 layers, {label}: stock={best[0] * 1e6:.1f} us '
              f'fast={best[1] * 1e6:.1f} us ratio={best[0] / best[1]:.2f}x')
    k32.VirtualFree(block, 0, 0x8000)


if __name__ == '__main__':
    main()
