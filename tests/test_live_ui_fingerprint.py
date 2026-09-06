"""Native build/dependency changes must invalidate previously green UI proof."""
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'tools'))
from live_ui.coverage import source_fingerprint


class FingerprintTests(unittest.TestCase):
    def test_native_build_inputs_invalidate_but_generated_outputs_do_not(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            old = source_fingerprint(root)
            for name in ('native/CMakeLists.txt', 'native/third_party/minhook/CMakeLists.txt',
                         'native/third_party/minhook/src/hook.c', 'native/src/bridge.cpp',
                         'native/include/bridge.hpp', 'content/live-ui/bus.json', 'tools/live_ui/runner.py'):
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('first')
                first = source_fingerprint(root)
                self.assertNotEqual(old, first, name)
                path.write_text('second')
                second = source_fingerprint(root)
                self.assertNotEqual(first, second, name)
                old = second
            for name in ('runtime/example.txt', 'native/build/CMakeLists.txt',
                         'tools/__pycache__/runner.pyc', 'docs/evidence.md'):
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('generated')
                self.assertEqual(old, source_fingerprint(root), name)


if __name__ == '__main__': unittest.main()
