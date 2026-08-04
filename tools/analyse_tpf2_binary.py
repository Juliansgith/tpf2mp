"""Small, dependency-light PE/string probe for the pinned Transport Fever 2 build.

This is intentionally a read-only reverse-engineering helper.  It never patches
or launches the executable.  `pefile` is optional but available in the project
workstation's Python installation.
"""

from __future__ import annotations

import argparse
import hashlib
import re
import struct
import sys
from pathlib import Path

import pefile

_LOCAL_CAPSTONE = Path(__file__).resolve().parents[1] / "runtime" / "re-tools" / "capstone"
if _LOCAL_CAPSTONE.exists():
    sys.path.insert(0, str(_LOCAL_CAPSTONE))


DEFAULT_TERMS = (
    "Lua 5.",
    "luaL_newstate",
    "luaL_register",
    "lua_pcall",
    "buildProposal",
    "sendCommand",
    "sendScriptEvent",
    "bookJournalEntry",
    "simPersonAtTerminalSystem",
    "simCargoAtTerminalSystem",
    "getHeightAt",
)


def location(pe: pefile.PE, offset: int) -> str:
    for section in pe.sections:
        start = section.PointerToRawData
        end = start + section.SizeOfRawData
        if start <= offset < end:
            rva = section.VirtualAddress + offset - start
            name = section.Name.rstrip(b"\0").decode("ascii", "replace")
            return f"section={name} file=0x{offset:X} rva=0x{rva:X} va=0x{pe.OPTIONAL_HEADER.ImageBase + rva:X}"
    return f"section=<headers/overlay> file=0x{offset:X}"


def occurrences(data: bytes, needle: bytes) -> list[int]:
    result: list[int] = []
    start = 0
    while True:
        offset = data.find(needle, start)
        if offset < 0:
            return result
        result.append(offset)
        start = offset + 1


def printable_strings(data: bytes, minimum: int = 5):
    expression = re.compile(rb"[\x20-\x7e]{%d,}" % minimum)
    for match in expression.finditer(data):
        yield match.start(), match.group().decode("ascii", "replace")


def runtime_functions(pe: pefile.PE) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    for entry in getattr(pe, "DIRECTORY_ENTRY_EXCEPTION", ()):  # x64 .pdata
        begin = int(entry.struct.BeginAddress)
        end = int(entry.struct.EndAddress)
        if begin < end:
            result.append((begin, end))
    return sorted(result)


def containing_function(functions: list[tuple[int, int]], rva: int) -> tuple[int, int] | None:
    low, high = 0, len(functions)
    while low < high:
        middle = (low + high) // 2
        if functions[middle][0] <= rva:
            low = middle + 1
        else:
            high = middle
    if low:
        candidate = functions[low - 1]
        if candidate[0] <= rva < candidate[1]:
            return candidate
    return None


def find_xrefs(pe: pefile.PE, targets: dict[int, str], context: int) -> None:
    try:
        from capstone import CS_ARCH_X86, CS_MODE_64, Cs
        from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP
    except ImportError as exc:  # pragma: no cover - workstation tooling path
        raise SystemExit(f"Capstone is required for --xref-term: {exc}") from exc

    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    decoder.detail = True
    decoder.skipdata = True
    image_base = pe.OPTIONAL_HEADER.ImageBase
    functions = runtime_functions(pe)
    matches: list[tuple[int, int, str, str]] = []
    # Feeding the complete ~49 MiB .text section to Capstone with detail mode
    # enabled exhausts its internal allocation on this executable. Windows x64
    # publishes function boundaries in .pdata, so scan one runtime function at
    # a time. Besides bounding memory, this starts every decode at a compiler-
    # supplied instruction boundary instead of an arbitrary byte chunk.
    for begin, end in functions:
        code = pe.get_data(begin, end - begin)
        for instruction in decoder.disasm(code, image_base + begin):
            # With skipdata enabled Capstone emits id=0 pseudo-instructions for
            # embedded data / undecodable bytes.  They deliberately have no
            # detail record, so asking for operands raises CS_ERR_SKIPDATA.
            if instruction.id == 0:
                continue
            referenced: set[int] = set()
            for operand in instruction.operands:
                if operand.type == X86_OP_IMM:
                    referenced.add(int(operand.imm))
                elif operand.type == X86_OP_MEM and operand.mem.base == X86_REG_RIP:
                    referenced.add(instruction.address + instruction.size + int(operand.mem.disp))
            for target in referenced:
                if target in targets:
                    matches.append((instruction.address, target, instruction.mnemonic, instruction.op_str))

    for address, target, mnemonic, operands in matches:
        rva = address - image_base
        function = containing_function(functions, rva)
        label = targets[target]
        print(f"\n[xref {label}] instruction=0x{address:X} rva=0x{rva:X} {mnemonic} {operands}")
        if not function:
            continue
        begin, end = function
        print(f"function_rva=0x{begin:X}..0x{end:X} bytes={end - begin}")
        start_rva = max(begin, rva - context)
        end_rva = min(end, rva + context)
        code = pe.get_data(start_rva, end_rva - start_rva)
        for instruction in decoder.disasm(code, image_base + start_rva):
            marker = ">" if instruction.address == address else " "
            print(f"{marker} 0x{instruction.address:X}: {instruction.mnemonic:<8} {instruction.op_str}")
    print(f"\nxrefs_found={len(matches)}")


def disassemble_rva(pe: pefile.PE, rva: int, byte_count: int) -> None:
    try:
        from capstone import CS_ARCH_X86, CS_MODE_64, Cs
    except ImportError as exc:  # pragma: no cover - workstation tooling path
        raise SystemExit(f"Capstone is required for --disasm-rva: {exc}") from exc

    if rva < 0 or byte_count <= 0 or rva + byte_count > pe.OPTIONAL_HEADER.SizeOfImage:
        raise SystemExit("--disasm-rva/--disasm-bytes fall outside the PE image")
    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    decoder.skipdata = True
    code = pe.get_data(rva, byte_count)
    print(f"\n[disassembly rva=0x{rva:X} bytes=0x{byte_count:X}]")
    for instruction in decoder.disasm(code, pe.OPTIONAL_HEADER.ImageBase + rva):
        if instruction.id == 0:
            print(f"  0x{instruction.address:X}: <data>   {instruction.bytes.hex(' ')}")
        else:
            print(
                f"  0x{instruction.address:X}: {instruction.bytes.hex(' '):<34} "
                f"{instruction.mnemonic:<8} {instruction.op_str}"
            )


def dump_pointer_table(pe: pefile.PE, rva: int, count: int) -> None:
    if rva < 0 or count <= 0 or rva + count * 8 > pe.OPTIONAL_HEADER.SizeOfImage:
        raise SystemExit("--pointer-table-rva/--pointer-count fall outside the PE image")
    data = pe.get_data(rva, count * 8)
    if len(data) != count * 8:
        raise SystemExit("could not read the complete pointer table")
    image_base = int(pe.OPTIONAL_HEADER.ImageBase)
    functions = runtime_functions(pe)
    print(f"\n[pointer table rva=0x{rva:X} count={count}]")
    for index, (value,) in enumerate(struct.iter_unpack("<Q", data)):
        target_rva = value - image_base
        function = containing_function(functions, target_rva)
        function_text = f"0x{function[0]:X}..0x{function[1]:X}" if function else "unknown"
        print(
            f"  [{index:02d}] va=0x{value:X} rva=0x{target_rva:X} "
            f"function={function_text}"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("--term", action="append", default=[])
    parser.add_argument("--string-regex", help="case-insensitive regex over printable ASCII strings")
    parser.add_argument("--max-strings", type=int, default=300)
    parser.add_argument("--xref-term", action="append", default=[], help="find executable references to an exact ASCII string")
    parser.add_argument("--xref-va", action="append", default=[], help="find executable references to an absolute VA")
    parser.add_argument("--xref-context", type=lambda value: int(value, 0), default=0x80, help="bytes around each xref")
    parser.add_argument("--disasm-rva", type=lambda value: int(value, 0), help="disassemble from this image-relative address")
    parser.add_argument("--disasm-bytes", type=lambda value: int(value, 0), default=0x100, help="byte count for --disasm-rva")
    parser.add_argument("--pointer-table-rva", type=lambda value: int(value, 0), help="dump an x64 image pointer table")
    parser.add_argument("--pointer-count", type=int, default=0, help="entry count for --pointer-table-rva")
    args = parser.parse_args()

    path = args.executable.resolve()
    data = path.read_bytes()
    pe = pefile.PE(data=data, fast_load=False)
    print(f"path={path}")
    print(f"bytes={len(data)}")
    print(f"sha256={hashlib.sha256(data).hexdigest()}")
    print(f"pe_timestamp=0x{pe.FILE_HEADER.TimeDateStamp:08X}")
    print(f"image_base=0x{pe.OPTIONAL_HEADER.ImageBase:X}")
    print(f"image_size=0x{pe.OPTIONAL_HEADER.SizeOfImage:X}")
    print(f"entry_rva=0x{pe.OPTIONAL_HEADER.AddressOfEntryPoint:X}")

    terms = tuple(args.term) if args.term else DEFAULT_TERMS
    for term in terms:
        print(f"\n[{term}]")
        found = False
        for encoding, needle in (("ascii", term.encode()), ("utf16le", term.encode("utf-16le"))):
            for offset in occurrences(data, needle):
                found = True
                print(f"{encoding} {location(pe, offset)}")
        if not found:
            print("not found")

    if args.string_regex:
        matcher = re.compile(args.string_regex, re.IGNORECASE)
        print(f"\n[strings matching /{args.string_regex}/i]")
        count = 0
        for offset, value in printable_strings(data):
            if matcher.search(value):
                print(f"{location(pe, offset)} {value}")
                count += 1
                if count >= args.max_strings:
                    print(f"... stopped at --max-strings={args.max_strings}")
                    break
        print(f"matches_printed={count}")

    if args.xref_term or args.xref_va:
        targets: dict[int, str] = {}
        for term in args.xref_term:
            for offset in occurrences(data, term.encode()):
                rva = pe.get_rva_from_offset(offset)
                targets[pe.OPTIONAL_HEADER.ImageBase + rva] = term
        for raw in args.xref_va:
            value = int(raw, 0)
            targets[value] = f"VA {value:#x}"
        find_xrefs(pe, targets, args.xref_context)

    if args.disasm_rva is not None:
        disassemble_rva(pe, args.disasm_rva, args.disasm_bytes)
    if args.pointer_table_rva is not None:
        dump_pointer_table(pe, args.pointer_table_rva, args.pointer_count)

    # The first 32 bytes at each executable section are useful when confirming
    # that an RVA was mapped correctly, without attempting disassembly here.
    print("\n[sections]")
    for section in pe.sections:
        name = section.Name.rstrip(b"\0").decode("ascii", "replace")
        characteristics = section.Characteristics
        print(
            f"{name} rva=0x{section.VirtualAddress:X} virtual=0x{section.Misc_VirtualSize:X} "
            f"raw=0x{section.PointerToRawData:X}+0x{section.SizeOfRawData:X} "
            f"execute={bool(characteristics & 0x20000000)} write={bool(characteristics & 0x80000000)}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
