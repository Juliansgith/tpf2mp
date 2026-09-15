import base64
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tpf2mp import map_preview as preview, world_generation
from tpf2mp.relay_api import RelayApiError


class MapPreviewTests(unittest.TestCase):
    def test_fixed_bitmap_roundtrip_and_hash_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            raw = b'\x10\x20\x30'*(512*288)
            (root/'raw').write_bytes(raw)
            image = preview.from_file(root/'raw')
            preview.write_bitmap(image, root/'map.bmp')
            self.assertEqual((root/'map.bmp').read_bytes()[54:], raw)
            image['sha256'] = 'f'*64
            with self.assertRaises(RelayApiError): preview.pixels(image)

    def test_remote_decoder_rejects_wrong_shape_size_codec_and_encoding(self):
        image = dict(format='bgr24-512x288', pixels=base64.b64encode(b'a'*preview.PIXEL_BYTES).decode(),
                     sha256=hashlib.sha256(b'a'*preview.PIXEL_BYTES).hexdigest())
        for bad in (None, {}, dict(image, format='png'), dict(image, pixels='!'), dict(image, url='file:///local')):
            with self.subTest(bad_type=type(bad)):
                with self.assertRaises(RelayApiError): preview.pixels(bad)

    def test_native_evidence_pins_request_and_completed_renderer(self):
        encoded = b'TPF2MP_WORLDGEN_1\n7 1950 0 0 1 1 0 0 0\n1\n!tpf2_mp 1\n'
        config = {'world': {'size': 'small', 'seed': 7}}
        with tempfile.TemporaryDirectory() as directory, patch.object(world_generation, 'native_request', return_value=encoded.decode()):
            root = Path(directory)
            (root/'native-request.txt').write_bytes(encoded)
            report = dict(complete=True, exitCode=0, requestSha256=hashlib.sha256(encoded).hexdigest())
            (root/'report.json').write_text(json.dumps(report))
            names = ['native-preview-ready','generator-resource-temperate.gen.lua','native-seed=7',
                     'configured-dimensions-32x32','native-terrain-hilliness=0','native-terrain-water=0','native-terrain-forest=2']
            (root/'native.jsonl').write_text('\n'.join(json.dumps({'event':name}) for name in names))
            (root/'preview-native.rgba').write_bytes(b'native pixels')
            (root/'preview-markers.json').write_bytes(b'[]')
            first = world_generation.verify_preview(config,root,root,root)
            (root/'preview-markers.json').write_bytes(b'[{}]')
            self.assertNotEqual(first, world_generation.verify_preview(config,root,root,root))
            (root/'native-request.txt').write_bytes(encoded+b'altered')
            with self.assertRaises(RelayApiError): world_generation.verify_preview(config,root,root,root)
