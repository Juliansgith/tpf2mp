"""Create a research-only copy with full hardware concurrency for render workers.

This does NOT rebuild the game from decompiled source. It changes one verified
two-byte instruction in a disposable copy of exact Build 35924. Production
launchers still reject its hash. No simulation/construction pool is changed.
"""
import argparse
import hashlib
import json
from pathlib import Path

SUPPORTED_SHA256 = '782b904a8f7bbdac1f7a18528f1a5c778691e5aa3087c37c351bf6912585175c'
PATCH_RVA = 0x32804D
PATCH_OFFSET = PATCH_RVA - 0x1000 + 0x400


def make_variant(original):
    if hashlib.sha256(original).hexdigest() != SUPPORTED_SHA256:
        raise ValueError('Only exact unmodified Build 35924 is accepted')
    if original[PATCH_OFFSET:PATCH_OFFSET + 2] != b'\xd1\xf8':
        raise ValueError('Render-worker division instruction mismatch')
    result = bytearray(original)
    result[PATCH_OFFSET:PATCH_OFFSET + 2] = b'\x90\x90'
    return bytes(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    source, output = args.source.resolve(), args.output.resolve()
    if source == output or not output.name.startswith('TransportFever2_perf_lab') or output.suffix.lower() != '.exe':
        raise ValueError('Output must be a separate TransportFever2_perf_lab*.exe research copy')
    variant = make_variant(source.read_bytes())
    with output.open('xb') as stream:
        stream.write(variant)
    print(json.dumps({'researchOnly': True, 'source': str(source), 'output': str(output),
                      'sourceSha256': SUPPORTED_SHA256,
                      'outputSha256': hashlib.sha256(variant).hexdigest(),
                      'rva': hex(PATCH_RVA), 'fileOffset': hex(PATCH_OFFSET),
                      'before': 'd1f8', 'after': '9090',
                      'effect': 'RenderDataManager Worker Pool: max(1, hardware_concurrency), not half',
                      'productionCompatible': False}, indent=2))


if __name__ == '__main__':
    main()
