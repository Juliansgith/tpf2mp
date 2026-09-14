import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('render_variant', Path(__file__).resolve().parents[1] / 'tools/create_native_render_worker_variant.py')
variant = importlib.util.module_from_spec(spec)
spec.loader.exec_module(variant)


class RenderWorkerVariantTests(unittest.TestCase):
    def image(self, instruction=b'\xd1\xf8'):
        return b'\0' * variant.PATCH_OFFSET + instruction + b'unchanged-tail'

    def test_unknown_binary_rejected(self):
        with self.assertRaisesRegex(ValueError, 'unmodified'):
            variant.make_variant(self.image())

    def test_expected_instruction_checked(self):
        image = self.image(b'\x00\x00')
        with patch.object(variant, 'SUPPORTED_SHA256', hashlib.sha256(image).hexdigest()):
            with self.assertRaisesRegex(ValueError, 'instruction mismatch'):
                variant.make_variant(image)

    def test_only_the_two_expected_bytes_change(self):
        image = self.image()
        with patch.object(variant, 'SUPPORTED_SHA256', hashlib.sha256(image).hexdigest()):
            result = variant.make_variant(image)
        self.assertEqual(len(result), len(image))
        self.assertEqual(result[:variant.PATCH_OFFSET], image[:variant.PATCH_OFFSET])
        self.assertEqual(result[variant.PATCH_OFFSET:variant.PATCH_OFFSET + 2], b'\x90\x90')
        self.assertEqual(result[variant.PATCH_OFFSET + 2:], image[variant.PATCH_OFFSET + 2:])

    def test_existing_output_preserved(self):
        image = self.image()
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'source.exe'
            output = Path(directory) / 'TransportFever2_perf_lab.exe'
            source.write_bytes(image)
            output.write_bytes(b'preserve-me')
            with patch.object(variant, 'SUPPORTED_SHA256', hashlib.sha256(image).hexdigest()), patch('sys.argv', ['variant', str(source), str(output)]):
                with self.assertRaises(FileExistsError):
                    variant.main()
            self.assertEqual(output.read_bytes(), b'preserve-me')

    def test_primary_executable_name_rejected(self):
        with patch('sys.argv', ['variant', 'source.exe', 'TransportFever2.exe']):
            with self.assertRaisesRegex(ValueError, 'separate'):
                variant.main()


if __name__ == '__main__':
    unittest.main()
