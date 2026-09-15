"""Find candidate RIP-relative references for targeted native performance analysis.

Read-only. Raw-pattern candidates are checked with Capstone but still require
confirmation against Ghidra's instruction boundaries. Output never claims heat.
"""
import argparse
import bisect
import json
from pathlib import Path
import re
import sys
import pefile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'runtime/re-tools/capstone'))
from capstone import Cs, CS_ARCH_X86, CS_MODE_64


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('executable', type=Path)
    parser.add_argument('--function-va', action='append', type=lambda value: int(value, 0), default=[])
    parser.add_argument('--string', action='append', default=[],
                        help='restrict string-reference research to these substrings')
    args = parser.parse_args()
    data = args.executable.read_bytes()
    pe = pefile.PE(data=data, fast_load=True)
    pe.parse_data_directories(directories=[1, 3])
    base = pe.OPTIONAL_HEADER.ImageBase
    functions = sorted((entry.struct.BeginAddress, entry.struct.EndAddress)
                       for entry in pe.DIRECTORY_ENTRY_EXCEPTION)
    starts = [begin for begin, end in functions]
    targets = {}
    for address in args.function_va:
        targets[address] = 'function target ' + hex(address)
    for match in re.finditer(rb'[ -~]{8,}', data):
        label = match.group().decode()
        if any(term in label for term in (args.string or (
            'simPersonDestinationRecomputationProbability',
            'ecs::SimPersonSystem::', 'ecs::SimPersonAtTerminalSystem::',
            'ecs::SimPersonCacheSystem::', 'ThreadPool.cpp',
            'PathFinder', 'BuildProposalVisitor'))):
            targets[base + pe.get_rva_from_offset(match.start())] = label
    for library in ([] if args.string else pe.DIRECTORY_ENTRY_IMPORT):
        for item in library.imports:
            if item.name and item.name.decode() in {'malloc', 'calloc', 'realloc', 'HeapAlloc', 'GetProcessHeap', '_aligned_malloc'}:
                targets[item.address] = item.name.decode()
    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    rows = []
    for section in pe.sections:
        if not section.Characteristics & 0x20000000:
            continue
        body = section.get_data()
        # REX.W LEA/MOV reg,[RIP+disp32], CALL [RIP+disp32], or direct CALL rel32.
        for match in re.finditer(rb'(?:[\x48\x4c][\x8d\x8b][\x05\x0d\x15\x1d\x25\x2d\x35\x3d]|\xff\x15|\xe8)[\x00-\xff]{4}', body):
            raw = match.group()
            rva = section.VirtualAddress + match.start()
            address = base + rva
            target = address + len(raw) + int.from_bytes(raw[-4:], 'little', signed=True)
            if target not in targets:
                continue
            instruction = next(decoder.disasm(raw, address), None)
            if instruction is None or instruction.size != len(raw):
                continue
            slot = bisect.bisect_right(starts, rva) - 1
            function = functions[slot] if slot >= 0 and rva < functions[slot][1] else None
            rows.append({'reference': hex(address), 'target': hex(target),
                         'function': hex(base + function[0]) if function else None,
                         'functionBytes': function[1] - function[0] if function else None,
                         'instruction': instruction.mnemonic + ' ' + instruction.op_str,
                         'evidence': targets[target]})
    print(json.dumps({'candidateOnly': True, 'runtimeFunctionCount': len(functions), 'references': rows}, indent=2))


if __name__ == '__main__':
    main()
